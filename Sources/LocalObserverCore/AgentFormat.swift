import Foundation

public enum AgentFormat {
    public static let unavailable = "Unavailable"

    public static func tokens(_ value: Int64?) -> String {
        guard let value else { return unavailable }
        return compact(Double(value))
    }

    public static func compact(_ value: Double) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000_000 { return trim(value / 1_000_000_000, "B") }
        if absolute >= 1_000_000 { return trim(value / 1_000_000, "M") }
        if absolute >= 1_000 { return trim(value / 1_000, "K") }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    /// 1.62B, 26K, 4.72M: two decimals below 10, one below 100, none above.
    private static func trim(_ value: Double, _ suffix: String) -> String {
        let digits = abs(value) < 10 ? 2 : (abs(value) < 100 ? 1 : 0)
        return value.formatted(.number.precision(.fractionLength(0...digits))) + suffix
    }

    public static func cost(_ value: Double?, estimated: Bool = false) -> String {
        guard let value else { return unavailable }
        let text: String
        if value == 0 { text = "$0.00" }
        else if value < 0.01 { text = "<$0.01" }
        else { text = value.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
        return estimated ? "≈\(text)" : text
    }

    public static func metric(_ value: Double, _ metric: AgentMetricKind) -> String {
        switch metric {
        case .tokens: return compact(value)
        case .cost: return cost(value)
        case .requests: return compact(value)
        }
    }

    public static func percent(_ fraction: Double, digits: Int = 1) -> String {
        (fraction).formatted(.percent.precision(.fractionLength(0...digits)))
    }

    public static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60)m" }
        if s < 86_400 { return s % 3_600 >= 60 ? "\(s / 3_600)h \((s % 3_600) / 60)m" : "\(s / 3_600)h" }
        let days = s / 86_400
        let hours = (s % 86_400) / 3_600
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }

    /// "in 2h 14m", "tomorrow at 09:00", "Thu at 09:00".
    public static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        if seconds < 12 * 3_600 { return "in \(duration(seconds))" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        if seconds < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) at \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    public static func resetText(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Reset time unavailable" }
        if date <= now { return "Resetting now" }
        return "Resets \(relative(date, now: now))"
    }

    public static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < 10 { return "just now" }
        return "\(duration(s)) ago"
    }
}

/// How a window's usage compares with an even burn across the window.
public struct LimitPace {
    public enum Verdict { case unknown, comfortable, onPace, ahead, exhausted }

    public var verdict: Verdict
    public var elapsed: Double?
    /// When the window runs out at the current rate, if that happens before the reset.
    public var runsOutAt: Date?

    public init(window: AgentQuotaWindow, now: Date = .now) {
        elapsed = window.elapsedFraction(now: now)
        runsOutAt = nil
        let used = window.usedPercent / 100
        if used >= 1 {
            verdict = .exhausted
            return
        }
        guard let elapsed, elapsed > 0.02, let reset = window.resetsAt else {
            verdict = .unknown
            return
        }
        let elapsedSeconds = elapsed * (window.windowDuration ?? 0)
        if used > 0, elapsedSeconds > 0 {
            let rate = used / elapsedSeconds
            let outAt = now.addingTimeInterval((1 - used) / rate)
            if outAt < reset { runsOutAt = outAt }
        }
        if runsOutAt != nil {
            verdict = .ahead
        } else if used > elapsed - 0.05 {
            verdict = .onPace
        } else {
            verdict = .comfortable
        }
    }

    public var sentence: String {
        switch verdict {
        case .unknown: return ""
        case .exhausted: return "Limit reached"
        case .comfortable: return "Under pace"
        case .onPace: return "On pace"
        case .ahead:
            guard let runsOutAt else { return "Ahead of pace" }
            return "At this rate, runs out \(AgentFormat.relative(runsOutAt))"
        }
    }
}
