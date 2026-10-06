import Foundation
import LocalObserverRepos

/// Live diff rules: numstat, name-status and unified diffs parse the same way every time (renames, binary files,
/// paths with spaces and quoting included), the session's starting commit is read from the reflog, reverts undo
/// exactly one file, and a real repository reads back correctly end to end.
enum DiffChecks {
    static func run() {
        checkNumstat()
        checkNameStatus()
        checkUnifiedDiff()
        checkUntracked()
        checkBaseline()
        checkRevertPlans()
        checkSummary()
        checkRealRepository()
    }

    private static func checkNumstat() {
        let text = "3\t1\tsrc/a.swift\0-\t-\tlogo.png\0" + "5\t0\t\0old name.txt\0new name.txt\0" + "0\t2\tdir with space/b c.md\0"
        let entries = RepoDiff.parseNumstat(text)
        precondition(entries.count == 4, "Numstat entries: \(entries)")
        precondition(entries[0].path == "src/a.swift" && entries[0].additions == 3 && entries[0].deletions == 1, "Numstat counts")
        precondition(entries[1].additions == nil && entries[1].deletions == nil, "Binary numstat has no counts")
        precondition(entries[2].oldPath == "old name.txt" && entries[2].path == "new name.txt" && entries[2].additions == 5, "Numstat rename")
        precondition(entries[3].path == "dir with space/b c.md", "Numstat path with spaces")
        precondition(RepoDiff.parseNumstat("").isEmpty, "Empty numstat")
    }

    private static func checkNameStatus() {
        let text = "M\0src/a.swift\0A\0new file.txt\0D\0gone.txt\0R087\0old name.txt\0new name.txt\0C100\0x\0y\0T\0link\0"
        let entries = RepoDiff.parseNameStatus(text)
        precondition(entries.map(\.status) == [.modified, .added, .deleted, .renamed, .copied, .typeChanged], "Name-status kinds: \(entries)")
        precondition(entries[1].path == "new file.txt", "Name-status path with spaces")
        precondition(entries[3].oldPath == "old name.txt" && entries[3].path == "new name.txt", "Name-status rename keeps both paths")
        precondition(entries[4].oldPath == "x" && entries[4].path == "y", "Name-status copy")
        precondition(RepoDiffStatus(code: "R100") == .renamed && RepoDiffStatus(code: "X") == nil, "Status codes")
    }

    private static func checkUnifiedDiff() {
        let diff = """
        diff --git a/src/a.swift b/src/a.swift
        index 1111111..2222222 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -1,3 +1,3 @@
         let a = 1
        --- not a header, a removed line starting with dashes
        +let b = 2
        diff --git a/my file.txt b/my file.txt
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/my file.txt\t
        @@ -0,0 +1 @@
        +hello
        diff --git a/logo.png b/logo.png
        index 4444444..5555555 100644
        Binary files a/logo.png and b/logo.png differ
        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 6666666..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git "a/tab\\there.txt" "b/tab\\there.txt"
        new file mode 100644
        --- /dev/null
        +++ "b/tab\\there.txt"
        @@ -0,0 +1 @@
        +x

        """
        let sections = RepoDiff.parseUnifiedDiff(diff)
        precondition(sections.map(\.path) == ["src/a.swift", "my file.txt", "logo.png", "new name.txt", "gone.txt", "tab\there.txt"],
                     "Unified diff paths: \(sections.map(\.path))")
        precondition(sections[0].hunks.hasPrefix("@@ -1,3") && sections[0].hunks.contains("--- not a header"), "Hunks start at @@ and keep dashed lines")
        precondition(!sections[0].hunks.contains("diff --git"), "Hunks stop before the next file")
        precondition(sections[1].oldPath == nil && sections[1].hunks == "@@ -0,0 +1 @@\n+hello", "Trailing tab after a path with spaces is dropped")
        precondition(sections[2].isBinary && sections[2].hunks.isEmpty, "Binary section")
        precondition(sections[3].oldPath == "old name.txt" && sections[3].hunks.isEmpty, "Pure rename")
        precondition(sections[4].path == "gone.txt" && sections[4].hunks.hasSuffix("-bye"), "Deleted file keeps its old path")
        precondition(!sections[5].hunks.hasSuffix("\n"), "Final newline isn't part of the last hunk")

        // The hunks feed the GitHub-style renderer as they are.
        let lines = GHDiffLine.parse(sections[0].hunks)
        precondition(lines.map(\.kind) == [.hunk, .context, .deletion, .addition], "Hunks render as diff lines")

        precondition(RepoDiff.unquote("\"caf\\303\\251 \\\"q\\\"\"") == "café \"q\"", "Octal and escaped quotes unquote")
        precondition(RepoDiff.unquote("plain name") == "plain name", "Unquoted text is untouched")

        let merged = RepoDiff.merge(
            nameStatus: RepoDiff.parseNameStatus("M\0src/a.swift\0A\0my file.txt\0M\0logo.png\0R100\0old name.txt\0new name.txt\0D\0gone.txt\0"),
            numstat: RepoDiff.parseNumstat("1\t1\tsrc/a.swift\0" + "1\t0\tmy file.txt\0-\t-\tlogo.png\0" + "0\t0\t\0old name.txt\0new name.txt\0" + "0\t1\tgone.txt\0"),
            patches: sections)
        precondition(merged.map(\.path) == ["gone.txt", "logo.png", "my file.txt", "new name.txt", "src/a.swift"], "Merged and sorted: \(merged.map(\.path))")
        precondition(merged[1].isBinary && merged[1].patch == nil, "Binary file has no patch")
        precondition(merged[2].status == .added && merged[2].additions == 1 && merged[2].patch != nil, "Added file joins its counts and patch")
        precondition(merged[3].oldPath == "old name.txt" && merged[3].status == .renamed && merged[3].patch == nil, "Rename joins")
        precondition(merged[3].unifiedText.contains("rename from old name.txt\nrename to new name.txt"), "Copied rename keeps its header")
        precondition(merged[0].unifiedText.contains("+++ /dev/null"), "Copied deletion diffs against /dev/null")
    }

