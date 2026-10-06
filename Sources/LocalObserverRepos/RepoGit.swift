import Foundation

/// Runs git and parses what it says. Every call is read-only unless its name says otherwise, and none of them take
/// git's optional locks, so scanning never trips up an agent committing in the same repository.
public enum RepoGit {
    public static let gitPath = "/usr/bin/git"

    // MARK: Process

    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var ok: Bool { status == 0 }
    }

    /// Reads both pipes before waiting (waiting first deadlocks once output fills the pipe buffer), and kills the
    /// process after `timeout` so a repository on a sleeping network drive can't stall a scan.
    @discardableResult
    public static func run(_ executable: String, _ args: [String], in directory: String? = nil,
                           timeout: TimeInterval = 15, environment extra: [String: String] = [:]) -> Output {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let directory { proc.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        // Apps launched from Finder get a bare PATH; gh and git helpers (credential managers) live in these.
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ":")
        for (k, v) in extra { env[k] = v }
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice
        // A semaphore, not waitUntilExit: that polls a run loop, which adds ~100ms to every short-lived git call.
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch { return Output(status: -1, stdout: "", stderr: error.localizedDescription) }
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        exited.wait()
        killer.cancel()
        return Output(status: proc.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    static func git(_ root: String, _ args: [String], timeout: TimeInterval = 15) -> Output {
        run(gitPath, ["-C", root, "--no-optional-locks"] + args, timeout: timeout)
    }

    // MARK: Discovery

    /// Folders under home that usually hold code, when they exist.
    public static var defaultRoots: [String] {
        let home = NSHomeDirectory()
        let names = ["workspace", "Developer", "code", "Code", "Projects", "projects", "src", "dev", "repos", "GitHub",
                     "github", "Sites", "Documents/GitHub", "Documents/Projects", "Documents/code"]
        var seen = Set<String>()
        return names.map { home + "/" + $0 }.filter { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
            // Case-insensitive volumes list "Code" and "code" as the same folder.
            let real = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? path
            return seen.insert(real.lowercased()).inserted
        }
    }

    private static let skipped: Set<String> = [
        "node_modules", ".build", "build", "dist", "out", "Pods", "vendor", "target", "DerivedData", ".venv", "venv",
        "env", "__pycache__", "Library", "Applications", "Pictures", "Movies", "Music", ".Trash", "bower_components",
        ".next", ".nuxt", ".turbo", ".gradle", "Carthage", "coverage", "tmp",
    ]

    /// Main checkouts under `roots`, `depth` folders deep. Linked worktrees and submodules (a `.git` file, not a
    /// folder) are skipped: worktrees are listed under their repository instead.
    public static func discover(roots: [String], depth: Int) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        var seen = Set<String>()
        func visit(_ dir: String, _ level: Int) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir + "/.git", isDirectory: &isDir) {
                if isDir.boolValue, seen.insert(dir).inserted { found.append(dir) }
                return
            }
            guard level < depth,
                  let children = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for child in children where !child.hasPrefix(".") && !skipped.contains(child) {
                let path = dir + "/" + child
                var childIsDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &childIsDir), childIsDir.boolValue else { continue }
                // Don't follow symlinked folders: they loop, and point at repos found elsewhere anyway.
                if let attrs = try? fm.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { continue }
                // Skip app bundles and other packages.
                if child.hasSuffix(".app") || child.hasSuffix(".xcodeproj") || child.hasSuffix(".xcworkspace") { continue }
                visit(path, level + 1)
            }
        }
        for root in roots { visit((root as NSString).standardizingPath, 0) }
        return found
    }

    // MARK: Reading a repository

    /// Cheap fingerprint of a repository's refs: changes on commit, checkout, fetch, push, branch and worktree
    /// edits. When it hasn't moved, everything but `git status` is reused from the last scan.
    public static func refSignature(_ root: String) -> String {
        let git = root + "/.git"
        let files = ["HEAD", "index", "logs/HEAD", "FETCH_HEAD", "packed-refs", "worktrees", "refs/heads", "refs/remotes",
                     "logs/refs/stash", "config"]
        let fm = FileManager.default
        return files.map { file -> String in
            let date = (try? fm.attributesOfItem(atPath: git + "/" + file))?[.modificationDate] as? Date
            return date.map { String(Int($0.timeIntervalSince1970 * 1000)) } ?? "-"
        }.joined(separator: ":")
    }

    /// `git status --porcelain=v2 --branch` for one checkout.
    public static func status(_ root: String) -> (RepoBranchStatus, RepoChanges)? {
        let out = git(root, ["status", "--porcelain=v2", "--branch", "--untracked-files=normal", "--ignore-submodules=dirty"])
        guard out.ok else { return nil }
        return parseStatus(out.stdout)
    }

    public static func parseStatus(_ text: String) -> (RepoBranchStatus, RepoChanges) {
        var branch = RepoBranchStatus()
        var changes = RepoChanges()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# ") {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": branch.head = parts[2] == "(initial)" ? "" : parts[2]
                case "branch.head": branch.branch = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": branch.upstream = parts[2]
                case "branch.ab":
                    for token in parts[2].split(separator: " ") {
                        if token.hasPrefix("+") { branch.ahead = Int(token.dropFirst()) ?? 0 }
                        if token.hasPrefix("-") { branch.behind = Int(token.dropFirst()) ?? 0 }
                    }
                default: break
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // `1 XY …`: X is the index (staged) side, Y the worktree side; `.` means unchanged.
                let xy = Array(line.dropFirst(2).prefix(2))
                guard xy.count == 2 else { continue }
                if xy[0] != "." { changes.staged += 1 } else if xy[1] != "." { changes.modified += 1 }
            } else if line.hasPrefix("u ") {
                changes.conflicted += 1
            } else if line.hasPrefix("? ") {
                changes.untracked += 1
            }
        }
        return (branch, changes)
    }

    /// `git worktree list --porcelain`, minus the main checkout.
    public static func parseWorktrees(_ text: String, mainRoot: String) -> [RepoWorktree] {
        var result: [RepoWorktree] = []
        for block in text.components(separatedBy: "\n\n") {
            var path = "", head = "", branch: String? = nil, locked = false, prunable = false, bare = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst("HEAD ".count)) }
                else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst("branch ".count))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                }
                else if line.hasPrefix("locked") { locked = true }
                else if line.hasPrefix("prunable") { prunable = true }
                else if line == "bare" { bare = true }
            }
            guard !path.isEmpty, !bare, (path as NSString).standardizingPath != (mainRoot as NSString).standardizingPath else { continue }
            result.append(RepoWorktree(path: path, branch: branch, head: head, isLocked: locked, isPrunable: prunable))
        }
        return result
    }

    /// What doesn't change between commits: remote, default branch, merged branches, worktrees, last commit.
    struct RefInfo {
        var unpushed: Int?
        var lastCommitAt: Date?
        var subject = ""
        var author = ""
        var remoteURL = ""
        var defaultBranch: String?
        var merged: [String] = []
        var branchCount = 0
        var worktrees: [RepoWorktree] = []
    }

    static func refInfo(_ root: String, currentBranch: String?) -> RefInfo {
        var info = RefInfo()
        let log = git(root, ["log", "-1", "--format=%ct%x1f%s%x1f%an"])
        if log.ok {
            let parts = log.stdout.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1F}")
            if parts.count >= 3 {
                info.lastCommitAt = TimeInterval(parts[0]).map(Date.init(timeIntervalSince1970:))
                info.subject = parts[1]
                info.author = parts[2]
            }
        }
        let remotes = git(root, ["remote"]).stdout.split(separator: "\n").map(String.init)
        if !remotes.isEmpty {
            let remote = remotes.contains("origin") ? "origin" : remotes[0]
            info.remoteURL = git(root, ["remote", "get-url", remote]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // Commits on HEAD that no remote-tracking branch contains, upstream or not.
            if info.lastCommitAt != nil {
                info.unpushed = Int(git(root, ["rev-list", "--count", "HEAD", "--not", "--remotes"]).stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let head = git(root, ["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"])
            if head.ok {
                let ref = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                info.defaultBranch = ref.hasPrefix(remote + "/") ? String(ref.dropFirst(remote.count + 1)) : ref
            }
        }
        let branches = git(root, ["branch", "--format=%(refname:short)"]).stdout
            .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        info.branchCount = branches.count
        if info.defaultBranch == nil {
            info.defaultBranch = ["main", "master", "trunk", "develop"].first(where: branches.contains)
        }
        let worktrees = git(root, ["worktree", "list", "--porcelain"])
        if worktrees.ok { info.worktrees = parseWorktrees(worktrees.stdout, mainRoot: root) }
        if let base = info.defaultBranch, branches.contains(base) {
            let checkedOut = Set([currentBranch] + info.worktrees.map(\.branch)).compactMap { $0 }
            // `--no-contains`: a branch freshly cut from the default branch has nothing in it yet, but it isn't done.
            info.merged = git(root, ["branch", "--merged", base, "--no-contains", base, "--format=%(refname:short)"]).stdout
                .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != base && !checkedOut.contains($0) }
        }
        return info
    }

    /// Lines in the stash reflog, without spawning git.
    static func stashCount(_ root: String) -> Int {
        guard let text = try? String(contentsOfFile: root + "/.git/logs/refs/stash", encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    /// When the index was last written: staging, committing, or switching branches all touch it.
    static func indexTouched(_ gitDir: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: gitDir + "/index"))?[.modificationDate] as? Date
    }

    // MARK: Actions

    /// `git fetch --prune` of every remote. Network; can take a while.
    public static func fetch(_ root: String) -> Output { git(root, ["fetch", "--all", "--prune", "--quiet"], timeout: 90) }

    /// Fast-forward only, so a pull can never start a merge or rebase.
    public static func pull(_ root: String) -> Output { git(root, ["pull", "--ff-only", "--quiet"], timeout: 90) }

    /// `git branch -d` refuses unmerged branches, so this can only remove work that's safe in the default branch.
    public static func deleteMergedBranches(_ root: String, _ branches: [String]) -> Output {
        guard !branches.isEmpty else { return Output(status: 0, stdout: "", stderr: "") }
        return git(root, ["branch", "-d"] + branches)
    }

    /// Forgets worktrees whose folders are gone.
    /// Pushes the checked-out branch, setting its upstream on first push.
    public static func push(_ path: String) -> Output { git(path, ["push", "--set-upstream", "origin", "HEAD", "--quiet"], timeout: 120) }

    /// No --force: git refuses when the worktree has modified or untracked files.
    public static func removeWorktree(_ mainRoot: String, path: String) -> Output { git(mainRoot, ["worktree", "remove", path], timeout: 120) }

    public static func pruneWorktrees(_ root: String) -> Output { git(root, ["worktree", "prune"]) }
}
