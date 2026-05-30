import SwiftUI

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
    @Environment(\.openSettings) private var openSettings
    @State private var tab: Tab = .history

    var body: some View {
        Group {
            switch tab {
            case .history: HistoryView()
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .task {
            history.refresh()
            config.refresh()
        }
    }
}
