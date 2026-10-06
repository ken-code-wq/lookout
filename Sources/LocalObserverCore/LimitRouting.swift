import Foundation

// Smart limit routing: from every provider's plan windows, which agent to reach for right now and why.
// Pure; the app shows the advice on the Plan limits page, in the notch, in the digest, and as a notification.

/// What the routing engine recommends, with the numbers behind it.
public struct LimitAdvice: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Every provider with fresh data has room before its next reset.
        case allClear
        /// One provider is close to a limit and another has room: use that one until the reset.
        case switchProvider
        /// Only one provider reports fresh limits: when it runs out at the current pace, if it does.
        case forecast
        /// Every provider with fresh data is close to a limit; nothing to switch to.
        case allTight
        /// Limits exist but none were read recently enough to act on.
        case stale
        /// No provider reports limits.
        case noData
    }

    public enum Severity: Int, Comparable, Hashable, Sendable {
        case calm, warning, critical
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind
    public var severity: Severity
    /// The operational answer, e.g. "Use Codex for the next 48m".
    public var headline: String
    /// The numbers behind it, e.g. "Claude 5-hour session 92% used, resets in 48m · Codex weekly 10% used".
    public var detail: String
    /// The provider that's running short, and the window doing it.
    public var constrained: AgentKind?
    public var window: AgentQuotaWindow?
    /// The provider to use instead.
    public var recommended: AgentKind?
    /// When the constraining window resets: how long the recommendation holds.
    public var until: Date?
    /// When the constraining window runs dry at the current pace, if that's before its reset.
    public var runsOutAt: Date?
    /// Providers whose limits were left out because they're too old to trust.
    public var staleAgents: [AgentKind]

    public init(kind: Kind, severity: Severity, headline: String, detail: String, constrained: AgentKind? = nil,
                window: AgentQuotaWindow? = nil, recommended: AgentKind? = nil, until: Date? = nil, runsOutAt: Date? = nil,
                staleAgents: [AgentKind] = []) {
        self.kind = kind
        self.severity = severity
        self.headline = headline
        self.detail = detail
        self.constrained = constrained
        self.window = window
        self.recommended = recommended
        self.until = until
        self.runsOutAt = runsOutAt
        self.staleAgents = staleAgents
    }

    /// Worth interrupting for: a switch, a provider about to run out, or everything tight.
    public var isActionable: Bool { severity > .calm }
}

/// One window that just crossed the alert line at a pace that empties it before the reset.
public struct LimitRouteAlert: Hashable, Sendable {
    /// Stable per window and reset, so the same window alerts once per cycle.
    public var id: String
    public var window: AgentQuotaWindow
    public var runsOutAt: Date
    public var title: String
    public var body: String
}

public enum LimitRouting {
    /// A window at or past this share is "running high".
    public static let highPercent: Double = 80
    /// At or past this, a window is tight even when the pace says it will last.
    public static let criticalPercent: Double = 90
    /// Limits older than this aren't acted on. Live clients refresh every few minutes, so an hour means something's wrong.
    public static let staleAfter: TimeInterval = 3_600

    /// Windows that actually stop work when used up: the rolling session, weekly, daily and monthly caps with a reset.
    /// Model-scoped windows (Opus weekly) leave other models usable, and pay-as-you-go extras have no reset.
    public static func isGating(_ window: AgentQuotaWindow) -> Bool {
        guard window.resetsAt != nil else { return false }
        switch window.kind {
        case .session, .weekly, .daily, .monthly: return true
        case .weeklyModel, .model, .other: return false
        }
    }

    /// How one provider stands: its gating windows (fresh only), the one closest to stopping it, and when it was read.
    struct Standing {
        var agent: AgentKind
        var windows: [AgentQuotaWindow]
        var observedAt: Date
        var worst: AgentQuotaWindow
        var pace: LimitPace
        var now: Date

        /// Any gating window used up, past the critical line, or past the high line and burning faster than it lasts.
        var isConstrained: Bool {
            windows.contains { window in
                let verdict = LimitPace(window: window, now: now).verdict
                return verdict == .exhausted || window.usedPercent >= LimitRouting.criticalPercent
                    || (window.usedPercent >= LimitRouting.highPercent && verdict == .ahead)
            }
        }

        /// Lower is roomier: the fullest gating window.
        var load: Double { windows.map(\.usedPercent).max() ?? 0 }
    }

