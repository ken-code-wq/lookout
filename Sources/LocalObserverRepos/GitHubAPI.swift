import Foundation

/// Reads and acts on GitHub through `gh`, so the GitHub CLI's sign-in does the talking. Every call blocks; run them
/// off the main thread.
public enum GitHubAPI {
    public struct Failure: Error, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    // MARK: Plumbing

    /// String variables go as `-f` (always strings); Int ones as `-F`, which gh sends as numbers.
    static func graphQL(_ query: String, _ variables: [String: String] = [:], ints: [String: Int] = [:],
                        timeout: TimeInterval = 30) -> Result<[String: Any], Failure> {
        guard let gh = RepoGitHub.cliPath else { return .failure(Failure("The GitHub CLI isn't installed")) }
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (key, value) in variables.sorted(by: { $0.key < $1.key }) { args += ["-f", "\(key)=\(value)"] }
        for (key, value) in ints.sorted(by: { $0.key < $1.key }) { args += ["-F", "\(key)=\(value)"] }
        let out = RepoGit.run(gh, args, timeout: timeout)
        let object = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any]
        if let data = object?["data"] as? [String: Any], out.ok || data.values.contains(where: { !($0 is NSNull) }) {
            return .success(data)
        }
        let message = (object?["errors"] as? [[String: Any]])?.first?["message"] as? String
            ?? out.stderr.split(separator: "\n").first.map(String.init)
            ?? "gh exited with \(out.status)"
        return .failure(Failure(message))
    }

    /// Runs `gh` for an action and reports its first line of complaint on failure.
    static func gh(_ args: [String], in directory: String? = nil, timeout: TimeInterval = 60) -> Result<String, Failure> {
        guard let gh = RepoGitHub.cliPath else { return .failure(Failure("The GitHub CLI isn't installed")) }
        let out = RepoGit.run(gh, args, in: directory, timeout: timeout)
        if out.ok { return .success(out.stdout) }
        let reason = (out.stderr.isEmpty ? out.stdout : out.stderr)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return .failure(Failure(reason ?? "gh exited with \(out.status)"))
    }

    static func split(_ slug: String) -> (String, String) {
        let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func date(_ value: Any?) -> Date? { (value as? String).flatMap(iso.date(from:)) }
    static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func nodes(_ value: Any?) -> [[String: Any]] { (dict(value)?["nodes"] as? [[String: Any]]) ?? [] }
    static func count(_ value: Any?) -> Int { dict(value)?["totalCount"] as? Int ?? 0 }

    // MARK: Repositories

    static let repositoriesQuery = """
    query($cursor: String) {
      viewer {
        repositories(first: 100, after: $cursor, ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                     orderBy: {field: PUSHED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            nameWithOwner description isPrivate isFork isArchived isTemplate stargazerCount forkCount pushedAt url
            homepageUrl viewerPermission primaryLanguage { name color } defaultBranchRef { name }
            pullRequests(states: OPEN) { totalCount }
            issues(states: OPEN) { totalCount }
          }
        }
      }
    }
    """

    /// Every repository you own or can push to, most recently pushed first. Five pages at most.
    public static func repositories() -> Result<[GHRepository], Failure> {
        var all: [GHRepository] = []
        var cursor: String?
        for _ in 0..<5 {
            let result = graphQL(repositoriesQuery, cursor.map { ["cursor": $0] } ?? [:], timeout: 45)
            guard case .success(let data) = result else {
                if all.isEmpty, case .failure(let failure) = result { return .failure(failure) }
                break
            }
            let repos = dict(dict(data["viewer"])?["repositories"])
            all += nodes(repos).compactMap(repository)
            let page = dict(repos?["pageInfo"])
            guard page?["hasNextPage"] as? Bool == true, let next = page?["endCursor"] as? String else { break }
            cursor = next
        }
        return .success(all)
    }

    static func repository(_ node: [String: Any]) -> GHRepository? {
        guard let slug = node["nameWithOwner"] as? String else { return nil }
        let language = dict(node["primaryLanguage"]).flatMap { l in (l["name"] as? String).map { GHLanguage(name: $0, color: l["color"] as? String) } }
        return GHRepository(
            slug: slug, description: node["description"] as? String, isPrivate: node["isPrivate"] as? Bool ?? false,
            isFork: node["isFork"] as? Bool ?? false, isArchived: node["isArchived"] as? Bool ?? false,
            isTemplate: node["isTemplate"] as? Bool ?? false, stars: node["stargazerCount"] as? Int ?? 0,
            forks: node["forkCount"] as? Int ?? 0, openPulls: count(node["pullRequests"]), openIssues: count(node["issues"]),
            pushedAt: date(node["pushedAt"]), url: node["url"] as? String,
            homepage: (node["homepageUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }, language: language,
            defaultBranch: dict(node["defaultBranchRef"])?["name"] as? String,
            permission: node["viewerPermission"] as? String ?? "READ")
    }

    // MARK: Repository page

    static let commitFields = "oid messageHeadline committedDate author { name user { login } } statusCheckRollup { state }"

    static let detailQuery = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        description homepageUrl mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed viewerDefaultMergeMethod
        licenseInfo { spdxId name } watchers { totalCount }
        repositoryTopics(first: 12) { nodes { topic { name } } }
        languages(first: 10, orderBy: {field: SIZE, direction: DESC}) { edges { size node { name color } } }
        defaultBranchRef { name target { ... on Commit { history(first: 6) { nodes { \(commitFields) } } } } }
      }
    }
    """

    public static func detail(_ slug: String) -> Result<GHRepoDetail, Failure> {
        let (owner, name) = split(slug)
        return graphQL(detailQuery, ["owner": owner, "name": name]).flatMap { data in
            guard let repo = dict(data["repository"]) else { return .failure(Failure("Repository not found")) }
            let branch = dict(repo["defaultBranchRef"])
            var detail = GHRepoDetail(
                description: repo["description"] as? String,
                homepage: (repo["homepageUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                topics: nodes(repo["repositoryTopics"]).compactMap { dict($0["topic"])?["name"] as? String },
                license: dict(repo["licenseInfo"]).flatMap { ($0["spdxId"] as? String).flatMap { $0 == "NOASSERTION" ? nil : $0 } ?? $0["name"] as? String },
                languages: ((dict(repo["languages"])?["edges"] as? [[String: Any]]) ?? []).compactMap { edge in
                    guard let node = dict(edge["node"]), let name = node["name"] as? String else { return nil }
                    return GHLanguage(name: name, color: node["color"] as? String, size: edge["size"] as? Int ?? 0)
                },
                defaultBranch: branch?["name"] as? String,
                commits: nodes(dict(dict(branch?["target"])?["history"])).compactMap(commit),
                mergeMethods: mergeMethods(repo),
                defaultMergeMethod: GHMergeMethod(rawValue: (repo["viewerDefaultMergeMethod"] as? String ?? "").lowercased()) ?? .merge,
                watchers: count(repo["watchers"]))
            detail.readmeHTML = readme(slug)
            return .success(detail)
        }
    }

    static func mergeMethods(_ repo: [String: Any]?) -> [GHMergeMethod] {
        guard let repo else { return GHMergeMethod.allCases }
        var methods: [GHMergeMethod] = []
        if repo["mergeCommitAllowed"] as? Bool ?? true { methods.append(.merge) }
        if repo["squashMergeAllowed"] as? Bool ?? true { methods.append(.squash) }
        if repo["rebaseMergeAllowed"] as? Bool ?? true { methods.append(.rebase) }
        return methods
    }

    /// The README as GitHub renders it, or nil if there isn't one.
    static func readme(_ slug: String) -> String? {
        guard case .success(let html) = gh(["api", "repos/\(slug)/readme", "-H", "Accept: application/vnd.github.html"], timeout: 30),
              !html.isEmpty else { return nil }
        return html
    }

    static func commit(_ node: [String: Any]) -> GHCommit? {
        guard let oid = node["oid"] as? String else { return nil }
        let author = dict(node["author"])
        return GHCommit(oid: oid, headline: node["messageHeadline"] as? String ?? "", date: date(node["committedDate"]),
                        authorName: author?["name"] as? String ?? "", authorLogin: dict(author?["user"])?["login"] as? String,
                        checks: CheckState(rollup: dict(node["statusCheckRollup"])?["state"] as? String))
    }

    // MARK: Commits

    static let commitsQuery = """
    query($owner: String!, $name: String!, $ref: String!) {
      repository(owner: $owner, name: $name) {
        ref(qualifiedName: $ref) { target { ... on Commit { history(first: 60) { nodes { \(commitFields) } } } } }
      }
    }
    """

    public static func commits(_ slug: String, branch: String) -> Result<[GHCommit], Failure> {
        let (owner, name) = split(slug)
        return graphQL(commitsQuery, ["owner": owner, "name": name, "ref": "refs/heads/\(branch)"]).map { data in
            nodes(dict(dict(dict(dict(data["repository"])?["ref"])?["target"])?["history"])).compactMap(commit)
        }
    }

    // MARK: Branches

    static let branchesQuery = """
    query($owner: String!, $name: String!, $base: String!) {
      repository(owner: $owner, name: $name) {
        refs(refPrefix: "refs/heads/", first: 100, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
          nodes {
            name branchProtectionRule { pattern }
            compare(headRef: $base) { aheadBy behindBy }
            associatedPullRequests(first: 1, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number state isDraft title } }
            target { ... on Commit { \(commitFields) } }
          }
        }
      }
    }
    """

    public static func branches(_ slug: String, defaultBranch: String) -> Result<[GHBranch], Failure> {
        let (owner, name) = split(slug)
        return graphQL(branchesQuery, ["owner": owner, "name": name, "base": defaultBranch], timeout: 45).map { data in
            nodes(dict(dict(data["repository"])?["refs"])).compactMap { node in
                guard let branch = node["name"] as? String else { return nil }
                // compare(headRef: default) on this branch: "ahead" is what default has that this branch lacks.
                let compare = dict(node["compare"])
                let pull = nodes(node["associatedPullRequests"]).first.flatMap { pr -> GHBranchPull? in
                    guard let number = pr["number"] as? Int else { return nil }
                    return GHBranchPull(number: number, state: GHPullState(state: pr["state"] as? String, isDraft: pr["isDraft"] as? Bool ?? false),
                                        title: pr["title"] as? String ?? "")
                }
                return GHBranch(name: branch, ahead: compare?["behindBy"] as? Int ?? 0, behind: compare?["aheadBy"] as? Int ?? 0,
                                isDefault: branch == defaultBranch, isProtected: node["branchProtectionRule"] is [String: Any],
                                commit: dict(node["target"]).flatMap(commit), pull: pull)
            }
        }
    }

    // MARK: Pull requests

    static let pullListFields = """
    number title state isDraft createdAt updatedAt url headRefName baseRefName reviewDecision
    author { login } comments { totalCount }
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    """

    static func pullsQuery(states: String) -> String {
        """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            pullRequests(first: 50, states: \(states), orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { \(pullListFields) } }
          }
        }
        """
    }

    /// Open pull requests, or recently closed and merged ones.
    public static func pulls(_ slug: String, open: Bool) -> Result<[GHPullSummary], Failure> {
        let (owner, name) = split(slug)
        return graphQL(pullsQuery(states: open ? "[OPEN]" : "[CLOSED, MERGED]"), ["owner": owner, "name": name]).map { data in
            nodes(dict(dict(data["repository"])?["pullRequests"])).compactMap { pullSummary($0, repo: slug) }
        }
    }

    static func pullSummary(_ node: [String: Any], repo: String) -> GHPullSummary? {
        guard let number = node["number"] as? Int else { return nil }
        let rollup = dict(dict(nodes(node["commits"]).first?["commit"])?["statusCheckRollup"])
        return GHPullSummary(
            repo: repo, number: number, title: node["title"] as? String ?? "",
            state: GHPullState(state: node["state"] as? String, isDraft: node["isDraft"] as? Bool ?? false),
            author: dict(node["author"])?["login"] as? String ?? "ghost",
            headRef: node["headRefName"] as? String ?? "", baseRef: node["baseRefName"] as? String ?? "",
            createdAt: date(node["createdAt"]), updatedAt: date(node["updatedAt"]), comments: count(node["comments"]),
            checks: CheckState(rollup: rollup?["state"] as? String), review: ReviewState(decision: node["reviewDecision"] as? String),
            url: node["url"] as? String)
    }

    static let pullQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed viewerDefaultMergeMethod
        pullRequest(number: $number) {
          \(pullListFields)
          bodyHTML mergeable mergeStateStatus additions deletions changedFiles viewerCanUpdate viewerDidAuthor mergedAt closedAt
          author { login avatarUrl }
          threadComments: comments(first: 100) { nodes { id author { login avatarUrl } bodyHTML createdAt } }
          reviews(first: 100) { nodes { id author { login avatarUrl } state bodyHTML submittedAt } }
          reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { name } ... on Bot { login } } } }
          assignees(first: 10) { nodes { login } }
          labels(first: 20) { nodes { name color } }
          allCommits: commits(first: 100) { nodes { commit { \(commitFields) } } }
          lastCommit: commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
            __typename
            ... on CheckRun { name status conclusion detailsUrl startedAt completedAt checkSuite { workflowRun { workflow { name } } } }
            ... on StatusContext { context state targetUrl description }
          } } } } } }
        }
      }
    }
    """

    public static func pull(_ slug: String, number: Int) -> Result<GHPullDetail, Failure> {
        let (owner, name) = split(slug)
        return graphQL(pullQuery, ["owner": owner, "name": name], ints: ["number": number], timeout: 45).flatMap { data in
            let repo = dict(data["repository"])
            guard let node = dict(repo?["pullRequest"]), let summary = pullSummary(node, repo: slug) else {
                return .failure(Failure("Pull request #\(number) not found"))
            }
            return .success(pullDetail(node, summary: summary, repo: repo))
        }
    }

    static func pullDetail(_ node: [String: Any], summary: GHPullSummary, repo: [String: Any]?) -> GHPullDetail {
        // Aliased: the list fields already ask for `comments { totalCount }`, and GraphQL refuses the same field twice.
        var timeline: [GHTimelineItem] = nodes(node["threadComments"]).map { c in
            GHTimelineItem(id: c["id"] as? String ?? UUID().uuidString, kind: .comment,
                           author: dict(c["author"])?["login"] as? String ?? "ghost", avatarURL: dict(c["author"])?["avatarUrl"] as? String,
                           bodyHTML: c["bodyHTML"] as? String ?? "", date: date(c["createdAt"]))
        }
        var verdicts: [String: String] = [:]
        for r in nodes(node["reviews"]) {
            let author = dict(r["author"])?["login"] as? String ?? "ghost"
            let state = r["state"] as? String ?? "COMMENTED"
            if state != "COMMENTED" && state != "PENDING" { verdicts[author] = state }
            // A plain "commented" review with no text is GitHub's wrapper around inline comments; nothing to show.
            let body = r["bodyHTML"] as? String ?? ""
            if state == "PENDING" || (state == "COMMENTED" && body.isEmpty) { continue }
            timeline.append(GHTimelineItem(id: r["id"] as? String ?? UUID().uuidString, kind: .review(state), author: author,
                                           avatarURL: dict(r["author"])?["avatarUrl"] as? String, bodyHTML: body,
                                           date: date(r["submittedAt"])))
        }
        timeline.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }

        var reviewers = verdicts.map { GHReviewer(login: $0.key, state: $0.value) }.sorted { $0.login < $1.login }
        for request in nodes(node["reviewRequests"]) {
            let reviewer = dict(request["requestedReviewer"])
            guard let login = reviewer?["login"] as? String ?? reviewer?["name"] as? String else { continue }
            reviewers.removeAll { $0.login == login }
            reviewers.append(GHReviewer(login: login, state: nil))
        }

        let contexts = nodes(dict(dict(dict(nodes(node["lastCommit"]).first?["commit"])?["statusCheckRollup"])?["contexts"]))
        let mergeable: Bool? = switch node["mergeable"] as? String {
        case "MERGEABLE": true
        case "CONFLICTING": false
        default: nil
        }
        return GHPullDetail(
            summary: summary, bodyHTML: node["bodyHTML"] as? String ?? "", authorAvatar: dict(node["author"])?["avatarUrl"] as? String,
            mergeable: mergeable, mergeState: node["mergeStateStatus"] as? String ?? "UNKNOWN",
            additions: node["additions"] as? Int ?? 0, deletions: node["deletions"] as? Int ?? 0,
            changedFiles: node["changedFiles"] as? Int ?? 0, viewerCanUpdate: node["viewerCanUpdate"] as? Bool ?? false,
            viewerDidAuthor: node["viewerDidAuthor"] as? Bool ?? false, mergedAt: date(node["mergedAt"]), closedAt: date(node["closedAt"]),
            timeline: timeline, reviewers: reviewers,
            assignees: nodes(node["assignees"]).compactMap { $0["login"] as? String },
            labels: nodes(node["labels"]).compactMap { l in (l["name"] as? String).map { GHLabel(name: $0, color: l["color"] as? String ?? "888888") } },
            commits: nodes(node["allCommits"]).compactMap { dict($0["commit"]).flatMap(commit) },
            checks: contexts.compactMap(check),
            mergeMethods: mergeMethods(repo),
            defaultMergeMethod: GHMergeMethod(rawValue: (repo?["viewerDefaultMergeMethod"] as? String ?? "").lowercased()) ?? .merge)
    }

    static func check(_ node: [String: Any]) -> GHCheck? {
        if node["__typename"] as? String == "StatusContext" {
            guard let name = node["context"] as? String else { return nil }
            let state = node["state"] as? String
            return GHCheck(name: name, state: CheckState(rollup: state), detail: node["description"] as? String ?? state?.capitalized ?? "",
                           url: node["targetUrl"] as? String)
        }
        guard let name = node["name"] as? String else { return nil }
        let status = node["status"] as? String ?? ""
        let conclusion = node["conclusion"] as? String
        let state: CheckState
        if status != "COMPLETED" { state = .pending }
        else {
            switch conclusion {
            case "SUCCESS": state = .success
            case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED": state = .failure
            default: state = .none
            }
        }
        let started = date(node["startedAt"]), completed = date(node["completedAt"])
        let workflow = dict(dict(dict(node["checkSuite"])?["workflowRun"])?["workflow"])?["name"] as? String
        let detail = status != "COMPLETED" ? (status == "QUEUED" ? "Queued" : "In progress")
            : (conclusion ?? "Completed").replacingOccurrences(of: "_", with: " ").capitalized
        return GHCheck(name: name, workflow: workflow, state: state, detail: detail, url: node["detailsUrl"] as? String,
                       duration: started.flatMap { s in completed.map { $0.timeIntervalSince(s) } })
    }

    /// Files changed in a pull request, with their patches.
    public static func files(_ slug: String, number: Int) -> Result<[GHFile], Failure> {
        gh(["api", "--paginate", "repos/\(slug)/pulls/\(number)/files?per_page=100", "--jq", ".[]"], timeout: 60).map { text in
            text.split(separator: "\n").compactMap { line in
                guard let f = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let name = f["filename"] as? String else { return nil }
                return GHFile(filename: name, status: f["status"] as? String ?? "modified", additions: f["additions"] as? Int ?? 0,
                              deletions: f["deletions"] as? Int ?? 0, patch: f["patch"] as? String,
                              previousFilename: f["previous_filename"] as? String)
            }
        }
    }

    // MARK: Actions

    public static func merge(_ slug: String, number: Int, method: GHMergeMethod) -> Result<String, Failure> {
        gh(["pr", "merge", "\(number)", "-R", slug, "--\(method.rawValue)"])
    }

    public static func review(_ slug: String, number: Int, event: GHReviewEvent, body: String) -> Result<String, Failure> {
        var args = ["pr", "review", "\(number)", "-R", slug, event.flag]
        if !body.isEmpty { args += ["--body", body] }
        return gh(args)
    }

    public static func comment(_ slug: String, number: Int, body: String) -> Result<String, Failure> {
        gh(["pr", "comment", "\(number)", "-R", slug, "--body", body])
    }

    public static func close(_ slug: String, number: Int) -> Result<String, Failure> { gh(["pr", "close", "\(number)", "-R", slug]) }
    public static func reopen(_ slug: String, number: Int) -> Result<String, Failure> { gh(["pr", "reopen", "\(number)", "-R", slug]) }
    public static func markReady(_ slug: String, number: Int) -> Result<String, Failure> { gh(["pr", "ready", "\(number)", "-R", slug]) }

    /// `gh pr checkout` in the local clone: fetches the head branch (forks included) and switches to it.
    public static func checkout(_ slug: String, number: Int, in directory: String) -> Result<String, Failure> {
        gh(["pr", "checkout", "\(number)", "-R", slug], in: directory, timeout: 120)
    }

    /// `gh repo clone` into `destination`, which must not exist yet. Sets up `upstream` for forks, as gh does.
    public static func clone(_ slug: String, to destination: String) -> Result<String, Failure> {
        gh(["repo", "clone", slug, destination], timeout: 600)
    }

    public static func deleteBranch(_ slug: String, branch: String) -> Result<String, Failure> {
        let ref = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        return gh(["api", "-X", "DELETE", "repos/\(slug)/git/refs/heads/\(ref)"])
    }

    /// Switches the local clone to `branch`, creating a tracking branch from origin if there's no local one yet.
    /// Refuses (as git does) when uncommitted changes would be overwritten.
    public static func checkoutBranch(_ branch: String, in root: String) -> Result<String, Failure> {
        _ = RepoGit.git(root, ["fetch", "origin", branch, "--quiet"], timeout: 90)
        let exists = RepoGit.git(root, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).ok
        let out = exists ? RepoGit.git(root, ["switch", branch]) : RepoGit.git(root, ["switch", "--track", "origin/\(branch)"])
        if out.ok { return .success(out.stdout) }
        let reason = (out.stderr.isEmpty ? out.stdout : out.stderr).split(separator: "\n").first.map(String.init)
        return .failure(Failure((reason ?? "git exited with \(out.status)").replacingOccurrences(of: "error: ", with: "")
            .replacingOccurrences(of: "fatal: ", with: "")))
    }
}
