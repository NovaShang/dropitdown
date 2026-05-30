import AppKit
import OSLog
import UserNotifications
import SwiftUI

private let log = Logger(subsystem: "app.dropitdown.mac", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    let history = HistoryStore()
    private let runner = PythonRunner()
    private var didLaunchViaDrop = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("applicationDidFinishLaunching, didLaunchViaDrop=\(self.didLaunchViaDrop)")
        // Request notification permission once on first launch.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // The Dock invokes this when files are dropped on the icon (also when
    // a registered file type is double-clicked in Finder).
    func application(_ application: NSApplication, open urls: [URL]) {
        log.info("application(_:open:) called with \(urls.count, privacy: .public) urls: \(urls.map(\.path), privacy: .public)")
        didLaunchViaDrop = true
        // Hide the main window when launched purely from a drop.
        for window in NSApp.windows {
            window.orderOut(nil)
        }
        Task {
            await processDroppedFiles(urls)
        }
    }

    private func processDroppedFiles(_ urls: [URL]) async {
        let paths = urls.map { $0.path }
        log.info("processDroppedFiles starting for \(paths.count, privacy: .public) files")
        let results = await runner.process(files: paths)
        log.info("processDroppedFiles got \(results.count, privacy: .public) results")

        for r in results {
            history.refresh()
            await notify(result: r)
        }

        // If no main window is open and we launched purely from drop,
        // quit after processing — "use once and die" behavior.
        let hasOpenWindow = NSApp.windows.contains { $0.isVisible }
        if didLaunchViaDrop && !hasOpenWindow {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Notifications

    private func notify(result: ProcessResult) async {
        let content = UNMutableNotificationContent()
        if result.ok {
            content.title = "DropItDown · \(result.category ?? "")"
            content.body = "\(URL(fileURLWithPath: result.src).lastPathComponent) → \(result.summary ?? "")"
            if let id = result.recordID {
                content.userInfo = ["recordID": id]
            }
        } else {
            content.title = "DropItDown failed"
            content.body = "\(URL(fileURLWithPath: result.src).lastPathComponent): \(result.error ?? result.skippedReason ?? "unknown")"
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // Clicking the notification reveals the archived file in Finder.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let recordID = info["recordID"] as? Int else { return }
        await MainActor.run {
            runner.show(recordID: recordID)
        }
    }

    // Foreground delivery — show banner even if app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    // Allow open-untitled (no-arg launch via Dock click → show main window).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return true
    }
}