    /// Splits reports into providers with fresh gating windows and providers whose data is too old (or past its reset).
    static func standings(_ reports: [AgentLimitReport], now: Date, staleAfter: TimeInterval) -> (fresh: [Standing], stale: [AgentKind]) {
        var fresh: [Standing] = []
        var stale: [AgentKind] = []
        for report in reports {
            let gating = report.windows.filter(isGating)
            guard !gating.isEmpty else { continue }
            let observed = gating.map(\.observedAt).max() ?? report.fetchedAt ?? .distantPast
            // A window whose reset has passed holds last cycle's number; what it is now is unknown.
            let current = gating.filter { ($0.resetsAt ?? .distantFuture) > now }
            guard now.timeIntervalSince(observed) <= staleAfter, !current.isEmpty else {
                stale.append(report.agent)
                continue
            }
            let worst = current.max { urgency($0, now: now) < urgency($1, now: now) } ?? current[0]
            fresh.append(Standing(agent: report.agent, windows: current, observedAt: observed, worst: worst,
                                  pace: LimitPace(window: worst, now: now), now: now))
        }
        return (fresh, stale)
    }

    /// Orders windows by how soon they stop you: used up first, then the earliest run-out, then the fullest.
    static func urgency(_ window: AgentQuotaWindow, now: Date) -> Double {
        let pace = LimitPace(window: window, now: now)
        if pace.verdict == .exhausted { return 1_000_000 }
        if let out = pace.runsOutAt { return 10_000 + 1_000_000 / max(out.timeIntervalSince(now), 60) }
        return window.usedPercent
    }

    /// The recommendation for right now.
    public static func advice(reports: [AgentLimitReport], now: Date = .now, staleAfter: TimeInterval = staleAfter) -> LimitAdvice {
        let (fresh, stale) = standings(reports, now: now, staleAfter: staleAfter)
        let staleNote = stale.isEmpty ? nil
            : "\(names(stale)) not considered: \(stale.count == 1 ? "its" : "their") limits haven't been read in over \(AgentFormat.duration(staleAfter))"

        guard !fresh.isEmpty else {
            if stale.isEmpty {
                return LimitAdvice(kind: .noData, severity: .calm, headline: "No plan limits to compare",
                                   detail: "Connect a provider's plan limits to get a recommendation.")
            }
            return LimitAdvice(kind: .stale, severity: .calm, headline: "Limits are out of date",
                               detail: "\(names(stale)) limits haven't been read in over \(AgentFormat.duration(staleAfter)). Refresh before relying on them.",
                               staleAgents: stale)
        }

        let constrained = fresh.filter(\.isConstrained).sorted { urgency($0.worst, now: now) > urgency($1.worst, now: now) }

        if fresh.count == 1, let only = fresh.first {
            return forecast(only, now: now, staleNote: staleNote, stale: stale)
        }

        guard let tight = constrained.first else {
            return LimitAdvice(kind: .allClear, severity: .calm, headline: "All clear",
                               detail: join(["Every connected provider has room before its next reset", staleNote]),
                               staleAgents: stale)
        }

        let room = fresh.filter { !$0.isConstrained }.sorted { $0.load < $1.load }
        let reset = tight.worst.resetsAt
        let tightPhrase = describe(tight.worst, pace: tight.pace, now: now, withReset: true)
        guard let best = room.first else {
            let firstBack = constrained.min { ($0.worst.resetsAt ?? .distantFuture) < ($1.worst.resetsAt ?? .distantFuture) }
            let back = firstBack.flatMap { s in s.worst.resetsAt.map { "\(shortName(s.agent)) is back first, \(AgentFormat.relative($0, now: now))" } }
            return LimitAdvice(kind: .allTight, severity: .critical, headline: "Every connected provider is close to its limit",
                               detail: join([constrained.map { describe($0.worst, pace: $0.pace, now: now, withReset: false) }.joined(separator: " · "), back, staleNote]),
                               constrained: tight.agent, window: tight.worst, until: firstBack?.worst.resetsAt,
                               runsOutAt: tight.pace.runsOutAt, staleAgents: stale)
        }
        let roomPhrase = "\(shortName(best.agent)) \(windowName(best.worst)) \(percent(best.worst.usedPercent)) used"
        return LimitAdvice(kind: .switchProvider, severity: tight.pace.verdict == .exhausted ? .critical : .warning,
                           headline: "Use \(shortName(best.agent)) \(holdPhrase(reset, now: now))",
                           detail: join(["\(tightPhrase) · \(roomPhrase)", staleNote]),
                           constrained: tight.agent, window: tight.worst, recommended: best.agent, until: reset,
                           runsOutAt: tight.pace.runsOutAt, staleAgents: stale)
    }

