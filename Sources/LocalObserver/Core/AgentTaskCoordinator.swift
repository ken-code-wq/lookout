import Foundation
import AppKit
import LocalObserverCore
import LocalObserverRepos

/// Form state for the "New agent task" sheet. Every field is a starting point the sheet lets you change.
struct AgentTaskDraft: Identifiable {
    let id = UUID()
    var repoRoot: String? = nil
    var prompt = ""
    /// Branch a new worktree starts from; the repository's default branch when nil.
    var base: String? = nil
    /// Start in this existing checkout (the main one or a worktree) instead of making a worktree.
    var checkout: String? = nil
}

/// Starts agent tasks: finds the installed agent CLIs and terminals, makes the worktree, writes the launch script,
/// opens it in your terminal, and records the task so the session it starts can be recognised later.
@MainActor
final class AgentTaskCoordinator: ObservableObject {
    static let shared = AgentTaskCoordinator()

    @Published var draft: AgentTaskDraft?
    /// Agent CLIs found on this Mac, by full path. Nil until the first look.
    @Published private(set) var installed: [AgentCLI: String]?
    @Published private(set) var terminals: [TerminalApp] = [.terminal]
    @Published private(set) var launching = false
    private var searchPath: [String] = []
    private var detecting = false

    private var store: AgentTaskStore { .shared }

    /// Shows the sheet. From outside the main window (notch, menu bar), opens the window first.
    func present(_ draft: AgentTaskDraft = AgentTaskDraft(), openWindow: Bool = false) {
        if openWindow { LiveSurfaces.shared.openMain(.agentActivity) }
        detect()
        self.draft = draft
    }

    /// The terminal tasks open in: the saved choice while it's installed, else the first one found.
    var terminal: TerminalApp {
        if let saved = store.settings.terminal, terminals.contains(saved) { return saved }
        return terminals.first ?? .terminal
    }

    // MARK: Detection

