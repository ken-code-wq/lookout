#if DEBUG
import AppKit
import CoreAudio
import LocalObserverCore

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
        let sessions = runningSessions(now: now)
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
                    _ http: HttpState, title: String = "", latency: Int = 0, cpu: Double, mb: Int, uptime: TimeInterval) -> ServerEntry {
            let path = "\(root)/\(name)"
            return ServerEntry(pid: pid, pgid: pid, processName: process, command: command, port: port, bindAddress: "127.0.0.1",
                               workingDirectory: path, projectRoot: path, projectName: name, projectType: type,
                               httpState: http, statusCode: http == .online ? 200 : 0, latencyMs: latency, pageTitle: title,
                               cpu: cpu, rssKB: mb * 1024, uptime: uptime)
        }
        state.loadDemo(servers: [
            server(52_101, "aurora-api", "node", "node dist/server.js --port 3000", 3000, .node, .online,
                   title: "Aurora API", latency: 12, cpu: 3.4, mb: 182, uptime: 3 * 3600 + 1_240),
            server(52_244, "pixel-garden", "node", "node node_modules/.bin/vite --port 5173", 5173, .node, .online,
                   title: "Pixel Garden", latency: 8, cpu: 1.2, mb: 241, uptime: 52 * 60),
            server(52_390, "lumen-docs", "node", "node node_modules/.bin/astro dev --port 4321", 4321, .node, .online,
                   title: "Lumen Docs", latency: 21, cpu: 0.6, mb: 156, uptime: 6 * 3600),
            server(48_812, "tidepool", "python3", "python3 -m uvicorn tidepool.app:app --port 8000", 8000, .python, .online,
                   title: "Tidepool", latency: 15, cpu: 0.9, mb: 98, uptime: 26 * 3600),
            server(612, "postgres", "postgres", "postgres -D /usr/local/var/postgresql@16", 5432, .other, .offline,
                   cpu: 0.1, mb: 64, uptime: 4 * 86_400),
        ])
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