    private static func checkUntracked() {
        let (patch, lines) = RepoDiff.untrackedPatch(Data("one\ntwo\n".utf8))!
        precondition(lines == 2 && patch == "@@ -0,0 +1,2 @@\n+one\n+two", "Untracked file as additions: \(patch)")
        let open = RepoDiff.untrackedPatch(Data("tail".utf8))!
        precondition(open.lines == 1 && open.patch.hasSuffix("\\ No newline at end of file"), "Missing final newline is marked")
        precondition(RepoDiff.untrackedPatch(Data([0x89, 0x50, 0x00, 0x01])) == nil, "NUL bytes mean binary")
        precondition(RepoDiff.untrackedPatch(Data())?.lines == 0, "Empty untracked file")
    }

    private static func checkBaseline() {
        let text = [
            "ccc\u{1F}HEAD@{3000}\u{1F}commit: third",
            "bbb\u{1F}HEAD@{2000}\u{1F}commit: second",
            "aaa\u{1F}HEAD@{1000}\u{1F}checkout: moving from main to feat",
        ].joined(separator: "\n")
        let reflog = RepoDiff.parseReflog(text)
        precondition(reflog.count == 3 && reflog[0].date == Date(timeIntervalSince1970: 3000), "Reflog parsing")
        precondition(RepoDiff.sessionBase(reflog: reflog, start: Date(timeIntervalSince1970: 2500)) == "bbb", "Base is HEAD at session start")
        precondition(RepoDiff.sessionBase(reflog: reflog, start: Date(timeIntervalSince1970: 3500)) == "ccc", "Nothing committed since start")
        // A worktree made just after the session started: its creation entry is where the work began.
        precondition(RepoDiff.sessionBase(reflog: reflog, start: Date(timeIntervalSince1970: 900)) == "aaa", "Worktree made for the session")
        let commitsOnly = RepoDiff.parseReflog("bbb\u{1F}HEAD@{2000}\u{1F}commit: second")
        precondition(RepoDiff.sessionBase(reflog: commitsOnly, start: Date(timeIntervalSince1970: 1000)) == nil, "Unknown base stays unknown")
    }

    private static func checkRevertPlans() {
        let modified = RepoDiff.revertPlan(RepoDiffFile(path: "a b.txt", status: .modified))
        precondition(modified.commands == [["restore", "--source=HEAD", "--staged", "--worktree", "--", ":(literal)a b.txt"]] && modified.trash.isEmpty,
                     "Modified files restore from HEAD")
        precondition(RepoDiff.revertPlan(RepoDiffFile(path: "new.txt", status: .untracked)) == .init(commands: [], trash: ["new.txt"]),
                     "Untracked files go to the Trash")
        let renamed = RepoDiff.revertPlan(RepoDiffFile(path: "new.txt", oldPath: "old.txt", status: .renamed))
        precondition(renamed.commands.count == 2 && renamed.commands[1].last == ":(literal)old.txt" && renamed.trash == ["new.txt"],
                     "Renames restore the old path and drop the new one")
        precondition(RepoDiff.revertPlan(RepoDiffFile(path: "x", status: .added)).trash == ["x"], "Added files are unstaged and trashed")
    }

    private static func checkSummary() {
        let files = [RepoDiffFile(path: "a", status: .modified, additions: 100, deletions: 30),
                     RepoDiffFile(path: "b", status: .added, additions: 20, deletions: 4)]
        let summary = RepoDiffSummary(files)
        precondition(summary.label == "+120 −34 · 2 files" && !summary.isLarge, "Summary label: \(summary.label)")
        precondition(RepoDiffSummary(files: 1, additions: 1, deletions: 0).filesLabel == "1 file", "Singular file")
        precondition(RepoDiffSummary(files: RepoDiff.largeChangeFileCount).isLarge, "Scale warning threshold")
    }

