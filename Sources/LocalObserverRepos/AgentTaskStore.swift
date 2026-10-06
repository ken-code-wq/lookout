import Foundation
import Combine
import LocalObserverCore

/// An agent task started from Lookout: where it runs, on which branch, with which agent and prompt.
public struct AgentTask: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var repoRoot: String
    public var repoName: String
    /// The folder the agent was started in: the new worktree, or the checkout it was started in.
    public var directory: String
    public var branch: String?
    /// What a new worktree branched from. Nil when started in an existing checkout.
    public var baseBranch: String?
    public var isWorktree: Bool
    public var cli: AgentCLI
    public var prompt: String
    public var terminal: TerminalApp
    public var launchedAt: Date

    public init(id: UUID = UUID(), repoRoot: String, repoName: String, directory: String, branch: String?, baseBranch: String?,
                isWorktree: Bool, cli: AgentCLI, prompt: String, terminal: TerminalApp, launchedAt: Date = Date()) {
        self.id = id
        self.repoRoot = repoRoot
        self.repoName = repoName
        self.directory = directory
        self.branch = branch
        self.baseBranch = baseBranch
        self.isWorktree = isWorktree
        self.cli = cli
        self.prompt = prompt
        self.terminal = terminal
        self.launchedAt = launchedAt
    }

    /// First line of the prompt, for titles.
    public var summary: String {
        prompt.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// A saved prompt. `{branch}` and `{repo}` are filled in when it's used.
public struct AgentPromptTemplate: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var prompt: String

    public init(id: UUID = UUID(), title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }

    public func expanded(repo: String, branch: String?) -> String {
        prompt.replacingOccurrences(of: "{repo}", with: repo)
            .replacingOccurrences(of: "{branch}", with: branch ?? "this branch")
    }

    public static let fixCI = "Fix failing CI on this branch"

    public static let defaults: [AgentPromptTemplate] = [
        AgentPromptTemplate(title: fixCI, prompt: "CI is failing on {branch}. Run the failing checks locally, find the cause and fix it. Commit the fix once the checks pass."),
        AgentPromptTemplate(title: "Write tests for recent changes", prompt: "Look at the latest commits on {branch} and add tests for anything that isn't covered. Run the test suite and commit the tests."),
        AgentPromptTemplate(title: "Review and tidy this branch", prompt: "Review the changes on {branch} against the default branch. Fix bugs, edge cases and anything unclear, then commit."),
        AgentPromptTemplate(title: "Update dependencies", prompt: "Update {repo}'s dependencies to their latest compatible versions, fix anything that breaks, and make sure the build and tests pass. Commit the result."),
    ]
}

/// Settings for starting tasks; every key optional so older saves keep decoding as fields are added.
public struct AgentTaskSettings: Codable, Equatable, Sendable {
    public var terminal: TerminalApp?
    public var lastCLI: AgentCLI?
    public var useWorktree = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminal = try c.decodeIfPresent(TerminalApp.self, forKey: .terminal)
        lastCLI = try c.decodeIfPresent(AgentCLI.self, forKey: .lastCLI)
        useWorktree = try c.decodeIfPresent(Bool.self, forKey: .useWorktree) ?? true
    }
}

/// Tasks started from Lookout and the prompt templates, kept across launches. Joins a task to the agent session it
/// started by folder and start time, so the Sessions page can say "Started from Lookout".
@MainActor
public final class AgentTaskStore: ObservableObject {
    public static let shared = AgentTaskStore()

    @Published public private(set) var tasks: [AgentTask] = []
    @Published public var templates: [AgentPromptTemplate] { didSet { if !isDemo { save(templates, Keys.templates) } } }
    @Published public var settings: AgentTaskSettings { didSet { if !isDemo, settings != oldValue { save(settings, Keys.settings) } } }

    private let defaults: UserDefaults
    private var isDemo = false
    /// Oldest tasks drop off past this; only recent ones can still match a session.
    public static let limit = 200

    private enum Keys {
        static let tasks = "LocalObserver.agentTasks"
        static let templates = "LocalObserver.agentPromptTemplates"
        static let settings = "LocalObserver.agentTaskSettings"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        tasks = load([AgentTask].self, Keys.tasks) ?? []
        templates = load([AgentPromptTemplate].self, Keys.templates) ?? AgentPromptTemplate.defaults
        settings = load(AgentTaskSettings.self, Keys.settings) ?? AgentTaskSettings()
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    public func record(_ task: AgentTask) {
        tasks.insert(task, at: 0)
        if tasks.count > Self.limit { tasks.removeLast(tasks.count - Self.limit) }
        if !isDemo { save(tasks, Keys.tasks) }
    }

