import Foundation
import Combine

// CI and deploys: GitHub Actions workflow runs, their jobs, steps and logs, and deployments (Vercel, Netlify and
// anything else that reports to GitHub's Deployments API). All through `gh`.

public enum GHRunStatus: String, Sendable, Hashable {
    case queued, running, success, failure, cancelled, skipped, neutral

    /// REST `status` (queued, in_progress, completed, waiting, requested, pending) plus `conclusion`.
    public init(status: String?, conclusion: String?) {
        switch status {
        case "queued", "waiting", "requested", "pending": self = .queued
        case "in_progress": self = .running
        default:
            switch conclusion {
            case "success": self = .success
            case "failure", "timed_out", "startup_failure", "action_required": self = .failure
            case "cancelled": self = .cancelled
            case "skipped": self = .skipped
            default: self = .neutral
            }
        }
    }

    public var isActive: Bool { self == .queued || self == .running }
    public var title: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "In progress"
        case .success: return "Success"
        case .failure: return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        case .neutral: return "Completed"
        }
    }
    public var check: CheckState {
        switch self {
        case .queued, .running: return .pending
        case .success: return .success
        case .failure: return .failure
        default: return .none
        }
    }
}

public struct GHRun: Identifiable, Hashable, Sendable {
    public var id: Int
    public var repo: String
    public var workflow: String
    public var title: String
    public var status: GHRunStatus
    public var branch: String
    public var event: String
    public var sha: String
    public var actor: String
    public var number: Int
    public var attempt: Int
    public var createdAt: Date?
    public var startedAt: Date?
    public var updatedAt: Date?
    public var url: String

    public init(id: Int, repo: String, workflow: String, title: String, status: GHRunStatus, branch: String, event: String = "push",
                sha: String = "", actor: String = "", number: Int = 1, attempt: Int = 1, createdAt: Date? = nil, startedAt: Date? = nil,
                updatedAt: Date? = nil, url: String? = nil) {
        self.id = id
        self.repo = repo
        self.workflow = workflow
        self.title = title
        self.status = status
        self.branch = branch
        self.event = event
        self.sha = sha
        self.actor = actor
        self.number = number
        self.attempt = attempt
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.url = url ?? "https://github.com/\(repo)/actions/runs/\(id)"
    }

    public var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    /// Wall time so far, or in total once finished.
    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let start = startedAt ?? createdAt else { return nil }
        return (status.isActive ? now : (updatedAt ?? now)).timeIntervalSince(start)
    }
}

public struct GHStep: Hashable, Sendable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var name: String
    public var status: GHRunStatus

    public init(number: Int, name: String, status: GHRunStatus) {
        self.number = number
        self.name = name
        self.status = status
    }
}

public struct GHJob: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var status: GHRunStatus
    public var startedAt: Date?
    public var completedAt: Date?
    public var steps: [GHStep]
    public var url: String

    public init(id: Int, name: String, status: GHRunStatus, startedAt: Date? = nil, completedAt: Date? = nil, steps: [GHStep] = [], url: String = "") {
        self.id = id
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.steps = steps
        self.url = url
    }

    public var failedStep: GHStep? { steps.first { $0.status == .failure } }
}

public enum GHDeployState: String, Sendable, Hashable {
    case success, failure, pending, inProgress, inactive, unknown

    public init(_ raw: String?) {
        switch raw?.uppercased() {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "QUEUED", "WAITING": self = .pending
        case "IN_PROGRESS": self = .inProgress
        case "INACTIVE", "DESTROYED": self = .inactive
        default: self = .unknown
        }
    }

    public var title: String {
        switch self {
        case .success: return "Ready"
        case .failure: return "Failed"
        case .pending: return "Queued"
        case .inProgress: return "Deploying"
        case .inactive: return "Superseded"
        case .unknown: return "Unknown"
        }
    }
    public var check: CheckState {
        switch self {
        case .success: return .success
        case .failure: return .failure
        case .pending, .inProgress: return .pending
        default: return .none
        }
    }
}

public struct GHDeployment: Identifiable, Hashable, Sendable {
    public var id: String
    public var repo: String
    public var environment: String
    public var state: GHDeployState
    public var sha: String
    public var branch: String?
    public var creator: String
    public var createdAt: Date?
    public var url: String?
    public var logURL: String?

    public init(id: String, repo: String, environment: String, state: GHDeployState, sha: String = "", branch: String? = nil,
                creator: String = "", createdAt: Date? = nil, url: String? = nil, logURL: String? = nil) {
        self.id = id
        self.repo = repo
        self.environment = environment
        self.state = state
        self.sha = sha
        self.branch = branch
        self.creator = creator
        self.createdAt = createdAt
        self.url = url
        self.logURL = logURL
    }

