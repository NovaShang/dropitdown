import AppKit
import Carbon.HIToolbox
import OSLog
import SwiftUI
import UserNotifications

private let log = Logger(subsystem: "app.dropitdown.mac", category: "AppDelegate")

/// Process lifecycle per PRD §3.1.
///
/// Unified rule: when the management window is **not** open **and** there are
/// no in-progress tasks, terminate immediately. Two flows fall out of it:
///
/// - Drop flow: a drop wakes the process. The auto-created window is kept
///   hidden, files are processed, and once the queue drains (and no window
///   was opened meanwhile) the app quits.
/// - Management flow: launching from the Dock (or clicking the Dock icon
///   mid-processing) shows the main window, which then persists. Closing it
///   quits once any running tasks finish.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    let history = HistoryStore()
    let config = ConfigStore()
    private let runner = PythonRunner()

    /// Number of in-progress drop-processing batches.
    private var activeTasks = 0
    /// A drop initiated this launch — run headless and quit when done.
    private var launchedViaDrop = false
    /// The management window is up (normal launch, or surfaced via the Dock).
    /// This is the single source of truth for "is the main window open": the
    /// app stays alive while it's true, and quits when it goes false with no
    /// tasks left.
    private var managementActive = false
    /// The WindowGroup's NSWindow, handed over by `WindowAccessor` in RootView
    /// so we can show/hide it and watch it close — without confusing it for
    /// the Settings window.
    private weak var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Take over the open-documents Apple Event *before* AppKit installs
        // its default handler. AppKit's default not only calls
        // application(_:open:) but also drives SwiftUI's window machinery,
        // which closes/cycles the main window on every drop — breaking the
        // management flow. Handling the event ourselves keeps file opens
        // entirely decoupled from the window.
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
        // Re-assert our handler in case AppKit replaced it during launch.
        installOpenDocumentsHandler()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    /// Called by RootView the moment its hosting NSWindow is installed. With
    /// the open-documents event handled ourselves, SwiftUI only ever creates
    /// a window for a *management* launch (a plain launch, or a Dock reopen) —
    /// never for a headless drop. So this firing is the deterministic signal
    /// that we're in management mode; reveal the window and stay alive.
    ///
    /// The `launchedViaDrop && !managementActive` branch is defensive: if a
    /// stray auto-window ever did appear during a headless drop, keep it
    /// hidden (transparent + off-screen, so no flash) and let the app quit.
    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        if launchedViaDrop && !managementActive {
            window.alphaValue = 0
            window.orderOut(nil)
        } else {
            managementActive = true
            revealWindow()
        }
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        let urls = Self.fileURLs(from: event)
        guard !urls.isEmpty else { return }
        // If no management window is up, this is a cold/headless drop launch.
        if !managementActive { launchedViaDrop = true }
        // Warm drop (management window already up): leave the window alone.
        beginTask(urls)
    }

    /// Pull file URLs out of an `kAEOpenDocuments` event's direct object,
    /// whether it's a single descriptor or a list.
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

    private func revealWindow() {
        guard let window = mainWindow else { return }
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
    }

    private func beginTask(_ urls: [URL]) {
        activeTasks += 1
        Task {
            await processDroppedFiles(urls)
            activeTasks -= 1
            evaluateTermination()
        }
    }

    private func processDroppedFiles(_ urls: [URL]) async {
        let paths = urls.map { $0.path }
        let results = await runner.process(files: paths)
        history.refresh()
        for r in results { await notify(result: r) }
    }

    /// The PRD §3.1 rule, evaluated at every transition (task finished,
    /// window closed).
    private func evaluateTermination() {
        if activeTasks == 0 && !managementActive {
            log.info("no tasks, no window — terminating")
            NSApp.terminate(nil)
        }
    }

    @objc private func mainWindowWillClose(_ note: Notification) {
        guard let closed = note.object as? NSWindow, closed === mainWindow else { return }
        managementActive = false
        // Let the close settle before deciding (a task may still be running,
        // in which case we wait for it to finish instead).
        DispatchQueue.main.async { [weak self] in self?.evaluateTermination() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Dock click while running headless → surface the management window.
            managementActive = true
            NSApp.activate(ignoringOtherApps: true)
            if mainWindow != nil {
                revealWindow()
                return false  // we revealed the existing (hidden) window
            }
            // Headless drop launch created no window — let AppKit make one
            // (applicationShouldOpenUntitledFile). registerMainWindow reveals
            // it because managementActive is now true.
            return true
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Termination is governed by evaluateTermination() so we can wait for
        // in-flight tasks before quitting.
        false
    }

    private func notify(result: ProcessResult) async {
        let content = UNMutableNotificationContent()
        if result.ok {
            content.title = "DropItDown · \(result.category ?? "")"
            content.body = "\(URL(fileURLWithPath: result.src).lastPathComponent) → \(result.summary ?? "")"
            if let id = result.recordID { content.userInfo = ["recordID": id] }
        } else {
            content.title = "DropItDown failed"
            content.body = "\(URL(fileURLWithPath: result.src).lastPathComponent): \(result.error ?? result.skippedReason ?? "unknown")"
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let recordID = info["recordID"] as? Int else { return }
        await MainActor.run { runner.show(recordID: recordID) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
}
