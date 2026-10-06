#if DEBUG
import AppKit
import CoreAudio
import LocalObserverCore
import LocalObserverRepos
import LocalObserverDisk

/// Debug-only: `LOCAL_OBSERVER_SNAPSHOT_DEMO=1` makes the snapshot harness render made-up but plausible data
/// (projects, sessions, a year of usage, plan limits, servers, audio) so screenshots never show this Mac's.
/// Everything is seeded, so reruns produce the same images (relative to the day they're rendered).
@MainActor
enum SnapshotDemo {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_DEMO"] == "1" }

    /// Deterministic SplitMix64, so the heatmap looks the same on every run.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
        mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    }

    private static let root = "/Users/dev/code"
    private static let projects = ["aurora-api", "pixel-garden", "tidepool", "lumen-docs", "orbit-cli"]
    /// Model, $ per million tokens processed (blended, cache-heavy), and how often the agent shows up.
    private static let agentModels: [(AgentKind, [String], Double, Double)] = [
        (.claude, ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"], 0.55, 0.42),
        (.codex, ["gpt-5-codex", "gpt-5"], 0.35, 0.24),
        (.antigravity, ["gemini-2.5-pro", "gemini-2.5-flash"], 0.25, 0.14),
        (.openCode, ["kimi-k2", "qwen3-coder"], 0.15, 0.11),
        (.qoder, ["qoder-auto"], 0.2, 0.09),
    ]

    // MARK: - Agents

    static func loadAgents(into store: AgentStore) {
        let now = Date()
        let sessions = runningSessions(now: now).map(withDemoCheckout)
        let recent = recentSessions(now: now)
        let ledger = ledger(now: now)
        let counts = Dictionary(grouping: ledger, by: \.agent).mapValues(\.count)
        let integrations = AgentKind.allCases.map { agent in
            let installed = agent != .pi && agent != .cursor
            return AgentIntegration(
                agent: agent, isInstalled: installed,
                installedPath: installed ? "/usr/local/bin/\(agent.executableNames.first ?? agent.rawValue)" : "",
                runningProcessCount: sessions.filter { $0.agent == agent }.count,
                sessionCount: (sessions + recent).filter { $0.agent == agent }.count,
                usageEventCount: counts[agent] ?? 0,
                sourceState: installed ? .available : .unavailable,
                message: installed ? "" : "Not installed", lastUpdated: installed ? now : nil)
        }
        let snapshot = AgentSnapshot(discoveredAt: now, processes: sessions, sessions: sessions + recent, usageEvents: [],
                                     limitReports: [], integrations: integrations, warnings: [])
        store.loadDemo(snapshot: snapshot, ledger: ledger, limits: limits(now: now))
    }

    private static func session(_ n: Int, _ agent: AgentKind, _ project: String, _ title: String, model: String,
                                branch: String, state: AgentActivityState, started: TimeInterval, updated: TimeInterval,
                                tokens: Int64, cost: Double?, running: Bool, now: Date, host: String = "Terminal") -> AgentSession {
        let path = "\(root)/\(project)"
        let process = running ? AgentProcess(
            pid: Int32(41_000 + n * 137), parentPID: Int32(40_000 + n), processName: agent.executableNames.first ?? agent.rawValue,
            executablePath: "/usr/local/bin/\(agent.executableNames.first ?? agent.rawValue)", workingDirectory: path,
            startedAt: now.addingTimeInterval(-started), terminal: "ttys00\(n)",
            host: AgentHostApp(pid: Int32(400 + n), name: host,
                               bundlePath: host == "Terminal" ? "/System/Applications/Utilities/Terminal.app" : "/Applications/\(host).app")
        ) : nil
        let input = tokens * 7 / 10
        return AgentSession(
            id: "demo-\(agent.rawValue)-\(n)", agent: agent, sessionID: "demo-session-\(n)", title: title, process: process,
            projectPath: path, projectName: project, model: model, account: "dev@example.com", branch: branch,
            state: state, startedAt: now.addingTimeInterval(-started), updatedAt: now.addingTimeInterval(-updated),
            sourcePath: "", sourceKind: running ? .process : .transcript,
            usage: TokenUsage(inputTokens: input, uncachedInputTokens: input / 6, cachedInputTokens: input * 5 / 6,
                              outputTokens: tokens - input),
            cost: cost, requests: Int(tokens / 40_000) + 3, costIsEstimated: agent != .claude,
            contextTokens: min(tokens / 4, 168_000))
    }

    /// Running sessions get a live checkout like the real scan attaches; two work in agent-made worktrees.
    private static func withDemoCheckout(_ session: AgentSession) -> AgentSession {
        var s = session
        let main = "\(root)/\(session.projectName)"
        switch session.agent {
        case .claude:
            s.checkout = GitCheckout(root: "/Users/dev/.t3/worktrees/\(session.projectName)/t3code-4f2a91", mainRoot: main,
                                     branch: session.branch, isLinkedWorktree: true)
        case .qoder:
            s.checkout = GitCheckout(root: "/Users/dev/.qoder/worktrees/app/9c1e7b/\(session.projectName)", mainRoot: main,
                                     branch: session.branch, isLinkedWorktree: true)
        default:
            s.checkout = GitCheckout(root: main, mainRoot: main, branch: session.branch, isLinkedWorktree: false)
        }
        return s
    }

    private static func runningSessions(now: Date) -> [AgentSession] {
        [
            session(1, .claude, "aurora-api", "Add rate limiting to /search", model: "claude-sonnet-4-5",
                    branch: "feat/search-rate-limit", state: .working, started: 48 * 60, updated: 4,
                    tokens: 4_820_000, cost: 3.42, running: true, now: now),
            session(2, .codex, "pixel-garden", "Fix flaky auth test", model: "gpt-5-codex",
                    branch: "fix/flaky-auth", state: .needsInput, started: 22 * 60, updated: 90,
                    tokens: 1_960_000, cost: 1.18, running: true, now: now, host: "Ghostty"),
            session(3, .antigravity, "lumen-docs", "Dark mode for settings", model: "gemini-2.5-pro",
                    branch: "feat/dark-settings", state: .waiting, started: 75 * 60, updated: 6 * 60,
                    tokens: 2_740_000, cost: 0.86, running: true, now: now, host: "Antigravity"),
            session(4, .openCode, "orbit-cli", "Stream progress bars for uploads", model: "kimi-k2",
                    branch: "main", state: .toolUse, started: 12 * 60, updated: 10,
                    tokens: 640_000, cost: 0.21, running: true, now: now),
            session(5, .qoder, "tidepool", "Migrate jobs to the new queue", model: "qoder-auto",
                    branch: "chore/queue-v2", state: .idle, started: 3 * 3600, updated: 41 * 60,
                    tokens: 1_310_000, cost: nil, running: true, now: now, host: "Qoder"),
        ]
    }

    private static func recentSessions(now: Date) -> [AgentSession] {
        [
            session(6, .claude, "tidepool", "Write migration for tide_events index", model: "claude-opus-4-1",
                    branch: "main", state: .idle, started: 5 * 3600, updated: 3 * 3600,
                    tokens: 3_100_000, cost: 4.95, running: false, now: now),
            session(7, .codex, "aurora-api", "Bump OpenTelemetry and fix spans", model: "gpt-5",
                    branch: "deps/otel-1.30", state: .idle, started: 9 * 3600, updated: 7 * 3600,
                    tokens: 1_420_000, cost: 0.74, running: false, now: now),
            session(8, .claude, "pixel-garden", "Sprite atlas packing is off by one", model: "claude-sonnet-4-5",
                    branch: "fix/atlas-padding", state: .idle, started: 26 * 3600, updated: 24 * 3600,
                    tokens: 2_050_000, cost: 1.63, running: false, now: now),
            session(9, .antigravity, "orbit-cli", "Add --json output to orbit status", model: "gemini-2.5-flash",
                    branch: "feat/status-json", state: .idle, started: 30 * 3600, updated: 29 * 3600,
                    tokens: 880_000, cost: 0.12, running: false, now: now),
        ]
    }

    /// A year of usage: weekday-heavy, slowly growing, with quiet stretches and the odd busy weekend.
    private static func ledger(now: Date) -> [AgentUsageEvent] {
        var rng = Seeded(state: 0x10C0_0D7E)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var events: [AgentUsageEvent] = []
        for back in stride(from: 364, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            let growth = 0.12 + 0.88 * pow(Double(364 - back) / 364, 1.4)
            // Roughly two weeks off in mid-winter and a quiet week in summer.
            let vacation = (back > 270 && back < 285) || (back > 120 && back < 126)
            var activity = pow(rng.unit(), 1.3)
            if rng.unit() < 0.06 { activity *= 2.2 }
            if weekend { activity *= rng.unit() < 0.25 ? 0.9 : 0.15 }
            if vacation { activity *= 0.05 }
            if rng.unit() < 0.07 { activity = 0 }
            // Today always has something on the go: the dashboard's "Today" and 24h cards shouldn't be empty.
            var sessions = back == 0 ? 8 : Int((activity * 8 * growth).rounded())
            if !weekend, !vacation, activity > 0, back < 200 { sessions = max(sessions, 1 + Int(growth * 2)) }
            guard sessions > 0 else { continue }
            let sinceMidnight = now.timeIntervalSince(day)
            for s in 0..<sessions {
                let roll = rng.unit()
                var cumulative = 0.0
                let entry = agentModels.first { cumulative += $0.3; return roll < cumulative } ?? agentModels[0]
                let (agent, models, rate, _) = entry
                let model = rng.pick(models)
                let project = rng.pick(projects)
                let sessionID = "demo-\(back)-\(s)"
                let turns = rng.int(3...14)
                let start = back == 0
                    ? now.addingTimeInterval(-rng.range(0.1...0.95) * min(sinceMidnight, 13 * 3600))
                    : day.addingTimeInterval(rng.range(9 * 3600...20 * 3600))
                for turn in 0..<turns {
                    let at = start.addingTimeInterval(Double(turn) * rng.range(60...420))
                    guard at <= now else { break }
                    let tokens = Int64(rng.range(18_000...140_000) * growth * (model.contains("opus") ? 1.4 : 1))
                    let output = tokens / Int64(rng.int(18...40))
                    let cached = (tokens - output) * Int64(rng.int(70...92)) / 100
                    let usage = TokenUsage(inputTokens: tokens - output, uncachedInputTokens: tokens - output - cached,
                                           cachedInputTokens: cached, outputTokens: output)
                    let cost = Double(tokens) / 1_000_000 * rate * (model.contains("opus") ? 3 : 1)
                    events.append(AgentUsageEvent(
                        id: "\(sessionID)-\(turn)", agent: agent, sessionID: sessionID,
                        projectPath: "\(root)/\(project)", projectName: project, model: model, observedAt: at,
                        usage: usage, cost: cost, requests: 1, sourcePath: "", sourceKind: .transcript,
                        costIsEstimated: agent != .claude, cacheSavings: cost * 0.6))
                }
            }
        }
        return events.sorted { $0.observedAt < $1.observedAt }
    }

    private static func limits(now: Date) -> [AgentLimitReport] {
        let hour: TimeInterval = 3600, day: TimeInterval = 86_400
        func window(_ agent: AgentKind, _ id: String, _ label: String, _ kind: AgentLimitKind, _ percent: Double,
                    resetsIn: TimeInterval, duration: TimeInterval?, detail: String = "", source: String) -> AgentQuotaWindow {
            AgentQuotaWindow(id: "\(agent.rawValue)-\(id)", agent: agent, label: label, kind: kind, usedPercent: percent,
                             resetsAt: now.addingTimeInterval(resetsIn), windowDuration: duration, detail: detail,
                             observedAt: now, source: source, account: "dev@example.com")
        }
        let claude = "Anthropic usage API", codex = "Codex usage API", agy = "agy usage report", copilot = "GitHub Copilot API"
        return [
            AgentLimitReport(agent: .claude, status: .connected, plan: "Max 5x", account: "dev@example.com", windows: [
                window(.claude, "session", "5-hour session", .session, 64, resetsIn: 1.6 * hour, duration: 5 * hour, source: claude),
                window(.claude, "weekly", "Weekly · all models", .weekly, 41, resetsIn: 3.3 * day, duration: 7 * day, source: claude),
                window(.claude, "weekly-opus", "Weekly · Opus", .weeklyModel, 18, resetsIn: 3.3 * day, duration: 7 * day, source: claude),
            ], fetchedAt: now, source: claude),
            AgentLimitReport(agent: .codex, status: .connected, plan: "Plus", account: "dev@example.com", windows: [
                window(.codex, "session", "5-hour", .session, 27, resetsIn: 3.1 * hour, duration: 5 * hour, source: codex),
                window(.codex, "weekly", "Weekly", .weekly, 52, resetsIn: 4.5 * day, duration: 7 * day, source: codex),
            ], fetchedAt: now, source: codex),
            AgentLimitReport(agent: .antigravity, status: .connected, plan: "Pro", account: "dev@example.com", windows: [
                window(.antigravity, "pro-5h", "Gemini Pro · 5-hour", .session, 83, resetsIn: 0.7 * hour, duration: 5 * hour, source: agy),
                window(.antigravity, "pro-weekly", "Gemini Pro · Weekly", .weekly, 36, resetsIn: 5.2 * day, duration: 7 * day, source: agy),
            ], fetchedAt: now, source: agy),
            AgentLimitReport(agent: .copilot, status: .connected, plan: "Pro", account: "dev-octocat", windows: [
                window(.copilot, "premium-interactions", "Premium requests", .monthly, 46, resetsIn: 12 * day, duration: 30 * day,
                       detail: "138 of 300 used", source: copilot),
            ], fetchedAt: now, source: copilot),
        ]
    }

    // MARK: - Servers

    static func loadServers(into state: AppState) {
        func server(_ pid: Int32, _ name: String, _ process: String, _ command: String, _ port: Int, _ type: ProjectType,
                    _ http: HttpState, title: String = "", latency: Int = 0, cpu: Double, mb: Int, uptime: TimeInterval,
                    branch: String? = nil, worktree: String? = nil) -> ServerEntry {
            let main = "\(root)/\(name)"
            let path = worktree ?? main
            let git = branch.map { GitCheckout(root: path, mainRoot: main, branch: $0, isLinkedWorktree: worktree != nil) }
            return ServerEntry(pid: pid, pgid: pid, processName: process, command: command, port: port, bindAddress: "127.0.0.1",
                               workingDirectory: path, projectRoot: path, projectName: name, projectType: type,
                               httpState: http, statusCode: http == .online ? 200 : 0, latencyMs: latency, pageTitle: title,
                               cpu: cpu, rssKB: mb * 1024, uptime: uptime, git: git)
        }
        state.loadDemo(servers: [
            server(52_101, "aurora-api", "node", "node dist/server.js --port 3000", 3000, .node, .online,
                   title: "Aurora API", latency: 12, cpu: 3.4, mb: 182, uptime: 3 * 3600 + 1_240, branch: "main"),
            server(53_017, "aurora-api", "node", "node dist/server.js --port 3001", 3001, .node, .online,
                   title: "Aurora API", latency: 14, cpu: 2.1, mb: 176, uptime: 41 * 60, branch: "feat/search-rate-limit",
                   worktree: "/Users/dev/.t3/worktrees/aurora-api/t3code-4f2a91"),
            server(52_244, "pixel-garden", "node", "node node_modules/.bin/vite --port 5173", 5173, .node, .online,
                   title: "Pixel Garden", latency: 8, cpu: 1.2, mb: 241, uptime: 52 * 60, branch: "fix/flaky-auth"),
            server(52_390, "lumen-docs", "node", "node node_modules/.bin/astro dev --port 4321", 4321, .node, .online,
                   title: "Lumen Docs", latency: 21, cpu: 0.6, mb: 156, uptime: 6 * 3600, branch: "main"),
            server(48_812, "tidepool", "python3", "python3 -m uvicorn tidepool.app:app --port 8000", 8000, .python, .online,
                   title: "Tidepool", latency: 15, cpu: 0.9, mb: 98, uptime: 26 * 3600, branch: "chore/queue-v2",
                   worktree: "/Users/dev/.qoder/worktrees/app/9c1e7b/tidepool"),
            server(612, "postgres", "postgres", "postgres -D /usr/local/var/postgresql@16", 5432, .other, .offline,
                   cpu: 0.1, mb: 64, uptime: 4 * 86_400),
        ])
    }

    // MARK: - Repos

    static func loadRepos(into store: RepoStore) {
        let now = Date()
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        let hour: TimeInterval = 3600, day: TimeInterval = 86_400
        let repos = [
            Repo(root: "\(root)/aurora-api", name: "aurora-api",
                 status: RepoBranchStatus(branch: "main", head: "a1b2c3d", upstream: "origin/main", ahead: 0, behind: 2),
                 changes: RepoChanges(modified: 2), stashes: 1, unpushed: 0, lastCommitAt: ago(5 * hour),
                 lastCommitSubject: "Cache search results per tenant", lastCommitAuthor: "Dev", remoteURL: "git@github.com:acme/aurora-api.git",
                 github: "acme/aurora-api", defaultBranch: "main", mergedBranches: ["fix/typo-readme", "deps/otel-1.29", "spike/redis"],
                 branchCount: 9, worktrees: [
                    RepoWorktree(path: "/Users/dev/.t3/worktrees/aurora-api/t3code-4f2a91", branch: "feat/search-rate-limit", head: "f00d",
                                 changes: RepoChanges(staged: 1, modified: 4), ahead: 3, lastTouched: ago(4 * 60)),
                    RepoWorktree(path: "/Users/dev/.codex/worktrees/a7/aurora-api", branch: "deps/otel-1.30", head: "beef",
                                 changes: RepoChanges(), ahead: 0, lastTouched: ago(7 * hour)),
                 ], lastTouched: ago(20 * 60)),
            Repo(root: "\(root)/pixel-garden", name: "pixel-garden",
                 status: RepoBranchStatus(branch: "fix/flaky-auth", head: "c0ffee", upstream: "origin/fix/flaky-auth", ahead: 1),
                 changes: RepoChanges(modified: 3, untracked: 1), unpushed: 1, lastCommitAt: ago(90 * 60),
                 lastCommitSubject: "Retry token refresh once before failing", lastCommitAuthor: "Dev",
                 remoteURL: "https://github.com/acme/pixel-garden.git", github: "acme/pixel-garden", defaultBranch: "main",
                 branchCount: 4, lastTouched: ago(90)),
            Repo(root: "\(root)/tidepool", name: "tidepool",
                 status: RepoBranchStatus(branch: "main", head: "d00d", upstream: "origin/main"),
                 changes: RepoChanges(), unpushed: 0, lastCommitAt: ago(3 * hour),
                 lastCommitSubject: "Index tide_events by station and time", lastCommitAuthor: "Dev",
                 remoteURL: "git@github.com:acme/tidepool.git", github: "acme/tidepool", defaultBranch: "main", branchCount: 6,
                 worktrees: [RepoWorktree(path: "/Users/dev/.qoder/worktrees/app/9c1e7b/tidepool", branch: "chore/queue-v2", head: "abc",
                                          changes: RepoChanges(modified: 7, untracked: 2), ahead: 0, lastTouched: ago(41 * 60))],
                 lastTouched: ago(41 * 60)),
            Repo(root: "\(root)/lumen-docs", name: "lumen-docs",
                 status: RepoBranchStatus(branch: "feat/dark-settings", head: "e1e1", upstream: nil),
                 changes: RepoChanges(modified: 1), unpushed: 4, lastCommitAt: ago(6 * hour),
                 lastCommitSubject: "Settings page follows the system appearance", lastCommitAuthor: "Dev",
                 remoteURL: "git@github.com:acme/lumen-docs.git", github: "acme/lumen-docs", defaultBranch: "main", branchCount: 3,
                 lastTouched: ago(6 * 60)),
            Repo(root: "\(root)/orbit-cli", name: "orbit-cli",
                 status: RepoBranchStatus(branch: "main", head: "0b1t", upstream: "origin/main"),
                 changes: RepoChanges(), unpushed: 0, lastCommitAt: ago(29 * hour),
                 lastCommitSubject: "Add --json output to orbit status", lastCommitAuthor: "Dev",
                 remoteURL: "git@github.com:acme/orbit-cli.git", github: "acme/orbit-cli", defaultBranch: "main", branchCount: 2,
                 lastTouched: ago(29 * hour)),
            Repo(root: "\(root)/sketchbook", name: "sketchbook",
                 status: RepoBranchStatus(branch: "main", head: "5k37"),
                 changes: RepoChanges(modified: 5, untracked: 3), unpushed: nil, lastCommitAt: ago(19 * day),
                 lastCommitSubject: "Shader experiments", lastCommitAuthor: "Dev", branchCount: 1, lastTouched: ago(19 * day)),
            Repo(root: "\(root)/old-portfolio", name: "old-portfolio",
                 status: RepoBranchStatus(branch: "redesign", head: "p0rt", upstream: "origin/redesign", ahead: 2),
                 changes: RepoChanges(modified: 2), unpushed: 2, lastCommitAt: ago(34 * day),
                 lastCommitSubject: "New hero section", lastCommitAuthor: "Dev", remoteURL: "git@github.com:dev/portfolio.git",
                 github: "dev/portfolio", defaultBranch: "main", branchCount: 3, lastTouched: ago(34 * day)),
        ]
        func pr(_ n: Int, _ title: String, _ repo: String, _ branch: String, _ checks: CheckState, _ review: ReviewState,
                role: PullRequest.Role = .mine, author: String = "dev", draft: Bool = false, mergeable: Bool? = true, updated: TimeInterval) -> PullRequest {
            PullRequest(number: n, title: title, url: "https://github.com/\(repo)/pull/\(n)", repo: repo, branch: branch, isDraft: draft,
                        updatedAt: ago(updated), checks: checks, review: review, mergeable: mergeable, author: author, role: role)
        }
        let pulls = [
            pr(214, "Add rate limiting to /search", "acme/aurora-api", "feat/search-rate-limit", .pending, .required, updated: 6 * 60),
            pr(88, "Fix flaky auth test", "acme/pixel-garden", "fix/flaky-auth", .failure, .none, updated: 25 * 60),
            pr(57, "Migrate jobs to the new queue", "acme/tidepool", "chore/queue-v2", .success, .approved, updated: 2 * hour),
            pr(41, "Dark mode for settings", "acme/lumen-docs", "feat/dark-settings", .success, .changesRequested, draft: false, updated: 5 * hour),
            pr(219, "Move tenant config to Postgres", "acme/aurora-api", "feat/tenant-config", .success, .required,
               role: .reviewRequested, author: "sam", updated: 50 * 60),
            pr(12, "Document the plugin API", "acme/orbit-cli", "docs/plugins", .none, .required,
               role: .reviewRequested, author: "rin", updated: 26 * hour),
        ]
        store.loadDemo(repos: repos, pulls: pulls, login: "dev")
    }

    static func loadDisk(into store: DiskStore) {
        let now = Date()
        func ago(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
        let gb: Int64 = 1_000_000_000, mb: Int64 = 1_000_000
        let home = "/Users/dev"
        let items = [
            DiskItem(kind: .nodeModules, path: "\(root)/pixel-garden/node_modules", name: "node_modules", project: "pixel-garden",
                     bytes: 1_840 * mb, lastUsed: ago(0.05), safety: .review, note: "A server is running here (:5173)"),
            DiskItem(kind: .nodeModules, path: "\(root)/old-portfolio/node_modules", name: "node_modules", project: "old-portfolio",
                     bytes: 912 * mb, lastUsed: ago(34), note: DiskKind.nodeModules.rebuildHint),
            DiskItem(kind: .webBuild, path: "\(root)/lumen-docs/.next", name: ".next", project: "lumen-docs",
                     bytes: 640 * mb, lastUsed: ago(0.3), note: DiskKind.webBuild.rebuildHint),
            DiskItem(kind: .rustTarget, path: "\(root)/orbit-cli/target", name: "target", project: "orbit-cli",
                     bytes: 4 * gb + 300 * mb, lastUsed: ago(21), note: DiskKind.rustTarget.rebuildHint),
            DiskItem(kind: .pythonVenv, path: "\(root)/tidepool/.venv", name: ".venv", project: "tidepool",
                     bytes: 780 * mb, lastUsed: ago(0.1), safety: .review, note: "Codex is working here"),
            DiskItem(kind: .nodeModules, path: "\(root)/sketchbook/packages/web/node_modules", name: "node_modules", project: "sketchbook/packages/web",
                     bytes: 1_210 * mb, lastUsed: ago(19), note: DiskKind.nodeModules.rebuildHint),
            DiskItem(kind: .worktree, path: "\(home)/.codex/worktrees/a7/aurora-api", name: "deps/otel-1.30", project: "aurora-api · Codex",
                     ownerRoot: "\(root)/aurora-api", bytes: 1_420 * mb, lastUsed: ago(0.3), safety: .review, note: "Pull request #216 is open"),
            DiskItem(kind: .worktree, path: "\(home)/.t3/worktrees/aurora-api/t3code-4f2a91", name: "feat/search-rate-limit", project: "aurora-api · T3 Code",
                     ownerRoot: "\(root)/aurora-api", bytes: 1_380 * mb, lastUsed: ago(0.01), safety: .keep, note: "5 uncommitted, 3 unpushed"),
            DiskItem(kind: .worktree, path: "\(home)/.qoder/worktrees/app/1b2c/aurora-api", name: "fix/cache-keys", project: "aurora-api · Qoder",
                     ownerRoot: "\(root)/aurora-api", bytes: 1_350 * mb, lastUsed: ago(9), note: "Merged, nothing unsaved"),
            DiskItem(kind: .npmCache, path: "\(home)/.npm/_cacache", name: "npm cache", bytes: 3_100 * mb, lastUsed: ago(1), note: DiskKind.npmCache.rebuildHint),
            DiskItem(kind: .homebrewCache, path: "\(home)/Library/Caches/Homebrew", name: "Homebrew downloads", bytes: 2_400 * mb, lastUsed: ago(16),
                     note: DiskKind.homebrewCache.rebuildHint),
            DiskItem(kind: .pnpmStore, path: "\(home)/Library/pnpm/store", name: "pnpm store", bytes: 5_800 * mb, lastUsed: ago(2), note: DiskKind.pnpmStore.rebuildHint),
            DiskItem(kind: .derivedData, path: "\(home)/Library/Developer/Xcode/DerivedData", name: "DerivedData", bytes: 11 * gb, lastUsed: ago(3),
                     note: DiskKind.derivedData.rebuildHint),
            DiskItem(kind: .deviceSupport, path: "\(home)/Library/Developer/Xcode/iOS DeviceSupport", name: "iOS DeviceSupport", bytes: 6_200 * mb,
                     lastUsed: ago(80), safety: .review, note: DiskKind.deviceSupport.rebuildHint),
            DiskItem(kind: .xcodeArchives, path: "\(home)/Library/Developer/Xcode/Archives", name: "Archives", bytes: 1_900 * mb, lastUsed: ago(40),
                     safety: .keep, note: DiskKind.xcodeArchives.rebuildHint),
            DiskItem(id: "docker:builder", kind: .dockerBuildCache, path: "", name: "Build cache", bytes: 7_300 * mb, safety: .safe, note: "9.1 GB total"),
            DiskItem(id: "docker:images", kind: .dockerImages, path: "", name: "Unused images", bytes: 4_600 * mb, safety: .review,
                     note: "23 images, 4 in use · 8.2 GB total"),
            DiskItem(id: "docker:volumes", kind: .dockerVolumes, path: "", name: "Unused volumes", bytes: 1_200 * mb, safety: .keep,
                     note: "6 volumes, 2 in use. Volumes hold data, so Lookout leaves them alone."),
            DiskItem(kind: .agentData, path: "\(home)/.claude/projects", name: "Claude Code transcripts", bytes: 2_700 * mb, lastUsed: ago(0.01),
                     safety: .keep, note: DiskKind.agentData.rebuildHint),
            DiskItem(kind: .agentData, path: "\(home)/.codex/sessions", name: "Codex sessions", bytes: 840 * mb, lastUsed: ago(0.2),
                     safety: .keep, note: DiskKind.agentData.rebuildHint),
        ]
        store.loadDemo(volume: DiskVolume(name: "Macintosh HD", total: 494 * gb, available: 38 * gb), items: items)
    }

    static func loadGitHub(into store: GitHubStore) {
        let now = Date()
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        let hour: TimeInterval = 3600, day: TimeInterval = 86_400
        let swift = GHLanguage(name: "Swift", color: "#F05138"), ts = GHLanguage(name: "TypeScript", color: "#3178c6")
        let go = GHLanguage(name: "Go", color: "#00ADD8"), py = GHLanguage(name: "Python", color: "#3572A5")
        let rust = GHLanguage(name: "Rust", color: "#dea584"), mdx = GHLanguage(name: "MDX", color: "#fcb32c")
        let repositories = [
            GHRepository(slug: "acme/aurora-api", description: "Multi-tenant search API with per-tenant caching and rate limits.",
                         isPrivate: true, stars: 48, forks: 6, openPulls: 3, openIssues: 11, pushedAt: ago(20 * 60), language: go),
            GHRepository(slug: "acme/pixel-garden", description: "A cozy pixel-art garden you grow from your commit history.",
                         stars: 1_284, forks: 97, openPulls: 1, openIssues: 23, pushedAt: ago(90 * 60), homepage: "https://pixel.garden", language: ts),
            GHRepository(slug: "acme/tidepool", description: "Tide station ingest and forecasting jobs.", isPrivate: true,
                         stars: 12, forks: 1, openPulls: 1, pushedAt: ago(3 * hour), language: py),
            GHRepository(slug: "acme/lumen-docs", description: "Documentation site for Lumen.", stars: 210, forks: 41,
                         openPulls: 2, openIssues: 4, pushedAt: ago(6 * hour), language: mdx),
            GHRepository(slug: "acme/orbit-cli", description: "Orbit from your terminal: deploys, logs and status.", stars: 3_920,
                         forks: 288, openPulls: 1, openIssues: 57, pushedAt: ago(29 * hour), language: rust),
            GHRepository(slug: "dev/lookout-notes", description: "Notes and sketches for menu bar apps.", stars: 3,
                         pushedAt: ago(4 * day), language: swift),
            GHRepository(slug: "dev/portfolio", description: nil, stars: 1, pushedAt: ago(34 * day), language: ts),
            GHRepository(slug: "dev/dotfiles", description: "zsh, git and editor config.", isFork: false, isArchived: true,
                         stars: 0, pushedAt: ago(400 * day), language: GHLanguage(name: "Shell", color: "#89e051")),
        ]
        let slug = "acme/aurora-api"
        func commit(_ oid: String, _ headline: String, _ author: String, _ s: TimeInterval, _ checks: CheckState = .success) -> GHCommit {
            GHCommit(oid: oid + String(repeating: "0", count: 40 - oid.count), headline: headline, date: ago(s), authorName: author,
                     authorLogin: author, checks: checks)
        }
        let mainCommits = [
            commit("a1b2c3d", "Cache search results per tenant", "dev", 5 * hour),
            commit("9f8e7d6", "Bump otel to 1.29", "renovate", 9 * hour),
            commit("4c4c4c4", "Document the /search pagination cursor", "sam", 26 * hour),
            commit("7a7a7a7", "Fix tenant id leaking into shared cache keys", "dev", 30 * hour, .failure),
            commit("3b3b3b3", "Add /healthz with build info", "rin", 3 * day),
            commit("1e1e1e1", "Split search handlers into their own package", "dev", 4 * day),
        ]
        let readme = """
        <h1>aurora-api</h1>
        <p>Multi-tenant search API. Every tenant gets its own cache namespace and rate limits, and every request is traced.</p>
        <h2>Running locally</h2>
        <pre><code>make dev        # api on :8080, redis on :6379
        make test       # unit + integration</code></pre>
        <h2>Layout</h2>
        <ul><li><code>search/</code> query parsing, ranking and pagination</li>
        <li><code>tenants/</code> tenant config and limits</li><li><code>cache/</code> per-tenant result cache</li></ul>
        <p>See <a href="https://github.com/acme/aurora-api/wiki">the wiki</a> for deployment notes.</p>
        """
        let detail = GHRepoDetail(
            description: repositories[0].description, homepage: "https://aurora.acme.dev", topics: ["search", "golang", "redis", "multi-tenant"],
            license: "MIT", languages: [GHLanguage(name: "Go", color: "#00ADD8", size: 812_000), GHLanguage(name: "Shell", color: "#89e051", size: 41_000),
                                        GHLanguage(name: "Dockerfile", color: "#384d54", size: 12_000), GHLanguage(name: "Makefile", color: "#427819", size: 6_000)],
            defaultBranch: "main", readmeHTML: readme, commits: mainCommits, defaultMergeMethod: .squash, watchers: 9)
        func branch(_ name: String, _ ahead: Int, _ behind: Int, _ c: GHCommit, pull: GHBranchPull? = nil, isDefault: Bool = false,
                    protected: Bool = false) -> GHBranch {
            GHBranch(name: name, ahead: ahead, behind: behind, isDefault: isDefault, isProtected: protected, commit: c, pull: pull)
        }
        let branches = [
            branch("main", 0, 0, mainCommits[0], isDefault: true, protected: true),
            branch("feat/search-rate-limit", 3, 2, commit("f00d001", "Token bucket per tenant", "dev", 4 * 60, .pending),
                   pull: GHBranchPull(number: 214, state: .open, title: "Add rate limiting to /search")),
            branch("deps/otel-1.30", 1, 0, commit("beef002", "Bump otel to 1.30", "renovate", 7 * hour),
                   pull: GHBranchPull(number: 216, state: .draft, title: "Bump otel to 1.30")),
            branch("feat/tenant-config", 8, 5, commit("c0de003", "Read tenant limits from Postgres", "sam", 50 * 60),
                   pull: GHBranchPull(number: 219, state: .open, title: "Move tenant config to Postgres")),
            branch("fix/cache-keys", 0, 4, commit("7a7a7a7", "Fix tenant id leaking into shared cache keys", "dev", 30 * hour),
                   pull: GHBranchPull(number: 209, state: .merged, title: "Fix tenant id leaking into cache keys")),
            branch("spike/redis-cluster", 12, 41, commit("5p1k3", "Try redis cluster mode", "dev", 40 * day)),
            branch("docs/pagination", 0, 9, commit("4c4c4c4", "Document the /search pagination cursor", "sam", 26 * hour),
                   pull: GHBranchPull(number: 211, state: .closed, title: "Pagination docs")),
        ]
        func summary(_ n: Int, _ title: String, _ state: GHPullState, _ author: String, _ head: String, _ created: TimeInterval,
                     _ updated: TimeInterval, comments: Int = 0, checks: CheckState = .success, review: ReviewState = .none) -> GHPullSummary {
            GHPullSummary(repo: slug, number: n, title: title, state: state, author: author, headRef: head, baseRef: "main",
                          createdAt: ago(created), updatedAt: ago(updated), comments: comments, checks: checks, review: review)
        }
        let open = [
            summary(219, "Move tenant config to Postgres", .open, "sam", "feat/tenant-config", 2 * day, 50 * 60, comments: 4, review: .required),
            summary(214, "Add rate limiting to /search", .open, "dev", "feat/search-rate-limit", 3 * day, 6 * 60, comments: 3,
                    checks: .pending, review: .approved),
            summary(216, "Bump otel to 1.30", .draft, "renovate", "deps/otel-1.30", 7 * hour, 7 * hour),
        ]
        let closed = [
            summary(209, "Fix tenant id leaking into cache keys", .merged, "dev", "fix/cache-keys", 3 * day, 30 * hour, comments: 2, review: .approved),
            summary(211, "Pagination docs", .closed, "sam", "docs/pagination", 6 * day, 2 * day, comments: 1),
            summary(204, "Split search handlers into their own package", .merged, "dev", "refactor/search-pkg", 8 * day, 4 * day, comments: 6, review: .approved),
        ]
        let prCommits = [
            commit("f00d0a1", "Add token bucket limiter", "dev", 3 * day),
            commit("f00d0a2", "Per-tenant limits from config", "dev", 2 * day),
            commit("f00d001", "Token bucket per tenant", "dev", 4 * 60, .pending),
        ]
        let pull = GHPullDetail(
            summary: open[1],
            bodyHTML: "<p>Adds a token-bucket rate limiter in front of <code>/search</code>, keyed by tenant.</p><ul><li>Limits come from tenant config (default 50 req/s, burst 100)</li><li>Over-limit requests get <code>429</code> with <code>Retry-After</code></li><li>Metrics: <code>search_ratelimited_total</code></li></ul><p>Closes #187.</p>",
            mergeable: true, mergeState: "BLOCKED", additions: 214, deletions: 37, changedFiles: 3, viewerCanUpdate: true, viewerDidAuthor: true,
            timeline: [
                GHTimelineItem(id: "c1", kind: .comment, author: "sam", bodyHTML: "<p>Should the burst be configurable per tenant too? Enterprise tenants spike at the top of the hour.</p>", date: ago(2 * day)),
                GHTimelineItem(id: "c2", kind: .comment, author: "dev", bodyHTML: "<p>Good call, added <code>burst</code> next to <code>rate</code> in the tenant config.</p>", date: ago(40 * hour)),
                GHTimelineItem(id: "r1", kind: .review("APPROVED"), author: "sam", bodyHTML: "<p>Looks great. Ship it once CI is green.</p>", date: ago(5 * hour)),
            ],
            reviewers: [GHReviewer(login: "sam", state: "APPROVED"), GHReviewer(login: "rin", state: nil)],
            assignees: ["dev"],
            labels: [GHLabel(name: "enhancement", color: "a2eeef"), GHLabel(name: "api", color: "0e8a16"), GHLabel(name: "needs-deploy-note", color: "fbca04")],
            commits: prCommits,
            checks: [
                GHCheck(name: "test", workflow: "CI", state: .success, detail: "Success", url: "https://github.com", duration: 192),
                GHCheck(name: "lint", workflow: "CI", state: .success, detail: "Success", url: "https://github.com", duration: 41),
                GHCheck(name: "integration", workflow: "CI", state: .pending, detail: "In progress", url: "https://github.com"),
                GHCheck(name: "codecov/patch", state: .success, detail: "92.31% of diff hit", url: "https://github.com"),
            ],
            defaultMergeMethod: .squash)
        let files = [
            GHFile(filename: "search/ratelimit.go", status: "added", additions: 96, deletions: 0, patch: """
            @@ -0,0 +1,14 @@
            +package search
            +
            +import "golang.org/x/time/rate"
            +
            +// Limiter hands out one token bucket per tenant.
            +type Limiter struct {
            +\tmu      sync.Mutex
            +\tbuckets map[string]*rate.Limiter
            +}
            +
            +func (l *Limiter) Allow(tenant string, cfg tenants.Limits) bool {
            +\treturn l.bucket(tenant, cfg).Allow()
            +}
            """),
            GHFile(filename: "search/handler.go", status: "modified", additions: 18, deletions: 7, patch: """
            @@ -41,9 +41,20 @@ func (h *Handler) Search(w http.ResponseWriter, r *http.Request) {
             \ttenant := tenants.FromContext(r.Context())
            -\tresults, err := h.engine.Query(r.Context(), q)
            -\tif err != nil {
            -\t\thttp.Error(w, err.Error(), 500)
            +\tif !h.limiter.Allow(tenant.ID, tenant.Limits) {
            +\t\tw.Header().Set("Retry-After", "1")
            +\t\thttp.Error(w, "rate limited", http.StatusTooManyRequests)
            +\t\tmetrics.RateLimited.WithLabelValues(tenant.ID).Inc()
            \t\treturn
            \t}
            +\tresults, err := h.engine.Query(r.Context(), q)
            """),
            GHFile(filename: "tenants/config.go", status: "modified", additions: 100, deletions: 30, patch: nil),
        ]
        store.loadDemo(repositories: repositories, details: [slug: detail], branches: [slug: branches],
                       openPulls: [slug: open], closedPulls: [slug: closed],
                       commits: [GitHubStore.commitsKey(slug, branch: "main"): mainCommits],
                       pulls: [pull], files: [GitHubStore.filesKey(slug, 214): files])
    }

    // MARK: - Audio

    static func loadAudio() {
        let artwork = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [.systemTeal, .systemIndigo, .systemPurple])?.draw(in: rect, angle: 45)
            return true
        }
        MediaController.shared.loadDemo(track: MediaController.Track(
            bundleID: "com.apple.Music", appName: "Music", title: "Low Tide Static", artist: "The Night Shift",
            album: "Ambient for Focus", duration: 247, position: 96, isPlaying: true, fetchedAt: .now), artwork: artwork)
        AppAudio.shared.loadDemo(
            apps: [
                .init(bundleID: "com.apple.Music", name: "Music", processObjects: [], bundleIDs: ["com.apple.Music"], isPlaying: true, pid: 701),
                .init(bundleID: "com.apple.Safari", name: "Safari", processObjects: [], bundleIDs: ["com.apple.Safari"], isPlaying: false, pid: 702),
            ],
            outputs: [
                .init(uid: "demo-builtin", name: "MacBook Pro Speakers", objectID: 0, transport: kAudioDeviceTransportTypeBuiltIn),
                .init(uid: "demo-headphones", name: "Studio Headphones", objectID: 0, transport: kAudioDeviceTransportTypeBluetooth),
            ],
            systemOutputUID: "demo-builtin")
    }
}
#endif