    public func forget(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        if !isDemo { save(tasks, Keys.tasks) }
    }

    /// The task that started a session, if any.
    public func task(for session: AgentSession) -> AgentTask? {
        guard !tasks.isEmpty else { return nil }
        let paths = [session.projectPath, session.checkout?.root].compactMap { $0 }.filter { !$0.isEmpty }
        for path in paths {
            if let task = Self.match(path: path, startedAt: session.startedAt, in: tasks) { return task }
        }
        return nil
    }

    /// A session belongs to a task when it runs in the task's folder (or below it) and started from shortly before
    /// the launch to a while after it; the newest such task wins. The window keeps sessions you start yourself
    /// in the same checkout later from being claimed.
    public nonisolated static func match(path: String, startedAt: Date, in tasks: [AgentTask],
                                         before: TimeInterval = 120, after: TimeInterval = 1_800) -> AgentTask? {
        let path = (path as NSString).standardizingPath
        return tasks.filter { task in
            let dir = (task.directory as NSString).standardizingPath
            guard path == dir || path.hasPrefix(dir + "/") else { return false }
            let delta = startedAt.timeIntervalSince(task.launchedAt)
            return delta >= -before && delta <= after
        }
        .max { $0.launchedAt < $1.launchedAt }
    }

    /// Repositories you've started tasks in come first, newest first; the rest by when they were last worked on.
    public nonisolated static func recentFirst(_ repos: [Repo], tasks: [AgentTask]) -> [Repo] {
        var latest: [String: Date] = [:]
        for task in tasks { latest[task.repoRoot] = max(latest[task.repoRoot] ?? .distantPast, task.launchedAt) }
        return repos.sorted { a, b in
            switch (latest[a.root], latest[b.root]) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let ta = a.lastTouched ?? .distantPast, tb = b.lastTouched ?? .distantPast
                return ta != tb ? ta > tb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    // MARK: Templates

    public func saveTemplate(title: String, prompt: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        templates.append(AgentPromptTemplate(title: name.isEmpty ? "Untitled prompt" : name, prompt: prompt))
    }

    public func deleteTemplate(_ id: UUID) { templates.removeAll { $0.id == id } }

    public func resetTemplates() { templates = AgentPromptTemplate.defaults }

    // MARK: Demo

    /// Debug/demo: shows these tasks instead of the saved ones. Never persisted.
    public func loadDemo(tasks: [AgentTask]) {
        isDemo = true
        self.tasks = tasks
    }
}

// MARK: - Git

/// The git side of starting a task: listing branches to start from and making the worktree.
public enum AgentTaskGit {
    /// Local branch names, the default branch first.
    public static func localBranches(_ root: String, defaultBranch: String? = nil) -> [String] {
        let names = RepoGit.git(root, ["branch", "--format=%(refname:short)"]).stdout
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = defaultBranch, names.contains(first) else { return names }
        return [first] + names.filter { $0 != first }
    }

    public struct Worktree: Sendable, Equatable {
        public var path: String
        public var branch: String
    }

    /// What `create` would make: a free `agent/…` branch name and folder.
    public static func plan(root: String, prompt: String, branches: [String],
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Worktree {
        let branch = AgentTaskNaming.branchName(for: prompt, taken: Set(branches))
        return Worktree(path: AgentTaskNaming.worktreePath(repoRoot: root, branch: branch, exists: exists), branch: branch)
    }

    /// `git worktree add -b agent/<slug> <folder> <base>`: a new branch from `base`, checked out next to the
    /// repository. Never touches the main checkout. Returns git's complaint on failure.
    public static func create(root: String, prompt: String, base: String) -> Result<Worktree, AgentTaskError> {
        let plan = plan(root: root, prompt: prompt, branches: localBranches(root))
        let container = (plan.path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: container, withIntermediateDirectories: true)
        } catch {
            return .failure(AgentTaskError("Couldn't create \(container): \(error.localizedDescription)"))
        }
        let out = RepoGit.git(root, ["worktree", "add", "--quiet", "-b", plan.branch, plan.path, base], timeout: 120)
        guard out.ok else {
            let reason = (out.stderr.isEmpty ? out.stdout : out.stderr).split(separator: "\n").first.map(String.init) ?? "git exited with \(out.status)"
            return .failure(AgentTaskError(reason.replacingOccurrences(of: "fatal: ", with: "")))
        }
        GitCheckout.resetCache()
        return .success(plan)
    }
}

public struct AgentTaskError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}
