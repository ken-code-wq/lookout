import Foundation
import Combine

/// Where the GitHub page is: the repository list when the path is empty, else a repository tab or a pull request.
public enum GHRoute: Hashable, Sendable {
    case repo(String, GHRepoTab)
    case pull(String, Int)

    public var slug: String {
        switch self {
        case .repo(let slug, _), .pull(let slug, _): return slug
        }
    }
}

public enum GHRepoTab: String, CaseIterable, Identifiable, Sendable {
    case code = "Code"
    case pulls = "Pull requests"
    case branches = "Branches"
    case commits = "Commits"
    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .pulls: return "arrow.triangle.pull"
        case .branches: return "arrow.triangle.branch"
        case .commits: return "clock.arrow.circlepath"
        }
    }
}

public enum GHPullTab: String, CaseIterable, Identifiable, Sendable {
    case conversation = "Conversation"
    case commits = "Commits"
    case checks = "Checks"
    case files = "Files changed"
    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .conversation: return "bubble.left.and.bubble.right"
        case .commits: return "smallcircle.filled.circle"
        case .checks: return "checklist"
        case .files: return "doc.text"
        }
    }
}

/// The "Type" filter on GitHub's repository list.
public enum GHRepoFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case sources = "Sources"
    case forks = "Forks"
    case publicOnly = "Public"
    case privateOnly = "Private"
    case archived = "Archived"
    case templates = "Templates"
    public var id: String { rawValue }

    public func matches(_ repo: GHRepository) -> Bool {
        switch self {
        case .all: return true
        case .sources: return !repo.isFork
        case .forks: return repo.isFork
        case .publicOnly: return !repo.isPrivate
        case .privateOnly: return repo.isPrivate
        case .archived: return repo.isArchived
        case .templates: return repo.isTemplate
        }
    }
}

public enum GHRepoSort: String, CaseIterable, Identifiable, Sendable {
    case pushed = "Last updated"
    case name = "Name"
    case stars = "Stars"
    public var id: String { rawValue }
}

/// GitHub as GitHub shows it: your repositories, and for each one its README, branches, pull requests and commits,
/// down to a pull request's conversation, checks and diff. Everything is fetched on demand and kept for the session;
/// reopening a page shows the last copy at once and refreshes it behind.
@MainActor
public final class GitHubStore: ObservableObject {
    public static let shared = GitHubStore()

    @Published public private(set) var repositories: [GHRepository] = []
    @Published public private(set) var lastRepositories: Date?
    @Published public var path: [GHRoute] = []

    @Published public private(set) var details: [String: GHRepoDetail] = [:]
    @Published public private(set) var branches: [String: [GHBranch]] = [:]
    @Published public private(set) var openPulls: [String: [GHPullSummary]] = [:]
    @Published public private(set) var closedPulls: [String: [GHPullSummary]] = [:]
    /// Keyed `slug@branch`.
    @Published public private(set) var commits: [String: [GHCommit]] = [:]
    /// Keyed `slug#number`.
    @Published public private(set) var pulls: [String: GHPullDetail] = [:]
    @Published public private(set) var files: [String: [GHFile]] = [:]

    /// Load keys with a request in flight.
    @Published public private(set) var loading: Set<String> = []
    @Published public private(set) var errors: [String: String] = [:]
    /// Pull requests and branches with an action (merge, review, delete…) in flight, by load key.
    @Published public private(set) var working: Set<String> = []

    // Repository list controls.
    @Published public var query = ""
    @Published public var filter: GHRepoFilter = .all
    @Published public var sort: GHRepoSort = .pushed
    @Published public var language: String?

    /// Result of an action, for the app to show as a toast: message, succeeded.
    public var onActionResult: ((String, Bool) -> Void)?

    private var isDemo = false
    private var fetched: [String: Date] = [:]
    /// A page shown again within this long isn't refetched.
    public static let freshness: TimeInterval = 60

    public init() {}

    // MARK: Keys

    public static func repoKey(_ slug: String) -> String { "repo:\(slug)" }
    public static func branchesKey(_ slug: String) -> String { "branches:\(slug)" }
    public static func pullsKey(_ slug: String, open: Bool) -> String { "pulls:\(slug):\(open ? "open" : "closed")" }
    public static func commitsKey(_ slug: String, branch: String) -> String { "\(slug)@\(branch)" }
    public static func pullKey(_ slug: String, _ number: Int) -> String { "\(slug)#\(number)" }
    public static func filesKey(_ slug: String, _ number: Int) -> String { "files:\(slug)#\(number)" }
    static let repositoriesKey = "repositories"

    public func isLoading(_ key: String) -> Bool { loading.contains(key) }
    public func error(_ key: String) -> String? { errors[key] }

    // MARK: Navigation

    public var route: GHRoute? { path.last }

