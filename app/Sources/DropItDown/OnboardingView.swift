import AppKit
import SwiftUI

/// First-run setup wizard. Shown by `RootView` when no config.toml exists.
///
/// Kept deliberately small — two real decisions only: the folders, and *where
/// DropItDown lives* (menu bar vs Dock). The drop action defaults to Archive
/// and is left for Settings, so the wizard never has to explain lifecycle or
/// per-drop choices. When it finishes, `config.needsSetup` flips false and
/// `RootView` swaps in the real UI.
struct OnboardingView: View {
    @EnvironmentObject var config: ConfigStore

    @State private var archiveRoot = "~/Documents/Archive"
    @State private var mdRoot = "~/Documents/Notes"
    @State private var menuBarEnabled = true
    @State private var launchAtLogin = false
    @State private var saving = false

    private var canStart: Bool {
        !archiveRoot.trimmingCharacters(in: .whitespaces).isEmpty
            && !mdRoot.trimmingCharacters(in: .whitespaces).isEmpty
            && !saving
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                foldersSection
                homeSection
                quotaNote
                startBar
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)          // center the column
            .padding(.horizontal, 36)
            .padding(.vertical, 40)
        }
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            AppLogoView()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to DropItDown")
                    .font(.largeTitle.weight(.semibold))
                Text("Drop a file, and AI converts, classifies, and files it away.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Folders

    private var foldersSection: some View {
        OnboardingGroup(title: "Where things go", systemImage: "folder") {
            OnboardingFolderRow(label: "Archive", help: "Original files are filed here.",
                                path: $archiveRoot)
            OnboardingFolderRow(label: "Notes", help: "Markdown notes are written here (point it at an Obsidian vault if you like).",
                                path: $mdRoot)
        }
    }

    // MARK: - Where DropItDown lives

    private var homeSection: some View {
        OnboardingGroup(title: "Where to drop files", systemImage: "hand.point.up.left") {
            HomeCard(
                title: "Live in the menu bar",
                badge: "Recommended",
                systemImage: "menubar.rectangle",
                detail: "Always ready in the background. Drop files on the menu-bar icon — hold the drag a moment to choose how to file them.",
                selected: menuBarEnabled
            ) { menuBarEnabled = true }

            HomeCard(
                title: "Just a Dock app",
                badge: nil,
                systemImage: "dock.rectangle",
                detail: "No background app. Drop files on its Dock icon. Tip: keep DropItDown in your Dock so it's always a drop away.",
                selected: !menuBarEnabled
            ) { menuBarEnabled = false }

            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login")
            }
            .padding(.top, 2)
        }
    }

    private var quotaNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Classification is ready out of the box with a free monthly quota — no API key needed. You can switch to your own key later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Start

    private var startBar: some View {
        HStack {
            Spacer()
            Button(action: start) {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Get Started")
                        .frame(minWidth: 110)
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canStart)
        }
    }

    private func start() {
        saving = true
        Task {
            let ok = await config.setup(
                archiveRoot: archiveRoot.trimmingCharacters(in: .whitespaces),
                mdRoot: mdRoot.trimmingCharacters(in: .whitespaces),
                dropAction: "archive",          // sensible default; tweak in Settings
                menuBar: menuBarEnabled,
                launchAtLogin: launchAtLogin
            )
            LoginItem.set(launchAtLogin)
            saving = false
            if ok {
                NotificationCenter.default.post(name: .dropItDownConfigChanged, object: nil)
            }
        }
    }
}

extension Notification.Name {
    /// Posted when the config changes in a way the AppDelegate must react to
    /// (menu-bar vs Dock). The delegate observes this to re-apply mode.
    static let dropItDownConfigChanged = Notification.Name("dropItDownConfigChanged")
    /// Posted to open the AppDelegate-hosted preferences window (reliable in
    /// accessory mode, unlike the SwiftUI Settings scene).
    static let dropItDownOpenSettings = Notification.Name("dropItDownOpenSettings")
}

// MARK: - Building blocks

/// A selectable "where DropItDown lives" card: icon, title (+ optional badge),
/// one-line description, radio dot.
private struct HomeCard: View {
    let title: String
    let badge: String?
    let systemImage: String
    let detail: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.callout.weight(.semibold))
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.tint.opacity(0.15))
                                .clipShape(Capsule())
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(.quaternary.opacity(0.30)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Section container matching the onboarding's spacing / card style.
private struct OnboardingGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
    }
}

/// Folder row with a textfield + Choose… button (a local copy of the
/// Settings folder picker so onboarding is self-contained).
private struct OnboardingFolderRow: View {
    let label: String
    let help: String
    @Binding var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.callout)
                    .frame(width: 64, alignment: .leading)
                TextField("~/…", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button {
                    choose()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Choose a folder")
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 74)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let expanded = (path as NSString).expandingTildeInPath
        if !expanded.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }
        if panel.runModal() == .OK, let url = panel.url {
            let home = NSHomeDirectory()
            path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
    }
}
