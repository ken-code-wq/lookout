import Foundation
import LocalObserverCore

/// Uncommitted work in a checkout, from `git status`.
public struct RepoChanges: Hashable, Sendable, Codable {
    public var staged = 0
    public var modified = 0
    public var untracked = 0
    public var conflicted = 0

    public init(staged: Int = 0, modified: Int = 0, untracked: Int = 0, conflicted: Int = 0) {
        self.staged = staged
        self.modified = modified
        self.untracked = untracked
        self.conflicted = conflicted
    }

    /// Files touched, each counted once.
    public var total: Int { staged + modified + untracked + conflicted }
    public var isClean: Bool { total == 0 }

    /// "3 modified, 1 staged, 2 untracked".
    public var summary: String {
        var parts: [String] = []
        if conflicted > 0 { parts.append("\(conflicted) conflicted") }
        if modified > 0 { parts.append("\(modified) modified") }
        if staged > 0 { parts.append("\(staged) staged") }
        if untracked > 0 { parts.append("\(untracked) untracked") }
        return parts.isEmpty ? "Clean" : parts.joined(separator: ", ")
    }
}

/// Branch line of `git status --porcelain=v2 --branch`.
public struct RepoBranchStatus: Hashable, Sendable, Codable {
    public var branch: String?
    public var head: String = ""
    public var upstream: String?
    public var ahead = 0
    public var behind = 0

    public init(branch: String? = nil, head: String = "", upstream: String? = nil, ahead: Int = 0, behind: Int = 0) {
        self.branch = branch
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

/// A linked worktree of a repository (the main checkout is the repo itself).
public struct RepoWorktree: Identifiable, Hashable, Sendable, Codable {
    public var id: String { path }
    public var path: String
    public var branch: String?
    public var head: String
    public var isLocked: Bool
    /// Its folder is gone; `git worktree prune` would clean up the bookkeeping.
    public var isPrunable: Bool
    public var changes: RepoChanges?
    public var ahead: Int
    public var behind: Int
    /// Last time anything was committed or staged there.
    public var lastTouched: Date?

    public init(path: String, branch: String?, head: String, isLocked: Bool = false, isPrunable: Bool = false,
                changes: RepoChanges? = nil, ahead: Int = 0, behind: Int = 0, lastTouched: Date? = nil) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.changes = changes
        self.ahead = ahead
        self.behind = behind
        self.lastTouched = lastTouched
    }

    public var refLabel: String { branch ?? (head.isEmpty ? "detached" : String(head.prefix(7))) }
    public var name: String { (path as NSString).lastPathComponent }
    public var owner: String? { RepoFormat.worktreeOwner(path) }
    public var isDirty: Bool { !(changes?.isClean ?? true) }
}

/// One local git repository and the state of its main checkout.
public struct Repo: Identifiable, Hashable, Sendable, Codable {
    public var id: String { root }
    public var root: String
    public var name: String
    public var status: RepoBranchStatus
    public var changes: RepoChanges
    public var stashes: Int
    /// Commits on HEAD that no remote has. Nil when the repository has no remotes at all.
    public var unpushed: Int?
    public var lastCommitAt: Date?
    public var lastCommitSubject: String
    public var lastCommitAuthor: String
    public var remoteURL: String
    /// `owner/name` when origin is on GitHub.
    public var github: String?
    public var defaultBranch: String?
    /// Local branches already merged into the default branch (never the current or default branch).
    public var mergedBranches: [String]
    public var branchCount: Int
    public var worktrees: [RepoWorktree]
    /// Latest of the last commit and the last index write: roughly "when did someone last work here".
    public var lastTouched: Date?

    public init(root: String, name: String, status: RepoBranchStatus = RepoBranchStatus(), changes: RepoChanges = RepoChanges(),
                stashes: Int = 0, unpushed: Int? = 0, lastCommitAt: Date? = nil, lastCommitSubject: String = "",
                lastCommitAuthor: String = "", remoteURL: String = "", github: String? = nil, defaultBranch: String? = nil,
                mergedBranches: [String] = [], branchCount: Int = 0, worktrees: [RepoWorktree] = [], lastTouched: Date? = nil) {
        self.root = root
        self.name = name
        self.status = status
        self.changes = changes
        self.stashes = stashes
        self.unpushed = unpushed
        self.lastCommitAt = lastCommitAt
        self.lastCommitSubject = lastCommitSubject
        self.lastCommitAuthor = lastCommitAuthor
        self.remoteURL = remoteURL
        self.github = github
        self.defaultBranch = defaultBranch
        self.mergedBranches = mergedBranches
        self.branchCount = branchCount
        self.worktrees = worktrees
        self.lastTouched = lastTouched
    }

