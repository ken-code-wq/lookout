import Foundation

// What an agent has changed in its checkout: the working tree against HEAD, and the commits it made since its session
// started. Parsing is pure and checked in LocalObserverVerification; the git calls are read-only except `revert`.

/// How a file differs from HEAD, in git's name-status terms plus untracked files.
public enum RepoDiffStatus: String, Hashable, Sendable, CaseIterable {
    case added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted

    /// `M`, `R100`, `C75`, …: git's name-status letter, with any similarity score after it.
    public init?(code: Substring) {
        switch code.first {
        case "A": self = .added
        case "M": self = .modified
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        case "?": self = .untracked
        default: return nil
        }
    }

    /// One letter, so a file's status never rests on colour alone.
    public var letter: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }

    public var title: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        case .untracked: return "Untracked"
        case .conflicted: return "Conflicted"
        }
    }

    /// The file exists in the working tree, so it can be opened.
    public var existsOnDisk: Bool { self != .deleted }
}

/// One changed file. Paths are relative to the checkout root.
public struct RepoDiffFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    /// Where a renamed or copied file came from.
    public var oldPath: String?
    public var status: RepoDiffStatus
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool
    /// Unified-diff hunks, from the first `@@`. Nil for binary files, pure renames, and files too large to show.
    public var patch: String?
    /// The diff (or the untracked file) was over `RepoDiff.maxPatchBytes`, so it isn't shown or counted in full.
    public var isTooLarge: Bool

    public init(path: String, oldPath: String? = nil, status: RepoDiffStatus, additions: Int = 0, deletions: Int = 0,
                isBinary: Bool = false, patch: String? = nil, isTooLarge: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.patch = patch
        self.isTooLarge = isTooLarge
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// The file as a standalone `git diff` section, for copying.
    public var unifiedText: String {
        let old = status == .added || status == .untracked ? "/dev/null" : "a/" + (oldPath ?? path)
        let new = status == .deleted ? "/dev/null" : "b/" + path
        var text = "diff --git a/\(oldPath ?? path) b/\(path)\n"
        if let oldPath, status == .renamed { text += "rename from \(oldPath)\nrename to \(path)\n" }
        if isBinary { return text + "Binary files \(old) and \(new) differ\n" }
        guard let patch, !patch.isEmpty else { return text }
        return text + "--- \(old)\n+++ \(new)\n" + patch + (patch.hasSuffix("\n") ? "" : "\n")
    }
}

/// "+120 −34 · 7 files": the compact line agent rows show.
public struct RepoDiffSummary: Hashable, Sendable {
    public var files: Int
    public var additions: Int
    public var deletions: Int

    public init(files: Int = 0, additions: Int = 0, deletions: Int = 0) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }

    public init(_ files: [RepoDiffFile]) {
        self.init(files: files.count, additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
    }

    public var isEmpty: Bool { files == 0 }
    /// Big enough that it's worth a second look before trusting it: see `RepoDiff.largeChangeFileCount`.
    public var isLarge: Bool { files >= RepoDiff.largeChangeFileCount }
    public var filesLabel: String { "\(files) file\(files == 1 ? "" : "s")" }
    public var label: String { "+\(additions) −\(deletions) · \(filesLabel)" }
}

/// A commit made in the checkout since the session started.
public struct RepoDiffCommit: Identifiable, Hashable, Sendable {
    public var id: String { sha }
    public var sha: String
    public var subject: String
    public var date: Date?

    public init(sha: String, subject: String, date: Date?) {
        self.sha = sha
        self.subject = subject
        self.date = date
    }
}

/// What HEAD gained during the session: the commit it started on, the commits since, and their combined diff.
public struct RepoSessionCommits: Hashable, Sendable {
    public var base: String
    public var commits: [RepoDiffCommit]
    public var files: [RepoDiffFile]
    /// False when HEAD moved somewhere that doesn't contain the starting commit (a branch switch or rebase), so the
    /// diff includes work that isn't the agent's.
    public var baseIsAncestor: Bool

    public init(base: String, commits: [RepoDiffCommit], files: [RepoDiffFile], baseIsAncestor: Bool) {
        self.base = base
        self.commits = commits
        self.files = files
        self.baseIsAncestor = baseIsAncestor
    }
}

/// Everything changed in one checkout, read in one go.
public struct RepoWorkDiff: Hashable, Sendable {
    public var root: String
    /// HEAD's commit; empty in a repository with no commits yet.
    public var head: String
    /// Working tree (staged and not) against HEAD, plus untracked files.
    public var uncommitted: [RepoDiffFile]
    /// Nil when the session's starting commit couldn't be found, or nothing was committed since.
    public var committed: RepoSessionCommits?
    /// Why `committed` is nil, when that's worth saying.
    public var committedNote: String?
    public var checkedAt: Date

