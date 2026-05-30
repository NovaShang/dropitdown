import SwiftUI
import AppKit

struct IgnoreView: View {
    @EnvironmentObject var config: ConfigStore

    var body: some View {
        Group {
            if config.ignorePatterns.isEmpty {
                PlaceholderView(systemImage: "line.3.horizontal.decrease",
                                title: "No ignore patterns",
                                subtitle: "These let the LLM see only the parts of your archive that matter. Run `dropitdown clean` to populate.")
            } else {
                List {
                    SwiftUI.Section {
                        ForEach(config.ignorePatterns, id: \.self) { pattern in
                            HStack(spacing: 10) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .foregroundStyle(.tertiary)
                                Text(pattern)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        HStack {
                            Text("\(config.ignorePatterns.count) patterns active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath:
                                    NSString("~/Library/Application Support/DropItDown/ignore").expandingTildeInPath))
                            } label: {
                                Label("Edit file", systemImage: "pencil")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}