    /// One provider: when it runs out at this pace, or that it lasts until the reset.
    private static func forecast(_ only: Standing, now: Date, staleNote: String?, stale: [AgentKind]) -> LimitAdvice {
        let name = shortName(only.agent)
        let window = only.worst
        let label = windowName(window)
        let used = "\(percent(window.usedPercent)) used"
        let reset = AgentFormat.resetText(window.resetsAt, now: now).lowercased()
        let headline: String
        let severity: LimitAdvice.Severity
        switch only.pace.verdict {
        case .exhausted:
            headline = "\(name) \(label) is used up"
            severity = .critical
        case .ahead:
            let out = only.pace.runsOutAt.map { AgentFormat.relative($0, now: now) } ?? "before the reset"
            headline = "At this pace, \(name) \(label) runs out \(out)"
            severity = window.usedPercent >= highPercent ? .critical : .warning
        case .onPace, .comfortable, .unknown:
            headline = only.pace.verdict == .unknown ? "\(name) \(label) \(used)" : "At this pace, \(name) lasts until its \(label) resets"
            severity = only.isConstrained ? .warning : .calm
        }
        return LimitAdvice(kind: .forecast, severity: severity, headline: headline,
                           detail: join(["\(used), \(reset)", staleNote]),
                           constrained: severity > .calm ? only.agent : nil, window: window, until: window.resetsAt,
                           runsOutAt: only.pace.runsOutAt, staleAgents: stale)
    }

    /// Windows that should alert now: fresh, gating, at or past `threshold`, and on course to run dry before they reset.
    /// Each carries the routing suggestion, when there is one.
    public static func alerts(reports: [AgentLimitReport], now: Date = .now, threshold: Double = highPercent,
                              staleAfter: TimeInterval = staleAfter) -> [LimitRouteAlert] {
        let (fresh, _) = standings(reports, now: now, staleAfter: staleAfter)
        let advice = advice(reports: reports, now: now, staleAfter: staleAfter)
        var alerts: [LimitRouteAlert] = []
        for standing in fresh {
            for window in standing.windows where window.usedPercent >= threshold {
                let pace = LimitPace(window: window, now: now)
                guard pace.verdict == .ahead, let out = pace.runsOutAt, let reset = window.resetsAt else { continue }
                // Reset times jitter by fractions of a second between reads; a minute is the same cycle.
                let id = "route-\(window.id)-\(Int(reset.timeIntervalSince1970 / 60))"
                let name = shortName(window.agent)
                let title = "\(name) \(windowName(window)) at \(percent(window.usedPercent)), runs out \(AgentFormat.relative(out, now: now))"
                var body = "At this pace it runs dry before it \(AgentFormat.resetText(reset, now: now).lowercased())."
                if advice.kind == .switchProvider, advice.constrained == window.agent, let to = advice.recommended,
                   let alt = fresh.first(where: { $0.agent == to }) {
                    body += " \(shortName(to)) has room (\(windowName(alt.worst)) \(percent(alt.worst.usedPercent)) used): use it \(holdPhrase(reset, now: now))."
                }
                alerts.append(LimitRouteAlert(id: id, window: window, runsOutAt: out, title: title, body: body))
            }
        }
        return alerts
    }

    // MARK: Wording

    /// "Claude 5-hour session 92% used, resets in 48m" or "…, runs out in 22m".
    static func describe(_ window: AgentQuotaWindow, pace: LimitPace, now: Date, withReset: Bool) -> String {
        var text = "\(shortName(window.agent)) \(windowName(window)) \(percent(window.usedPercent)) used"
        if withReset { text += ", " + AgentFormat.resetText(window.resetsAt, now: now).lowercased() }
        else if let out = pace.runsOutAt { text += ", runs out \(AgentFormat.relative(out, now: now))" }
        return text
    }

    /// "for the next 48m" within the day, "until Thu at 09:00" beyond it.
    static func holdPhrase(_ reset: Date?, now: Date) -> String {
        guard let reset, reset > now else { return "for now" }
        let seconds = reset.timeIntervalSince(now)
        return seconds < 12 * 3_600 ? "for the next \(AgentFormat.duration(seconds))" : "until \(AgentFormat.relative(reset, now: now))"
    }

    /// "Weekly · all models" reads as "weekly" in a sentence; other labels keep their words with a lowercase lead.
    static func windowName(_ window: AgentQuotaWindow) -> String {
        switch window.kind {
        case .weekly where window.label.hasPrefix("Weekly"): return "weekly"
        case .daily where window.label.hasPrefix("Daily"): return "daily"
        case .monthly where window.label == "Monthly": return "monthly"
        default:
            guard let first = window.label.first, first.isUppercase,
                  let word = window.label.split(separator: " ").first,
                  ["Weekly", "Monthly", "Daily", "Premium"].contains(String(word)) else { return window.label }
            return first.lowercased() + window.label.dropFirst()
        }
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// The name people say: "Claude", "Copilot", "Codex".
    public static func shortName(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude"
        case .copilot: return "Copilot"
        default: return agent.name
        }
    }

    static func names(_ agents: [AgentKind]) -> String {
        ListFormatter.localizedString(byJoining: agents.map(shortName))
    }

    private static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}
