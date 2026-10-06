import Foundation
import LocalObserverCore
import LocalObserverRepos

/// Repos rules: git's porcelain output and GitHub's replies parse the same way every time, worktrees are told apart
/// from main checkouts, and a real repository with a linked worktree reads back correctly end to end.
enum RepoChecks {
    @MainActor
    static func run() {
        if ProcessInfo.processInfo.environment["REPO_BENCH"] == "1" { bench() }
        if ProcessInfo.processInfo.environment["GH_LIVE"] == "1" { live() }
        checkStatusParsing()
        checkWorktreeParsing()
        checkSlugs()
        checkHead()
        checkGitHubParsing()
        checkDiffParsing()
        checkGitHubStore()
        checkRealRepository()
    }

    /// Diff lines are numbered on both sides the way GitHub numbers them.
    private static func checkDiffParsing() {
        let patch = "@@ -10,4 +10,5 @@ func a() {\n context\n-old\n+new\n+added\n tail\n\\ No newline at end of file"
        let lines = GHDiffLine.parse(patch)
        precondition(lines.map(\.kind) == [.hunk, .context, .deletion, .addition, .addition, .context, .context], "Diff line kinds")
        precondition(lines[1].old == 10 && lines[1].new == 10, "Context numbered on both sides")
        precondition(lines[2].old == 11 && lines[2].new == nil, "Deletion numbered on the old side")
        precondition(lines[3].new == 11 && lines[4].new == 12 && lines[3].old == nil, "Additions numbered on the new side")
        precondition(lines[5].old == 12 && lines[5].new == 13, "Context after changes")
        precondition(lines[6].old == nil && lines[6].text.hasPrefix("\\"), "No-newline marker isn't numbered")
        precondition(GHPullState(state: "OPEN", isDraft: true) == .draft && GHPullState(state: "MERGED", isDraft: false) == .merged
                     && GHPullState(state: "CLOSED", isDraft: true) == .closed, "Pull state mapping")
    }

    /// Navigation: switching tabs within a repository replaces the top of the trail instead of stacking.
    @MainActor
    private static func checkGitHubStore() {
        let store = GitHubStore()
        store.open(.repo("a/b", .code))
        store.open(.repo("a/b", .branches))
        precondition(store.path == [.repo("a/b", .branches)], "Tab switch replaces the trail's top")
        store.open(.pull("a/b", 3))
        store.open(.repo("c/d", .code))
        precondition(store.path.count == 3, "Another repository stacks")
        store.back()
        precondition(store.route == .pull("a/b", 3), "Back pops one step")
        store.home()
        precondition(store.route == nil, "Home clears the trail")

        store.loadDemo(repositories: [
            GHRepository(slug: "me/app", description: "Search app", stars: 5, pushedAt: Date(), language: GHLanguage(name: "Swift", color: nil)),
            GHRepository(slug: "me/old", isFork: true, isArchived: true, stars: 50, pushedAt: Date(timeIntervalSince1970: 0)),
            GHRepository(slug: "org/site", isPrivate: true, stars: 1, pushedAt: Date().addingTimeInterval(-60), language: GHLanguage(name: "Swift", color: nil)),
        ], details: [:], branches: [:], openPulls: [:], closedPulls: [:], commits: [:], pulls: [], files: [:])
        precondition(store.filteredRepositories.map(\.slug) == ["me/app", "org/site", "me/old"], "Sorted by last push")
        store.sort = .stars
        precondition(store.filteredRepositories.first?.slug == "me/old", "Sorted by stars")
        store.filter = .sources
        precondition(!store.filteredRepositories.contains { $0.isFork }, "Sources leaves out forks")
        store.filter = .privateOnly
        precondition(store.filteredRepositories.map(\.slug) == ["org/site"], "Private filter")
        store.filter = .all
        store.query = "search"
        precondition(store.filteredRepositories.map(\.slug) == ["me/app"], "Query matches descriptions")
        store.query = ""
        store.language = "Swift"
        precondition(store.filteredRepositories.count == 2 && store.languages == ["Swift"], "Language filter")
    }

