import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: Int
    let ts: String
    let sourcePath: String
    let archivedPath: String
    let mdPath: String?
    let category: String?
    let summary: String?
    let undone: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case ts
        case sourcePath = "source_path"
        case archivedPath = "archived_path"
        case mdPath = "md_path"
        case category
        case summary
        case undone
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var loading: Bool = false
    private let runner = PythonRunner()
    /// Hard gate to prevent concurrent fetches. SwiftUI's WindowGroup
    /// fires `.onAppear` multiple times during launch animations; without
    /// this gate we'd spawn 2-3 redundant subprocesses that race on the
    /// SQLite journal.
    private var inflight = false

    func refresh(limit: Int = 100) {
        guard !inflight else { return }
        inflight = true
        loading = true
        Task {
            defer {
                self.inflight = false
                self.loading = false
            }
            self.entries = await runner.fetchHistory(limit: limit)
        }
    }
}
