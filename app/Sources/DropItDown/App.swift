import SwiftUI

@main
struct DropItDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Main window opens on user-driven launch (double-click in Finder,
        // or when the app is already running and the user clicks the Dock
        // icon). Drop-on-Dock launches do not surface this window — see
        // AppDelegate.applicationOpenUntitledFile.
        WindowGroup("DropItDown", id: "main") {
            ContentView()
                .environmentObject(delegate.history)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}
