import AppKit
import OSLog
import SwiftUI
import UserNotifications

private let log = Logger(subsystem: "app.dropitdown.mac", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    let history = HistoryStore()
    let config = ConfigStore()
    private let runner = PythonRunner()
    private var didLaunchViaDrop = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        log.info("application(_:open:) called with \(urls.count, privacy: .public) urls")
        didLaunchViaDrop = true
        for window in NSApp.windows { window.orderOut(nil) }
        Task { await processDroppedFiles(urls) }
    }

    private func processDroppedFiles(_ urls: [URL]) async {
        let paths = urls.map { $0.path }
        let results = await runner.process(files: paths)
        history.refresh()
        for r in results { await notify(result: r) }
        let hasOpenWindow = NSApp.windows.contains { $0.isVisible }
        if didLaunchViaDrop && !hasOpenWindow {
            NSApp.terminate(nil)
        }
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
