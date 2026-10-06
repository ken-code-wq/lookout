import Foundation
import UserNotifications
import LocalObserverCore
import LocalObserverRepos
import LocalObserverDisk
import LocalObserverWidgetUI

/// Feeds the Disk pillar what the rest of Lookout knows: project folders (repositories, worktrees, launchers),
/// which of them a server or agent is using right now, and each worktree's git state. Also watches free space and
/// warns once when it drops below the threshold.
@MainActor
final class DiskCoordinator {
    static let shared = DiskCoordinator()

    private weak var state: AppState?
    private weak var agentStore: AgentStore?
    private var timer: Timer?
    private var warned = false

    /// Free space is checked this often; it's one `statfs`, so cheap.
    static let volumeInterval: TimeInterval = 600

    func attach(state: AppState, agentStore: AgentStore) {
        guard self.state == nil else { return }
        self.state = state
        self.agentStore = agentStore
        let disk = DiskStore.shared
        disk.onActionResult = { [weak state] message, ok in
            state?.show(Toast(message: message, symbol: ok ? "checkmark.circle" : "exclamationmark.triangle", tone: ok ? .success : .danger))
        }
        disk.onWorktreesChanged = { RepoStore.shared.refresh(quiet: true) }
        disk.refreshVolume()
        timer = Timer.scheduledTimer(withTimeInterval: Self.volumeInterval, repeats: true) { _ in
            Task { @MainActor in DiskCoordinator.shared.checkSpace() }
        }
        timer?.tolerance = 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.checkSpace() }
    }

    /// Measures everything. Called when the Cleanup page opens and on refresh.
    func scan() {
        let repos = RepoStore.shared
        let busy = foldersInUse()
        func inUse(_ path: String) -> String? {
            busy.first { $0.key == path || $0.key.hasPrefix(path + "/") }?.value
        }
        var projects: [String: DiskProject] = [:]
        for repo in repos.visibleRepos {
            projects[repo.root] = DiskProject(root: repo.root, name: repo.name, lastTouched: repo.lastTouched, inUse: inUse(repo.root))
            for wt in repo.worktrees where !wt.isPrunable {
                projects[wt.path] = DiskProject(root: wt.path, name: "\(repo.name) (\(wt.refLabel))", lastTouched: wt.lastTouched, inUse: inUse(wt.path))
            }
        }
        for launcher in state?.managed ?? [] where projects[launcher.workingDirectory] == nil {
            let covered = projects.keys.contains { launcher.workingDirectory.hasPrefix($0 + "/") }
            if !covered {
                projects[launcher.workingDirectory] = DiskProject(root: launcher.workingDirectory, name: launcher.name,
                                                                  inUse: inUse(launcher.workingDirectory))
            }
        }
        for root in DiskStore.shared.settings.extraRoots where projects[root] == nil {
            projects[root] = DiskProject(root: root, name: (root as NSString).lastPathComponent, inUse: inUse(root))
        }

        let worktrees: [DiskWorktree] = repos.visibleRepos.flatMap { repo in
            repo.worktrees.map { wt in
                DiskWorktree(path: wt.path, mainRoot: repo.root, repoName: repo.name, branch: wt.branch, owner: wt.owner,
                             uncommitted: wt.changes?.total ?? 0, unpushed: wt.ahead,
                             merged: wt.branch.map { repo.mergedBranches.contains($0) || Self.isMergedRemotely($0, repo: repo) } ?? false,
                             openPull: repos.pull(for: repo, branch: wt.branch)?.number, prunable: wt.isPrunable,
                             lastTouched: wt.lastTouched, inUse: inUse(wt.path))
            }
        }
        DiskStore.shared.scan(projects: Array(projects.values), worktrees: worktrees)
    }

    /// A branch whose pull request GitHub shows as merged counts as merged even when it was squashed, which
    /// `git branch --merged` can't see.
    private static func isMergedRemotely(_ branch: String, repo: Repo) -> Bool {
        guard let slug = repo.github else { return false }
        let github = GitHubStore.shared
        if let pull = github.branches[slug]?.first(where: { $0.name == branch })?.pull, pull.state == .merged { return true }
        return (github.closedPulls[slug] ?? []).contains { $0.headRef == branch && $0.state == .merged }
    }

    /// Folders something is running in right now, with what: "A server is running here (:3000)".
    private func foldersInUse() -> [String: String] {
        var busy: [String: String] = [:]
        for server in state?.servers ?? [] where !server.workingDirectory.isEmpty && server.workingDirectory != "/" {
            busy[server.projectRoot.isEmpty ? server.workingDirectory : server.projectRoot] = "A server is running here (:\(server.port))"
        }
        for session in agentStore?.runningSessions ?? [] {
            let path = session.checkout?.root ?? session.projectPath
            guard !path.isEmpty else { continue }
            busy[path] = "\(session.agent.shortName) is working here"
        }
        return busy
    }

    // MARK: Low space

    private func checkSpace() {
        let disk = DiskStore.shared
        disk.refreshVolume()
        // Read on the next turn, once the volume has been re-read.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let volume = disk.volume else { return }
            if !disk.isLowOnSpace { self.warned = false; return }
            guard !self.warned, disk.settings.notifyLowSpace else { return }
            self.warned = true
            let free = DiskFormat.bytes(volume.available)
            if AgentNotifier.isAvailable {
                let content = UNMutableNotificationContent()
                content.title = "Only \(free) free on \(volume.name)"
                content.body = "Open Cleanup in Lookout to see what's safe to clear."
                content.sound = .default
                content.userInfo = ["url": "\(WidgetLink.scheme)://cleanup"]
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "low-space-\(Int(Date().timeIntervalSince1970))",
                                                                             content: content, trigger: nil))
            }
            if Preferences.shared.notchAlerts {
                NotchController.shared.show(NotchAlert(id: "low-space", kind: .limit, agent: nil, title: "Running low on space",
                                                       detail: "\(free) free on \(volume.name). Cleanup shows what's safe to clear.",
                                                       badge: "Disk", sessionID: nil, symbol: "internaldrive.fill",
                                                       url: "\(WidgetLink.scheme)://cleanup"), seconds: 6)
            }
        }
    }
}
