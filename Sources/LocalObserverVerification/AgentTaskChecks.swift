import Foundation
import LocalObserverCore
import LocalObserverRepos

/// Starting agent tasks: prompts survive shell quoting byte for byte, branch and folder names are tidy and never
/// collide, each CLI gets the right arguments, launched tasks find their sessions, and a real worktree gets made.
enum AgentTaskChecks {
    @MainActor
    static func run() {
        checkQuoting()
        checkSlugs()
        checkUniqueness()
        checkArguments()
        checkScript()
        checkLocator()
        checkMatching()
        checkOrdering()
        checkStore()
        checkRealWorktree()
    }

    /// Quoted text goes through a real shell and comes back unchanged.
    private static func checkQuoting() {
        precondition(ShellQuote.quote("plain-word_1.txt") == "plain-word_1.txt", "Safe words stay bare")
        precondition(ShellQuote.quote("") == "''", "Empty string is an empty word")
        precondition(ShellQuote.quote("it's") == "'it'\\''s'", "Single quotes are closed, escaped, reopened")
        precondition(ShellQuote.appleScript("say \"hi\" \\ bye") == "say \\\"hi\\\" \\\\ bye", "AppleScript escaping")
        precondition(ShellQuote.yaml("a \"b\"\nc") == "\"a \\\"b\\\"\\nc\"", "YAML escaping")
        let nasty = [
            "Fix the bug in `parse()` and $(rm -rf ~) don't run this",
            "quotes ' \" '' \"\" and backslash \\ \\n",
            "multi\nline\n\tprompt with ünïcödé and emoji 🚀",
            "$HOME ${PATH} !! !$ * ? [a-z] ~ ; | & > < # %",
            "-n", "--help", "'", "\\",
        ]
        for text in nasty {
            for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
                let out = RepoGit.run(shell, ["-c", "printf %s " + ShellQuote.quote(text)])
                precondition(out.ok && out.stdout == text, "\(shell) didn't read back \(text.debugDescription): \(out.stdout.debugDescription)")
            }
        }
        let argv = ["/x/claude", "a b", "c'd"]
        let out = RepoGit.run("/bin/zsh", ["-c", "printf '%s\\n' " + ShellQuote.command(Array(argv.dropFirst()))])
        precondition(out.stdout == "a b\nc'd\n", "Each argument stays one word")
    }

    private static func checkSlugs() {
        precondition(AgentTaskNaming.slug("Fix the flaky login test (again!)") == "fix-the-flaky-login-test-again", "Basic slug")
        precondition(AgentTaskNaming.slug("  Résumé   upload: café  ") == "resume-upload-cafe", "Accents fold, punctuation collapses")
        precondition(AgentTaskNaming.slug("!!!") == "task" && AgentTaskNaming.slug("") == "task", "Nothing usable falls back to task")
        precondition(AgentTaskNaming.slug("日本語のテスト") == "task", "Non-Latin text falls back to task")
        let long = AgentTaskNaming.slug("Refactor the authentication middleware so that sessions expire properly after logout")
        precondition(long.count <= 40 && !long.hasSuffix("-") && long.hasPrefix("refactor-the-authentication"), "Long prompts cut at a word: \(long)")
        precondition(AgentTaskNaming.slug(String(repeating: "a", count: 60)).count == 40, "One huge word is truncated")
        precondition(AgentTaskNaming.slug("Fix CI\non main") == "fix-ci-on-main", "Newlines are separators")
    }

    private static func checkUniqueness() {
        let taken: Set<String> = ["main", "agent/fix-login", "Agent/Fix-Login-2"]
        precondition(AgentTaskNaming.branchName(for: "Add search", taken: taken) == "agent/add-search", "Free name used as is")
        precondition(AgentTaskNaming.branchName(for: "Fix login", taken: taken) == "agent/fix-login-3", "Collisions count up, ignoring case")
        precondition(AgentTaskNaming.worktreeContainer(repoRoot: "/Users/me/code/app/") == "/Users/me/code/app-worktrees", "Worktrees go beside the repository")
        let existing: Set<String> = ["/Users/me/code/app-worktrees/fix-login"]
        let path = AgentTaskNaming.worktreePath(repoRoot: "/Users/me/code/app", branch: "agent/fix-login", exists: existing.contains)
        precondition(path == "/Users/me/code/app-worktrees/fix-login-2", "Folder made unique: \(path)")
        precondition(AgentTaskNaming.worktreePath(repoRoot: "/r/app", branch: "feat/x", exists: { _ in false }) == "/r/app-worktrees/feat-x",
                     "Other prefixes become part of the folder name")
    }

    private static func checkArguments() {
        precondition(AgentCLI.claude.arguments(prompt: "  do it \n") == ["do it"], "Claude takes the prompt as its argument")
        precondition(AgentCLI.openCode.arguments(prompt: "x") == ["--prompt", "x"], "OpenCode uses --prompt")
        precondition(AgentCLI.copilot.arguments(prompt: "x") == ["-i", "x"], "Copilot uses -i to stay interactive")
        precondition(AgentCLI.codex.arguments(prompt: "   ").isEmpty, "Blank prompt starts the agent without one")
        precondition(AgentCLI.allCases.allSatisfy { !$0.executableNames.isEmpty }, "Every CLI has an executable")
        precondition(AgentTaskScript.preview(.claude, prompt: "Fix it's bug") == "claude 'Fix it'\\''s bug'", "Preview command")
    }

    private static func checkScript() {
        let script = AgentTaskScript.script(directory: "/tmp/my app", executable: "/opt/homebrew/bin/claude", arguments: ["it's $HOME"],
                                            title: "app: fix", searchPath: ["/opt/homebrew/bin", "/Users/me/.nvm/versions/node/v22.1.0/bin"])
        let lines = script.split(separator: "\n").map(String.init)
        precondition(lines.first == "#!/bin/zsh -l", "Script runs in a login zsh")
        precondition(lines.contains("cd '/tmp/my app' || exit 1"), "Script cds into the checkout")
        precondition(lines.contains("/opt/homebrew/bin/claude 'it'\\''s $HOME'"), "Script runs the agent with the quoted prompt")
        precondition(lines.last == "exec \"${SHELL:-/bin/zsh}\" -l", "Script leaves you in a shell afterwards")
        precondition(lines.contains { $0.hasPrefix("export PATH=/opt/homebrew/bin:/Users/me/.nvm") }, "Script extends PATH")
        // The script itself must be valid zsh.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agent-task-\(UUID().uuidString).zsh").path
        try? script.write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        precondition(RepoGit.run("/bin/zsh", ["-n", file]).ok, "Launch script parses")

        let warp = AgentTaskScript.warpLaunchConfiguration(name: "Lookout", title: "t", directory: "/tmp/a", scriptPath: "/tmp/s s.command")
        precondition(warp.contains("cwd: \"/tmp/a\"") && warp.contains("exec: \"'/tmp/s s.command'\""), "Warp launch configuration")
        let iterm = AgentTaskScript.iTermAppleScript(scriptPath: "/tmp/a b.command")
        precondition(iterm.contains("command \"/bin/zsh -l '/tmp/a b.command'\""), "iTerm script")
    }

    private static func checkLocator() {
        let dirs = AgentCLILocator.searchDirectories(home: "/Users/me", path: "/usr/bin:/opt/homebrew/bin", nodeVersions: ["v18.2.0", "v22.10.1", "v22.9.0"])
        precondition(dirs.first == "/Users/me/.local/bin", "Agent installers' own folder first")
        precondition(dirs.filter { $0 == "/opt/homebrew/bin" }.count == 1, "Folders listed once")
        let nvm = dirs.filter { $0.contains(".nvm") }
        precondition(nvm.first == "/Users/me/.nvm/versions/node/v22.10.1/bin" && nvm.last?.contains("v18") == true, "Newest Node first")
        precondition(dirs.last == "/usr/bin", "Inherited PATH last")
        let found = AgentCLILocator.locate(.cursor, in: dirs) { $0 == "/opt/homebrew/bin/cursor-agent" || $0 == "/usr/bin/cursor-agent" }
        precondition(found == "/opt/homebrew/bin/cursor-agent", "First folder wins")
        precondition(AgentCLILocator.locate(.claude, in: dirs) { _ in false } == nil, "Missing CLI is nil")
    }

    private static func task(_ dir: String, at: TimeInterval, repo: String = "/r/app") -> AgentTask {
        AgentTask(repoRoot: repo, repoName: (repo as NSString).lastPathComponent, directory: dir, branch: "agent/x", baseBranch: "main",
                  isWorktree: true, cli: .claude, prompt: "Do it\nmore", terminal: .terminal, launchedAt: Date(timeIntervalSince1970: at))
    }

    private static func checkMatching() {
        let early = task("/r/app", at: 1_000), late = task("/r/app", at: 5_000), wt = task("/r/app-worktrees/x", at: 1_000)
        let tasks = [early, late, wt]
        func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
        precondition(AgentTaskStore.match(path: "/r/app-worktrees/x/src", startedAt: at(1_010), in: tasks) == wt, "Subfolders of a worktree match")
        precondition(AgentTaskStore.match(path: "/r/app", startedAt: at(5_005), in: tasks) == late, "Newest task in the window wins")
        precondition(AgentTaskStore.match(path: "/r/app", startedAt: at(1_005), in: tasks) == early, "Earlier task for earlier session")
        precondition(AgentTaskStore.match(path: "/r/app", startedAt: at(3_500), in: tasks) == nil, "Sessions long after a launch aren't claimed")
        precondition(AgentTaskStore.match(path: "/r/application", startedAt: at(1_005), in: tasks) == nil, "Prefix of a folder name isn't a match")
        precondition(AgentTaskStore.match(path: "/r/app", startedAt: at(900), in: tasks) == early, "Slightly-early clocks still match")
        precondition(early.summary == "Do it", "Summary is the first line")
    }

    private static func checkOrdering() {
        let now = Date()
        let a = Repo(root: "/r/a", name: "a", lastTouched: now)
        let b = Repo(root: "/r/b", name: "b", lastTouched: now.addingTimeInterval(-100))
        let c = Repo(root: "/r/c", name: "c", lastTouched: now.addingTimeInterval(-50))
        let d = Repo(root: "/r/d", name: "d", lastTouched: now.addingTimeInterval(-500))
        let tasks = [task("/r/b", at: 10, repo: "/r/b"), task("/r/d", at: 20, repo: "/r/d"), task("/r/b", at: 5, repo: "/r/b")]
        let order = AgentTaskStore.recentFirst([a, b, c, d], tasks: tasks).map(\.name)
        precondition(order == ["d", "b", "a", "c"], "Recent task repositories first, then last touched: \(order)")
    }

    @MainActor
    private static func checkStore() {
        let suite = "agent-task-verify-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentTaskStore(defaults: defaults)
        precondition(store.templates.map(\.title).contains(AgentPromptTemplate.fixCI), "Default templates")
        store.record(task("/r/app", at: 1))
        store.saveTemplate(title: " Mine ", prompt: "Do {repo} on {branch}")
        store.settings.terminal = .ghostty
        let reloaded = AgentTaskStore(defaults: defaults)
        precondition(reloaded.tasks.count == 1 && reloaded.tasks[0].prompt == "Do it\nmore", "Tasks persist")
        precondition(reloaded.templates.last?.title == "Mine", "Templates persist, trimmed")
        precondition(reloaded.templates.last?.expanded(repo: "app", branch: nil) == "Do app on this branch", "Placeholders fill in")
        precondition(reloaded.settings.terminal == .ghostty && reloaded.settings.useWorktree, "Settings persist")
        for i in 0..<(AgentTaskStore.limit + 5) { reloaded.record(task("/r/\(i)", at: Double(i))) }
        precondition(reloaded.tasks.count == AgentTaskStore.limit && reloaded.tasks[0].directory == "/r/\(AgentTaskStore.limit + 4)", "History is capped, newest kept")
    }

    /// A temporary repository: two tasks with the same prompt get separate branches and folders, both off main.
    private static func checkRealWorktree() {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("agent-task-verify-\(UUID().uuidString)").path
        let root = base + "/app"
        defer { try? fm.removeItem(atPath: base) }
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        func git(_ args: String...) -> RepoGit.Output {
            RepoGit.run(RepoGit.gitPath, ["-C", root, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args)
        }
        precondition(git("init", "-q", "-b", "main").ok, "git init")
        fm.createFile(atPath: root + "/a.txt", contents: Data("a".utf8))
        _ = git("add", ".")
        precondition(git("commit", "-q", "-m", "first").ok, "git commit")
        _ = git("branch", "develop")

        precondition(AgentTaskGit.localBranches(root, defaultBranch: "main") == ["main", "develop"], "Default branch listed first")
        guard case .success(let first) = AgentTaskGit.create(root: root, prompt: "Fix the login bug", base: "main"),
              case .success(let second) = AgentTaskGit.create(root: root, prompt: "Fix the login bug", base: "develop") else {
            preconditionFailure("Worktree creation failed")
        }
        precondition(first.branch == "agent/fix-the-login-bug" && second.branch == "agent/fix-the-login-bug-2", "Branches unique")
        precondition(first.path == base + "/app-worktrees/fix-the-login-bug" && second.path == base + "/app-worktrees/fix-the-login-bug-2",
                     "Folders beside the repository: \(first.path)")
        precondition(fm.fileExists(atPath: second.path + "/a.txt"), "Worktree is checked out")
        let checkout = GitCheckout.locate(second.path)
        precondition(checkout?.isLinkedWorktree == true && checkout?.branch == "agent/fix-the-login-bug-2", "Worktree reads as linked, on its branch")
        precondition(RepoGit.parseWorktrees(git("worktree", "list", "--porcelain").stdout, mainRoot: root).count == 2, "Both worktrees listed")
        if case .success = AgentTaskGit.create(root: root, prompt: "x", base: "no-such-branch") {
            preconditionFailure("A missing base branch should fail")
        }
    }
}
