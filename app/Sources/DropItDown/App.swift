import SwiftUI

@main
struct DropItDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(delegate.history)
                .environmentObject(delegate.config)
                .frame(minWidth: 900, minHeight: 600)
                .navigationTitle("")
                .background(WindowAccessor { delegate.registerMainWindow($0) })
        }
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentSize)
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Route the standard Settings… item (⌘,) to our own window — the
            // SwiftUI Settings scene doesn't open reliably in accessory mode.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Multi-tab preferences window (Cmd+,). Bundles classification config
/// with the ignore-pattern list and the LLM-learned rules — those are
/// configuration concerns, not main navigation.
struct PreferencesView: View {
    @EnvironmentObject var config: ConfigStore

    var body: some View {
        TabView {
            SettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            IgnoreView()
                .tabItem { Label("Ignore", systemImage: "line.3.horizontal.decrease") }
            RulesView()
                .tabItem { Label("Rules", systemImage: "checkmark.shield") }
        }
        .frame(width: 640, height: 620)
    }
}
