import Foundation

// What the GitHub-style screens show: repositories, branches, pull requests and their conversations, as GitHub
// reports them. Everything here is read through `gh`, never with a token Lookout holds.

public struct GHLanguage: Hashable, Sendable {
    public var name: String
    /// GitHub's linguist color, `#rrggbb`.
    public var color: String?
    public var size: Int

    public init(name: String, color: String?, size: Int = 0) {
        self.name = name
        self.color = color
        self.size = size
    }
}

public struct GHRepository: Identifiable, Hashable, Sendable {
    public var id: String { slug }
    /// `owner/name`.
    public var slug: String
    public var description: String?
    public var isPrivate: Bool
    public var isFork: Bool
    public var isArchived: Bool
    public var isTemplate: Bool
    public var stars: Int
    public var forks: Int
    public var openPulls: Int
    public var openIssues: Int
    public var pushedAt: Date?
    public var url: String
    public var homepage: String?
    public var language: GHLanguage?
    public var defaultBranch: String?
    /// ADMIN, MAINTAIN, WRITE, TRIAGE or READ.
    public var permission: String

    public init(slug: String, description: String? = nil, isPrivate: Bool = false, isFork: Bool = false, isArchived: Bool = false,
                isTemplate: Bool = false, stars: Int = 0, forks: Int = 0, openPulls: Int = 0, openIssues: Int = 0,
                pushedAt: Date? = nil, url: String? = nil, homepage: String? = nil, language: GHLanguage? = nil,
                defaultBranch: String? = "main", permission: String = "ADMIN") {
        self.slug = slug
        self.description = description
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.isArchived = isArchived
        self.isTemplate = isTemplate
        self.stars = stars
        self.forks = forks
        self.openPulls = openPulls
        self.openIssues = openIssues
        self.pushedAt = pushedAt
        self.url = url ?? "https://github.com/\(slug)"
        self.homepage = homepage
        self.language = language
        self.defaultBranch = defaultBranch
        self.permission = permission
    }

    public var owner: String { String(slug.split(separator: "/").first ?? "") }
    public var name: String { String(slug.split(separator: "/").last ?? Substring(slug)) }
    public var canWrite: Bool { ["ADMIN", "MAINTAIN", "WRITE"].contains(permission) }
    /// "Public", "Private", "Public template", "Public archive", like the badge beside a name on GitHub.
    public var visibilityLabel: String {
        let base = isPrivate ? "Private" : "Public"
        if isArchived { return base + " archive" }
        if isTemplate { return base + " template" }
        return base
    }
}

public enum GHPullState: String, Hashable, Sendable, CaseIterable {
    case open, draft, merged, closed

    public init(state: String?, isDraft: Bool) {
        switch state?.uppercased() {
        case "MERGED": self = .merged
        case "CLOSED": self = .closed
        default: self = isDraft ? .draft : .open
        }
    }

    public var title: String {
        switch self {
        case .open: return "Open"
        case .draft: return "Draft"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }
    public var isOpen: Bool { self == .open || self == .draft }
}

public struct GHCommit: Identifiable, Hashable, Sendable {
    public var id: String { oid }
    public var oid: String
    public var headline: String
    public var date: Date?
    public var authorName: String
    public var authorLogin: String?
    public var checks: CheckState

    public init(oid: String, headline: String, date: Date?, authorName: String, authorLogin: String? = nil, checks: CheckState = .none) {
        self.oid = oid
        self.headline = headline
        self.date = date
        self.authorName = authorName
        self.authorLogin = authorLogin
        self.checks = checks
    }

    public var short: String { String(oid.prefix(7)) }
    public var author: String { authorLogin ?? authorName }
}

/// A pull request as it appears in a list.
public struct GHPullSummary: Identifiable, Hashable, Sendable {
    public var id: String { "\(repo)#\(number)" }
    public var repo: String
    public var number: Int
    public var title: String
    public var state: GHPullState
    public var author: String
    public var headRef: String
    public var baseRef: String
    public var createdAt: Date?
    public var updatedAt: Date?
    public var comments: Int
    public var checks: CheckState
    public var review: ReviewState
    public var url: String

    public init(repo: String, number: Int, title: String, state: GHPullState, author: String, headRef: String, baseRef: String,
                createdAt: Date?, updatedAt: Date?, comments: Int = 0, checks: CheckState = .none, review: ReviewState = .none,
                url: String? = nil) {
        self.repo = repo
        self.number = number
        self.title = title
        self.state = state
        self.author = author
        self.headRef = headRef
        self.baseRef = baseRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.comments = comments
        self.checks = checks
        self.review = review
        self.url = url ?? "https://github.com/\(repo)/pull/\(number)"
    }
}

public struct GHBranchPull: Hashable, Sendable {
    public var number: Int
    public var state: GHPullState
    public var title: String