    public func open(_ route: GHRoute) {
        // Switching tabs within a repository replaces the top entry rather than stacking every tab visited.
        if case .repo(let slug, _) = route, case .repo(let top, _)? = path.last, top == slug {
            path[path.count - 1] = route
        } else {
            path.append(route)
        }
    }

    public func back() { if !path.isEmpty { path.removeLast() } }
    public func home() { path = [] }

    // MARK: Loading

    /// Runs `work` off the main thread and stores its result under `key`, unless a recent copy exists.
    private func load<T: Sendable>(_ key: String, force: Bool, store: @escaping (GitHubStore, T) -> Void,
                                   _ work: @escaping @Sendable () -> Result<T, GitHubAPI.Failure>) {
        guard !isDemo, !loading.contains(key) else { return }
        if !force, let at = fetched[key], Date().timeIntervalSince(at) < Self.freshness { return }
        loading.insert(key)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { work() }.value
            guard let self else { return }
            self.loading.remove(key)
            switch result {
            case .success(let value):
                store(self, value)
                self.errors[key] = nil
                self.fetched[key] = Date()
            case .failure(let failure):
                self.errors[key] = failure.message
            }
        }
    }

    public func loadRepositories(force: Bool = false) {
        load(Self.repositoriesKey, force: force, store: { s, v in s.repositories = v; s.lastRepositories = Date() }) {
            GitHubAPI.repositories()
        }
    }

    public func loadDetail(_ slug: String, force: Bool = false) {
        load(Self.repoKey(slug), force: force, store: { s, v in s.details[slug] = v }) { GitHubAPI.detail(slug) }
    }

    public func loadBranches(_ slug: String, force: Bool = false) {
        let base = defaultBranch(slug)
        load(Self.branchesKey(slug), force: force, store: { s, v in s.branches[slug] = v }) {
            GitHubAPI.branches(slug, defaultBranch: base)
        }
    }

    public func loadPulls(_ slug: String, open: Bool, force: Bool = false) {
        load(Self.pullsKey(slug, open: open), force: force, store: { s, v in
            if open { s.openPulls[slug] = v } else { s.closedPulls[slug] = v }
        }) { GitHubAPI.pulls(slug, open: open) }
    }

    public func loadCommits(_ slug: String, branch: String, force: Bool = false) {
        let key = Self.commitsKey(slug, branch: branch)
        load(key, force: force, store: { s, v in s.commits[key] = v }) { GitHubAPI.commits(slug, branch: branch) }
    }

    public func loadPull(_ slug: String, _ number: Int, force: Bool = false) {
        let key = Self.pullKey(slug, number)
        load(key, force: force, store: { s, v in s.pulls[key] = v }) { GitHubAPI.pull(slug, number: number) }
    }

    public func loadFiles(_ slug: String, _ number: Int, force: Bool = false) {
        let key = Self.filesKey(slug, number)
        load(key, force: force, store: { s, v in s.files[key] = v }) { GitHubAPI.files(slug, number: number) }
    }

    /// Reloads whatever the current page shows.
    public func refreshCurrent() {
        switch route {
        case nil:
            loadRepositories(force: true)
        case .repo(let slug, let tab):
            loadDetail(slug, force: true)
            switch tab {
            case .code: break
            case .pulls: loadPulls(slug, open: true, force: true); loadPulls(slug, open: false, force: true)
            case .branches: loadBranches(slug, force: true)
            case .commits: loadCommits(slug, branch: defaultBranch(slug), force: true)
            }
        case .pull(let slug, let number):
            loadPull(slug, number, force: true)
            loadFiles(slug, number, force: true)
        }
    }

    public var isLoadingCurrent: Bool {
        switch route {
        case nil: return loading.contains(Self.repositoriesKey)
        case .repo(let slug, _), .pull(let slug, _): return loading.contains { $0.contains(slug) }
        }
    }

    // MARK: Derived

    public func repository(_ slug: String) -> GHRepository? {
        repositories.first { $0.slug.caseInsensitiveCompare(slug) == .orderedSame }
    }

    public func defaultBranch(_ slug: String) -> String {
        details[slug]?.defaultBranch ?? repository(slug)?.defaultBranch ?? "main"
    }

    public func pull(_ slug: String, _ number: Int) -> GHPullDetail? { pulls[Self.pullKey(slug, number)] }
    public func files(_ slug: String, _ number: Int) -> [GHFile]? { files[Self.filesKey(slug, number)] }
    public func commits(_ slug: String, branch: String) -> [GHCommit]? { commits[Self.commitsKey(slug, branch: branch)] }

    /// Languages across your repositories, most used first, for the language filter.
    public var languages: [String] {
        var counts: [String: Int] = [:]
        for repo in repositories { if let name = repo.language?.name { counts[name, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    public var filteredRepositories: [GHRepository] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return repositories
            .filter { filter.matches($0) }
            .filter { language == nil || $0.language?.name == language }
            .filter { q.isEmpty || $0.slug.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false) }
            .sorted { a, b in
                switch sort {
                case .pushed: return (a.pushedAt ?? .distantPast) > (b.pushedAt ?? .distantPast)
                case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                case .stars: return a.stars != b.stars ? a.stars > b.stars : a.name < b.name
                }
            }
    }

    // MARK: Actions

    private func act(_ key: String, success: String, then reload: @escaping (GitHubStore) -> Void,
                     _ work: @escaping @Sendable () -> Result<String, GitHubAPI.Failure>) {
        guard !working.contains(key) else { return }
        if isDemo {
            onActionResult?(success + " (demo)", true)
            return
        }
        working.insert(key)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { work() }.value
            guard let self else { return }
            self.working.remove(key)
            switch result {
            case .success: self.onActionResult?(success, true)
            case .failure(let failure): self.onActionResult?(failure.message, false)
            }
            reload(self)
        }
    }

    private func reloadPull(_ slug: String, _ number: Int) -> (GitHubStore) -> Void {
        { s in
            s.loadPull(slug, number, force: true)
            s.loadPulls(slug, open: true, force: true)
            s.loadPulls(slug, open: false, force: true)
        }
    }

    public func merge(_ slug: String, _ number: Int, method: GHMergeMethod) {
        act(Self.pullKey(slug, number), success: "Merged #\(number)", then: reloadPull(slug, number)) {
            GitHubAPI.merge(slug, number: number, method: method)
        }
    }

    public func review(_ slug: String, _ number: Int, event: GHReviewEvent, body: String) {
        let verb = event == .approve ? "Approved" : (event == .requestChanges ? "Requested changes on" : "Reviewed")
        act(Self.pullKey(slug, number), success: "\(verb) #\(number)", then: reloadPull(slug, number)) {
            GitHubAPI.review(slug, number: number, event: event, body: body)
        }
    }

    public func comment(_ slug: String, _ number: Int, body: String) {
        act(Self.pullKey(slug, number), success: "Commented on #\(number)", then: reloadPull(slug, number)) {
            GitHubAPI.comment(slug, number: number, body: body)
        }
    }

    public func close(_ slug: String, _ number: Int) {
        act(Self.pullKey(slug, number), success: "Closed #\(number)", then: reloadPull(slug, number)) {
            GitHubAPI.close(slug, number: number)
        }
    }

    public func reopen(_ slug: String, _ number: Int) {
        act(Self.pullKey(slug, number), success: "Reopened #\(number)", then: reloadPull(slug, number)) {
            GitHubAPI.reopen(slug, number: number)
        }
    }

    public func markReady(_ slug: String, _ number: Int) {
        act(Self.pullKey(slug, number), success: "#\(number) is ready for review", then: reloadPull(slug, number)) {
            GitHubAPI.markReady(slug, number: number)
        }
    }

    public func deleteBranch(_ slug: String, _ branch: String) {
        act("branch:\(slug):\(branch)", success: "Deleted \(branch)", then: { s in
            s.loadBranches(slug, force: true)
            s.loadPulls(slug, open: false, force: true)
        }) { GitHubAPI.deleteBranch(slug, branch: branch) }
    }

    /// Checks a pull request out in a local clone; `then` runs after, e.g. to rescan local repositories.
    public func checkout(_ slug: String, _ number: Int, in root: String, then: @escaping () -> Void = {}) {
        act(Self.pullKey(slug, number) + ":checkout", success: "Checked out #\(number)", then: { _ in then() }) {
            GitHubAPI.checkout(slug, number: number, in: root)
        }
    }

    public func checkoutBranch(_ slug: String, _ branch: String, in root: String, then: @escaping () -> Void = {}) {
        act("branch:\(slug):\(branch):checkout", success: "Switched to \(branch)", then: { _ in then() }) {
            GitHubAPI.checkoutBranch(branch, in: root)
        }
    }

    // MARK: Demo

    /// Debug/demo: shows this data and never touches GitHub. Actions report success without doing anything.
    public func loadDemo(repositories: [GHRepository], details: [String: GHRepoDetail], branches: [String: [GHBranch]],
                         openPulls: [String: [GHPullSummary]], closedPulls: [String: [GHPullSummary]],
                         commits: [String: [GHCommit]], pulls: [GHPullDetail], files: [String: [GHFile]]) {
        isDemo = true
        self.repositories = repositories
        self.details = details
        self.branches = branches
        self.openPulls = openPulls
        self.closedPulls = closedPulls
        self.commits = commits
        self.pulls = Dictionary(uniqueKeysWithValues: pulls.map { (Self.pullKey($0.summary.repo, $0.summary.number), $0) })
        self.files = files
        lastRepositories = Date()
    }
}
