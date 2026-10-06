import Foundation
import LocalObserverDisk
import LocalObserverRepos

/// Disk rules: artifacts are only recognised with the file that proves them, worktrees with unsaved work are never
/// clearable, the delete guard refuses anything that changed since the scan, and Docker's sizes parse.
enum DiskChecks {
    static func run() {
        if ProcessInfo.processInfo.environment["DISK_SCAN"] == "1" { scanThisMac() }
        checkWorktreeVerdicts()
        checkDockerParsing()
        checkArtifactsAndClearing()
    }

    /// `DISK_SCAN=1`: what Cleanup would find on this Mac, biggest first. Read-only.
    private static func scanThisMac() {
        let start = Date()
        let roots = RepoGit.discover(roots: RepoGit.defaultRoots, depth: 3)
        let projects = roots.map { DiskProject(root: $0, name: ($0 as NSString).lastPathComponent) }
        var items = DiskScanner.fixedItems() + DiskScanner.artifacts(in: projects) + DiskScanner.dockerItems()
        print("found \(items.count) items in \(roots.count) repos in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            guard !items[i].path.isEmpty else { return }
            let size = DiskScanner.size(items[i].path)
            lock.lock(); items[i].bytes = size; lock.unlock()
        }
        print("measured in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        for item in items.sorted(by: { ($0.bytes ?? 0) > ($1.bytes ?? 0) }).prefix(25) {
            print("  \(DiskFormat.bytes(item.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.safety.title.padding(toLength: 7, withPad: " ", startingAt: 0)) \(item.displayPath)")
        }
        print("total \(DiskFormat.bytes(items.reduce(0) { $0 + ($1.bytes ?? 0) })), safe \(DiskFormat.bytes(items.filter { $0.canClear && $0.safety == .safe }.reduce(0) { $0 + ($1.bytes ?? 0) }))")
    }

    private static func checkWorktreeVerdicts() {
        func verdict(_ wt: DiskWorktree) -> DiskSafety { wt.verdict.0 }
        let base = DiskWorktree(path: "/x", mainRoot: "/r", repoName: "r", branch: "b")
        var wt = base
        wt.uncommitted = 2; wt.merged = true
        precondition(verdict(wt) == .keep, "Uncommitted work keeps a worktree even when merged")
        wt = base; wt.unpushed = 1; wt.merged = true
        precondition(verdict(wt) == .keep, "Unpushed commits keep a worktree")
        wt = base; wt.inUse = "Claude is working here"; wt.merged = true
        precondition(verdict(wt) == .keep, "A running agent keeps its worktree")
        wt = base; wt.openPull = 4
        precondition(verdict(wt) == .review, "An open pull request means review")
        wt = base; wt.merged = true
        precondition(verdict(wt) == .safe, "Clean and merged is safe")
        wt = base
        precondition(verdict(wt) == .review, "Clean but unmerged is review")
        wt = base; wt.prunable = true; wt.uncommitted = 3
        precondition(verdict(wt) == .safe, "A missing folder is only bookkeeping")
    }

    private static func checkDockerParsing() {
        let text = """
        {"Active":"4","Reclaimable":"4.6GB (56%)","Size":"8.2GB","TotalCount":"23","Type":"Images"}
        {"Active":"1","Reclaimable":"12.5MB (90%)","Size":"13.9MB","TotalCount":"5","Type":"Containers"}
        {"Active":"2","Reclaimable":"1.2GB (80%)","Size":"1.5GB","TotalCount":"6","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"731.4kB","Size":"731.4kB","TotalCount":"12","Type":"Build Cache"}
        """
        let items = Dictionary(uniqueKeysWithValues: DiskScanner.parseDockerDF(text).map { ($0.kind, $0) })
        precondition(items[.dockerImages]?.bytes == 4_600_000_000, "Docker image reclaimable")
        precondition(items[.dockerContainers]?.bytes == 12_500_000, "Docker container reclaimable")
        precondition(items[.dockerBuildCache]?.bytes == 731_400 && items[.dockerBuildCache]?.safety == .safe, "Docker build cache")
        precondition(items[.dockerVolumes]?.canClear == false, "Docker volumes are never cleared")
        precondition(DiskFormat.parseDockerSize("0B") == 0, "Zero size")
    }

