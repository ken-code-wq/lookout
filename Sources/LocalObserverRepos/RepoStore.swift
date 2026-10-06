import Foundation
import Combine

public struct RepoSettings: Codable, Equatable, Sendable {
    /// Folders searched for repositories. Nil means the usual code folders under home (`RepoGit.defaultRoots`).
    public var roots: [String]? = nil
    /// How many folders deep to look under each root.
    public var depth = 3
    public var gitHubEnabled = true
    public var notifyChecksFailed = true
    public var notifyChecksPassed = true
    public var notifyReviewRequested = true
    public var notifyApproved = true
    /// Unsaved work untouched for this long counts as forgotten.
    public var forgottenDays = 7
    /// Repositories left out of every list, by root.
    public var hidden: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every key optional, so settings saved by older versions keep decoding as fields are added.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RepoSettings()
        roots = try c.decodeIfPresent([String].self, forKey: .roots)
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? d.depth
        gitHubEnabled = try c.decodeIfPresent(Bool.self, forKey: .gitHubEnabled) ?? d.gitHubEnabled
        notifyChecksFailed = try c.decodeIfPresent(Bool.self, forKey: .notifyChecksFailed) ?? d.notifyChecksFailed
        notifyChecksPassed = try c.decodeIfPresent(Bool.self, forKey: .notifyChecksPassed) ?? d.notifyChecksPassed
        notifyReviewRequested = try c.decodeIfPresent(Bool.self, forKey: .notifyReviewRequested) ?? d.notifyReviewRequested
        notifyApproved = try c.decodeIfPresent(Bool.self, forKey: .notifyApproved) ?? d.notifyApproved
        forgottenDays = try c.decodeIfPresent(Int.self, forKey: .forgottenDays) ?? d.forgottenDays
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? d.hidden
    }

    public var effectiveRoots: [String] { roots ?? RepoGit.defaultRoots }
}

/// Tabs on the Repositories page.
public enum RepoView: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case changes = "Uncommitted"
    case unpushed = "Unpushed"
    case behind = "Behind"
    case forgotten = "Forgotten"
    case worktrees = "Worktrees"
    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .changes: return "pencil.line"
        case .unpushed: return "arrow.up.circle"
        case .behind: return "arrow.down.circle"
        case .forgotten: return "clock.badge.exclamationmark"
        case .worktrees: return "square.stack.3d.down.right"
        }
    }
}

public enum RepoSort: String, CaseIterable, Identifiable, Sendable {
    case recent = "Last touched"
    case name = "Name"
    case changes = "Most changes"
    public var id: String { rawValue }
}

/// The Repos pillar: every git repository under your code folders, the state of each checkout and worktree, and
/// your pull requests with their checks. Stands on its own: it reads nothing from the agent or server stores.
@MainActor
public final class RepoStore: ObservableObject {
    public static let shared = RepoStore()

