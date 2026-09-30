import Foundation
import LocalObserverCore

extension WidgetSnapshot {
    /// Believable data for the widget gallery before the app has written a snapshot, and for debug renders.
    public static func sample(now: Date = .now) -> WidgetSnapshot {
        func window(_ agent: AgentKind, _ id: String, _ label: String, _ kind: AgentLimitKind, _ used: Double,
                    resetIn: TimeInterval, duration: TimeInterval) -> Window {
            Window(AgentQuotaWindow(id: "\(agent.rawValue)-\(id)", agent: agent, label: label, kind: kind, usedPercent: used,
                                    resetsAt: now.addingTimeInterval(resetIn), windowDuration: duration,
                                    observedAt: now, source: "sample", account: ""))
        }
        let hour: TimeInterval = 3_600
        let providers = [
            Provider(agent: .claude, plan: "Max", windows: [
                window(.claude, "session", "5-hour", .session, 71, resetIn: 1.6 * hour, duration: 5 * hour),
                window(.claude, "weekly", "Weekly", .weekly, 38, resetIn: 3.2 * 24 * hour, duration: 7 * 24 * hour),
                window(.claude, "opus", "Weekly Opus", .weeklyModel, 54, resetIn: 3.2 * 24 * hour, duration: 7 * 24 * hour)
            ], headlineID: "claude-session"),
            Provider(agent: .codex, plan: "Pro", windows: [
                window(.codex, "session", "5-hour", .session, 22, resetIn: 3.1 * hour, duration: 5 * hour),
                window(.codex, "weekly", "Weekly", .weekly, 47, resetIn: 5 * 24 * hour, duration: 7 * 24 * hour)
            ], headlineID: "codex-session"),
            Provider(agent: .copilot, plan: "Pro+", windows: [
                window(.copilot, "monthly", "Premium requests", .monthly, 63, resetIn: 11 * 24 * hour, duration: 30 * 24 * hour)
            ], headlineID: nil)
        ]
        let sessions = [
            Session(id: "s1", agent: .claude, project: "local-observer", title: "Add desktop widgets", model: "claude-opus-4-5",
                    state: .needsInput, startedAt: now.addingTimeInterval(-42 * 60), tokens: 1_840_000),
            Session(id: "s2", agent: .codex, project: "ledger-api", title: "Fix flaky settlement test", model: "gpt-5-codex",
                    state: .working, startedAt: now.addingTimeInterval(-18 * 60), tokens: 610_000),
            Session(id: "s3", agent: .claude, project: "marketing-site", title: "Tighten hero copy", model: "claude-sonnet-4-5",
                    state: .waiting, startedAt: now.addingTimeInterval(-2.4 * hour), tokens: 380_000),
            Session(id: "s4", agent: .openCode, project: "infra", title: "Terraform plan review", model: "kimi-k2",
                    state: .idle, startedAt: now.addingTimeInterval(-5 * hour), tokens: 90_000)
        ]
        // A working day: quiet overnight, busy late morning and afternoon.
        let shape: [Double] = [0, 0, 0, 0, 0, 0, 0, 0.1, 0.3, 0.8, 1, 0.7, 0.4, 0.6, 0.9, 1, 0.8, 0.5, 0.3, 0.2, 0.4, 0.6, 0.3, 0.1]
        let start = Calendar.current.dateInterval(of: .hour, for: now.addingTimeInterval(-23 * hour))?.start ?? now
        var hourly: [Bucket] = []
        for (index, weight) in shape.enumerated() {
            let date = start.addingTimeInterval(Double(index) * hour)
            hourly.append(Bucket(date: date, agent: .claude, value: weight * 310_000))
            hourly.append(Bucket(date: date, agent: .codex, value: weight * (index % 3 == 0 ? 160_000 : 60_000)))
        }
        let today = Usage(processed: 4_720_000, cost: 18.42, costIsEstimated: true, sessions: 9, cacheHitRate: 0.82,
                          hourly: hourly, models: [
                              Model(title: "claude-opus-4-5", agent: .claude, tokens: 2_910_000, cost: 12.80, share: 0.62),
                              Model(title: "gpt-5-codex", agent: .codex, tokens: 1_040_000, cost: 3.10, share: 0.22),
                              Model(title: "claude-sonnet-4-5", agent: .claude, tokens: 640_000, cost: 2.36, share: 0.13),
                              Model(title: "kimi-k2", agent: .openCode, tokens: 130_000, cost: 0.16, share: 0.03)
                          ])
        let servers = [
            Server(port: 3000, name: "marketing-site", url: "http://localhost:3000", symbol: "hexagon", health: .live, status: "Live · 14ms", uptime: 3.2 * hour),
            Server(port: 5173, name: "dashboard", url: "http://localhost:5173", symbol: "hexagon", health: .live, status: "Live · 6ms", uptime: 1.1 * hour),
            Server(port: 8000, name: "ledger-api", url: "http://localhost:8000", symbol: "chevron.left.forwardslash.chevron.right", health: .failing, status: "500", uptime: 26 * 60),
            Server(port: 5432, name: "postgres", url: "http://localhost:5432", symbol: "shippingbox", health: .quiet, status: "TCP only", uptime: 2 * 24 * hour),
            Server(port: 6379, name: "redis", url: "http://localhost:6379", symbol: "shippingbox", health: .quiet, status: "TCP only", uptime: 2 * 24 * hour)
        ]
        return WidgetSnapshot(generatedAt: now, sessions: sessions, providers: providers, glanceProviders: [.claude, .codex],
                              today: today, servers: servers)
    }
}
