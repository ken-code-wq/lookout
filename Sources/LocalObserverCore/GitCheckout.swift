import Foundation

/// The git checkout a folder belongs to: which repository, which branch, and whether it's a linked worktree
/// (`git worktree add`, or the per-task worktrees T3 Code, Qoder, Codex and friends create).
///
/// Read straight from the `.git` files, never by spawning git, so it's cheap enough to call on every scan.
/// Where the repository lives is cached per folder; HEAD is re-read on every call, so a `git switch` shows up
/// on the next scan.
public struct GitCheckout: Hashable, Sendable, Codable {
    /// Top of this checkout's working tree.
    public var root: String
    /// The main working tree. Equal to `root` unless this is a linked worktree.
    public var mainRoot: String
    /// Branch name, or nil on a detached HEAD.
    public var branch: String?
    /// Commit HEAD points at when detached; empty otherwise.
    public var detachedHead: String
    public var isLinkedWorktree: Bool

    public init(root: String, mainRoot: String, branch: String?, detachedHead: String = "", isLinkedWorktree: Bool) {
        self.root = root
        self.mainRoot = mainRoot
        self.branch = branch
        self.detachedHead = detachedHead
        self.isLinkedWorktree = isLinkedWorktree
    }

    /// The repository's name: the main checkout's folder, so `~/.t3/worktrees/workbook/t3code-0e8aa87a` reads as
    /// "workbook" rather than its throwaway folder name.
    public var repoName: String { (mainRoot as NSString).lastPathComponent }

    /// Branch, or the short commit for a detached HEAD.
    public var refLabel: String {
        if let branch { return branch }
        return detachedHead.isEmpty ? "detached" : String(detachedHead.prefix(7))
    }

    public var isDetached: Bool { branch == nil }

    /// The tool that made this worktree, guessed from where it lives.
    public var worktreeOwner: String? {
        guard isLinkedWorktree else { return nil }
        return Self.owner(ofWorktreeAt: root)
    }

    public static func owner(ofWorktreeAt path: String) -> String? {
        let home = NSHomeDirectory()
        let known: [(String, String)] = [
            ("/.t3/worktrees/", "T3 Code"), ("/.qoder/worktrees/", "Qoder"), ("/.codex/worktrees/", "Codex"),
            ("/.claude/worktrees/", "Claude Code"), ("/.cursor/worktrees/", "Cursor"), ("/conductor/workspaces/", "Conductor"),
            ("/.superset/worktrees/", "Superset"), ("/.vibe-kanban/", "Vibe Kanban"), ("/.windsurf/worktrees/", "Windsurf"),
        ]
        for (fragment, name) in known where path.hasPrefix(home + fragment) || path.contains(fragment) { return name }
        return nil
    }

    // MARK: Lookup

    /// Where a checkout's git data lives. HEAD is read fresh from `gitDir` on every lookup.
    private struct Location {
        var root: String
        var mainRoot: String
        var gitDir: String
        var linked: Bool
    }

    private static let lock = NSLock()
    /// Folder → location (nil: not inside a repository). Bounded; cleared wholesale when it grows past the cap.
    private static var cache: [String: Location?] = [:]

    /// The checkout containing `path`, or nil when it isn't inside a git working tree.
    public static func locate(_ path: String) -> GitCheckout? {
        guard !path.isEmpty, path != "/" else { return nil }
        let location: Location?
        lock.lock()
        if let cached = cache[path] {
            lock.unlock()
            location = cached
        } else {
            lock.unlock()
            let found = find(from: path)
            lock.lock()
            if cache.count > 2_000 { cache.removeAll() }
            cache[path] = found
            lock.unlock()
            location = found
        }
        guard let location else { return nil }
        let head = readHead(gitDir: location.gitDir)
        return GitCheckout(root: location.root, mainRoot: location.mainRoot, branch: head.branch,
                           detachedHead: head.detached, isLinkedWorktree: location.linked)
    }

    /// Forgets cached locations, e.g. after worktrees were added or removed.
    public static func resetCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func find(from path: String) -> Location? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var dir = (path as NSString).standardizingPath
        for _ in 0..<24 {
            let dotGit = dir + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                if isDir.boolValue {
                    return Location(root: dir, mainRoot: dir, gitDir: dotGit, linked: false)
                }
                // Linked worktree (or submodule): `.git` is a file saying `gitdir: <path>`.
                guard let gitDir = gitDirPointer(in: dotGit, relativeTo: dir) else { return nil }
                let common = commonDir(of: gitDir)
                // A submodule's gitdir has no commondir and lives under the parent's `.git/modules`.
                guard let common else { return Location(root: dir, mainRoot: dir, gitDir: gitDir, linked: false) }
                let main = (common as NSString).lastPathComponent == ".git"
                    ? (common as NSString).deletingLastPathComponent
                    : dir
                return Location(root: dir, mainRoot: main, gitDir: gitDir, linked: true)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty || dir == home || parent == "/" { return nil }
            dir = parent
        }
        return nil
    }

    static func gitDirPointer(in file: String, relativeTo dir: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let absolute = raw.hasPrefix("/") ? raw : dir + "/" + raw
        return (absolute as NSString).standardizingPath
    }

    /// `<gitdir>/commondir` points from a worktree's admin folder back to the shared `.git`.
    static func commonDir(of gitDir: String) -> String? {
        guard let text = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) else { return nil }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let absolute = raw.hasPrefix("/") ? raw : gitDir + "/" + raw
        return (absolute as NSString).standardizingPath
    }

    /// `ref: refs/heads/feat/x` → branch "feat/x"; a bare hash → detached at that commit.
    public static func parseHead(_ text: String) -> (branch: String?, detached: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let prefix = "refs/heads/"
            return (ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref, "")
        }
        return (nil, line)
    }

    private static func readHead(gitDir: String) -> (branch: String?, detached: String) {
        guard let text = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return (nil, "") }
        return parseHead(text)
    }
}
