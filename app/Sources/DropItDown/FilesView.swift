import SwiftUI
import AppKit

/// Browse the user's MD root tree on the left, preview the selected note
/// on the right. Reads md_root from the user's config.toml.
struct FilesView: View {
    @State private var rootURL: URL?
    @State private var selectedURL: URL?
    @State private var previewContent: String = ""

    var body: some View {
        HSplitView {
            tree
                .frame(minWidth: 220)
            preview
                .frame(minWidth: 360)
        }
        .task {
            rootURL = await loadMDRoot()
        }
    }

    private var tree: some View {
        VStack(alignment: .leading) {
            if let root = rootURL {
                ScrollView {
                    FileNodeView(url: root, selectedURL: $selectedURL)
                        .padding(8)
                }
                .onChange(of: selectedURL) { _, newValue in
                    loadPreview(url: newValue)
                }
            } else {
                Text("Loading…").foregroundStyle(.secondary).padding()
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading) {
            if let url = selectedURL {
                HStack {
                    Text(url.lastPathComponent).font(.headline)
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                }
                .padding(.bottom, 4)
                ScrollView {
                    Text(previewContent)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
            } else {
                Text("Select a note from the tree")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
    }

    private func loadPreview(url: URL?) {
        guard let url = url else {
            previewContent = ""
            return
        }
        previewContent = (try? String(contentsOf: url, encoding: .utf8)) ?? "(could not read)"
    }

    private func loadMDRoot() async -> URL? {
        // Read directly from config.toml. Simple parser since we only need
        // one string field — avoids a TOMLKit dependency.
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DropItDown/config.toml")
        guard let text = try? String(contentsOf: configPath, encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("md_root") {
                if let eq = trimmed.firstIndex(of: "=") {
                    let rhs = trimmed[trimmed.index(after: eq)...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    let expanded = (rhs as NSString).expandingTildeInPath
                    return URL(fileURLWithPath: expanded)
                }
            }
        }
        return nil
    }
}

private struct FileNodeView: View {
    let url: URL
    @Binding var selectedURL: URL?
    @State private var expanded: Bool = true

    var body: some View {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        if isDir {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children, id: \.self) { child in
                    FileNodeView(url: child, selectedURL: $selectedURL)
                        .padding(.leading, 8)
                }
            } label: {
                Label(url.lastPathComponent, systemImage: "folder")
                    .font(.callout)
            }
        } else if url.pathExtension == "md" {
            HStack {
                Image(systemName: "doc.text")
                Text(url.lastPathComponent)
                    .font(.callout)
                Spacer()
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .background(selectedURL == url ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(4)
            .onTapGesture { selectedURL = url }
        }
    }

    private var children: [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { lhs, rhs in
                let lDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if lDir != rDir { return lDir && !rDir }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }
}