    public init(number: Int, state: GHPullState, title: String) {
        self.number = number
        self.state = state
        self.title = title
    }
}

public struct GHBranch: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    /// Commits on this branch that the default branch doesn't have.
    public var ahead: Int
    /// Commits on the default branch that this branch doesn't have.
    public var behind: Int
    public var isDefault: Bool
    public var isProtected: Bool
    public var commit: GHCommit?
    public var pull: GHBranchPull?

    public init(name: String, ahead: Int = 0, behind: Int = 0, isDefault: Bool = false, isProtected: Bool = false,
                commit: GHCommit? = nil, pull: GHBranchPull? = nil) {
        self.name = name
        self.ahead = ahead
        self.behind = behind
        self.isDefault = isDefault
        self.isProtected = isProtected
        self.commit = commit
        self.pull = pull
    }

    /// GitHub calls a branch stale after three months without a commit.
    public func isStale(now: Date = Date()) -> Bool {
        guard let date = commit?.date else { return true }
        return now.timeIntervalSince(date) > 90 * 86_400
    }
}

/// GitHub's Branches page sections.
public enum GHBranchSection: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview"
    case yours = "Yours"
    case active = "Active"
    case stale = "Stale"
    case all = "All"
    public var id: String { rawValue }
}

public enum GHMergeMethod: String, CaseIterable, Identifiable, Sendable {
    case merge, squash, rebase
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .merge: return "Create a merge commit"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }
    public var button: String {
        switch self {
        case .merge: return "Merge pull request"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }
    public var detail: String {
        switch self {
        case .merge: return "All commits from this branch will be added to the base branch via a merge commit."
        case .squash: return "The commits from this branch will be combined into one commit in the base branch."
        case .rebase: return "The commits from this branch will be rebased and added to the base branch."
        }
    }
}

public struct GHRepoDetail: Hashable, Sendable {
    public var description: String?
    public var homepage: String?
    public var topics: [String]
    public var license: String?
    public var languages: [GHLanguage]
    public var defaultBranch: String?
    /// GitHub's own rendering of the README.
    public var readmeHTML: String?
    public var commits: [GHCommit]
    public var mergeMethods: [GHMergeMethod]
    public var defaultMergeMethod: GHMergeMethod
    public var watchers: Int

    public init(description: String? = nil, homepage: String? = nil, topics: [String] = [], license: String? = nil,
                languages: [GHLanguage] = [], defaultBranch: String? = "main", readmeHTML: String? = nil, commits: [GHCommit] = [],
                mergeMethods: [GHMergeMethod] = GHMergeMethod.allCases, defaultMergeMethod: GHMergeMethod = .merge, watchers: Int = 0) {
        self.description = description
        self.homepage = homepage
        self.topics = topics
        self.license = license
        self.languages = languages
        self.defaultBranch = defaultBranch
        self.readmeHTML = readmeHTML
        self.commits = commits
        self.mergeMethods = mergeMethods
        self.defaultMergeMethod = defaultMergeMethod
        self.watchers = watchers
    }

    public var languageTotal: Int { languages.reduce(0) { $0 + $1.size } }
}

/// One entry in a pull request's conversation: a comment, or a review with its verdict.
public struct GHTimelineItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case comment
        /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED.
        case review(String)
    }
    public var id: String
    public var kind: Kind
    public var author: String
    public var avatarURL: String?
    public var bodyHTML: String
    public var date: Date?

    public init(id: String, kind: Kind, author: String, avatarURL: String? = nil, bodyHTML: String, date: Date?) {
        self.id = id
        self.kind = kind
        self.author = author
        self.avatarURL = avatarURL
        self.bodyHTML = bodyHTML
        self.date = date
    }
}

public struct GHCheck: Identifiable, Hashable, Sendable {
    public var id: String { workflow.map { "\($0)/\(name)" } ?? name }
    public var name: String
    public var workflow: String?
    public var state: CheckState
    /// SUCCESS, FAILURE, SKIPPED, CANCELLED, NEUTRAL, IN_PROGRESS…, for the row's subtitle.
    public var detail: String
    public var url: String?
    public var duration: TimeInterval?

    public init(name: String, workflow: String? = nil, state: CheckState, detail: String = "", url: String? = nil, duration: TimeInterval? = nil) {
        self.name = name
        self.workflow = workflow
        self.state = state
        self.detail = detail
        self.url = url
        self.duration = duration
    }
}

public struct GHLabel: Hashable, Sendable {
    public var name: String
    public var color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

public struct GHReviewer: Hashable, Sendable {
    public var login: String
    /// Latest verdict, or nil while the review is only requested.
    public var state: String?