    public init(root: String, head: String, uncommitted: [RepoDiffFile], committed: RepoSessionCommits? = nil,
                committedNote: String? = nil, checkedAt: Date = Date()) {
        self.root = root
        self.head = head
        self.uncommitted = uncommitted
        self.committed = committed
        self.committedNote = committedNote
        self.checkedAt = checkedAt
    }

    public var summary: RepoDiffSummary { RepoDiffSummary(uncommitted) }

    /// The uncommitted changes as one `git diff`, for copying.
    public var unifiedText: String { uncommitted.map(\.unifiedText).joined() }
}

public enum RepoDiff {
    /// A session touching this many files gets a warning: big enough to review before trusting.
    public static let largeChangeFileCount = 40
    /// Per-file diffs (and untracked files) above this aren't shown or line-counted.
    public static let maxPatchBytes = 512 * 1024
    /// Untracked files read for line counts per refresh; any beyond still count as files.
    public static let maxUntrackedRead = 200

    // MARK: Parsing

    /// `git diff --numstat -z`: `12\t3\tpath\0`, or `12\t3\t\0old\0new\0` for a rename; `-\t-\t` for binary files.
    public struct Numstat: Hashable, Sendable {
        public var path: String
        public var oldPath: String?
        /// Nil for binary files.
        public var additions: Int?
        public var deletions: Int?
    }

    public static func parseNumstat(_ text: String) -> [Numstat] {
        var tokens = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        var result: [Numstat] = []
        while let token = tokens.popFirst() {
            guard !token.isEmpty else { continue }
            let parts = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let added = Int(parts[0]), deleted = Int(parts[1])
            if parts[2].isEmpty {
                // Rename or copy: the two paths follow as their own tokens.
                guard let old = tokens.popFirst(), let new = tokens.popFirst() else { break }
                result.append(Numstat(path: new, oldPath: old, additions: added, deletions: deleted))
            } else {
                result.append(Numstat(path: String(parts[2]), oldPath: nil, additions: added, deletions: deleted))
            }
        }
        return result
    }

    /// `git diff --name-status -z`: `M\0path\0`, or `R100\0old\0new\0` for renames and copies.
    public struct NameStatus: Hashable, Sendable {
        public var status: RepoDiffStatus
        public var path: String
        public var oldPath: String?
    }

    public static func parseNameStatus(_ text: String) -> [NameStatus] {
        var tokens = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        var result: [NameStatus] = []
        while let code = tokens.popFirst() {
            guard !code.isEmpty else { continue }
            guard let status = RepoDiffStatus(code: Substring(code)), let first = tokens.popFirst() else { continue }
            if status == .renamed || status == .copied {
                guard let second = tokens.popFirst() else { break }
                result.append(NameStatus(status: status, path: second, oldPath: first))
            } else {
                result.append(NameStatus(status: status, path: first, oldPath: nil))
            }
        }
        return result
    }

    /// One file's section of a `git diff -p`.
    public struct PatchSection: Hashable, Sendable {
        public var path: String
        public var oldPath: String?
        public var isBinary: Bool
        /// From the first `@@` on; empty for binary files and pure renames.
        public var hunks: String
    }

    /// Splits `git diff -p` into files. Paths come from the `---`/`+++`, `rename` and `Binary files` lines, which
    /// git writes unambiguously (quoted when unusual); the `diff --git` line is only a fallback, since a path with
    /// " b/" in it can't be split reliably.
    public static func parseUnifiedDiff(_ text: String) -> [PatchSection] {
        var sections: [PatchSection] = []
        var lines: [Substring] = []
        func flush() {
            if let section = section(lines) { sections.append(section) }
            lines.removeAll(keepingCapacity: true)
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") { flush() }
            lines.append(line)
        }
        flush()
        return sections
    }