    public var branch: String? { status.branch }
    public var refLabel: String { status.branch ?? (status.head.isEmpty ? "detached" : String(status.head.prefix(7))) }
    public var displayPath: String { root.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    public var isDirty: Bool { !changes.isClean }
    public var unpushedCount: Int { max(unpushed ?? 0, status.ahead) }
    public var hasUnpushed: Bool { unpushedCount > 0 }
    public var isBehind: Bool { status.behind > 0 }
    public var hasConflicts: Bool { changes.conflicted > 0 }
    /// No remote at all: nothing here is backed up anywhere.
    public var isLocalOnly: Bool { remoteURL.isEmpty }
    public var dirtyWorktrees: [RepoWorktree] { worktrees.filter(\.isDirty) }

    /// Work that exists only on this Mac: uncommitted changes or commits no remote has, here or in a worktree.
    public var hasLocalOnlyWork: Bool {
        isDirty || hasUnpushed || worktrees.contains { $0.isDirty || $0.ahead > 0 }
    }

    public var needsAttention: Bool { hasLocalOnlyWork || isBehind || hasConflicts }

    /// Unsaved work that nobody has touched for `days`: the "I forgot about that branch" list.
    public func isForgotten(days: Int, now: Date = Date()) -> Bool {
        guard hasLocalOnlyWork, let touched = lastTouched else { return false }
        return now.timeIntervalSince(touched) > Double(days) * 86_400
    }

    public var githubURL: URL? { github.flatMap { URL(string: "https://github.com/\($0)") } }
    public func githubBranchURL(_ branch: String) -> URL? {
        github.flatMap { URL(string: "https://github.com/\($0)/tree/\(branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch)") }
    }

    /// Branches checked out anywhere in this repository: the main checkout and every worktree.
    public var checkedOutBranches: Set<String> {
        Set(([status.branch] + worktrees.map(\.branch)).compactMap { $0 })
    }
}

// MARK: - GitHub

public enum CheckState: String, Hashable, Sendable, Codable {
    case success, failure, pending, none

    /// GraphQL `StatusState`: SUCCESS, FAILURE, ERROR, PENDING, EXPECTED.
    public init(rollup: String?) {
        switch rollup?.uppercased() {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "EXPECTED": self = .pending
        default: self = .none
        }
    }

    public var title: String {
        switch self {
        case .success: return "Checks passed"
        case .failure: return "Checks failed"
        case .pending: return "Checks running"
        case .none: return "No checks"
        }
    }
}

public enum ReviewState: String, Hashable, Sendable, Codable {
    case approved, changesRequested, required, none

    public init(decision: String?) {
        switch decision?.uppercased() {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .required
        default: self = .none
        }
    }

    public var title: String {
        switch self {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .required: return "Review required"
        case .none: return "No review"
        }
    }
}

public struct PullRequest: Identifiable, Hashable, Sendable, Codable {
    public enum Role: String, Hashable, Sendable, Codable { case mine, reviewRequested }

    public var id: String { url }
    public var number: Int
    public var title: String
    public var url: String
    /// `owner/name`.
    public var repo: String
    public var branch: String
    public var isDraft: Bool
    public var updatedAt: Date
    public var checks: CheckState
    public var review: ReviewState
    /// Nil while GitHub is still working it out.
    public var mergeable: Bool?
    public var author: String
    public var role: Role

    public init(number: Int, title: String, url: String, repo: String, branch: String, isDraft: Bool, updatedAt: Date,
                checks: CheckState, review: ReviewState, mergeable: Bool?, author: String, role: Role) {
        self.number = number
        self.title = title
        self.url = url
        self.repo = repo
        self.branch = branch
        self.isDraft = isDraft
        self.updatedAt = updatedAt
        self.checks = checks
        self.review = review
        self.mergeable = mergeable
        self.author = author
        self.role = role
    }

    public var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    /// Yours, green, approved, and mergeable: just needs the button pressed.
    public var isReadyToMerge: Bool {
        role == .mine && !isDraft && checks != .failure && checks != .pending && review == .approved && mergeable != false
    }
    /// Something only you can unblock: a review you owe, failing checks or requested changes on yours, or a conflict.
    public var needsYou: Bool {
        switch role {
        case .reviewRequested: return true
        case .mine: return checks == .failure || review == .changesRequested || mergeable == false
        }
    }
}

public enum GitHubStatus: Hashable, Sendable {
    case off
    case unknown
    /// `gh` isn't installed where Lookout can find it.
    case missingCLI
    case signedOut
    case ok(login: String)
    case error(String)

    public var login: String? { if case .ok(let login) = self { return login }; return nil }
}

// MARK: - Formatting

public enum RepoFormat {
    /// `git@github.com:owner/name.git`, `https://github.com/owner/name(.git)`, `ssh://git@github.com/owner/name` → `owner/name`.
    public static func githubSlug(_ remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = s.range(of: "github.com") else { return nil }
        s = String(s[range.upperBound...])
        s = String(s.drop { $0 == ":" || $0 == "/" })
        if s.hasSuffix(".git") { s.removeLast(4) }
        if s.hasSuffix("/") { s.removeLast() }
        let parts = s.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// The tool that made a worktree, guessed from where it lives.
    public static func worktreeOwner(_ path: String) -> String? { GitCheckout.owner(ofWorktreeAt: path) }

    public static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        if s < 86_400 * 30 { return "\(s / 86_400)d ago" }
        if s < 86_400 * 365 { return "\(s / (86_400 * 30))mo ago" }
        return "\(s / (86_400 * 365))y ago"
    }
}