    /// `GH_LIVE=1`: runs every GitHub query once against your account through `gh`, so a schema mistake shows up
    /// as a failure here rather than as an empty page.
    private static func live() {
        func ok<T>(_ label: String, _ result: Result<T, GitHubAPI.Failure>) -> T? {
            switch result {
            case .success(let value): print("  ✓ \(label)"); return value
            case .failure(let failure): print("  ✗ \(label): \(failure.message)"); return nil
            }
        }
        guard let repos = ok("repositories", GitHubAPI.repositories()) else { exit(1) }
        print("    \(repos.count) repositories, first: \(repos.first?.slug ?? "-")")
        // The most recently pushed repository with pull requests, else the most recent one.
        guard let repo = repos.first(where: { $0.openPulls > 0 }) ?? repos.first else { return }
        if let detail = ok("detail \(repo.slug)", GitHubAPI.detail(repo.slug)) {
            print("    \(detail.languages.count) languages, \(detail.commits.count) commits, readme: \(detail.readmeHTML?.count ?? 0) chars")
        }
        let base = repo.defaultBranch ?? "main"
        if let branches = ok("branches", GitHubAPI.branches(repo.slug, defaultBranch: base)) {
            print("    \(branches.count) branches: \(branches.prefix(4).map { "\($0.name) -\($0.behind)/+\($0.ahead)" })")
        }
        _ = ok("commits", GitHubAPI.commits(repo.slug, branch: base))
        // CI: the most recently pushed repository that has workflow runs.
        for candidate in repos.prefix(15) {
            guard case .success(let runs) = GitHubAPI.runs(candidate.slug, perPage: 5), let run = runs.first else { continue }
            print("  ✓ runs \(candidate.slug): \(runs.count), latest \(run.workflow) \(run.status.title) on \(run.branch)")
            if let jobs = ok("jobs", GitHubAPI.jobs(candidate.slug, run: run.id)), let job = jobs.first {
                print("    \(jobs.count) jobs, \(job.name): \(job.steps.count) steps")
                if let log = ok("log", GitHubAPI.jobLog(candidate.slug, job: job.id)) {
                    let lines = GHLogLine.parse(log)
                    print("    \(lines.count) log lines, \(lines.filter { $0.kind == .error }.count) errors, \(lines.filter { $0.kind == .group }.count) groups")
                }
            }
            break
        }
        for candidate in repos.prefix(10) {
            if case .success(let deploys) = GitHubAPI.deployments(candidate.slug), !deploys.isEmpty {
                print("  ✓ deployments \(candidate.slug): \(deploys.map { "\($0.environment) \($0.state.title) \($0.provider) \($0.url ?? "-")" })")
                break
            }
        }
        let open = ok("open pulls", GitHubAPI.pulls(repo.slug, open: true)) ?? []
        let closed = ok("closed pulls", GitHubAPI.pulls(repo.slug, open: false)) ?? []
        if let pr = open.first ?? closed.first {
            if let detail = ok("pull #\(pr.number)", GitHubAPI.pull(repo.slug, number: pr.number)) {
                print("    \(detail.summary.state) \(detail.commits.count) commits, \(detail.checks.count) checks, \(detail.timeline.count) timeline items, merge \(detail.mergeState)")
            }
            if let files = ok("files #\(pr.number)", GitHubAPI.files(repo.slug, number: pr.number)) {
                print("    \(files.count) files, \(files.compactMap(\.patch).map { GHDiffLine.parse($0).count }.reduce(0, +)) diff lines")
            }
        }
    }

