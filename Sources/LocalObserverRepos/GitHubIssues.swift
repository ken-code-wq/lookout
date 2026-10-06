import Foundation

// Issues and the notifications inbox, read and acted on through `gh`.

public enum GHIssueState: String, Hashable, Sendable {
    case open, completed, notPlanned

    public init(state: String?, reason: String?) {
        if state?.uppercased() == "OPEN" { self = .open; return }
        self = reason?.uppercased() == "NOT_PLANNED" ? .notPlanned : .completed
    }

    public var title: String {
        switch self {
        case .open: return "Open"
        case .completed: return "Closed"
        case .notPlanned: return "Not planned"
        }
    }
    public var isOpen: Bool { self == .open }
}

public struct GHIssueSummary: Identifiable, Hashable, Sendable {
    public var id: String { "\(repo)#\(number)" }
    public var repo: String
    public var number: Int
    public var title: String
    public var state: GHIssueState
    public var author: String
    public var labels: [GHLabel]
    public var comments: Int
    public var assignees: [String]
    public var createdAt: Date?
    public var updatedAt: Date?
    public var url: String

    public init(repo: String, number: Int, title: String, state: GHIssueState, author: String, labels: [GHLabel] = [], comments: Int = 0,
                assignees: [String] = [], createdAt: Date? = nil, updatedAt: Date? = nil, url: String? = nil) {
        self.repo = repo
        self.number = number
        self.title = title
        self.state = state
        self.author = author
        self.labels = labels
        self.comments = comments
        self.assignees = assignees
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.url = url ?? "https://github.com/\(repo)/issues/\(number)"
    }
}

public struct GHIssueDetail: Hashable, Sendable {
    public var summary: GHIssueSummary
    public var bodyHTML: String
    public var authorAvatar: String?
    public var timeline: [GHTimelineItem]
    public var viewerCanUpdate: Bool
    public var closedAt: Date?

    public init(summary: GHIssueSummary, bodyHTML: String = "", authorAvatar: String? = nil, timeline: [GHTimelineItem] = [],
                viewerCanUpdate: Bool = true, closedAt: Date? = nil) {
        self.summary = summary
        self.bodyHTML = bodyHTML
        self.authorAvatar = authorAvatar
        self.timeline = timeline
        self.viewerCanUpdate = viewerCanUpdate
        self.closedAt = closedAt
    }
}

