import SwiftUI
import AppKit

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @Binding var searchText: String
    @State private var selectedID: HistoryEntry.ID?
    @State private var fixingEntry: HistoryEntry?

    private var filteredEntries: [HistoryEntry] {
        guard !searchText.isEmpty else { return history.entries }
        let q = searchText.lowercased()
        return history.entries.filter {
            ($0.category?.lowercased().contains(q) ?? false) ||
            ($0.summary?.lowercased().contains(q) ?? false) ||
            URL(fileURLWithPath: $0.archivedPath).lastPathComponent.lowercased().contains(q)
        }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 360, idealWidth: 420)
            detail
                .frame(minWidth: 380)
        }
        .onChange(of: history.entries) { _, entries in
            if selectedID == nil, let first = entries.first {
                selectedID = first.id
            }
        }
        .sheet(item: $fixingEntry) { entry in
            FixSheet(entry: entry) { note in
                Task {
                    let runner = PythonRunner()
                    _ = await runner.runCLI(["fix", "--id", String(entry.id), note])
                    history.refresh()
                }
            }
        }
    }

    private var list: some View {
        Group {
            if filteredEntries.isEmpty {
                EmptyHistoryView()
            } else {
                List(selection: $selectedID) {
                    ForEach(filteredEntries) { entry in
                        HistoryRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu {
                                Button("Show in Finder") { reveal(entry) }
                                if entry.mdPath != nil {
                                    Button("Open Note") { openMD(entry) }
                                }
                                Divider()
                                Button("Fix…") { fixingEntry = entry }
                                Button("Undo Archive", role: .destructive) { undo(entry) }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let entry = filteredEntries.first(where: { $0.id == id }) {
            HistoryDetailView(entry: entry,
                              onReveal: { reveal(entry) },
                              onOpenMD: { openMD(entry) },
                              onFix: { fixingEntry = entry },
                              onUndo: { undo(entry) })
        } else {
            PlaceholderView(systemImage: "doc.text.magnifyingglass",
                            title: "Select an entry",
                            subtitle: "Choose a record to see its details, MD note, and quick actions.")
        }
    }

    private func reveal(_ e: HistoryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.archivedPath)])
    }
    private func openMD(_ e: HistoryEntry) {
        guard let md = e.mdPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: md))
    }
    private func undo(_ e: HistoryEntry) {
        Task {
            let runner = PythonRunner()
            _ = await runner.runCLI(["undo", String(e.id)])
            history.refresh()
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: entry.archivedPath).lastPathComponent)
                    .font(.body)
                    .strikethrough(entry.undone)
                    .lineLimit(1)
                if let s = entry.summary, !s.isEmpty {
                    Text(s)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let cat = entry.category {
                    Text(cat)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundStyle(.tint)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(shortDate(entry.ts))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        let ext = URL(fileURLWithPath: entry.archivedPath).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        case "png", "jpg", "jpeg", "heic", "tiff", "webp", "gif", "bmp": return "photo"
        case "mp3", "wav", "m4a", "aac", "flac": return "waveform"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "zip", "tar", "gz": return "archivebox"
        case "txt", "md", "markdown", "rtf": return "text.alignleft"
        case "json", "xml", "yaml", "yml": return "curlybraces"
        default: return "doc"
        }
    }

    private func shortDate(_ ts: String) -> String {
        let parts = ts.split(separator: "T")
        return String(parts.first ?? "")
    }
}

private struct HistoryDetailView: View {
    let entry: HistoryEntry
    let onReveal: () -> Void
    let onOpenMD: () -> Void
    let onFix: () -> Void
    let onUndo: () -> Void
    @State private var mdContent: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                metadata
                if !mdContent.isEmpty {
                    Divider()
                    notePreview
                }
            }
            .padding(20)
        }
        .background(.background)
        .task(id: entry.id) {
            if let md = entry.mdPath {
                mdContent = (try? String(contentsOf: URL(fileURLWithPath: md), encoding: .utf8)) ?? ""
            } else {
                mdContent = ""
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: entry.archivedPath).lastPathComponent)
                        .font(.title2.weight(.semibold))
                        .strikethrough(entry.undone)
                    if let cat = entry.category {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .imageScale(.small)
                            Text(cat)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                ActionButton(label: "Show in Finder", systemImage: "folder", action: onReveal)
                if entry.mdPath != nil {
                    ActionButton(label: "Open Note", systemImage: "doc.text", action: onOpenMD)
                }
                ActionButton(label: "Fix…", systemImage: "wand.and.stars", action: onFix)
                Spacer()
                Button(action: onUndo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = entry.summary, !s.isEmpty {
                Text(s)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            MetaRow(label: "Archived at", value: entry.archivedPath)
            if let md = entry.mdPath {
                MetaRow(label: "Note at", value: md)
            }
            MetaRow(label: "Originally from", value: entry.sourcePath)
            MetaRow(label: "Created", value: entry.ts)
        }
        .font(.callout)
    }

    private var notePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Note preview", systemImage: "doc.text.below.ecg")
                .font(.headline)
                .foregroundStyle(.secondary)
            MarkdownText(content: mdContent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct MetaRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

private struct ActionButton: View {
    let label: String
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct EmptyHistoryView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No files archived yet")
                .font(.title3)
            Text("Drop a file on the DropItDown icon in your Dock.\nIt will be filed and appear here.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FixSheet: View {
    let entry: HistoryEntry
    var onSubmit: (String) -> Void
    @State private var note: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Correct this archive")
                    .font(.title3.weight(.semibold))
                Text("Tell the LLM what went wrong. It will move the file, update the note, and learn a rule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: entry.archivedPath).lastPathComponent)
                    .font(.callout.weight(.medium))
                if let cat = entry.category {
                    Text("currently in \(cat)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $note)
                .frame(minHeight: 110)
                .padding(8)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .font(.body)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply Fix") {
                    onSubmit(note)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
