import SwiftUI
import AppKit

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var selected: HistoryEntry.ID?
    @State private var fixingEntry: HistoryEntry?

    var body: some View {
        VStack {
            HStack {
                Button {
                    history.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Spacer()
                if history.loading {
                    ProgressView().controlSize(.small)
                }
            }

            Table(history.entries, selection: $selected) {
                TableColumn("ID") { e in Text("\(e.id)").monospaced() }.width(40)
                TableColumn("When") { e in Text(short(e.ts)) }.width(80)
                TableColumn("Category") { e in Text(e.category ?? "-") }.width(180)
                TableColumn("File") { e in Text(URL(fileURLWithPath: e.archivedPath).lastPathComponent) }
                TableColumn("Summary") { e in Text(e.summary ?? "") }
            }
            .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
                if let id = ids.first, let entry = history.entries.first(where: { $0.id == id }) {
                    Button("Show in Finder") { reveal(entry) }
                    Button("Open MD note") { openMD(entry) }
                    Divider()
                    Button("Fix…") { fixingEntry = entry }
                    Button("Undo archive", role: .destructive) { undo(entry) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let entry = history.entries.first(where: { $0.id == id }) {
                    reveal(entry)
                }
            }
        }
        .sheet(item: $fixingEntry) { entry in
            FixSheet(entry: entry) { note in
                Task { await runFix(entry: entry, note: note) }
            }
        }
    }

    private func short(_ ts: String) -> String {
        // ISO 8601 → "2026-05-30"
        ts.split(separator: "T").first.map(String.init) ?? ts
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

    private func runFix(entry: HistoryEntry, note: String) async {
        let runner = PythonRunner()
        _ = await runner.runCLI(["fix", "--id", String(entry.id), note])
        history.refresh()
    }
}

private struct FixSheet: View {
    let entry: HistoryEntry
    var onSubmit: (String) -> Void
    @State private var note: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correct #\(entry.id)").font(.headline)
            Text(entry.category ?? "").foregroundStyle(.secondary).font(.caption)
            TextEditor(text: $note)
                .frame(minHeight: 100)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Apply") {
                    onSubmit(note)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