    /// Looks for agent CLIs and terminals off the main thread. The folder list covers the usual installers; a
    /// login shell's `command -v` catches anything installed somewhere else on your PATH.
    func detect() {
        guard !detecting else { return }
        detecting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([AgentCLI: String], [String]) in
                let dirs = AgentCLILocator.currentDirectories()
                var found: [AgentCLI: String] = [:]
                for cli in AgentCLI.allCases {
                    if let path = AgentCLILocator.locate(cli, in: dirs, isExecutable: FileManager.default.isExecutableFile) { found[cli] = path }
                }
                let missing = AgentCLI.allCases.filter { found[$0] == nil }.flatMap(\.executableNames)
                if !missing.isEmpty {
                    let out = RepoGit.run("/bin/zsh", ["-lc", "for c in \(missing.joined(separator: " ")); do command -v $c; done"], timeout: 5)
                    for line in out.stdout.split(separator: "\n").map(String.init) where line.hasPrefix("/") {
                        let name = (line as NSString).lastPathComponent
                        if let cli = AgentCLI.allCases.first(where: { found[$0] == nil && $0.executableNames.contains(name) }) { found[cli] = line }
                    }
                }
                let existing = dirs.filter { FileManager.default.fileExists(atPath: $0) }
                return (found, existing)
            }.value
            installed = result.0
            searchPath = result.1
            terminals = TerminalApp.allCases.filter { Self.appURL($0) != nil }
            if terminals.isEmpty { terminals = [.terminal] }
            detecting = false
        }
    }

    #if DEBUG
    /// Debug/demo (snapshot harness): these agents count as installed, and nothing on this Mac is looked at.
    func loadDemo(installed: [AgentCLI: String]) {
        detecting = true
        self.installed = installed
        terminals = [.terminal, .ghostty]
    }
    #endif

    static func appURL(_ terminal: TerminalApp) -> URL? {
        terminal.bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    // MARK: Launch

    /// Makes the worktree if asked, then opens the agent in the terminal. Calls back with nil on success or the
    /// reason it couldn't start.
    func launch(repo: Repo, cli: AgentCLI, prompt: String, worktreeBase: String?, checkout: String, then: @escaping (String?) -> Void) {
        guard !launching else { return }
        guard let executable = installed?[cli] else { then("\(cli.name) isn't installed where Lookout can find it."); return }
        launching = true
        let terminal = self.terminal
        let path = searchPath
        Task {
            var directory = checkout
            var branch = GitCheckout.locate(checkout)?.branch
            if let base = worktreeBase {
                let root = repo.root
                let made = await Task.detached(priority: .userInitiated) { AgentTaskGit.create(root: root, prompt: prompt, base: base) }.value
                switch made {
                case .success(let worktree):
                    directory = worktree.path
                    branch = worktree.branch
                case .failure(let error):
                    launching = false
                    then("Couldn't create the worktree: \(error.message)")
                    return
                }
            }
            let task = AgentTask(repoRoot: repo.root, repoName: repo.name, directory: directory, branch: branch, baseBranch: worktreeBase,
                                 isWorktree: worktreeBase != nil, cli: cli, prompt: prompt, terminal: terminal)
            let title = "\(repo.name): \(task.summary.prefix(40))"
            let script = AgentTaskScript.script(directory: directory, executable: executable, arguments: cli.arguments(prompt: prompt),
                                                title: title, searchPath: path)
            launching = false
            switch Self.open(script: script, id: task.id, title: title, directory: directory, in: terminal) {
            case .some(let error):
                then(error)
                if worktreeBase != nil { RepoStore.shared.refresh(quiet: true) }
            case .none:
                store.record(task)
                store.settings.lastCLI = cli
                store.settings.useWorktree = worktreeBase != nil
                then(nil)
                LiveSurfaces.shared.toast("Started \(cli.name) in \(terminal.name)" + (branch.map { " on \($0)" } ?? ""))
                // The new worktree shows up in Repos (and the hand-off) on the next scan; ask for one now and once
                // more shortly after, in case a scan was already running and this one was dropped.
                RepoStore.shared.refresh(quiet: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { RepoStore.shared.refresh(quiet: true) }
            }
        }
    }

    /// Scripts live here; old ones are cleared out on each launch.
    private static var scriptDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalObserver/AgentTasks", isDirectory: true)
    }

    /// Writes the launch script and hands it to the terminal. Returns why it failed, or nil.
    private static func open(script: String, id: UUID, title: String, directory: String, in terminal: TerminalApp) -> String? {
        let fm = FileManager.default
        let dir = scriptDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        prune(dir)
        let file = dir.appendingPathComponent("task-\(id.uuidString.prefix(8)).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return "Couldn't write the launch script: \(error.localizedDescription)"
        }
        guard let app = appURL(terminal) else { return "\(terminal.name) isn't installed." }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        switch terminal {
        case .terminal:
            // Terminal runs `.command` files in a new window, without needing permission to automate it.
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
        case .ghostty:
            configuration.arguments = ["-e", file.path]
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        case .iTerm:
            var error: NSDictionary?
            NSAppleScript(source: AgentTaskScript.iTermAppleScript(scriptPath: file.path))?.executeAndReturnError(&error)
            if let error {
                let denied = (error[NSAppleScript.errorNumber] as? Int) == -1743
                return denied ? "Lookout isn't allowed to control iTerm2. Allow it in System Settings › Privacy & Security › Automation."
                    : "iTerm2 didn't open the task: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error")"
            }
        case .warp:
            // Warp can't be handed a command directly; a launch configuration opens a tab that runs the script.
            let configs = fm.homeDirectoryForCurrentUser.appendingPathComponent(".warp/launch_configurations", isDirectory: true)
            try? fm.createDirectory(at: configs, withIntermediateDirectories: true)
            let yaml = configs.appendingPathComponent("lookout-task.yaml")
            let text = AgentTaskScript.warpLaunchConfiguration(name: "Lookout task", title: title, directory: directory, scriptPath: file.path)
            do { try text.write(to: yaml, atomically: true, encoding: .utf8) } catch {
                return "Couldn't write Warp's launch configuration: \(error.localizedDescription)"
            }
            guard let url = URL(string: "warp://launch/" + (yaml.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? yaml.path)) else {
                return "Couldn't build Warp's launch link."
            }
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    /// Launch scripts older than a week have long since run.
    private static func prune(_ dir: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: file) }
        }
    }
}
