import Foundation

struct AppConfig: Codable {
    var inbox: String
    var archiveRoot: String
    var mdRoot: String
    var dropAction: String
    var launchAtLogin: Bool
    var model: String
    var baseURL: String
    var hasAPIKey: Bool
    var maxContentChars: Int
    var cuEndpoint: String
    var cuAnalyzerID: String
    var cuFileTypes: [String]
    var hasCUKey: Bool

    enum CodingKeys: String, CodingKey {
        case inbox
        case archiveRoot = "archive_root"
        case mdRoot = "md_root"
        case dropAction = "drop_action"
        case launchAtLogin = "launch_at_login"
        case model
        case baseURL = "base_url"
        case hasAPIKey = "has_api_key"
        case maxContentChars = "max_content_chars"
        case cuEndpoint = "cu_endpoint"
        case cuAnalyzerID = "cu_analyzer_id"
        case cuFileTypes = "cu_file_types"
        case hasCUKey = "has_cu_key"
    }

    // Tolerate an older CLI / partial JSON that predates the behavior keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inbox = try c.decode(String.self, forKey: .inbox)
        archiveRoot = try c.decode(String.self, forKey: .archiveRoot)
        mdRoot = try c.decode(String.self, forKey: .mdRoot)
        dropAction = try c.decodeIfPresent(String.self, forKey: .dropAction) ?? "archive"
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        model = try c.decode(String.self, forKey: .model)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        hasAPIKey = try c.decode(Bool.self, forKey: .hasAPIKey)
        maxContentChars = try c.decode(Int.self, forKey: .maxContentChars)
        cuEndpoint = try c.decode(String.self, forKey: .cuEndpoint)
        cuAnalyzerID = try c.decode(String.self, forKey: .cuAnalyzerID)
        cuFileTypes = try c.decode([String].self, forKey: .cuFileTypes)
        hasCUKey = try c.decode(Bool.self, forKey: .hasCUKey)
    }
}

/// The three things a drop can do. Shared by the Behavior settings and the
/// menu-bar drop panel. The raw value is exactly the token the
/// `process`/`copy-md` CLI expects.
enum DropAction: String, CaseIterable, Identifiable {
    case archive
    case noteOnly = "note_only"
    case copyMD = "copy_md"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .archive:  return "Archive"
        case .noteOnly: return "Note only"
        case .copyMD:   return "Copy Markdown"
        }
    }

    var subtitle: String {
        switch self {
        case .archive:  return "Convert, classify, file the original, write a note"
        case .noteOnly: return "Write a note but leave the original in place"
        case .copyMD:   return "Convert to Markdown on the clipboard, save nothing"
        }
    }

    var systemImage: String {
        switch self {
        case .archive:  return "tray.and.arrow.down"
        case .noteOnly: return "note.text"
        case .copyMD:   return "doc.on.clipboard"
        }
    }

    static func from(_ raw: String) -> DropAction { DropAction(rawValue: raw) ?? .archive }
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: AppConfig?
    @Published private(set) var ignorePatterns: [String] = []
    @Published private(set) var rules: [String] = []
    @Published private(set) var loading: Bool = false
    /// True once a config fetch has completed and found no config.toml — the
    /// first-run signal that drives the onboarding wizard.
    @Published private(set) var needsSetup: Bool = false
    /// False until the first fetch returns, so the UI can show a spinner
    /// rather than flashing the onboarding screen on launch.
    @Published private(set) var hasLoadedOnce: Bool = false
    private let runner = PythonRunner()
    private var inflight = false

    func refresh() {
        guard !inflight else { return }
        inflight = true
        loading = true
        Task {
            defer { self.inflight = false; self.loading = false }
            async let cfg = fetchConfig()
            async let pats = fetchIgnore()
            async let rls = fetchRules()
            // Don't clobber a previously-good config with a transient nil (a
            // hiccup in `config show` would otherwise bounce the user to
            // onboarding / "No vault configured").
            if let fetched = await cfg { self.config = fetched }
            self.ignorePatterns = await pats
            self.rules = await rls
            self.needsSetup = (self.config == nil)
            self.hasLoadedOnce = true
        }
    }

    /// Run the non-interactive first-run setup, then reload. Returns true on
    /// success. `dropAction` is a `DropAction.rawValue`.
    @discardableResult
    func setup(archiveRoot: String, mdRoot: String, dropAction: String,
               apiKey: String, launchAtLogin: Bool) async -> Bool {
        var args = ["setup",
                    "--archive-root", archiveRoot,
                    "--md-root", mdRoot,
                    "--drop-action", dropAction]
        if !apiKey.isEmpty {
            args += ["--api-key", apiKey]
        }
        args.append(launchAtLogin ? "--launch-at-login" : "--no-launch-at-login")
        let (_, code) = await runner.runCLI(args)
        await reload()
        return code == 0
    }

    private func fetchConfig() async -> AppConfig? {
        let (out, _) = await runner.runCLI(["config", "show", "--json"])
        guard let data = out.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    private func fetchIgnore() async -> [String] {
        // Read directly from ~/Library/Application Support/DropItDown/ignore
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DropItDown/ignore")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func fetchRules() async -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DropItDown/rules")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
    }

    func setValue(_ key: String, _ value: String) async {
        _ = await runner.runCLI(["config", "set", key, value])
        refresh()
    }

    /// Write several config keys in one shot, then refresh once. Each pair is
    /// `(key, value)`; values are passed straight to `config set`, which is
    /// type-aware for list/int keys. Returns true if every write succeeded.
    @discardableResult
    func save(_ changes: [(String, String)]) async -> Bool {
        guard !changes.isEmpty else { return true }
        var allOK = true
        for (key, value) in changes {
            let (_, code) = await runner.runCLI(["config", "set", key, value])
            if code != 0 { allOK = false }
        }
        await reload()
        return allOK
    }

    /// Reload config synchronously-awaitable (used after a batch save so the
    /// caller can refresh its draft from the persisted result).
    private func reload() async {
        loading = true
        defer { loading = false }
        async let cfg = fetchConfig()
        async let pats = fetchIgnore()
        async let rls = fetchRules()
        if let fetched = await cfg { self.config = fetched }
        self.ignorePatterns = await pats
        self.rules = await rls
        self.needsSetup = (self.config == nil)
        self.hasLoadedOnce = true
    }
}
