import AppKit
import SwiftUI

/// First-run setup wizard. Shown by `RootView` when no config.toml exists.
///
/// Kept deliberately small — the folders, and an optional API key for AI
/// filing. The drop action defaults to Archive and is left for Settings.
/// When it finishes, `config.needsSetup` flips false and `RootView` swaps in
/// the real UI; the app becomes the resident menu-bar agent.
struct OnboardingView: View {
    @EnvironmentObject var config: ConfigStore

    @State private var archiveRoot = "~/Documents/Archive"
    @State private var mdRoot = "~/Documents/Notes"
    @State private var apiKey = ""
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
                keySection
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

    // MARK: - AI key (BYOK)

    private var keySection: some View {
        OnboardingGroup(title: "AI filing — bring your own key", systemImage: "sparkles") {
            // Set expectations up front: filing needs a key; the local
            // Copy-as-Markdown action doesn't. DropItDown never hosts a model.
            Text("**Filing runs on your own API key** — DropItDown never hosts a model. Without a key you can still drop a file to *Copy as Markdown* (a free, local conversion), but sorting files into folders needs one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text("API key")
                    .font(.callout)
                    .frame(width: 64, alignment: .leading)
                SecureField("sk-…  (DeepSeek or any OpenAI-compatible key)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }

            HStack(spacing: 6) {
                Image(systemName: apiKey.isEmpty ? "info.circle" : "checkmark.circle.fill")
                    .foregroundStyle(apiKey.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                if apiKey.isEmpty {
                    Text("No key yet? Filing stays off until you add one in Settings.")
                        .foregroundStyle(.secondary)
                    Link("Get a DeepSeek key →", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                } else {
                    Text("AI filing is ready. Endpoint and model are changeable in Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.leading, 74)

            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login")
            }
            .padding(.top, 4)
        }
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
                apiKey: apiKey.trimmingCharacters(in: .whitespaces),
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