    public init(login: String, state: String?) {
        self.login = login
        self.state = state
    }
}

public struct GHPullDetail: Hashable, Sendable {
    public var summary: GHPullSummary
    public var bodyHTML: String
    public var authorAvatar: String?
    /// Nil while GitHub is still computing it.
    public var mergeable: Bool?
    /// CLEAN, BLOCKED, BEHIND, DIRTY, UNSTABLE, HAS_HOOKS, DRAFT, UNKNOWN.
    public var mergeState: String
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var viewerCanUpdate: Bool
    public var viewerDidAuthor: Bool
    public var mergedAt: Date?
    public var closedAt: Date?
    public var timeline: [GHTimelineItem]
    public var reviewers: [GHReviewer]
    public var assignees: [String]
    public var labels: [GHLabel]
    public var commits: [GHCommit]
    public var checks: [GHCheck]
    public var mergeMethods: [GHMergeMethod]
    public var defaultMergeMethod: GHMergeMethod

    public init(summary: GHPullSummary, bodyHTML: String = "", authorAvatar: String? = nil, mergeable: Bool? = true,
                mergeState: String = "CLEAN", additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0,
                viewerCanUpdate: Bool = true, viewerDidAuthor: Bool = true, mergedAt: Date? = nil, closedAt: Date? = nil,
                timeline: [GHTimelineItem] = [], reviewers: [GHReviewer] = [], assignees: [String] = [], labels: [GHLabel] = [],
                commits: [GHCommit] = [], checks: [GHCheck] = [], mergeMethods: [GHMergeMethod] = GHMergeMethod.allCases,
                defaultMergeMethod: GHMergeMethod = .merge) {
        self.summary = summary
        self.bodyHTML = bodyHTML
        self.authorAvatar = authorAvatar
        self.mergeable = mergeable
        self.mergeState = mergeState
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.viewerCanUpdate = viewerCanUpdate
        self.viewerDidAuthor = viewerDidAuthor
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.timeline = timeline
        self.reviewers = reviewers
        self.assignees = assignees
        self.labels = labels
        self.commits = commits
        self.checks = checks
        self.mergeMethods = mergeMethods
        self.defaultMergeMethod = defaultMergeMethod
    }

    public var checksPassed: Int { checks.filter { $0.state == .success }.count }
    public var checksFailed: Int { checks.filter { $0.state == .failure }.count }
    public var checksRunning: Int { checks.filter { $0.state == .pending }.count }
}

public struct GHFile: Identifiable, Hashable, Sendable {
    public var id: String { filename }
    public var filename: String
    /// added, removed, modified, renamed, copied, changed, unchanged.
    public var status: String
    public var additions: Int
    public var deletions: Int
    /// Unified diff hunks. Nil for binary files and diffs GitHub considers too large.
    public var patch: String?
    public var previousFilename: String?

    public init(filename: String, status: String, additions: Int, deletions: Int, patch: String?, previousFilename: String? = nil) {
        self.filename = filename
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
        self.previousFilename = previousFilename
    }
}

public struct GHDiffLine: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case hunk, addition, deletion, context }
    public var id: Int
    public var kind: Kind
    public var old: Int?
    public var new: Int?
    public var text: String

    /// Splits a unified-diff patch into lines numbered on both sides, the way GitHub's diff view numbers them.
    public static func parse(_ patch: String) -> [GHDiffLine] {
        var lines: [GHDiffLine] = []
        var old = 0, new = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let id = lines.count
            if line.hasPrefix("@@") {
                // @@ -12,7 +12,9 @@ context
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                lines.append(GHDiffLine(id: id, kind: .hunk, old: nil, new: nil, text: line))
            } else if line.hasPrefix("+") {
                lines.append(GHDiffLine(id: id, kind: .addition, old: nil, new: new, text: String(line.dropFirst())))
                new += 1
            } else if line.hasPrefix("-") {
                lines.append(GHDiffLine(id: id, kind: .deletion, old: old, new: nil, text: String(line.dropFirst())))
                old += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file"
                lines.append(GHDiffLine(id: id, kind: .context, old: nil, new: nil, text: line))
            } else {
                if line.isEmpty && raw.endIndex == patch.endIndex { continue }
                lines.append(GHDiffLine(id: id, kind: .context, old: old, new: new, text: String(line.dropFirst())))
                old += 1
                new += 1
            }
        }
        return lines
    }
}

public enum GHReviewEvent: String, CaseIterable, Identifiable, Sendable {
    case comment, approve, requestChanges
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .comment: return "Comment"
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        }
    }
    public var detail: String {
        switch self {
        case .comment: return "Submit general feedback without explicit approval."
        case .approve: return "Submit feedback and approve merging these changes."
        case .requestChanges: return "Submit feedback that must be addressed before merging."
        }
    }
    var flag: String {
        switch self {
        case .comment: return "--comment"
        case .approve: return "--approve"
        case .requestChanges: return "--request-changes"
        }
    }
}