    private static func section(_ lines: [Substring]) -> PatchSection? {
        guard let first = lines.first, first.hasPrefix("diff --") else { return nil }
        var minus: String?, plus: String?, renameFrom: String?, renameTo: String?
        var binary = false
        var hunkStart: Int?
        for (i, line) in lines.enumerated().dropFirst() {
            if line.hasPrefix("@@") { hunkStart = i; break }
            if line.hasPrefix("--- ") { minus = headerPath(line.dropFirst(4), prefix: "a/") }
            else if line.hasPrefix("+++ ") { plus = headerPath(line.dropFirst(4), prefix: "b/") }
            else if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
                renameFrom = unquote(String(line.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst()))
            }
            else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
                renameTo = unquote(String(line.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst()))
            }
            else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { binary = true }
        }
        let fallback = gitLinePaths(first)
        guard let path = plus ?? renameTo ?? minus ?? fallback?.new else { return nil }
        var old = renameFrom
        if old == nil, let minus, minus != path { old = minus }
        if old == nil, binary, let fallback, fallback.old != path { old = fallback.old }
        var hunks = ""
        if let hunkStart {
            var body = lines[hunkStart...]
            // The split leaves an empty string after the final newline.
            if body.last?.isEmpty == true { body = body.dropLast() }
            hunks = body.joined(separator: "\n")
        }
        return PatchSection(path: path, oldPath: old, isBinary: binary, hunks: hunks)
    }

    /// `a/path`, `"a/odd\tpath"`, `/dev/null` (nil), and git's trailing tab after paths with spaces.
    static func headerPath(_ raw: Substring, prefix: String) -> String? {
        var value = String(raw)
        if value.hasSuffix("\t") { value.removeLast() }
        value = unquote(value)
        if value == "/dev/null" { return nil }
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    /// `diff --git a/x b/x`, split down the middle: both halves are the same path unless it was renamed, and when it
    /// was, the `rename` lines say so anyway.
    static func gitLinePaths(_ line: Substring) -> (old: String, new: String)? {
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("\"") {
            // Quoted: "a/…" "b/…"
            let parts = rest.components(separatedBy: "\" \"")
            guard parts.count == 2 else { return nil }
            let a = unquote(parts[0] + "\""), b = unquote("\"" + parts[1])
            return (String(a.dropFirst(2)), String(b.dropFirst(2)))
        }
        let chars = Array(rest)
        guard chars.count >= 7 else { return nil }
        // Same path on both sides: "a/" + p + " b/" + p, so the split is at the middle.
        let half = (chars.count - 1) / 2
        if chars.count % 2 == 1, chars[half] == " " {
            let a = String(chars[..<half]), b = String(chars[(half + 1)...])
            if a.hasPrefix("a/"), b.hasPrefix("b/"), a.dropFirst(2) == b.dropFirst(2) { return (String(a.dropFirst(2)), String(b.dropFirst(2))) }
        }
        guard let range = rest.range(of: " b/") else { return nil }
        return (String(rest[..<range.lowerBound].dropFirst(2)), String(rest[range.upperBound...]))
    }

    /// Undoes git's C-style quoting (`"tab\there"`, `"caf\303\251"`); unquoted text is returned as is.
    public static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        let inner = Array(text.utf8.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var i = 0
        while i < inner.count {
            let c = inner[i]
            guard c == UInt8(ascii: "\\"), i + 1 < inner.count else { bytes.append(c); i += 1; continue }
            let next = inner[i + 1]
            switch next {
            case UInt8(ascii: "n"): bytes.append(10); i += 2
            case UInt8(ascii: "t"): bytes.append(9); i += 2
            case UInt8(ascii: "r"): bytes.append(13); i += 2
            case UInt8(ascii: "a"): bytes.append(7); i += 2
            case UInt8(ascii: "b"): bytes.append(8); i += 2
            case UInt8(ascii: "f"): bytes.append(12); i += 2
            case UInt8(ascii: "v"): bytes.append(11); i += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0, j = i + 1
                while j < inner.count, j < i + 4, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(inner[j]) {
                    value = value * 8 + Int(inner[j] - UInt8(ascii: "0"))
                    j += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                i = j
            default: bytes.append(next); i += 2
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Joins name-status, numstat and patch output into one list, sorted by path. Name-status decides what's in it.
    public static func merge(nameStatus: [NameStatus], numstat: [Numstat], patches: [PatchSection]) -> [RepoDiffFile] {
        let counts = Dictionary(numstat.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let sections = Dictionary(patches.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return nameStatus.map { entry in
            let count = counts[entry.path]
            let section = sections[entry.path]
            let binary = section?.isBinary == true || (count != nil && count?.additions == nil)
            var file = RepoDiffFile(path: entry.path, oldPath: entry.oldPath, status: entry.status,
                                    additions: count?.additions ?? 0, deletions: count?.deletions ?? 0, isBinary: binary)
            if let hunks = section?.hunks, !hunks.isEmpty, !binary {
                if hunks.utf8.count > maxPatchBytes { file.isTooLarge = true } else { file.patch = hunks }
            }
            return file
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// An untracked file as an all-additions diff. Nil when it looks binary (a NUL byte in the first 8 KB).
    public static func untrackedPatch(_ data: Data) -> (patch: String, lines: Int)? {
        if data.isEmpty { return ("", 0) }
        if data.prefix(8_192).contains(0) { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let missingNewline = !text.hasSuffix("\n")
        if !missingNewline { lines.removeLast() }
        var patch = "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n")
        if missingNewline { patch += "\n\\ No newline at end of file" }
        return (patch, lines.count)
    }

    // MARK: Session baseline

    /// One HEAD reflog entry: the commit HEAD moved to, when, and why ("commit: …", "checkout: …").
    public struct ReflogEntry: Hashable, Sendable {
        public var sha: String
        public var date: Date
        public var subject: String
    }

    /// `git log -g --date=unix --format=%H%x1f%gd%x1f%gs`: newest first, `HEAD@{1696000000}` selectors.
    public static func parseReflog(_ text: String) -> [ReflogEntry] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count >= 3, let open = parts[1].lastIndex(of: "{"), let close = parts[1].lastIndex(of: "}"), open < close,
                  let seconds = TimeInterval(parts[1][parts[1].index(after: open)..<close]) else { return nil }
            return ReflogEntry(sha: parts[0], date: Date(timeIntervalSince1970: seconds), subject: parts[2])
        }
    }

    /// The commit HEAD was on when a session started: the newest reflog entry from before it. When the whole reflog
    /// is newer (a worktree made for the session), its first entry counts if it isn't itself a commit, since that's
    /// where the checkout began. Nil when it can't be told.
    public static func sessionBase(reflog: [ReflogEntry], start: Date) -> String? {
        if let before = reflog.first(where: { $0.date <= start }) { return before.sha }
        guard let oldest = reflog.last, !oldest.subject.hasPrefix("commit"),
              oldest.date.timeIntervalSince(start) < 10 * 60 else { return nil }
        return oldest.sha
    }

    // MARK: Reading

    private static let diffFlags = ["--no-color", "--no-ext-diff", "--no-textconv", "-M", "--ignore-submodules=dirty"]
    /// Git's empty tree: what HEAD is compared as before the first commit.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    private static func git(_ root: String, _ args: [String], timeout: TimeInterval = 15) -> RepoGit.Output {
        // quotePath off: non-ASCII names come through as UTF-8 rather than octal escapes.
        RepoGit.git(root, ["-c", "core.quotePath=false"] + args, timeout: timeout)
    }

    static func head(_ root: String) -> String? {
        let out = git(root, ["rev-parse", "--verify", "--quiet", "HEAD"])
        let sha = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.ok && !sha.isEmpty ? sha : nil
    }

    static func untrackedPaths(_ root: String) -> [String] {
        let out = git(root, ["ls-files", "--others", "--exclude-standard", "-z"])
        guard out.ok else { return [] }
        return out.stdout.split(separator: "\0").map(String.init)
    }

    /// The cheap read for agent rows: `git diff --numstat` against HEAD plus untracked files' line counts.
    /// Nil when the folder isn't a readable git checkout.
    public static func summary(_ root: String) -> RepoDiffSummary? {
        let base = head(root) ?? emptyTree
        let out = git(root, ["diff", base, "--numstat", "-z"] + diffFlags)
        guard out.ok else { return nil }
        var summary = RepoDiffSummary()
        for entry in parseNumstat(out.stdout) {
            summary.files += 1
            summary.additions += entry.additions ?? 0
            summary.deletions += entry.deletions ?? 0
        }
        for (i, path) in untrackedPaths(root).enumerated() {
            summary.files += 1
            guard i < maxUntrackedRead else { continue }
            summary.additions += untracked(root, path).additions
        }
        return summary
    }

    private static func untracked(_ root: String, _ path: String) -> RepoDiffFile {
        let full = root + "/" + path
        let size = (try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int ?? 0
        guard size <= maxPatchBytes else { return RepoDiffFile(path: path, status: .untracked, isTooLarge: true) }
        guard let data = FileManager.default.contents(atPath: full) else { return RepoDiffFile(path: path, status: .untracked) }
        guard let (patch, lines) = untrackedPatch(data) else { return RepoDiffFile(path: path, status: .untracked, isBinary: true) }
        return RepoDiffFile(path: path, status: .untracked, additions: lines, patch: patch.isEmpty ? nil : patch)
    }

    /// Files changed between two trees: `from` to `to`, or `from` to the working tree when `to` is nil.
    static func files(_ root: String, from: String, to: String?) -> [RepoDiffFile]? {
        let range = [from] + (to.map { [$0] } ?? [])
        let names = git(root, ["diff"] + range + ["--name-status", "-z"] + diffFlags)
        guard names.ok else { return nil }
        let numstat = git(root, ["diff"] + range + ["--numstat", "-z"] + diffFlags)
        let patch = git(root, ["diff"] + range + ["-p", "--unified=3"] + diffFlags, timeout: 30)
        return merge(nameStatus: parseNameStatus(names.stdout), numstat: parseNumstat(numstat.stdout),
                     patches: parseUnifiedDiff(patch.stdout))
    }

    /// The full read for the diff view: every uncommitted file with its diff, and when `since` is given, the commits
    /// made after it with their combined diff.
    public static func read(_ root: String, since start: Date?) -> RepoWorkDiff? {
        let headSHA = head(root)
        guard var uncommitted = files(root, from: headSHA ?? emptyTree, to: nil) else { return nil }
        let untrackedPaths = untrackedPaths(root)
        for (i, path) in untrackedPaths.enumerated() {
            uncommitted.append(i < maxUntrackedRead ? untracked(root, path) : RepoDiffFile(path: path, status: .untracked, isTooLarge: true))
        }
        uncommitted.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var result = RepoWorkDiff(root: root, head: headSHA ?? "", uncommitted: uncommitted)
        guard let start, let headSHA else { return result }

        let reflog = parseReflog(git(root, ["log", "-g", "--date=unix", "--format=%H%x1f%gd%x1f%gs", "-n", "500", "HEAD"]).stdout)
        guard let base = sessionBase(reflog: reflog, start: start) else {
            result.committedNote = "Lookout couldn't find the commit this session started on, so only uncommitted changes are shown."
            return result
        }
        guard base != headSHA else { return result }
        let ancestor = git(root, ["merge-base", "--is-ancestor", base, headSHA]).ok
        let log = git(root, ["log", "--format=%H%x1f%ct%x1f%s", "-n", "200", headSHA, "--not", base])
        let commits = log.stdout.split(separator: "\n").compactMap { line -> RepoDiffCommit? in
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count >= 3 else { return nil }
            return RepoDiffCommit(sha: parts[0], subject: parts[2], date: TimeInterval(parts[1]).map(Date.init(timeIntervalSince1970:)))
        }
        let files = files(root, from: base, to: headSHA) ?? []
        result.committed = RepoSessionCommits(base: base, commits: commits, files: files, baseIsAncestor: ancestor)
        return result
    }

    // MARK: Reverting

    /// What reverting a file does, step by step: git commands (arguments after `git -C root`) and files moved to the
    /// Trash. Paths are passed as literal pathspecs so names with `*` or `:` mean just that file.
    public struct RevertPlan: Hashable, Sendable {
        public var commands: [[String]]
        public var trash: [String]

        public init(commands: [[String]], trash: [String]) {
            self.commands = commands
            self.trash = trash
        }
    }

    public static func revertPlan(_ file: RepoDiffFile) -> RevertPlan {
        func literal(_ path: String) -> String { ":(literal)" + path }
        func restore(_ path: String) -> [String] { ["restore", "--source=HEAD", "--staged", "--worktree", "--", literal(path)] }
        func unstage(_ path: String) -> [String] { ["rm", "--cached", "--force", "--quiet", "--", literal(path)] }
        switch file.status {
        case .untracked:
            return RevertPlan(commands: [], trash: [file.path])
        case .added, .copied:
            return RevertPlan(commands: [unstage(file.path)], trash: [file.path])
        case .renamed:
            var commands = [unstage(file.path)]
            if let old = file.oldPath { commands.append(restore(old)) }
            return RevertPlan(commands: commands, trash: [file.path])
        case .modified, .deleted, .typeChanged, .conflicted:
            return RevertPlan(commands: [restore(file.path)], trash: [])
        }
    }

    /// Puts one file back the way HEAD has it. New files go to the Trash rather than being deleted, so a mistaken
    /// revert can still be undone from Finder. `discard` is swappable so checks don't fill the Trash.
    public static func revert(_ file: RepoDiffFile, in root: String,
                              discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> RepoGit.Output {
        let plan = revertPlan(file)
        for args in plan.commands {
            let out = git(root, args)
            guard out.ok else { return out }
        }
        for path in plan.trash {
            let url = URL(fileURLWithPath: root + "/" + path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try discard(url) } catch {
                return RepoGit.Output(status: 1, stdout: "", stderr: error.localizedDescription)
            }
        }
        return RepoGit.Output(status: 0, stdout: "", stderr: "")
    }
}