    /// Vercel, Netlify, Render…, guessed from the bot that created it.
    public var provider: String {
        let c = creator.lowercased()
        if c.contains("vercel") { return "Vercel" }
        if c.contains("netlify") { return "Netlify" }
        if c.contains("render") { return "Render" }
        if c.contains("railway") { return "Railway" }
        if c.contains("github-actions") { return "Actions" }
        return creator.replacingOccurrences(of: "[bot]", with: "")
    }
    public var isProduction: Bool { environment.lowercased().hasPrefix("production") }
}

/// One line of a job log, with what it is.
public struct GHLogLine: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case group, error, warning, command, plain }
    public var id: Int
    public var kind: Kind
    public var text: String

    /// GitHub's job log: each line starts with an ISO timestamp, and `##[group]`, `##[error]`, `##[warning]`
    /// markers say what it is.
    public static func parse(_ log: String) -> [GHLogLine] {
        var lines: [GHLogLine] = []
        for raw in log.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = String(raw)
            // "2026-10-06T10:00:01.1234567Z message"
            if text.count > 29, text.dropFirst(4).first == "-", let space = text.firstIndex(of: " "),
               text.distance(from: text.startIndex, to: space) <= 30 {
                text = String(text[text.index(after: space)...])
            }
            text = text.replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression)
            let kind: Kind
            if text.hasPrefix("##[group]") { kind = .group; text = String(text.dropFirst(9)) }
            else if text.hasPrefix("##[endgroup]") { continue }
            else if text.hasPrefix("##[error]") { kind = .error; text = String(text.dropFirst(9)) }
            else if text.hasPrefix("##[warning]") { kind = .warning; text = String(text.dropFirst(11)) }
            else if text.hasPrefix("[command]") { kind = .command; text = String(text.dropFirst(9)) }
            // Beyond GitHub's own markers, only lines shaped like a compiler or test failure: "error: …",
            // "file.ts(3,1): error TS…", "FAIL src/…", "Error: …". Prose that mentions "error" stays plain.
            else if text.range(of: #"^(error|Error|ERROR)[:\[ ]|: error( |:)|^\s*(FAIL|FAILED)\b|^npm ERR!|^Traceback "#,
                                options: .regularExpression) != nil { kind = .error }
            else { kind = .plain }
            lines.append(GHLogLine(id: lines.count, kind: kind, text: text))
        }
        return lines
    }

    /// The lines around the first error, to hand to an agent: what failed, without a whole log of noise.
    public static func excerpt(_ lines: [GHLogLine], context: Int = 25, limit: Int = 80) -> String {
        guard let first = lines.firstIndex(where: { $0.kind == .error }) else {
            return lines.suffix(limit).map(\.text).joined(separator: "\n")
        }
        let start = max(0, first - context)
        return lines[start..<min(lines.count, start + limit)].map(\.text).joined(separator: "\n")
    }
}