    /// A throwaway project with real artifact folders, one impostor, and a symlink.
    private static func checkArtifactsAndClearing() {
        let fm = FileManager.default
        // A failed precondition skips the defer; sweep up after any earlier run that crashed.
        for leftover in (try? fm.contentsOfDirectory(atPath: NSHomeDirectory())) ?? [] where leftover.hasPrefix(".lookout-disk-check-") {
            try? fm.removeItem(atPath: NSHomeDirectory() + "/" + leftover)
        }
        let root = NSHomeDirectory() + "/.lookout-disk-check-\(UUID().uuidString.prefix(8))"
        defer { try? fm.removeItem(atPath: root) }
        func make(_ path: String, file: String? = nil) {
            try? fm.createDirectory(atPath: root + "/" + path, withIntermediateDirectories: true)
            if let file { fm.createFile(atPath: root + "/" + file, contents: Data("x".utf8)) }
        }
        make("app/node_modules/left-pad", file: "app/package.json")
        fm.createFile(atPath: root + "/app/node_modules/left-pad/index.js", contents: Data(repeating: 1, count: 50_000))
        make("app/web/.next", file: "app/web/package.json")
        make("tool/target/debug", file: "tool/Cargo.toml")
        make("notes/target")                                  // no Cargo.toml: not Rust's, must be left alone
        make("py/.venv/bin", file: "py/.venv/pyvenv.cfg")
        make("deep/a/b/c/node_modules", file: "deep/a/b/c/package.json")   // deeper than the search goes
        try? fm.createSymbolicLink(atPath: root + "/link/node_modules", withDestinationPath: root + "/app/node_modules")
        fm.createFile(atPath: root + "/link/package.json", contents: Data())

        let project = DiskProject(root: root, name: "check")
        let found = DiskScanner.artifacts(in: [project])
        let paths = Set(found.map { String($0.path.dropFirst(root.count + 1)) })
        precondition(paths == ["app/node_modules", "app/web/.next", "tool/target", "py/.venv"],
                     "Artifacts found: \(paths.sorted())")
        precondition(found.first { $0.path.hasSuffix("app/web/.next") }?.project == "check/app/web", "Monorepo package named")
        let busy = DiskScanner.artifacts(in: [DiskProject(root: root, name: "check", inUse: "A server is running here (:3000)")])
        precondition(busy.allSatisfy { $0.safety == .review }, "In-use projects need review")

        guard var modules = found.first(where: { $0.kind == .nodeModules }) else { preconditionFailure("node_modules") }
        modules.bytes = DiskScanner.size(modules.path)
        precondition((modules.bytes ?? 0) >= 50_000, "du measures the folder")

        // The guard re-checks before deleting: once package.json is gone, it's no longer provably node_modules.
        try? fm.removeItem(atPath: root + "/app/package.json")
        if case .success = DiskScanner.clear(modules) { preconditionFailure("Cleared a folder that changed since the scan") }
        precondition(fm.fileExists(atPath: modules.path), "Refused clear left it in place")
        fm.createFile(atPath: root + "/app/package.json", contents: Data())
        guard case .success = DiskScanner.clear(modules) else { preconditionFailure("Clearing node_modules") }
        precondition(!fm.fileExists(atPath: modules.path), "node_modules cleared")
        precondition(fm.fileExists(atPath: root + "/app/package.json"), "Only the artifact is touched")

        let outside = DiskItem(kind: .nodeModules, path: "/tmp/node_modules", name: "node_modules")
        if case .success = DiskScanner.clear(outside) { preconditionFailure("Cleared outside home") }
        let kept = DiskItem(kind: .agentData, path: root + "/py", name: "py", safety: .keep)
        if case .success = DiskScanner.clear(kept) { preconditionFailure("Cleared a kept item") }
        precondition(fm.fileExists(atPath: root + "/py/.venv"), "Kept items stay")
    }
}
