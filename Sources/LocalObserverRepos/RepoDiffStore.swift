import Foundation

/// Live diffs of the checkouts agents work in, keyed by checkout root so two sessions in one folder share a read.
///
/// Summaries are pulled by whatever shows them: each visible agent row asks every `summaryInterval`, and a root is
/// read at most that often however many rows ask, so nothing runs while no running session is on screen. Full diffs
/// are read only when the diff view opens or refreshes.
@MainActor
public final class RepoDiffStore: ObservableObject {
    public static let shared = RepoDiffStore()

    @Published public private(set) var summaries: [String: RepoDiffSummary] = [:]
    /// Full reads, keyed by `detailKey(root:since:)`.
    @Published public private(set) var details: [String: RepoWorkDiff] = [:]
    @Published public private(set) var loading: Set<String> = []
    /// Roots with a revert running.
    @Published public private(set) var busy: Set<String> = []

    /// How often a checkout's summary is re-read while a running session in it is on screen.
    public static let summaryInterval: TimeInterval = 20

    private var summaryChecked: [String: Date] = [:]
    private var summaryInFlight: Set<String> = []
    private var isDemo = false

    public init() {}

    public static func detailKey(root: String, since: Date?) -> String {
        root + "|" + (since.map { String(Int($0.timeIntervalSince1970)) } ?? "-")
    }

    public func summaryCheckedAt(_ root: String) -> Date? { summaryChecked[root] }

    /// Re-reads a checkout's summary unless it was read within `summaryInterval`.
    public func refreshSummary(root: String, force: Bool = false) {
        guard !isDemo, !root.isEmpty, !summaryInFlight.contains(root) else { return }
        if !force, let last = summaryChecked[root], Date().timeIntervalSince(last) < Self.summaryInterval { return }
        summaryInFlight.insert(root)
        Task { [weak self] in
            let summary = await Task.detached(priority: .utility) { RepoDiff.summary(root) }.value
            guard let self else { return }
            self.summaryInFlight.remove(root)
            self.summaryChecked[root] = Date()
            if self.summaries[root] != summary { self.summaries[root] = summary }
        }
    }

    /// Reads every changed file with its diff, and the commits made since `since`.
    public func loadDetail(root: String, since: Date?) {
        let key = Self.detailKey(root: root, since: since)
        guard !isDemo, !root.isEmpty, !loading.contains(key) else { return }
        loading.insert(key)
        Task { [weak self] in
            let diff = await Task.detached(priority: .userInitiated) { RepoDiff.read(root, since: since) }.value
            guard let self else { return }
            self.loading.remove(key)
            self.details[key] = diff
            // The full read is newer than any summary, so rows catch up at once.
            if let diff {
                self.summaries[root] = diff.summary
                self.summaryChecked[root] = diff.checkedAt
            }
        }
    }

    /// Puts one file back the way HEAD has it, then re-reads. Reports a message and whether it worked.
    public func revert(_ file: RepoDiffFile, root: String, since: Date?, then: @escaping (String, Bool) -> Void) {
        guard !isDemo else { then("Demo data can't be reverted", false); return }
        guard !busy.contains(root) else { return }
        busy.insert(root)
        Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) { RepoDiff.revert(file, in: root) }.value
            guard let self else { return }
            self.busy.remove(root)
            self.loadDetail(root: root, since: since)
            if out.ok {
                then(file.status == .untracked || file.status == .added ? "Moved \(file.name) to the Trash" : "Reverted \(file.name)", true)
            } else {
                then(out.stderr.split(separator: "\n").first.map(String.init) ?? "Couldn't revert \(file.name)", false)
            }
        }
    }

    /// Made-up diffs for the snapshot harness; nothing is read from disk afterwards.
    public func loadDemo(summaries: [String: RepoDiffSummary], details: [String: RepoWorkDiff]) {
        isDemo = true
        self.summaries = summaries
        self.details = details
        for root in summaries.keys { summaryChecked[root] = Date() }
    }
}
