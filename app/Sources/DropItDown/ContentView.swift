import SwiftUI

struct ContentView: View {
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        TabView {
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            FilesView()
                .tabItem { Label("Files", systemImage: "folder") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .padding()
        .onAppear {
            history.refresh()
        }
    }
}
