import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var configText: String = ""
    @State private var saved: Bool = false

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DropItDown/config.toml")
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("config.toml").font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([configURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }

            TextEditor(text: $configText)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.3))

            HStack {
                if saved { Text("Saved ✓").foregroundStyle(.green).font(.caption) }
                Spacer()
                Button("Reload") { load() }
                Button("Save") { save() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear { load() }
    }

    private func load() {
        configText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        saved = false
    }

    private func save() {
        try? configText.write(to: configURL, atomically: true, encoding: .utf8)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
    }
}
