import Foundation
import LocalObserverCore

/// lookout:// routing, the status the CLI prints, and where the CLI gets installed.
enum AutomationChecks {
    static func run() {
        checkRoutes()
        checkLauncherMatching()
        checkStatus()
        checkInstallLocation()
    }

    private static func route(_ string: String) -> LookoutRoute? { URL(string: string).flatMap(LookoutRoute.init(url:)) }

    private static func checkRoutes() {
        precondition(route("lookout://open/usage") == .open(.usage), "open/<page> should route to the page")
        precondition(route("lookout://open/PRs") == .open(.pulls), "Page slugs should accept aliases, any case")
        precondition(route("lookout://open/nowhere") == nil, "Unknown pages shouldn't route")
        precondition(route("lookout://palette") == .palette, "palette route failed")
        precondition(route("lookout://new-task") == .newTask && route("lookout://weekly-report") == .weeklyReport, "Sheet routes failed")
        precondition(route("lookout://launcher/web/start") == .launcher(name: "web", action: .start), "launcher start failed")
        precondition(route("lookout://launcher/My%20API/stop") == .launcher(name: "My API", action: .stop), "Launcher names should be decoded")
        precondition(route("lookout://launcher/api%2Fv2/toggle") == .launcher(name: "api/v2", action: .toggle), "An encoded slash belongs to the name")
        precondition(route("lookout://launcher/web/explode") == nil, "Unknown launcher actions shouldn't route")
        precondition(route("lookout://launcher") == .open(.launchers), "Bare launcher link should open the page")
        precondition(route("lookout://keep-awake") == .keepAwake(.toggle) && route("lookout://keep-awake/on") == .keepAwake(.on), "keep-awake failed")
        precondition(route("lookout://timer") == .timer(minutes: 25), "Timer should default to 25 minutes")
        precondition(route("lookout://timer/start/10") == .timer(minutes: 10) && route("lookout://timer?minutes=5") == .timer(minutes: 5), "Timer minutes failed")
        precondition(route("lookout://timer/stop") == .timer(minutes: nil), "Timer stop failed")
        precondition(route("lookout://timer/0") == nil && route("lookout://timer/abc") == nil, "Bad timer lengths shouldn't route")
        precondition(route("https://open/usage") == nil, "Other schemes must be ignored")
        // The widgets' links keep working.
        precondition(route("localobserver://limits") == .open(.limits), "Legacy page link failed")
        precondition(route("localobserver://activity") == .open(.sessions), "Legacy activity link failed")
        precondition(route("localobserver://session?id=abc-1") == .session(id: "abc-1"), "Legacy session link failed")
        precondition(route("LOOKOUT://usage") == .open(.usage), "Scheme should be case-insensitive")

        // Every route survives a round trip through its URL, which is how the CLI and intents send them.
        let all: [LookoutRoute] = LookoutPage.allCases.map { .open($0) } + [
            .session(id: "x y"), .launcher(name: "api/v2 #1?", action: .stop), .palette, .newTask, .weeklyReport, .peek,
            .keepAwake(.off), .timer(minutes: 90), .timer(minutes: nil), .refresh, .checkForUpdates
        ]
        for r in all { precondition(LookoutRoute(url: r.url) == r, "Round trip failed for \(r.url)") }
    }

    private static func checkLauncherMatching() {
        let names = ["Web", "web-admin", "API"]
        precondition(LookoutRoute.matchLauncher("web", names: names) == 0, "Exact name should win over a prefix")
        precondition(LookoutRoute.matchLauncher("ap", names: names) == 2, "A unique prefix should match")
        precondition(LookoutRoute.matchLauncher("w", names: names) == nil, "An ambiguous prefix shouldn't match")
        precondition(LookoutRoute.matchLauncher("  ", names: names) == nil, "Blank shouldn't match")
    }

    private static func checkStatus() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = { (id: String, used: Double) in
            WidgetSnapshot.Window(AgentQuotaWindow(id: id, agent: .claude, label: id, kind: .session, usedPercent: used,
                                                   resetsAt: now.addingTimeInterval(5400), windowDuration: 5 * 3600,
                                                   observedAt: now, source: "test", account: ""))
        }
        let snapshot = WidgetSnapshot(
            generatedAt: now.addingTimeInterval(-60),
            sessions: [
                .init(id: "a", agent: .claude, project: "shop", title: "Fix cart", model: "opus", state: .needsInput, startedAt: now, tokens: 10),
                .init(id: "b", agent: .codex, project: "api", title: "Tests", model: "gpt", state: .working, startedAt: now, tokens: nil)
            ],
            providers: [.init(agent: .claude, plan: "Max", windows: [window("5h", 30), window("week", 80)], headlineID: "5h")],
            glanceProviders: [],
            today: .empty,
            servers: [.init(port: 3000, name: "shop", url: "http://localhost:3000", symbol: "globe", health: .live, status: "Live", uptime: 61)]
        )
        let status = LookoutStatus(snapshot, now: now)
        precondition(!status.stale && LookoutStatus(snapshot, now: now.addingTimeInterval(3600)).stale, "Staleness failed")
        precondition(status.needingAttention.map(\.id) == ["a"], "Only sessions waiting on you need attention")
        precondition(status.remainingPercent(for: .claude) == 70, "Remaining should come from the headline window")
        precondition(status.remainingPercent(for: .cursor) == nil, "No limits means no answer, not zero")
        precondition(status.limits.filter(\.headline).count == 1, "Exactly one headline window per provider")
        precondition(status.servers.first?.uptimeSeconds == 61, "Server uptime failed")
        precondition(status.agentsText.contains("Claude Code") && status.serversText.contains(":3000"), "Text tables failed")
        precondition(LookoutStatus.table([["a", "bb", "c"], ["ccc", "d", "e"]]) == "a    bb  c\nccc  d   e", "Table alignment failed")

        let data = try? LookoutStatus.encoder.encode(status)
        let decoded = data.flatMap { try? JSONDecoder.iso8601.decode(LookoutStatus.self, from: $0) }
        precondition(decoded?.agents.count == 2 && decoded?.limits.count == 2, "Status JSON should round-trip")
    }

    private static func checkInstallLocation() {
        precondition(CLIInstallLocation.directory(home: "/Users/me") { $0 == "/usr/local/bin" } == "/usr/local/bin", "Writable /usr/local/bin should win")
        precondition(CLIInstallLocation.directory(home: "/Users/me") { _ in false } == "/Users/me/.local/bin", "Fallback should be ~/.local/bin")
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
