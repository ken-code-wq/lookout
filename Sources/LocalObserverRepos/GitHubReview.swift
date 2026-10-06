import Foundation

// Line comments on a pull request's diff, and opening new pull requests, through `gh`.

public struct GHReviewComment: Identifiable, Hashable, Sendable {
    public var id: Int
    public var path: String
    /// Line in the file on `side`; nil once the code it was on has changed (an outdated comment).
    public var line: Int?
    /// RIGHT for the new version of the file, LEFT for the old.
    public var side: String
    public var author: String
    public var bodyHTML: String
    public var createdAt: Date?
    public var replyTo: Int?
    public var url: String

    public init(id: Int, path: String, line: Int?, side: String = "RIGHT", author: String, bodyHTML: String, createdAt: Date? = nil,
                replyTo: Int? = nil, url: String = "") {
        self.id = id
        self.path = path
        self.line = line
        self.side = side
        self.author = author
        self.bodyHTML = bodyHTML
        self.createdAt = createdAt
        self.replyTo = replyTo
        self.url = url
    }

    /// Comments grouped into threads: each top-level comment followed by its replies, oldest first.
    public static func threads(_ comments: [GHReviewComment]) -> [[GHReviewComment]] {
        let roots = comments.filter { $0.replyTo == nil }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        return roots.map { root in
            [root] + comments.filter { $0.replyTo == root.id }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        }
    }
}

/// What a new pull request would contain: the commits between base and head.
public struct GHComparison: Hashable, Sendable {
    public var aheadBy: Int
    public var behindBy: Int
    public var commits: [String]
    public var files: Int

    public init(aheadBy: Int, behindBy: Int, commits: [String], files: Int) {
        self.aheadBy = aheadBy
        self.behindBy = behindBy
        self.commits = commits
        self.files = files
    }

    /// Title from a single commit, or the branch name made readable.
    public func suggestedTitle(head: String) -> String {
        if commits.count == 1, let only = commits.first { return only }
        let name = head.split(separator: "/").last.map(String.init) ?? head
        let words = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    public var suggestedBody: String {
        commits.isEmpty ? "" : commits.map { "- \($0)" }.joined(separator: "\n")
    }
}

extension GitHubAPI {
    public static func reviewComments(_ slug: String, number: Int) -> Result<[GHReviewComment], Failure> {
        gh(["api", "--paginate", "-H", "Accept: application/vnd.github.full+json", "repos/\(slug)/pulls/\(number)/comments?per_page=100",
            "--jq", ".[]"], timeout: 45).map { text in
            text.split(separator: "\n").compactMap { line in
                guard let c = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = c["id"] as? Int else { return nil }
                return GHReviewComment(id: id, path: c["path"] as? String ?? "", line: c["line"] as? Int, side: c["side"] as? String ?? "RIGHT",
                                       author: dict(c["user"])?["login"] as? String ?? "ghost", bodyHTML: c["body_html"] as? String ?? "",
                                       createdAt: date(c["created_at"]), replyTo: c["in_reply_to_id"] as? Int, url: c["html_url"] as? String ?? "")
            }
        }
    }

    public static func addReviewComment(_ slug: String, number: Int, commit: String, path: String, line: Int, side: String,
                                        body: String) -> Result<String, Failure> {
        gh(["api", "-X", "POST", "repos/\(slug)/pulls/\(number)/comments", "-f", "body=\(body)", "-f", "commit_id=\(commit)",
            "-f", "path=\(path)", "-F", "line=\(line)", "-f", "side=\(side)"])
    }

    public static func replyReviewComment(_ slug: String, number: Int, to id: Int, body: String) -> Result<String, Failure> {
        gh(["api", "-X", "POST", "repos/\(slug)/pulls/\(number)/comments/\(id)/replies", "-f", "body=\(body)"])
    }

    public static func compare(_ slug: String, base: String, head: String) -> Result<GHComparison, Failure> {
        let b = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? base
        let h = head.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? head
        return gh(["api", "repos/\(slug)/compare/\(b)...\(h)"], timeout: 30).flatMap { text in
            guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                return .failure(Failure("Unexpected reply from GitHub"))
            }
            let commits = (o["commits"] as? [[String: Any]] ?? []).compactMap {
                (dict($0["commit"])?["message"] as? String)?.split(separator: "\n").first.map(String.init)
            }
            return .success(GHComparison(aheadBy: o["ahead_by"] as? Int ?? 0, behindBy: o["behind_by"] as? Int ?? 0,
                                         commits: commits, files: (o["files"] as? [Any])?.count ?? 0))
        }
    }

    /// Opens a pull request and returns its number.
    public static func createPull(_ slug: String, base: String, head: String, title: String, body: String, draft: Bool) -> Result<Int, Failure> {
        var args = ["pr", "create", "-R", slug, "--base", base, "--head", head, "--title", title, "--body", body]
        if draft { args.append("--draft") }
        return gh(args, timeout: 60).flatMap { out in
            guard let range = out.range(of: #"/pull/(\d+)"#, options: .regularExpression),
                  let number = Int(out[range].dropFirst("/pull/".count)) else { return .failure(Failure("Created, but gh didn't say which number")) }
            return .success(number)
        }
    }
}