    /// `REPO_BENCH=1`: times discovery and a cold read of this Mac's repositories.
    private static func bench() {
        var start = Date()
        let roots = RepoGit.discover(roots: RepoGit.defaultRoots, depth: 3)
        print("discover: \(roots.count) repos in \(Int(Date().timeIntervalSince(start) * 1000)) ms from \(RepoGit.defaultRoots)")
        start = Date()
        for root in roots {
            let t = Date()
            guard let (repo, _) = RepoStoreProbe.read(root) else { print("  unreadable", root); continue }
            print("  \(Int(Date().timeIntervalSince(t) * 1000)) ms", terminator: "")
            print("  \(repo.name) [\(repo.refLabel)] \(repo.changes.summary) unpushed=\(repo.unpushed.map(String.init) ?? "-") behind=\(repo.status.behind) wt=\(repo.worktrees.map { "\($0.refLabel)(\($0.owner ?? "-"))" }) merged=\(repo.mergedBranches.count) gh=\(repo.github ?? "-")")
        }
        print("read (serial): \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    private static func checkStatusParsing() {
        let text = """
        # branch.oid 1234567890abcdef
        # branch.head feat/search
        # branch.upstream origin/feat/search
        # branch.ab +2 -3
        1 .M N... 100644 100644 100644 abc abc src/a.swift
        1 M. N... 100644 100644 100644 abc abc src/b.swift
        1 MM N... 100644 100644 100644 abc abc src/c.swift
        2 R. N... 100644 100644 100644 abc abc R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 abc abc abc both.swift
        ? notes.md
        ? scratch/
        """
        let (branch, changes) = RepoGit.parseStatus(text)
        precondition(branch.branch == "feat/search" && branch.upstream == "origin/feat/search", "Status branch parsing")
        precondition(branch.ahead == 2 && branch.behind == 3, "Status ahead/behind parsing")
        precondition(changes.modified == 1 && changes.staged == 3 && changes.conflicted == 1 && changes.untracked == 2, "Status change counts: \(changes)")
        let detached = RepoGit.parseStatus("# branch.oid abc\n# branch.head (detached)\n").0
        precondition(detached.branch == nil && detached.head == "abc", "Detached status parsing")
        let initial = RepoGit.parseStatus("# branch.oid (initial)\n# branch.head main\n").0
        precondition(initial.head.isEmpty && initial.branch == "main", "Initial commit status parsing")
    }

    private static func checkWorktreeParsing() {
        let text = """
        worktree /code/app
        HEAD aaa
        branch refs/heads/main

        worktree /Users/me/.t3/worktrees/app/t3code-1
        HEAD bbb
        branch refs/heads/feat/x

        worktree /Users/me/.qoder/worktrees/app/d1/app
        HEAD ccc
        detached
        locked

        worktree /tmp/gone
        HEAD ddd
        branch refs/heads/old
        prunable gitdir file points to non-existent location

        """
        let list = RepoGit.parseWorktrees(text, mainRoot: "/code/app")
        precondition(list.count == 3, "Main checkout must be left out of worktrees")
        precondition(list[0].branch == "feat/x" && list[0].owner == "T3 Code", "T3 worktree parsing")
        precondition(list[1].branch == nil && list[1].isLocked && list[1].refLabel == "ccc" && list[1].owner == "Qoder", "Detached worktree parsing")
        precondition(list[2].isPrunable, "Prunable worktree parsing")
    }

    private static func checkSlugs() {
        for remote in ["git@github.com:ken/lookout.git", "https://github.com/ken/lookout", "https://github.com/ken/lookout.git",
                       "ssh://git@github.com/ken/lookout.git", "https://user@github.com/ken/lookout/"] {
            precondition(RepoFormat.githubSlug(remote) == "ken/lookout", "GitHub slug for \(remote)")
        }
        precondition(RepoFormat.githubSlug("git@gitlab.com:ken/lookout.git") == nil, "Non-GitHub remote must have no slug")
    }

    private static func checkHead() {
        precondition(GitCheckout.parseHead("ref: refs/heads/feat/a/b\n").branch == "feat/a/b", "HEAD branch parsing")
        let detached = GitCheckout.parseHead("0123456789abcdef\n")
        precondition(detached.branch == nil && detached.detached == "0123456789abcdef", "Detached HEAD parsing")
    }

    private static func checkGitHubParsing() {
        let json = """
        {"data":{"viewer":{"login":"ken"},
        "mine":{"nodes":[
          {"number":12,"title":"Add search","url":"https://github.com/ken/app/pull/12","isDraft":false,"updatedAt":"2026-10-05T16:47:29Z",
           "headRefName":"feat/search","reviewDecision":"APPROVED","mergeable":"MERGEABLE","repository":{"nameWithOwner":"ken/app"},
           "author":{"login":"ken"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}},
          {"number":13,"title":"Fix auth","url":"https://github.com/ken/app/pull/13","isDraft":false,"updatedAt":"2026-10-05T16:47:29Z",
           "headRefName":"fix/auth","reviewDecision":null,"mergeable":"CONFLICTING","repository":{"nameWithOwner":"ken/app"},
           "author":{"login":"ken"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"ERROR"}}}]}},
          {"number":14,"title":"No checks","url":"https://github.com/ken/app/pull/14","isDraft":true,"updatedAt":"2026-10-05T16:47:29Z",
           "headRefName":"wip","reviewDecision":null,"mergeable":"UNKNOWN","repository":{"nameWithOwner":"ken/app"},
           "author":{"login":"ken"},"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}
        ]},
        "review":{"nodes":[
          {"number":7,"title":"Teammate change","url":"https://github.com/org/api/pull/7","isDraft":false,"updatedAt":"2026-10-04T10:00:00Z",
           "headRefName":"feat/x","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","repository":{"nameWithOwner":"org/api"},
           "author":{"login":"sam"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING"}}}]}}
        ]}}}
        """
        let result = RepoGitHub.parse(Data(json.utf8))
        precondition(result.status == .ok(login: "ken"), "GitHub viewer parsing")
        precondition(result.pulls.count == 4, "GitHub pull count")
        let byNumber = Dictionary(uniqueKeysWithValues: result.pulls.map { ($0.number, $0) })
        precondition(byNumber[12]?.isReadyToMerge == true && byNumber[12]?.needsYou == false, "Approved green PR is ready")
        precondition(byNumber[13]?.checks == .failure && byNumber[13]?.mergeable == false && byNumber[13]?.needsYou == true, "Failing PR needs you")
        precondition(byNumber[14]?.checks == CheckState.none && byNumber[14]?.mergeable == nil && byNumber[14]?.isDraft == true, "Draft without checks")
        precondition(byNumber[7]?.role == .reviewRequested && byNumber[7]?.checks == .pending && byNumber[7]?.needsYou == true, "Review request")
        let failed = RepoGitHub.parse(Data(#"{"errors":[{"message":"Bad credentials"}]}"#.utf8))
        precondition(failed.status == .error("Bad credentials") && failed.pulls.isEmpty, "GitHub error parsing")
    }

    /// A throwaway repository with a commit, a dirty file, a merged branch, and a linked worktree on its own branch.
    private static func checkRealRepository() {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("repo-verify-\(UUID().uuidString)").path
        let main = base + "/app", worktree = base + "/wt"
        defer { try? fm.removeItem(atPath: base) }
        try? fm.createDirectory(atPath: main, withIntermediateDirectories: true)
        func git(_ dir: String, _ args: String...) {
            let out = RepoGit.run(RepoGit.gitPath, ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args)
            precondition(out.ok, "git \(args.joined(separator: " ")) failed: \(out.stderr)")
        }
        git(main, "init", "-q", "-b", "main")
        fm.createFile(atPath: main + "/a.txt", contents: Data("a".utf8))
        git(main, "add", ".")
        git(main, "commit", "-q", "-m", "first")
        git(main, "branch", "done-already")
        fm.createFile(atPath: main + "/b.txt", contents: Data("b".utf8))
        git(main, "add", ".")
        git(main, "commit", "-q", "-m", "second")
        git(main, "worktree", "add", "-q", "-b", "feat/wt", worktree)
        fm.createFile(atPath: main + "/dirty.txt", contents: Data("x".utf8))
        fm.createFile(atPath: worktree + "/wip.txt", contents: Data("y".utf8))

        let found = RepoGit.discover(roots: [base], depth: 2)
        precondition(found == [main], "Discovery must find the main checkout and skip the worktree: \(found)")

        let checkout = GitCheckout.locate(worktree + "/sub/../")
        precondition(checkout?.isLinkedWorktree == true && checkout?.branch == "feat/wt", "Worktree checkout: \(String(describing: checkout))")
        precondition(checkout?.repoName == "app" && checkout?.mainRoot.hasSuffix("/app") == true, "Worktree main repo")
        let mainCheckout = GitCheckout.locate(main)
        precondition(mainCheckout?.isLinkedWorktree == false && mainCheckout?.branch == "main", "Main checkout")

        guard let (repo, _) = RepoStoreProbe.read(main) else { preconditionFailure("Repository read failed") }
        precondition(repo.branch == "main" && repo.changes.untracked == 1, "Repository status: \(repo.changes)")
        precondition(repo.isLocalOnly && repo.unpushed == nil, "A repository without remotes is local-only")
        precondition(repo.mergedBranches == ["done-already"], "Merged branches: \(repo.mergedBranches)")
        precondition(repo.worktrees.count == 1 && repo.worktrees[0].branch == "feat/wt" && repo.worktrees[0].changes?.untracked == 1,
                     "Worktree status: \(repo.worktrees)")
        precondition(repo.hasLocalOnlyWork, "Dirty repository has local-only work")
    }
}
