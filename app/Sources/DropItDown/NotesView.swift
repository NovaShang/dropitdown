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
            // Header stays fixed; the body owns its own scrolling so we can
            // swap in a TextKit view for heavy notes without nesting scrolls.
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.tint)
                    Text(url.lastPathComponent).font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                    .help("Open in your default editor")
                }
                Text(url.deletingLastPathComponent().path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Divider()
                NoteReader(content: noteText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .padding(20)
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

/// Renders a note's body, picking the safe renderer for its size. Small
/// notes get pretty MarkdownUI in a SwiftUI ScrollView; large notes (PDF
/// dumps can be hundreds of KB) get a TextKit `NSTextView`, which renders
/// arbitrarily long text without the deep `Text` concatenation that
/// overflows the stack in MarkdownUI.
private struct NoteReader: View {
    let content: String

    var body: some View {
        let stripped = MarkdownText.stripFrontmatter(content)
        if NoteReader.isHeavy(stripped) {
            PlainNoteText(text: stripped)
        } else {
            ScrollView {
                MarkdownText(content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
            }
        }
    }

    /// Conservative ceiling well under MarkdownUI's stack-overflow point.
    /// Either a large byte count or many lines (which become many
    /// concatenated `Text` nodes within a paragraph) trips the fallback.
    static func isHeavy(_ body: String) -> Bool {
        if body.utf16.count > 16_000 { return true }
        var newlines = 0
        for ch in body where ch == "\n" {
            newlines += 1
            if newlines > 700 { return true }
        }
        return false
    }
}

/// Read-only, selectable TextKit view for large notes. NSTextView streams
/// huge documents efficiently and scrolls itself.
private struct PlainNoteText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 0, height: 4)
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        tv.scroll(.zero)
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
