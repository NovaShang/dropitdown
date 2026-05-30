import SwiftUI
import AppKit

struct RulesView: View {
    @EnvironmentObject var config: ConfigStore

    var body: some View {
        Group {
            if config.rules.isEmpty {
                PlaceholderView(systemImage: "checkmark.shield",
                                title: "No rules yet",
                                subtitle: "Use the Fix… action on a wrong archive and the LLM will record a rule to prevent the same mistake.")
            } else {
                List {
                    SwiftUI.Section {
                        ForEach(Array(config.rules.enumerated()), id: \.offset) { _, rule in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(.tint)
                                    .padding(.top, 2)
                                Text(rule)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        HStack {
                            Text("\(config.rules.count) rule\(config.rules.count == 1 ? "" : "s") learned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath:
                                    NSString("~/Library/Application Support/DropItDown/rules").expandingTildeInPath))
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
