import AppKit
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
    /// The management window is in play (normal launch, or surfaced via the
    /// Dock). While true, the app stays alive even with no tasks.
    private var uiEstablished = false
    /// The WindowGroup's NSWindow, handed over by `WindowAccessor` in RootView
    /// so we can show/hide it and watch it close — without confusing it for
    /// the Settings window.
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // A drop is delivered during launch (before this runloop turn ends),
        // so by the next turn we know whether this was a plain launch. If it
        // wasn't a drop, the window SwiftUI already showed is the management
        // window and should stay.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.launchedViaDrop {
                self.uiEstablished = true
            }
        }
    }

    /// Called by RootView once its hosting NSWindow exists.
    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        // If the window materialized during a headless drop launch, keep it
        // off-screen until the user explicitly asks for it.
        if launchedViaDrop && !uiEstablished {
            window.orderOut(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        log.info("open: \(urls.count, privacy: .public) url(s)")
        if !uiEstablished {
            // Cold drop launch: run headless, suppress the auto window.
            launchedViaDrop = true
            mainWindow?.orderOut(nil)
        }
        // Warm drop (management window already up): leave the window alone.
        beginTask(urls)
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
        if activeTasks == 0 && !isMainWindowVisible {
            log.info("no tasks, no window — terminating")
            NSApp.terminate(nil)
        }
    }

    private var isMainWindowVisible: Bool {
        mainWindow?.isVisible ?? false
    }

    @objc private func mainWindowWillClose(_ note: Notification) {
        guard let closed = note.object as? NSWindow, closed === mainWindow else { return }
        uiEstablished = false
        // Let the close settle before deciding (a task may still be running,
        // in which case we wait for it to finish instead).
        DispatchQueue.main.async { [weak self] in self?.evaluateTermination() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Dock click while running headless → surface the management window.
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            uiEstablished = true
            return false  // handled — don't let AppKit spawn a second window
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
