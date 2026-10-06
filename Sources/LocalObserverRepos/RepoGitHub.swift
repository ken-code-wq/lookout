import Foundation

/// Pull requests and their checks, through the GitHub CLI's own sign-in. Lookout never sees or stores the token:
/// `gh` makes the request, and only the parsed result comes back.
public enum RepoGitHub {
    /// Where `gh` usually lives. Apps opened from Finder don't inherit the shell's PATH, so look in the usual places.
    public static var cliPath: String? {
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", home + "/.local/bin/gh", "/usr/bin/gh",
                          home + "/bin/gh", "/run/current-system/sw/bin/gh", home + "/.nix-profile/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct Result: Sendable {
        public var status: GitHubStatus
        public var pulls: [PullRequest]
    }

    static let query = """
    query {
      viewer { login }
      mine: search(query: "is:open is:pr author:@me archived:false", type: ISSUE, first: 40) { nodes { ...pr } }
      review: search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 40) { nodes { ...pr } }
    }
    fragment pr on PullRequest {
      number title url isDraft updatedAt headRefName reviewDecision mergeable
      repository { nameWithOwner }
      author { login }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    public static func fetch() -> Result {
        guard let gh = cliPath else { return Result(status: .missingCLI, pulls: []) }
        let out = RepoGit.run(gh, ["api", "graphql", "-f", "query=\(query)"], timeout: 30)
        guard out.ok else {
            let message = (out.stderr + out.stdout).lowercased()
            if message.contains("gh auth login") || message.contains("not logged") || message.contains("authentication") {
                return Result(status: .signedOut, pulls: [])
            }
            let line = out.stderr.split(separator: "\n").first.map(String.init) ?? "gh exited with \(out.status)"
            return Result(status: .error(line), pulls: [])
        }
        return parse(Data(out.stdout.utf8))
    }

    public static func parse(_ data: Data) -> Result {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any] else {
            let message = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["errors"] as? [[String: Any]])?
                .first?["message"] as? String
            return Result(status: .error(message ?? "Unexpected reply from GitHub"), pulls: [])
        }
        let login = (body["viewer"] as? [String: Any])?["login"] as? String ?? ""
        func nodes(_ key: String) -> [[String: Any]] {
            ((body[key] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        }
        var pulls: [PullRequest] = []
        var seen = Set<String>()
        for (key, role) in [("review", PullRequest.Role.reviewRequested), ("mine", .mine)] {
            for node in nodes(key) {
                guard let pr = pull(node, role: role), seen.insert(pr.url).inserted else { continue }
                pulls.append(pr)
            }
        }
        return Result(status: .ok(login: login), pulls: pulls)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func pull(_ node: [String: Any], role: PullRequest.Role) -> PullRequest? {
        guard let number = node["number"] as? Int, let url = node["url"] as? String,
              let repo = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
        let commits = (node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]]
        let commit = commits?.first?["commit"] as? [String: Any]
        let rollup = commit?["statusCheckRollup"] as? [String: Any]
        let mergeable: Bool? = switch node["mergeable"] as? String {
        case "MERGEABLE": true
        case "CONFLICTING": false
        default: nil
        }
        return PullRequest(
            number: number,
            title: node["title"] as? String ?? "",
            url: url,
            repo: repo,
            branch: node["headRefName"] as? String ?? "",
            isDraft: node["isDraft"] as? Bool ?? false,
            updatedAt: (node["updatedAt"] as? String).flatMap(isoFormatter.date(from:)) ?? Date(),
            checks: CheckState(rollup: rollup?["state"] as? String),
            review: ReviewState(decision: node["reviewDecision"] as? String),
            mergeable: mergeable,
            author: (node["author"] as? [String: Any])?["login"] as? String ?? "",
            role: role
        )
    }
}
