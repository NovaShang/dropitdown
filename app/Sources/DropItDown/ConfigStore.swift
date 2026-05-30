import Foundation

struct AppConfig: Codable {
    var inbox: String
    var archiveRoot: String
    var mdRoot: String
    var classificationMode: String
    var model: String
    var baseURL: String
    var proxyURL: String
    var deviceID: String
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
        case classificationMode = "classification_mode"
        case model
        case baseURL = "base_url"
        case proxyURL = "proxy_url"
        case deviceID = "device_id"
        case hasAPIKey = "has_api_key"
        case maxContentChars = "max_content_chars"
        case cuEndpoint = "cu_endpoint"
        case cuAnalyzerID = "cu_analyzer_id"
        case cuFileTypes = "cu_file_types"
        case hasCUKey = "has_cu_key"
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: AppConfig?
    @Published private(set) var ignorePatterns: [String] = []
    @Published private(set) var rules: [String] = []
    @Published private(set) var loading: Bool = false
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
            self.config = await cfg
            self.ignorePatterns = await pats
            self.rules = await rls
        }
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
        self.config = await cfg
        self.ignorePatterns = await pats
        self.rules = await rls
    }
}
