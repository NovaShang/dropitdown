import AppKit
import Carbon.HIToolbox
import OSLog
import SwiftUI
import UserNotifications

private let log = Logger(subsystem: "app.dropitdown.mac", category: "AppDelegate")

/// How the app presents itself. Decided at launch and re-applied when
/// onboarding finishes.
///
/// - `.menuBar`: resident accessory agent (no Dock icon). A status item is the
///   drop target; the app never auto-quits.
/// - `.onboarding`: no config yet; show the wizard window with a Dock icon.
enum AppMode { case onboarding, menuBar }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    let history = HistoryStore()
    let config = ConfigStore()
    private let runner = PythonRunner()

    private var mode: AppMode = .menuBar
    private var statusController: StatusItemController?

    /// Notification category + action identifiers for the post-archive
    /// feedback affordance: an "undo" button and a free-text "correct" field,
    /// both routing back to the bundled CLI (`undo` / `fix`).
    private static let archivedCategoryID = "archived"
    private static let undoActionID = "undo"
    private static let fixActionID = "fix"

    private static func archivedCategory() -> UNNotificationCategory {
        // A single action shows as a direct button; two or more collapse under
        // a "Options" chevron. We keep the richer one — a one-line correction
        // that also teaches a rule. Undo lives in the History window.
        let fix = UNTextInputNotificationAction(
            identifier: fixActionID,
            title: "Correct…",
            options: [],
            textInputButtonTitle: "Apply",
            textInputPlaceholder: "Where it should go, or what's wrong"
        )
        return UNNotificationCategory(
            identifier: archivedCategoryID,
            actions: [fix],
            intentIdentifiers: [],
            options: []
        )
    }

    /// Number of in-progress drop-processing batches (drives the menu-bar
    /// busy spinner).
    private var activeTasks = 0 {
        didSet {
            guard (oldValue == 0) != (activeTasks == 0) else { return }
            statusController?.setBusy(activeTasks > 0)
        }
    }
    private weak var mainWindow: NSWindow?
    /// Strong ref in menu-bar mode so the single window survives being closed
    /// and can be re-shown when the icon is clicked again (a weak ref would go
    /// nil once SwiftUI drops its own reference on close).
    private var retainedWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Decide the mode before the WindowGroup creates its window, so
        // registerMainWindow() knows whether to reveal or hide it.
        mode = determineMode()
        NSApp.setActivationPolicy(mode == .menuBar ? .accessory : .regular)

        // Take over the open-documents Apple Event before AppKit installs its
        // default handler (which would drive SwiftUI's window machinery on
        // every drop). Kept in all modes so Finder "Open With" still works.
        installOpenDocumentsHandler()
    }

    private func installOpenDocumentsHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installOpenDocumentsHandler()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.archivedCategory()])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Onboarding completion flips the app into menu-bar mode.
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .dropItDownConfigChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(showPreferences),
            name: .dropItDownOpenSettings, object: nil)

        if mode == .menuBar { installStatusItem() }
    }

    // MARK: - Mode

    private func configPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DropItDown/config.toml")
    }

    /// No config file ⇒ onboarding; otherwise the resident menu-bar agent.
    /// (Checked without a subprocess so launch is instant.)
    private func determineMode() -> AppMode {
        FileManager.default.fileExists(atPath: configPath().path) ? .menuBar : .onboarding
    }

    /// Onboarding finished (config.toml now exists) — become the resident
    /// menu-bar agent.
    @objc private func configChanged() {
        let newMode = determineMode()
        guard newMode != mode else { return }
        log.info("mode change \(String(describing: self.mode)) → \(String(describing: newMode))")
        mode = newMode
        if newMode == .menuBar {
            NSApp.setActivationPolicy(.accessory)
            installStatusItem()
        }
    }

    private func installStatusItem() {
        guard statusController == nil else { return }
        let controller = StatusItemController()
        controller.onAction = { [weak self] urls, action in self?.runDrop(urls: urls, action: action) }
        controller.onOpen = { [weak self] in self?.openMainWindow() }
        controller.onSettings = { openSettingsWindow() }
        controller.defaultAction = { [weak self] in self?.currentDefaultAction() ?? .archive }
        controller.install()
        statusController = controller
    }

    private func currentDefaultAction() -> DropAction {
        if let raw = config.config?.dropAction { return DropAction.from(raw) }
        return .archive
    }

    // MARK: - Window

    /// Called by RootView when its hosting NSWindow is installed.
    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        switch mode {
        case .onboarding:
            revealWindow()
        case .menuBar:
            // Resident: keep the window across closes, hidden until summoned.
            window.isReleasedWhenClosed = false
            retainedWindow = window
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    private func revealWindow() {
        guard let window = mainWindow else { return }
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
    }

    /// Menu-bar "Open" — bring the resident window to the front.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Prefer the retained window (menu-bar mode keeps a strong ref so it
        // survives closing).
        let window = mainWindow ?? retainedWindow
        if let window {
            mainWindow = window
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
        }
    }

    private var prefsWindow: NSWindow?

    /// Show our own preferences window hosting the existing PreferencesView.
    /// Bypasses the SwiftUI Settings scene, which doesn't reliably open in
    /// accessory mode.
    @objc private func showPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        if prefsWindow == nil {
            let host = NSHostingController(rootView: PreferencesView().environmentObject(config))
            let window = NSWindow(contentViewController: host)
            window.title = "DropItDown Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            prefsWindow = window
        }
        prefsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Open-documents (Finder "Open With")

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        let urls = Self.fileURLs(from: event)
        guard !urls.isEmpty else { return }
        runDrop(urls: urls, action: nil)   // nil ⇒ configured default action
    }

    private static func fileURLs(from event: NSAppleEventDescriptor) -> [URL] {
        guard let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return [] }
        func url(_ d: NSAppleEventDescriptor) -> URL? {
            guard let coerced = d.coerce(toDescriptorType: typeFileURL) else { return nil }
            return URL(dataRepresentation: coerced.data, relativeTo: nil)
        }
        let count = direct.numberOfItems
        if count == 0 { return [url(direct)].compactMap { $0 } }
        return (1...count).compactMap { direct.atIndex($0).flatMap(url) }
    }

    // MARK: - Running a drop

    /// Entry point for every drop. `action == nil` uses the configured
    /// default. No prompts on the drop path: dropped folders are archived
    /// whole (one folder, one note) — `--folder-mode` on the CLI overrides.
    private func runDrop(urls: [URL], action: DropAction?) {
        let resolved = action ?? currentDefaultAction()
        activeTasks += 1
        Task {
            await processDrop(urls: urls, action: resolved)
            activeTasks -= 1
        }
    }

    private func processDrop(urls: [URL], action: DropAction) async {
        let paths = urls.map(\.path)
        switch action {
        case .archive, .noteOnly:
            let results = await runner.process(files: paths, move: action == .archive,
                                               folderMode: "whole")
            history.refresh()
            for r in results { await notify(result: r) }
        case .copyMD:
            for p in paths { _ = await runner.runCLI(["copy-md", p]) }
            await notifySimple(
                title: "Copied as Markdown",
                body: paths.count == 1
                    ? "\(URL(fileURLWithPath: paths[0]).lastPathComponent) is on the clipboard"
                    : "\(paths.count) items on the clipboard")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
            return false
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { mode == .onboarding }

    // MARK: - Notifications

    private func notify(result: ProcessResult) async {
        let content = UNMutableNotificationContent()
        if result.ok {
            content.title = "DropItDown · \(result.category ?? "")"
            content.body = "\(URL(fileURLWithPath: result.src).lastPathComponent) → \(result.summary ?? "")"
            if result.mdPath != nil {
                content.subtitle = "📋 .md path on clipboard"
            }
            if let id = result.recordID {
                content.userInfo = ["recordID": id]
                content.categoryIdentifier = Self.archivedCategoryID
            }
        } else {
            content.title = "DropItDown failed"
            content.body = "\(URL(fileURLWithPath: result.src).lastPathComponent): \(result.error ?? result.skippedReason ?? "unknown")"
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func notifySimple(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let recordID = info["recordID"] as? Int else { return }
        switch response.actionIdentifier {
        case Self.undoActionID:
            await runRecordAction(["undo", String(recordID)], recordID: recordID, kind: .undo)
        case Self.fixActionID:
            let text = ((response as? UNTextInputNotificationResponse)?.userText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            await runRecordAction(["fix", text, "--id", String(recordID)], recordID: recordID, kind: .fix)
        default:
            await MainActor.run { runner.show(recordID: recordID) }
        }
    }

    private enum RecordAction { case undo, fix }

    /// Run an `undo`/`fix` CLI invocation from a notification action, then post
    /// a confirmation. Counted as a task so the menu-bar spinner reflects it.
    @MainActor
    private func runRecordAction(_ args: [String], recordID: Int, kind: RecordAction) async {
        activeTasks += 1
        let (_, code) = await runner.runCLI(args)
        history.refresh()
        await postActionFollowup(recordID: recordID, kind: kind, ok: code == 0)
        activeTasks -= 1
    }

    @MainActor
    private func postActionFollowup(recordID: Int, kind: RecordAction, ok: Bool) async {
        let content = UNMutableNotificationContent()
        if !ok {
            content.title = "DropItDown"
            content.body = kind == .undo ? "Undo failed" : "Correction failed"
        } else if kind == .undo {
            content.title = "Undone"
            content.body = "Original restored (note kept)"
        } else {
            let entries = await runner.fetchHistory(limit: 100)
            let category = entries.first { $0.id == recordID }?.category
            content.title = "Re-filed"
            content.body = category.map { "Now under \($0) — rule saved" }
                ?? "Updated as you asked — rule saved"
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }
}
