import SwiftUI
import AppKit

/// Editable preferences form. Loads the persisted config into a local draft,
/// lets the user change every field, and writes the diff back via
/// `config set` when they hit Save. Secrets (API keys) are write-only: the
/// form shows whether one is set but never displays it.
struct SettingsView: View {
    @EnvironmentObject var config: ConfigStore

    @State private var draft = ConfigDraft()
    @State private var loadedFrom: AppConfig?
    @State private var saving = false
    @State private var savedFlash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if loadedFrom != nil {
                    foldersSection
                    behaviorSection
                    classificationSection
                    visionSection
                    advancedSection
                } else if config.loading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    PlaceholderView(systemImage: "exclamationmark.triangle",
                                    title: "No config found",
                                    subtitle: "Run `dropitdown init` in Terminal to create one.")
                        .frame(minHeight: 320)
                }
            }
            .padding(24)
            .padding(.bottom, 70)
        }
        .background(.background)
        .safeAreaInset(edge: .bottom) {
            if loadedFrom != nil {
                saveBar
            }
        }
        .onAppear(perform: syncDraft)
        .onChange(of: config.config?.inbox) { syncDraft() }
    }

    // MARK: - Draft sync

    private func syncDraft() {
        guard let cfg = config.config else {
            if !config.loading { config.refresh() }
            return
        }
        // Only reset the draft when loading a genuinely different config, so
        // in-progress edits aren't clobbered by a background refresh.
        if loadedFrom == nil {
            draft = ConfigDraft(cfg)
        }
        loadedFrom = cfg
    }

    private var isDirty: Bool {
        guard let cfg = loadedFrom else { return false }
        return !draft.changes(from: cfg).isEmpty
    }

    private func save() {
        guard let cfg = loadedFrom else { return }
        let changes = draft.changes(from: cfg)
        guard !changes.isEmpty else { return }
        let changedKeys = Set(changes.map { $0.0 })
        saving = true
        Task {
            await config.save(changes)
            // Side effects that live outside config.toml:
            if changedKeys.contains("launch_at_login") {
                LoginItem.set(draft.launchAtLogin)
            }
            saving = false
            // Re-baseline the draft against the freshly persisted config.
            if let fresh = config.config {
                loadedFrom = fresh
                draft = ConfigDraft(fresh)
            }
            savedFlash = true
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            savedFlash = false
        }
    }

    private func revert() {
        guard let cfg = loadedFrom else { return }
        draft = ConfigDraft(cfg)
    }

    // MARK: - Sections

    private var foldersSection: some View {
        SettingsGroup(title: "Folders", systemImage: "folder") {
            FolderField(label: "Inbox", path: $draft.inbox)
            FolderField(label: "Archive root", path: $draft.archiveRoot)
            FolderField(label: "Markdown root", path: $draft.mdRoot)
        }
    }

    private var behaviorSection: some View {
        SettingsGroup(title: "Behavior", systemImage: "slider.horizontal.3") {
            FormRow(label: "Drop action") {
                Picker("", selection: $draft.dropAction) {
                    ForEach(DropAction.allCases) { a in
                        Text(a.title).tag(a.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Text(DropAction.from(draft.dropAction).subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $draft.launchAtLogin) {
                Text("Launch at login")
            }
        }
    }

    private var classificationSection: some View {
        SettingsGroup(title: "Classification", systemImage: "brain") {
            FormRow(label: "Endpoint") {
                TextField("https://api.deepseek.com", text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            FormRow(label: "Model") {
                TextField("deepseek-chat", text: $draft.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            SecretField(label: "API key",
                        isSet: loadedFrom?.hasAPIKey ?? false,
                        value: $draft.apiKey)
            helpText("Works with any OpenAI-compatible endpoint (DeepSeek, OpenAI, Claude proxies, …).")
        }
    }

    private var visionSection: some View {
        SettingsGroup(title: "Document Vision (Azure CU)", systemImage: "eye") {
            FormRow(label: "Endpoint") {
                TextField("https://<resource>.cognitiveservices.azure.com", text: $draft.cuEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            FormRow(label: "Analyzer") {
                TextField("prebuilt-read", text: $draft.cuAnalyzerID)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            SecretField(label: "API key",
                        isSet: loadedFrom?.hasCUKey ?? false,
                        value: $draft.cuAPIKey)
            FormRow(label: "File types") {
                TextField("pdf, png, wav  (blank = all)", text: $draft.cuFileTypes)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            helpText("Better extraction for scanned PDFs, images, audio, and video. Leave the endpoint blank to disable.")
        }
    }

    private var advancedSection: some View {
        SettingsGroup(title: "Advanced", systemImage: "wrench.and.screwdriver") {
            FormRow(label: "Content limit") {
                HStack(spacing: 6) {
                    TextField("8000", text: $draft.maxContentChars)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("characters sent to the model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button {
                    openConfigFile()
                } label: {
                    Label("Edit config.toml", systemImage: "doc.text")
                }
                Button {
                    revealAppSupport()
                } label: {
                    Label("Reveal data folder", systemImage: "folder")
                }
            }
            .padding(.top, 4)
            helpText("All preferences live in ~/Library/Application Support/DropItDown.")
        }
    }

    // MARK: - Save bar

    private var saveBar: some View {
        HStack(spacing: 12) {
            if savedFlash {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .transition(.opacity)
            } else if isDirty {
                Text("Unsaved changes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert", action: revert)
                .disabled(!isDirty || saving)
            Button {
                save()
            } label: {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save")
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty || saving)
        }
        .animation(.easeInOut(duration: 0.2), value: savedFlash)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Helpers

    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    private func openConfigFile() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DropItDown/config.toml")
        NSWorkspace.shared.open(url)
    }

    private func revealAppSupport() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DropItDown")
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
}

// MARK: - Draft model

/// A mutable, all-strings copy of the config the form edits. Secrets start
/// empty (the real values are never sent to the UI); a non-empty secret on
/// save overwrites the stored key.
struct ConfigDraft {
    var inbox = ""
    var archiveRoot = ""
    var mdRoot = ""
    var dropAction = "archive"
    var launchAtLogin = false
    var baseURL = ""
    var model = ""
    var apiKey = ""
    var cuEndpoint = ""
    var cuAnalyzerID = ""
    var cuAPIKey = ""
    var cuFileTypes = ""
    var maxContentChars = ""

    init() {}

    init(_ cfg: AppConfig) {
        inbox = cfg.inbox
        archiveRoot = cfg.archiveRoot
        mdRoot = cfg.mdRoot
        dropAction = cfg.dropAction
        launchAtLogin = cfg.launchAtLogin
        baseURL = cfg.baseURL
        model = cfg.model
        cuEndpoint = cfg.cuEndpoint
        cuAnalyzerID = cfg.cuAnalyzerID
        cuFileTypes = cfg.cuFileTypes.joined(separator: ", ")
        maxContentChars = String(cfg.maxContentChars)
        // Secrets intentionally left blank.
    }

    /// Diff this draft against the loaded config, returning `(key, value)`
    /// pairs to pass to `config set`. Only changed fields are emitted;
    /// secrets are emitted only when the user actually typed something.
    func changes(from cfg: AppConfig) -> [(String, String)] {
        var out: [(String, String)] = []
        func add(_ key: String, _ new: String, _ old: String) {
            if new.trimmingCharacters(in: .whitespaces) != old {
                out.append((key, new.trimmingCharacters(in: .whitespaces)))
            }
        }
        add("inbox", inbox, cfg.inbox)
        add("archive_root", archiveRoot, cfg.archiveRoot)
        add("md_root", mdRoot, cfg.mdRoot)
        add("drop_action", dropAction, cfg.dropAction)
        if launchAtLogin != cfg.launchAtLogin {
            out.append(("launch_at_login", launchAtLogin ? "true" : "false"))
        }
        add("base_url", baseURL, cfg.baseURL)
        add("model", model, cfg.model)

        add("cu_endpoint", cuEndpoint, cfg.cuEndpoint)
        add("cu_analyzer_id", cuAnalyzerID, cfg.cuAnalyzerID)
        let normalizedTypes = cfg.cuFileTypes.joined(separator: ", ")
        if cuFileTypes.trimmingCharacters(in: .whitespaces) != normalizedTypes {
            out.append(("cu_file_types", cuFileTypes))
        }
        if maxContentChars != String(cfg.maxContentChars),
           !maxContentChars.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(("max_content_chars", maxContentChars.trimmingCharacters(in: .whitespaces)))
        }

        // Write-only secrets: only when the user typed a value.
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { out.append(("api_key", key)) }
        let cuKey = cuAPIKey.trimmingCharacters(in: .whitespaces)
        if !cuKey.isEmpty { out.append(("cu_api_key", cuKey)) }

        return out
    }
}

// MARK: - Reusable building blocks

private struct SettingsGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// A labelled row with a trailing editable control. The label column is
/// fixed-width so every field lines up.
private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// Editable path field with a Choose… button that opens an NSOpenPanel.
private struct FolderField: View {
    let label: String
    @Binding var path: String

    var body: some View {
        FormRow(label: label) {
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
            path = abbreviateHome(url.path)
        }
    }

    private func abbreviateHome(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

/// Write-only secret field. Shows whether a value is already stored without
/// ever revealing it; typing a new value overwrites on save.
private struct SecretField: View {
    let label: String
    let isSet: Bool
    @Binding var value: String

    var body: some View {
        FormRow(label: label) {
            SecureField(isSet ? "•••••••• (stored — type to replace)" : "Enter key",
                        text: $value)
                .textFieldStyle(.roundedBorder)
            if isSet {
                Label("set", systemImage: "checkmark.seal.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("A key is currently stored")
            }
        }
    }
}
