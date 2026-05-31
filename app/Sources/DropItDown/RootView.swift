import SwiftUI
import AppKit

/// Open the Settings scene via AppKit. `@Environment(\.openSettings)` only
/// exists in newer SDKs (it fails to compile against the macOS 14 SDK CI
/// uses), so go through the responder chain — `showSettingsWindow:` on
/// macOS 13+, falling back to the old `showPreferencesWindow:` name.
@MainActor
func openSettingsWindow() {
    if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

enum Tab: Hashable, CaseIterable {
    case history
    case notes

    var label: String {
        switch self {
        case .history: return "History"
        case .notes:   return "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .notes:   return "doc.text"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var config: ConfigStore
    @State private var tab: Tab = .history
    @State private var searchText: String = ""

    var body: some View {
        Group {
            switch tab {
            case .history: HistoryView(searchText: $searchText)
            case .notes:   NotesView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    AppLogoView()
                        .frame(width: 22, height: 22)
                    Text("DropItDown")
                        .font(.headline)
                }
                .padding(.trailing, 8)
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Label(t.label, systemImage: t.systemImage)
                            .labelStyle(.titleAndIcon)
                            .tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            // Gear + search live in one trailing group so they sit flush
            // against each other — no stray gap between them.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings (⌘,)")

                if tab == .history {
                    SearchField(text: $searchText, prompt: "Search history")
                        .frame(width: 200)
                }
            }
        }
        .task {
            history.refresh()
            config.refresh()
        }
    }
}

/// Native `NSSearchField` wrapped for SwiftUI so we can place it inside a
/// toolbar group next to other controls (SwiftUI's `.searchable` always
/// floats to the far edge with its own spacing, which left an awkward gap).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String = "Search"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}