public struct GHNotification: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case pullRequest = "PullRequest", issue = "Issue", release = "Release",
                                         discussion = "Discussion", checkSuite = "CheckSuite", commit = "Commit", other }
    public var id: String
    public var repo: String
    public var title: String
    public var kind: Kind
    /// Why you got it: review_requested, mention, author, assign, comment, ci_activity, subscribed…
    public var reason: String
    public var unread: Bool
    public var updatedAt: Date?
    /// PR or issue number, from the subject URL.
    public var number: Int?

    public init(id: String, repo: String, title: String, kind: Kind, reason: String, unread: Bool, updatedAt: Date? = nil, number: Int? = nil) {
        self.id = id
        self.repo = repo
        self.title = title
        self.kind = kind
        self.reason = reason
        self.unread = unread
        self.updatedAt = updatedAt
        self.number = number
    }

    public var reasonTitle: String {
        switch reason {
        case "review_requested": return "Review requested"
        case "mention", "team_mention": return "Mentioned"
        case "author": return "Your thread"
        case "assign": return "Assigned"
        case "comment": return "Commented"
        case "ci_activity": return "CI activity"
        case "state_change": return "State changed"
        case "security_alert": return "Security alert"
        case "manual", "subscribed": return "Subscribed"
        default: return reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Things addressed to you rather than to everyone watching.
    public var isDirect: Bool { ["review_requested", "mention", "team_mention", "assign", "author", "security_alert"].contains(reason) }

    public var webURL: String {
        switch (kind, number) {
        case (.pullRequest, let n?): return "https://github.com/\(repo)/pull/\(n)"
        case (.issue, let n?): return "https://github.com/\(repo)/issues/\(n)"
        case (.release, _): return "https://github.com/\(repo)/releases"
        default: return "https://github.com/\(repo)"
        }
    }
}

extension GitHubAPI {
    static let issueListFields = """
    number title state stateReason createdAt updatedAt url author { login } comments { totalCount }
    labels(first: 10) { nodes { name color } } assignees(first: 5) { nodes { login } }
    """

    public static func issues(_ slug: String, open: Bool) -> Result<[GHIssueSummary], Failure> {
        let (owner, name) = split(slug)
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            issues(first: 50, states: \(open ? "[OPEN]" : "[CLOSED]"), orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { \(issueListFields) } }
          }
        }
        """
        return graphQL(query, ["owner": owner, "name": name]).map { data in
            nodes(dict(dict(data["repository"])?["issues"])).compactMap { issueSummary($0, repo: slug) }
        }
    }

    static func issueSummary(_ n: [String: Any], repo: String) -> GHIssueSummary? {
        guard let number = n["number"] as? Int else { return nil }
        return GHIssueSummary(repo: repo, number: number, title: n["title"] as? String ?? "",
                              state: GHIssueState(state: n["state"] as? String, reason: n["stateReason"] as? String),
                              author: dict(n["author"])?["login"] as? String ?? "ghost",
                              labels: nodes(n["labels"]).compactMap { l in (l["name"] as? String).map { GHLabel(name: $0, color: l["color"] as? String ?? "888888") } },
                              comments: count(n["comments"]), assignees: nodes(n["assignees"]).compactMap { $0["login"] as? String },
                              createdAt: date(n["createdAt"]), updatedAt: date(n["updatedAt"]), url: n["url"] as? String)
    }

    public static func issue(_ slug: String, number: Int) -> Result<GHIssueDetail, Failure> {
        let (owner, name) = split(slug)
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            issue(number: $number) {
              \(issueListFields) bodyHTML viewerCanUpdate closedAt author { login avatarUrl }
              threadComments: comments(first: 100) { nodes { id author { login avatarUrl } bodyHTML createdAt } }
            }
          }
        }
        """
        return graphQL(query, ["owner": owner, "name": name], ints: ["number": number]).flatMap { data in
            guard let n = dict(dict(data["repository"])?["issue"]), let summary = issueSummary(n, repo: slug) else {
                return .failure(Failure("Issue #\(number) not found"))
            }
            let timeline = nodes(n["threadComments"]).map { c in
                GHTimelineItem(id: c["id"] as? String ?? UUID().uuidString, kind: .comment, author: dict(c["author"])?["login"] as? String ?? "ghost",
                               avatarURL: dict(c["author"])?["avatarUrl"] as? String, bodyHTML: c["bodyHTML"] as? String ?? "", date: date(c["createdAt"]))
            }
            return .success(GHIssueDetail(summary: summary, bodyHTML: n["bodyHTML"] as? String ?? "",
                                          authorAvatar: dict(n["author"])?["avatarUrl"] as? String, timeline: timeline,
                                          viewerCanUpdate: n["viewerCanUpdate"] as? Bool ?? false, closedAt: date(n["closedAt"])))
        }
    }

    public static func commentIssue(_ slug: String, number: Int, body: String) -> Result<String, Failure> {
        gh(["issue", "comment", "\(number)", "-R", slug, "--body", body])
    }

    public static func closeIssue(_ slug: String, number: Int, notPlanned: Bool) -> Result<String, Failure> {
        gh(["issue", "close", "\(number)", "-R", slug, "--reason", notPlanned ? "not planned" : "completed"])
    }

    public static func reopenIssue(_ slug: String, number: Int) -> Result<String, Failure> {
        gh(["issue", "reopen", "\(number)", "-R", slug])
    }

    public static func createIssue(_ slug: String, title: String, body: String) -> Result<String, Failure> {
        gh(["issue", "create", "-R", slug, "--title", title, "--body", body])
    }

    // MARK: Notifications

    /// Unread notifications, plus read ones from the last few days when `all`.
    public static func notifications(all: Bool) -> Result<[GHNotification], Failure> {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 86_400))
        let path = "notifications?per_page=50" + (all ? "&all=true&since=\(since)" : "")
        return gh(["api", path], timeout: 30).flatMap { text in
            guard let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
                return .failure(Failure("Unexpected reply from GitHub"))
            }
            return .success(list.compactMap(notification))
        }
    }

    public static func notification(_ n: [String: Any]) -> GHNotification? {
        guard let id = n["id"] as? String, let subject = dict(n["subject"]) else { return nil }
        let url = subject["url"] as? String ?? ""
        let number = url.split(separator: "/").last.flatMap { Int($0) }
        return GHNotification(id: id, repo: dict(n["repository"])?["full_name"] as? String ?? "", title: subject["title"] as? String ?? "",
                              kind: GHNotification.Kind(rawValue: subject["type"] as? String ?? "") ?? .other,
                              reason: n["reason"] as? String ?? "", unread: n["unread"] as? Bool ?? false,
                              updatedAt: date(n["updated_at"]), number: number)
    }

    public static func markRead(_ id: String) -> Result<String, Failure> {
        gh(["api", "-X", "PATCH", "notifications/threads/\(id)"])
    }

    public static func markAllRead() -> Result<String, Failure> {
        gh(["api", "-X", "PUT", "notifications", "-F", "read=true"])
    }
}
