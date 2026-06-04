import Foundation
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "app.dropitdown.mac", category: "LoginItem")

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+) for the
/// "launch at login" preference. Registering adds the .app as a login item;
/// the system handles the rest. Failures are logged, not fatal — the toggle
/// is a convenience, not load-bearing.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let s) where s != .enabled:
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            default:
                break  // already in the desired state
            }
        } catch {
            log.error("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}