    @Published public private(set) var repos: [Repo] = []
    @Published public private(set) var pulls: [PullRequest] = []
    @Published public private(set) var gitHub: GitHubStatus = .unknown
    @Published public private(set) var isScanning = false
    @Published public private(set) var isFetchingGitHub = false
    @Published public private(set) var lastScan: Date?
    @Published public private(set) var lastGitHub: Date?
    /// Repositories with a fetch, pull, or cleanup running.
    @Published public private(set) var busy: Set<String> = []
    @Published public var settings: RepoSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            if settings.roots != oldValue.roots || settings.depth != oldValue.depth { refresh(rediscover: true) }
            if settings.gitHubEnabled != oldValue.gitHubEnabled { refreshGitHub() }
        }
    }
    @Published public var searchText = ""
    @Published public var view: RepoView = .all
    @Published public var sort: RepoSort = .recent
    @Published public var selection: String?

    /// Result of a user action (fetch, pull, cleanup), for the app to show as a toast: message, succeeded.
    public var onActionResult: ((String, Bool) -> Void)?

    private let defaults: UserDefaults
    private static let settingsKey = "LocalObserver.repoSettings"
    private var started = false
    private var isDemo = false
    private var discovered: [String] = []
    private var lastDiscovery: Date = .distantPast
    private var refCache: [String: (signature: String, info: RepoGit.RefInfo)] = [:]
    private var scanTask: Task<Void, Never>?
    private var gitHubTask: Task<Void, Never>?
    private var localTimer: Timer?
    private var gitHubTimer: Timer?

    /// Local state is re-read this often; it's a `git status` per checkout, so a couple of minutes is plenty.
    public static let localInterval: TimeInterval = 120
    /// Pull requests are polled this often, or `fastGitHubInterval` while one of yours has checks running.
    public static let gitHubInterval: TimeInterval = 180
    public static let fastGitHubInterval: TimeInterval = 45
    /// New repositories appear rarely; walk the folders again this often.
    public static let discoveryInterval: TimeInterval = 600

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(RepoSettings.self, from: $0) } ?? RepoSettings()
    }

    /// Starts scanning. Separate from init so the snapshot harness can load demo data without touching this Mac.
    public func start() {
        guard !started, !isDemo else { return }
        started = true
        refresh(rediscover: true)
        refreshGitHub()
        localTimer = Timer.scheduledTimer(withTimeInterval: Self.localInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(quiet: true) }
        }
        localTimer?.tolerance = 20
        scheduleGitHub()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    // MARK: Scanning

    /// Coalesces: a call while a scan runs is dropped.
    public func refresh(rediscover: Bool = false, quiet: Bool = false) {
        guard !isDemo, scanTask == nil else { return }
        if !quiet { isScanning = true }
        let walk = rediscover || discovered.isEmpty || Date().timeIntervalSince(lastDiscovery) > Self.discoveryInterval
        let roots = settings.effectiveRoots
        let depth = settings.depth
        let known = discovered
        let cache = refCache
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (roots: [String], repos: [Repo], cache: [String: (signature: String, info: RepoGit.RefInfo)]) in
                let found = walk ? RepoGit.discover(roots: roots, depth: depth) : known
                let read = Self.read(found, cache: cache)
                return (found, read.repos, read.cache)
            }.value
            guard let self else { return }
            if walk {
                self.discovered = result.roots
                self.lastDiscovery = Date()
            }
            self.refCache = result.cache
            if result.repos != self.repos { self.repos = result.repos }
            self.lastScan = Date()
            if let selection = self.selection, !result.repos.contains(where: { $0.root == selection }) { self.selection = nil }
            self.isScanning = false
            self.scanTask = nil
        }
    }

    /// Reads every repository, at most a handful of git processes at once.
    nonisolated private static func read(_ roots: [String], cache: [String: (signature: String, info: RepoGit.RefInfo)])
        -> (repos: [Repo], cache: [String: (signature: String, info: RepoGit.RefInfo)]) {
        let lock = NSLock()
        var repos: [Repo] = []
        var fresh: [String: (signature: String, info: RepoGit.RefInfo)] = [:]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        for root in roots {
            queue.addOperation {
                guard let (repo, entry) = readRepo(root, cached: cache[root]) else { return }
                lock.lock()
                repos.append(repo)
                fresh[root] = entry
                lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return (repos.sorted { $0.root < $1.root }, fresh)
    }

    nonisolated static func readRepo(_ root: String, cached: (signature: String, info: RepoGit.RefInfo)?)
        -> (Repo, (signature: String, info: RepoGit.RefInfo))? {
        let signature = RepoGit.refSignature(root)
        guard let (status, changes) = RepoGit.status(root) else { return nil }
        let info = cached?.signature == signature ? cached!.info : RepoGit.refInfo(root, currentBranch: status.branch)
        var worktrees = info.worktrees
        for i in worktrees.indices where !worktrees[i].isPrunable {
            let path = worktrees[i].path
            if let (wtStatus, wtChanges) = RepoGit.status(path) {
                worktrees[i].changes = wtChanges
                worktrees[i].branch = wtStatus.branch ?? worktrees[i].branch
                worktrees[i].behind = wtStatus.behind
                let unpushed = info.remoteURL.isEmpty ? 0
                    : Int(RepoGit.git(path, ["rev-list", "--count", "HEAD", "--not", "--remotes"]).stdout
                        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                worktrees[i].ahead = max(wtStatus.ahead, unpushed)
            }
            if let gitDir = worktreeGitDir(path) {
                worktrees[i].lastTouched = [RepoGit.indexTouched(gitDir), modified(gitDir + "/logs/HEAD")].compactMap { $0 }.max()
            }
        }
        let unpushed: Int? = info.remoteURL.isEmpty || status.head.isEmpty ? nil
            : Int(RepoGit.git(root, ["rev-list", "--count", "HEAD", "--not", "--remotes"]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines))
        let touched = [info.lastCommitAt, RepoGit.indexTouched(root + "/.git")].compactMap { $0 }.max()
        let repo = Repo(
            root: root, name: (root as NSString).lastPathComponent, status: status, changes: changes,
            stashes: RepoGit.stashCount(root), unpushed: unpushed, lastCommitAt: info.lastCommitAt,
            lastCommitSubject: info.subject, lastCommitAuthor: info.author, remoteURL: info.remoteURL,
            github: RepoFormat.githubSlug(info.remoteURL), defaultBranch: info.defaultBranch,
            mergedBranches: info.merged, branchCount: info.branchCount, worktrees: worktrees, lastTouched: touched)
        return (repo, (signature, info))
    }

    nonisolated private static func worktreeGitDir(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return raw.hasPrefix("/") ? raw : (path as NSString).appendingPathComponent(raw)
    }

    nonisolated private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: GitHub

    public func refreshGitHub() {
        guard !isDemo, gitHubTask == nil else { return }
        guard settings.gitHubEnabled else {
            gitHub = .off
            if !pulls.isEmpty { pulls = [] }
            return
        }
        isFetchingGitHub = true
        gitHubTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { RepoGitHub.fetch() }.value
            guard let self else { return }
            if self.gitHub != result.status { self.gitHub = result.status }
            // Keep the last good list through a transient failure rather than blanking the page.
            if case .ok = result.status, result.pulls != self.pulls { self.pulls = result.pulls }
            if case .signedOut = result.status { self.pulls = [] }
            if case .missingCLI = result.status { self.pulls = [] }
            self.lastGitHub = Date()
            self.isFetchingGitHub = false
            self.gitHubTask = nil
            self.scheduleGitHub()
        }
    }

    /// Polls faster while checks are running on one of yours, so a red or green result shows up promptly.
    private func scheduleGitHub() {
        gitHubTimer?.invalidate()
        guard started else { return }
        let interval = pulls.contains { $0.role == .mine && $0.checks == .pending } ? Self.fastGitHubInterval : Self.gitHubInterval
        gitHubTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshGitHub() }
        }
        gitHubTimer?.tolerance = interval / 5
    }

    // MARK: Derived

    public var visibleRepos: [Repo] {
        let hidden = Set(settings.hidden)
        return repos.filter { !hidden.contains($0.root) }
    }

    public func repos(in view: RepoView) -> [Repo] {
        let all = visibleRepos
        switch view {
        case .all: return all
        case .changes: return all.filter { $0.isDirty || !$0.dirtyWorktrees.isEmpty }
        case .unpushed: return all.filter { $0.hasUnpushed || $0.worktrees.contains { $0.ahead > 0 } }
        case .behind: return all.filter(\.isBehind)
        case .forgotten: return all.filter { $0.isForgotten(days: settings.forgottenDays) }
        case .worktrees: return all.filter { !$0.worktrees.isEmpty }
        }
    }

    public var filtered: [Repo] {
        var list = repos(in: view)
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { repo in
                ([repo.name, repo.root, repo.refLabel, repo.github ?? "", repo.lastCommitSubject] + repo.worktrees.map(\.refLabel))
                    .contains { $0.lowercased().contains(q) }
            }
        }
        return list.sorted { a, b in
            switch sort {
            case .recent: return (a.lastTouched ?? .distantPast) > (b.lastTouched ?? .distantPast)
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .changes:
                let ca = a.changes.total + a.unpushedCount, cb = b.changes.total + b.unpushedCount
                return ca != cb ? ca > cb : a.name < b.name
            }
        }
    }

    public var selected: Repo? { selection.flatMap { id in repos.first { $0.root == id } } }

    /// Repositories holding work that exists only on this Mac.
    public var attentionRepos: [Repo] { visibleRepos.filter(\.hasLocalOnlyWork) }

    public var myPulls: [PullRequest] { pulls.filter { $0.role == .mine }.sorted { $0.updatedAt > $1.updatedAt } }
    public var reviewRequests: [PullRequest] { pulls.filter { $0.role == .reviewRequested }.sorted { $0.updatedAt > $1.updatedAt } }
    public var pullsNeedingYou: [PullRequest] { pulls.filter(\.needsYou) }
    public var failingPulls: [PullRequest] { myPulls.filter { $0.checks == .failure } }
    public var runningPulls: [PullRequest] { myPulls.filter { $0.checks == .pending } }
    public var readyPulls: [PullRequest] { myPulls.filter(\.isReadyToMerge) }

    /// Open pull requests for branches checked out in this repository (main checkout or a worktree).
    public func pulls(for repo: Repo) -> [PullRequest] {
        guard let slug = repo.github?.lowercased() else { return [] }
        let branches = repo.checkedOutBranches
        return pulls.filter { $0.repo.lowercased() == slug && $0.role == .mine && branches.contains($0.branch) }
    }

    public func pull(for repo: Repo, branch: String?) -> PullRequest? {
        guard let branch, let slug = repo.github?.lowercased() else { return nil }
        return pulls.first { $0.repo.lowercased() == slug && $0.branch == branch && $0.role == .mine }
    }

    /// The local checkout of a pull request's repository, if there is one.
    public func localRepo(for pull: PullRequest) -> Repo? {
        repos.first { $0.github?.lowercased() == pull.repo.lowercased() }
    }

    /// The local clone of a GitHub repository, by `owner/name`.
    public func localRepo(slug: String) -> Repo? {
        repos.first { $0.github?.caseInsensitiveCompare(slug) == .orderedSame }
    }

    // MARK: Actions

    public func fetch(_ repo: Repo) { perform(repo, verb: "Fetched", RepoGit.fetch) }
    public func pull(_ repo: Repo) { perform(repo, verb: "Pulled", RepoGit.pull) }
    public func pruneWorktrees(_ repo: Repo) { perform(repo, verb: "Pruned worktrees in", RepoGit.pruneWorktrees) }
    public func deleteMergedBranches(_ repo: Repo) {
        let branches = repo.mergedBranches
        perform(repo, verb: "Deleted \(branches.count) merged branch\(branches.count == 1 ? "" : "es") in") {
            RepoGit.deleteMergedBranches($0, branches)
        }
    }

    // MARK: Hand-off

    /// Pushes a checkout (the main one or a worktree) of `repo`.
    public func push(_ repo: Repo, path: String, branch: String) {
        perform(repo, busyKey: path, verb: "Pushed \(branch) of", { _ in RepoGit.push(path) })
    }

    /// Removes a worktree with git, which refuses if anything is unsaved. The branch stays.
    public func removeWorktree(_ repo: Repo, path: String) {
        perform(repo, busyKey: path, verb: "Removed a worktree of", { root in RepoGit.removeWorktree(root, path: path) })
    }

    /// Pushes if needed, then opens a pull request for the branch with `gh pr create --fill` (title and body from
    /// its commits). Reports the new pull request's number, or nil on failure.
    public func createPull(_ repo: Repo, path: String, branch: String, draft: Bool = false, then: @escaping (Int?) -> Void) {
        guard !isDemo, !busy.contains(path), let gh = RepoGitHub.cliPath else {
            onActionResult?(RepoGitHub.cliPath == nil ? "The GitHub CLI isn't installed" : "Busy", false)
            then(nil)
            return
        }
        busy.insert(path)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (Int?, String) in
                let push = RepoGit.push(path)
                guard push.ok else { return (nil, push.stderr.split(separator: "\n").first.map(String.init) ?? "Push failed") }
                var args = ["pr", "create", "--fill", "--head", branch]
                if draft { args.append("--draft") }
                let out = RepoGit.run(gh, args, in: path, timeout: 90)
                let text = out.stdout + out.stderr
                // gh prints the URL on success, and the existing one when a pull request is already open.
                let number = text.range(of: #"/pull/(\d+)"#, options: .regularExpression)
                    .flatMap { Int(text[$0].dropFirst("/pull/".count)) }
                return (number, out.ok ? "" : (out.stderr.split(separator: "\n").first.map(String.init) ?? "gh failed"))
            }.value
            guard let self else { return }
            self.busy.remove(path)
            if let number = result.0 {
                self.onActionResult?("Opened #\(number) for \(branch)", true)
            } else {
                self.onActionResult?(result.1, false)
            }
            self.refCache[repo.root] = nil
            self.refresh(quiet: true)
            self.refreshGitHub()
            then(result.0)
        }
    }

    public func fetchAll() {
        for repo in visibleRepos where !repo.isLocalOnly { fetch(repo) }
    }

    private func perform(_ repo: Repo, busyKey: String? = nil, verb: String, _ work: @escaping @Sendable (String) -> RepoGit.Output) {
        let key = busyKey ?? repo.root
        guard !isDemo, !busy.contains(key) else { return }
        busy.insert(key)
        let root = repo.root, name = repo.name
        Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) { work(root) }.value
            guard let self else { return }
            self.busy.remove(key)
            if out.ok {
                self.onActionResult?("\(verb) \(name)", true)
            } else {
                let reason = (out.stderr.isEmpty ? out.stdout : out.stderr)
                    .split(separator: "\n").first.map(String.init) ?? "git exited with \(out.status)"
                self.onActionResult?("\(name): \(reason.replacingOccurrences(of: "fatal: ", with: ""))", false)
            }
            self.refCache[root] = nil
            self.refresh(quiet: true)
        }
    }

    public func setHidden(_ repo: Repo, _ hidden: Bool) {
        if hidden { if !settings.hidden.contains(repo.root) { settings.hidden.append(repo.root) } }
        else { settings.hidden.removeAll { $0 == repo.root } }
    }

    // MARK: Demo

    /// Debug/demo: shows this data instead of scanning this Mac. Never persisted; scanning stays off afterwards.
    public func loadDemo(repos: [Repo], pulls: [PullRequest], login: String) {
        isDemo = true
        localTimer?.invalidate()
        gitHubTimer?.invalidate()
        self.repos = repos
        self.pulls = pulls
        gitHub = .ok(login: login)
        lastScan = Date()
        lastGitHub = Date()
    }
}


/// Reads one repository the way a scan does. For verification and the snapshot harness.
public enum RepoStoreProbe {
    public static func read(_ root: String) -> (Repo, String)? {
        RepoStore.readRepo(root, cached: nil).map { ($0.0, $0.1.signature) }
    }
}