extension GitHubAPI {
    public static func runs(_ slug: String, branch: String? = nil, perPage: Int = 20) -> Result<[GHRun], Failure> {
        var path = "repos/\(slug)/actions/runs?per_page=\(perPage)&exclude_pull_requests=true"
        if let branch, let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { path += "&branch=\(encoded)" }
        return gh(["api", path], timeout: 30).flatMap { text in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                return .failure(Failure("Unexpected reply from GitHub"))
            }
            return .success((object["workflow_runs"] as? [[String: Any]] ?? []).compactMap { run($0, repo: slug) })
        }
    }

    static func run(_ r: [String: Any], repo: String) -> GHRun? {
        guard let id = r["id"] as? Int else { return nil }
        return GHRun(id: id, repo: repo, workflow: r["name"] as? String ?? "Workflow",
                     title: r["display_title"] as? String ?? "", status: GHRunStatus(status: r["status"] as? String, conclusion: r["conclusion"] as? String),
                     branch: r["head_branch"] as? String ?? "", event: r["event"] as? String ?? "", sha: r["head_sha"] as? String ?? "",
                     actor: dict(r["actor"])?["login"] as? String ?? "", number: r["run_number"] as? Int ?? 0,
                     attempt: r["run_attempt"] as? Int ?? 1, createdAt: date(r["created_at"]), startedAt: date(r["run_started_at"]),
                     updatedAt: date(r["updated_at"]), url: r["html_url"] as? String)
    }

    public static func jobs(_ slug: String, run: Int) -> Result<[GHJob], Failure> {
        gh(["api", "repos/\(slug)/actions/runs/\(run)/jobs?per_page=100"], timeout: 30).flatMap { text in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                return .failure(Failure("Unexpected reply from GitHub"))
            }
            return .success((object["jobs"] as? [[String: Any]] ?? []).compactMap { j in
                guard let id = j["id"] as? Int else { return nil }
                let steps = (j["steps"] as? [[String: Any]] ?? []).map {
                    GHStep(number: $0["number"] as? Int ?? 0, name: $0["name"] as? String ?? "",
                           status: GHRunStatus(status: $0["status"] as? String, conclusion: $0["conclusion"] as? String))
                }
                return GHJob(id: id, name: j["name"] as? String ?? "Job",
                             status: GHRunStatus(status: j["status"] as? String, conclusion: j["conclusion"] as? String),
                             startedAt: date(j["started_at"]), completedAt: date(j["completed_at"]), steps: steps,
                             url: j["html_url"] as? String ?? "")
            })
        }
    }

    /// Colour codes are allowed through (gh refuses them otherwise); `GHLogLine.parse` strips them.
    public static func jobLog(_ slug: String, job: Int) -> Result<String, Failure> {
        gh(["api", "--allow-escape-sequences", "repos/\(slug)/actions/jobs/\(job)/logs"], timeout: 60)
    }

    public static func rerun(_ slug: String, run: Int, failedOnly: Bool) -> Result<String, Failure> {
        gh(["run", "rerun", "\(run)", "-R", slug] + (failedOnly ? ["--failed"] : []))
    }

    public static func cancel(_ slug: String, run: Int) -> Result<String, Failure> {
        gh(["run", "cancel", "\(run)", "-R", slug])
    }

    static let deploymentsQuery = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        deployments(last: 30, orderBy: {field: CREATED_AT, direction: ASC}) {
          nodes { id environment createdAt commitOid ref { name } creator { login }
                  latestStatus { state environmentUrl logUrl createdAt } }
        }
      }
    }
    """

    /// The newest deployment per environment, newest first.
    public static func deployments(_ slug: String) -> Result<[GHDeployment], Failure> {
        let (owner, name) = split(slug)
        return graphQL(deploymentsQuery, ["owner": owner, "name": name]).map { data in
            let all = nodes(dict(dict(data["repository"])?["deployments"])).compactMap { d -> GHDeployment? in
                guard let id = d["id"] as? String else { return nil }
                let status = dict(d["latestStatus"])
                return GHDeployment(id: id, repo: slug, environment: d["environment"] as? String ?? "default",
                                    state: GHDeployState(status?["state"] as? String), sha: d["commitOid"] as? String ?? "",
                                    branch: dict(d["ref"])?["name"] as? String, creator: dict(d["creator"])?["login"] as? String ?? "",
                                    createdAt: date(d["createdAt"]),
                                    url: (status?["environmentUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    logURL: (status?["logUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
            var latest: [String: GHDeployment] = [:]
            for d in all where d.state != .inactive || latest[d.environment] == nil {
                if (latest[d.environment]?.createdAt ?? .distantPast) <= (d.createdAt ?? .distantPast) { latest[d.environment] = d }
            }
            return latest.values.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        }
    }
}

/// CI & Deploys: recent workflow runs and the latest deployment per environment for the repositories you work in,
/// polled faster while something is running. The app tells it which repositories to watch.
@MainActor
public final class CIStore: ObservableObject {
    public static let shared = CIStore()

    @Published public private(set) var runs: [GHRun] = []
    @Published public private(set) var deployments: [GHDeployment] = []
    @Published public private(set) var jobs: [Int: [GHJob]] = [:]
    @Published public private(set) var logs: [Int: [GHLogLine]] = [:]
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var error: String?
    @Published public private(set) var loadingJobs: Set<Int> = []
    @Published public private(set) var working: Set<Int> = []
    @Published public var selectedRun: Int?
    @Published public var searchText = ""

    /// A run finished: run, previous status. The app turns these into notifications.
    public var onRunFinished: ((GHRun) -> Void)?
    public var onActionResult: ((String, Bool) -> Void)?

    private var watched: [String] = []
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var isDemo = false
    private var primed = false

    public static let activeInterval: TimeInterval = 30
    public static let idleInterval: TimeInterval = 240

    public init() {}

    /// Repositories (`owner/name`) to follow. Starts polling the first time it's called.
    public func watch(_ slugs: [String]) {
        let unique = Array(NSOrderedSet(array: slugs.map { $0.lowercased() })) as? [String] ?? slugs
        guard unique != watched else { return }
        watched = unique
        refresh()
    }

    public var activeRuns: [GHRun] { runs.filter(\.status.isActive) }
    public var failedRuns: [GHRun] {
        // Latest run per workflow and branch: a failure that's been fixed since isn't news.
        var latest: [String: GHRun] = [:]
        for run in runs where latest["\(run.repo)|\(run.workflow)|\(run.branch)"] == nil { latest["\(run.repo)|\(run.workflow)|\(run.branch)"] = run }
        return latest.values.filter { $0.status == .failure }.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    public var filteredRuns: [GHRun] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return runs }
        return runs.filter { [$0.repo, $0.workflow, $0.title, $0.branch, $0.actor].contains { $0.lowercased().contains(q) } }
    }

    public func runs(for slug: String) -> [GHRun] { runs.filter { $0.repo.caseInsensitiveCompare(slug) == .orderedSame } }
    public func deployments(for slug: String) -> [GHDeployment] { deployments.filter { $0.repo.caseInsensitiveCompare(slug) == .orderedSame } }

    public func refresh() {
        guard !isDemo, task == nil, !watched.isEmpty else { return }
        isLoading = true
        let slugs = watched
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> ([GHRun], [GHDeployment], String?) in
                let lock = NSLock()
                var runs: [GHRun] = [], deploys: [GHDeployment] = [], errors: [String] = []
                DispatchQueue.concurrentPerform(iterations: slugs.count) { i in
                    let r = GitHubAPI.runs(slugs[i], perPage: 15)
                    let d = GitHubAPI.deployments(slugs[i])
                    lock.lock()
                    if case .success(let list) = r { runs += list } else if case .failure(let f) = r { errors.append(f.message) }
                    if case .success(let list) = d { deploys += list }
                    lock.unlock()
                }
                // Every repository failing means GitHub is unreachable; a few failing is just repos without Actions.
                return (runs.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }, deploys,
                        runs.isEmpty && errors.count == slugs.count ? errors.first : nil)
            }.value
            guard let self else { return }
            let previous = Dictionary(self.runs.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
            if self.primed {
                for run in result.0 where previous[run.id]?.isActive == true && !run.status.isActive { self.onRunFinished?(run) }
            }
            self.primed = true
            if result.0 != self.runs { self.runs = result.0 }
            if result.1 != self.deployments { self.deployments = result.1 }
            self.error = result.2
            self.lastRefresh = Date()
            self.isLoading = false
            self.task = nil
            // Keep an open run's jobs current while it runs.
            if let id = self.selectedRun, let run = self.runs.first(where: { $0.id == id }), run.status.isActive || self.jobs[id] != nil {
                self.loadJobs(run, force: true)
            }
            self.schedule()
        }
    }

    private func schedule() {
        timer?.invalidate()
        let interval = activeRuns.isEmpty ? Self.idleInterval : Self.activeInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = interval / 5
    }

    public func loadJobs(_ run: GHRun, force: Bool = false) {
        guard !isDemo, !loadingJobs.contains(run.id), force || jobs[run.id] == nil else { return }
        loadingJobs.insert(run.id)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { GitHubAPI.jobs(run.repo, run: run.id) }.value
            guard let self else { return }
            self.loadingJobs.remove(run.id)
            if case .success(let list) = result { self.jobs[run.id] = list }
        }
    }

    public func loadLog(_ job: GHJob, repo: String) {
        guard !isDemo, logs[job.id] == nil, !loadingJobs.contains(job.id) else { return }
        loadingJobs.insert(job.id)
        Task { [weak self] in
            let lines = await Task.detached(priority: .userInitiated) { () -> [GHLogLine] in
                switch GitHubAPI.jobLog(repo, job: job.id) {
                case .success(let text): return GHLogLine.parse(text)
                case .failure(let f): return [GHLogLine(id: 0, kind: .error, text: "Couldn't load the log: \(f.message)")]
                }
            }.value
            guard let self else { return }
            self.loadingJobs.remove(job.id)
            self.logs[job.id] = lines
        }
    }

    public func rerun(_ run: GHRun, failedOnly: Bool) {
        act(run, success: failedOnly ? "Re-running failed jobs of \(run.workflow)" : "Re-running \(run.workflow)") {
            GitHubAPI.rerun(run.repo, run: run.id, failedOnly: failedOnly)
        }
    }

    public func cancel(_ run: GHRun) {
        act(run, success: "Cancelled \(run.workflow)") { GitHubAPI.cancel(run.repo, run: run.id) }
    }

    private func act(_ run: GHRun, success: String, _ work: @escaping @Sendable () -> Result<String, GitHubAPI.Failure>) {
        guard !working.contains(run.id) else { return }
        if isDemo { onActionResult?(success + " (demo)", true); return }
        working.insert(run.id)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { work() }.value
            guard let self else { return }
            self.working.remove(run.id)
            switch result {
            case .success: self.onActionResult?(success, true)
            case .failure(let f): self.onActionResult?(f.message, false)
            }
            self.jobs[run.id] = nil
            try? await Task.sleep(for: .seconds(3))
            self.refresh()
        }
    }

    public func loadDemo(runs: [GHRun], deployments: [GHDeployment], jobs: [Int: [GHJob]], logs: [Int: [GHLogLine]]) {
        isDemo = true
        self.runs = runs
        self.deployments = deployments
        self.jobs = jobs
        self.logs = logs
        lastRefresh = Date()
    }
}
