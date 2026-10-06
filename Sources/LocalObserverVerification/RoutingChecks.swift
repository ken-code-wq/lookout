import Foundation
import LocalObserverCore

/// Limit routing: switch when one provider runs short and another has room, forecast with one provider,
/// stay quiet when all is well, and never act on stale or missing limits.
enum RoutingChecks {
    static func run() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        checkSwitch(now)
        checkAllClear(now)
        checkSingleProvider(now)
        checkStale(now)
        checkAllTight(now)
        checkAlerts(now)
    }

    private static let hour: TimeInterval = 3_600
    private static let day: TimeInterval = 86_400

    private static func window(_ agent: AgentKind, _ id: String, _ label: String, _ kind: AgentLimitKind, _ used: Double,
                               resetsIn: TimeInterval?, duration: TimeInterval?, observed: Date) -> AgentQuotaWindow {
        AgentQuotaWindow(id: "\(agent.rawValue)-\(id)", agent: agent, label: label, kind: kind, usedPercent: used,
                         resetsAt: resetsIn.map { observed.addingTimeInterval($0) }, windowDuration: duration,
                         observedAt: observed, source: "test", account: "")
    }

    private static func claude(_ session: Double, resetsIn: TimeInterval = 0.8 * hour, now: Date, observed: Date? = nil) -> AgentLimitReport {
        let at = observed ?? now
        return AgentLimitReport(agent: .claude, status: .connected, windows: [
            window(.claude, "session", "5-hour session", .session, session, resetsIn: resetsIn + now.timeIntervalSince(at), duration: 5 * hour, observed: at),
            window(.claude, "weekly", "Weekly · all models", .weekly, 30, resetsIn: 3 * day, duration: 7 * day, observed: at),
            // Model-scoped and pay-as-you-go windows don't decide routing.
            window(.claude, "weekly-opus", "Weekly · Opus", .weeklyModel, 99, resetsIn: 3 * day, duration: 7 * day, observed: at),
            window(.claude, "extra-usage", "Extra usage", .monthly, 100, resetsIn: nil, duration: nil, observed: at),
        ], fetchedAt: at)
    }

    private static func codex(_ weekly: Double, now: Date, observed: Date? = nil) -> AgentLimitReport {
        let at = observed ?? now
        return AgentLimitReport(agent: .codex, status: .connected, windows: [
            window(.codex, "session", "5-hour", .session, 5, resetsIn: 4 * hour, duration: 5 * hour, observed: at),
            window(.codex, "weekly", "Weekly", .weekly, weekly, resetsIn: 5 * day, duration: 7 * day, observed: at),
        ], fetchedAt: at)
    }

    private static func checkSwitch(_ now: Date) {
        // 92% with 84% of the window gone: runs out in ~22 minutes, before the reset in 48.
        let advice = LimitRouting.advice(reports: [claude(92, now: now), codex(10, now: now)], now: now)
        precondition(advice.kind == .switchProvider, "Routing should switch, got \(advice.kind)")
        precondition(advice.constrained == .claude && advice.recommended == .codex, "Routing picked the wrong providers")
        precondition(advice.headline == "Use Codex for the next 48m", "Routing headline: \(advice.headline)")
        precondition(advice.detail.hasPrefix("Claude 5-hour session 92% used, resets in 48m · Codex weekly 10% used"),
                     "Routing detail: \(advice.detail)")
        precondition(advice.runsOutAt != nil && advice.until == now.addingTimeInterval(0.8 * hour), "Routing should carry the run-out and reset")
        precondition(advice.isActionable, "A switch is worth surfacing")

        // The roomiest alternative wins, and a provider that's also running high isn't one.
        let copilot = AgentLimitReport(agent: .copilot, status: .connected, windows: [
            window(.copilot, "premium", "Premium requests", .monthly, 85, resetsIn: 12 * day, duration: 30 * day, observed: now),
        ], fetchedAt: now)
        let picked = LimitRouting.advice(reports: [claude(92, now: now), copilot, codex(40, now: now)], now: now)
        precondition(picked.recommended == .codex, "Routing should skip a provider that's itself above 80% (got \(String(describing: picked.recommended)))")
    }

    private static func checkAllClear(_ now: Date) {
        let advice = LimitRouting.advice(reports: [claude(40, now: now), codex(10, now: now)], now: now)
        precondition(advice.kind == .allClear && !advice.isActionable, "Healthy limits should be all clear, got \(advice.kind)")
        // 85% but burning slower than the window lasts: not a reason to switch.
        let steady = LimitRouting.advice(reports: [claude(85, resetsIn: 0.2 * hour, now: now), codex(10, now: now)], now: now)
        precondition(steady.kind == .allClear, "A high window on pace to last shouldn't route, got \(steady.kind)")
        // Providers without limits of their own (or not connected) are ignored rather than counted as healthy.
        let none = LimitRouting.advice(reports: [AgentLimitReport(agent: .openCode, status: .unsupported)], now: now)
        precondition(none.kind == .noData, "No windows means no data, got \(none.kind)")
    }

    private static func checkSingleProvider(_ now: Date) {
        let hot = LimitRouting.advice(reports: [claude(92, now: now)], now: now)
        precondition(hot.kind == .forecast && hot.recommended == nil, "One provider should forecast, never route")
        precondition(hot.headline.hasPrefix("At this pace, Claude 5-hour session runs out in "), "Forecast headline: \(hot.headline)")
        precondition(hot.severity == .critical && hot.runsOutAt != nil, "A forecast to run out above 80% is critical")

        let fine = LimitRouting.advice(reports: [claude(30, now: now)], now: now)
        precondition(fine.kind == .forecast && fine.severity == .calm && fine.runsOutAt == nil, "A comfortable single provider is a calm forecast")
        precondition(fine.headline == "At this pace, Claude lasts until its weekly resets"
                     || fine.headline == "At this pace, Claude lasts until its 5-hour session resets", "Calm forecast headline: \(fine.headline)")

        let done = LimitRouting.advice(reports: [claude(100, now: now)], now: now)
        precondition(done.kind == .forecast && done.headline == "Claude 5-hour session is used up", "Used-up forecast: \(done.headline)")
    }

    private static func checkStale(_ now: Date) {
        // Both read three hours ago: say so, recommend nothing.
        let old = now.addingTimeInterval(-3 * hour)
        let stale = LimitRouting.advice(reports: [claude(92, now: now, observed: old), codex(10, now: now, observed: old)], now: now)
        precondition(stale.kind == .stale && stale.recommended == nil && stale.staleAgents == [.claude, .codex], "Stale limits must not route")

        // A stale alternative isn't one: Claude is short, but Codex's 10% is too old to trust, so forecast only.
        let half = LimitRouting.advice(reports: [claude(92, now: now), codex(10, now: now, observed: old)], now: now)
        precondition(half.kind == .forecast && half.recommended == nil && half.staleAgents == [.codex],
                     "A stale provider can't be recommended, got \(half.kind)")
        precondition(half.detail.contains("Codex not considered"), "Stale providers should be named: \(half.detail)")

        // Fresh read, but every gating window's reset has passed: last cycle's numbers, so unknown now.
        let lapsed = AgentLimitReport(agent: .codex, status: .local, windows: [
            window(.codex, "weekly", "Weekly", .weekly, 97, resetsIn: -hour, duration: 7 * day, observed: now),
        ], fetchedAt: now)
        let advice = LimitRouting.advice(reports: [lapsed], now: now)
        precondition(advice.kind == .stale, "A window past its reset is unknown, not 97%")
    }

    private static func checkAllTight(_ now: Date) {
        let advice = LimitRouting.advice(reports: [claude(95, now: now), codex(96, now: now)], now: now)
        precondition(advice.kind == .allTight && advice.recommended == nil && advice.severity == .critical, "Everything tight: nothing to switch to")
        precondition(advice.detail.contains("Claude is back first"), "All-tight should say what resets first: \(advice.detail)")
    }

    private static func checkAlerts(_ now: Date) {
        let reports = [claude(92, now: now), codex(10, now: now)]
        let alerts = LimitRouting.alerts(reports: reports, now: now)
        precondition(alerts.count == 1 && alerts[0].window.id == "claude-session", "One window crossed 80% at a burning pace")
        precondition(alerts[0].body.contains("Codex has room") && alerts[0].body.contains("for the next 48m"), "Alert should carry the route: \(alerts[0].body)")
        // Same cycle, a read later with a jittered reset time: same id, so it isn't sent twice.
        var jittered = reports
        jittered[0].windows[0].resetsAt = jittered[0].windows[0].resetsAt?.addingTimeInterval(0.4)
        precondition(LimitRouting.alerts(reports: jittered, now: now).first?.id == alerts[0].id, "Alert ids should survive reset jitter")
        // On pace (even at 85%) or stale: no alert.
        precondition(LimitRouting.alerts(reports: [claude(85, resetsIn: 0.2 * hour, now: now)], now: now).isEmpty, "On-pace windows don't alert")
        precondition(LimitRouting.alerts(reports: [claude(92, now: now, observed: now.addingTimeInterval(-3 * hour))], now: now).isEmpty,
                     "Stale windows don't alert")
    }
}