    /// A throwaway repository: modified, added, deleted, renamed, binary and untracked files, names with spaces, a
    /// commit made "during the session", and reverts of each kind.
    private static func checkRealRepository() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("diff-verify-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }
        try? fm.createDirectory(atPath: root + "/dir with space", withIntermediateDirectories: true)
        func git(_ args: String...) {
            let out = RepoGit.run(RepoGit.gitPath, ["-C", root, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args)
            precondition(out.ok, "git \(args.joined(separator: " ")) failed: \(out.stderr)")
        }
        func write(_ path: String, _ text: String) { fm.createFile(atPath: root + "/" + path, contents: Data(text.utf8)) }
        git("init", "-q", "-b", "main")
        // Before any commit: everything is untracked, compared against the empty tree.
        write("first.txt", "1\n")
        precondition(RepoDiff.summary(root) == RepoDiffSummary(files: 1, additions: 1, deletions: 0), "Unborn repository summary")

        write("keep.txt", "a\nb\nc\n")
        write("dir with space/edit me.txt", "one\ntwo\n")
        write("remove.txt", "bye\n")
        write("move me.txt", "same\ncontent\nhere\n")
        fm.createFile(atPath: root + "/logo.png", contents: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]))
        git("add", ".")
        git("commit", "-q", "-m", "base")
        let sessionStart = Date()
        Thread.sleep(forTimeInterval: 1.1)
        write("keep.txt", "a\nB\nc\nd\n")
        git("commit", "-q", "-am", "during the session")

        write("dir with space/edit me.txt", "one\nTWO\n")
        try? fm.removeItem(atPath: root + "/remove.txt")
        git("mv", "move me.txt", "moved now.txt")
        fm.createFile(atPath: root + "/logo.png", contents: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x02]))
        write("brand new.txt", "x\ny\n")
        write("staged.txt", "s\n")
        git("add", "staged.txt")

        guard let summary = RepoDiff.summary(root) else { preconditionFailure("Summary read failed") }
        // edit me (+1 −1), remove (−1), rename (0), logo (binary), brand new (+2), staged (+1).
        precondition(summary.files == 6 && summary.additions == 4 && summary.deletions == 2, "Live summary: \(summary)")

        guard let diff = RepoDiff.read(root, since: sessionStart) else { preconditionFailure("Diff read failed") }
        let byPath = Dictionary(uniqueKeysWithValues: diff.uncommitted.map { ($0.path, $0) })
        precondition(byPath["dir with space/edit me.txt"]?.status == .modified && byPath["dir with space/edit me.txt"]?.patch?.contains("+TWO") == true,
                     "Modified file with spaces: \(diff.uncommitted)")
        precondition(byPath["remove.txt"]?.status == .deleted, "Deleted file")
        precondition(byPath["moved now.txt"]?.status == .renamed && byPath["moved now.txt"]?.oldPath == "move me.txt", "Staged rename")
        precondition(byPath["logo.png"]?.isBinary == true && byPath["logo.png"]?.patch == nil, "Binary file")
        precondition(byPath["brand new.txt"]?.status == .untracked && byPath["brand new.txt"]?.additions == 2, "Untracked file")
        precondition(byPath["staged.txt"]?.status == .added, "Staged new file")
        precondition(diff.unifiedText.contains("+TWO"), "Copy diff includes the changes")

        guard let committed = diff.committed else { preconditionFailure("Commits during the session: \(diff.committedNote ?? "none")") }
        precondition(committed.commits.map(\.subject) == ["during the session"] && committed.baseIsAncestor, "Session commits: \(committed.commits)")
        precondition(committed.files.map(\.path) == ["keep.txt"] && committed.files[0].additions == 2 && committed.files[0].deletions == 1,
                     "Committed diff: \(committed.files)")

        for path in ["dir with space/edit me.txt", "remove.txt", "moved now.txt", "brand new.txt", "staged.txt", "logo.png"] {
            guard let file = byPath[path] else { continue }
            let out = RepoDiff.revert(file, in: root) { try fm.removeItem(at: $0) }
            precondition(out.ok, "Revert \(path): \(out.stderr)")
        }
        let after = RepoDiff.summary(root)
        precondition(after == RepoDiffSummary(), "Everything reverted: \(String(describing: after))")
        precondition(fm.fileExists(atPath: root + "/move me.txt") && !fm.fileExists(atPath: root + "/moved now.txt"), "Rename reverted")
        precondition(!fm.fileExists(atPath: root + "/brand new.txt"), "Untracked file removed")
    }
}
