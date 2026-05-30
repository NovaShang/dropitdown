import SwiftUI
import AppKit

/// Browse the markdown vault (md_root) on the left, render the selected
/// note on the right. Mirrors a stripped-down Obsidian/Bear vibe.
struct NotesView: View {
    @EnvironmentObject var config: ConfigStore
    @State private var rootURL: URL?
    @State private var selected: URL?
    @State private var noteText: String = ""

    var body: some View {
        HSplitView {
            tree
                .frame(minWidth: 220, idealWidth: 260)
            preview
                .frame(minWidth: 360)
        }
        .task(id: config.config?.mdRoot) {
            if let path = config.config?.mdRoot {
                rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
        }
        .onChange(of: selected) { _, newValue in
            loadNote(url: newValue)
        }
    }

    private var tree: some View {
        Group {
            if let root = rootURL {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        FileNode(url: root, depth: 0, selected: $selected)
                    }
                    .padding(.vertical, 6)
                }
                .background(.background)
            } else {
                PlaceholderView(systemImage: "folder",
                                title: "No vault configured",
                                subtitle: "Set md_root in Settings.")
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let url = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.tint)
                        Text(url.lastPathComponent).font(.title2.weight(.semibold))
                        Spacer()
                    }
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Divider()
                    MarkdownText(content: noteText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .background(.background)
        } else {
            PlaceholderView(systemImage: "sidebar.right",
                            title: "Select a note",
                            subtitle: "Pick a markdown file from the tree to read it here.")
        }
    }

    private func loadNote(url: URL?) {
        guard let url = url else { noteText = ""; return }
        noteText = (try? String(contentsOf: url, encoding: .utf8)) ?? "(could not read)"
    }
}

private struct FileNode: View {
    let url: URL
    let depth: Int
    @Binding var selected: URL?
    @State private var expanded: Bool = true

    var body: some View {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 12)
                            .foregroundStyle(.secondary)
                        Image(systemName: expanded ? "folder.fill" : "folder")
                            .foregroundStyle(.tint)
                        Text(url.lastPathComponent)
                            .font(.callout)
                        Spacer()
                    }
                    .padding(.leading, CGFloat(depth) * 14 + 8)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(children, id: \.self) { child in
                        FileNode(url: child, depth: depth + 1, selected: $selected)
                    }
                }
            }
        } else if url.pathExtension.lowercased() == "md" {
            Button {
                selected = url
            } label: {
                HStack(spacing: 4) {
                    Spacer().frame(width: 12)
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.callout)
                    Spacer()
                }
                .padding(.leading, CGFloat(depth) * 14 + 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .background(selected == url ? Color.accentColor.opacity(0.18) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
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
