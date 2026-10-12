import Foundation

// Milestones: thresholds crossed once and kept with the moment the history shows they were crossed. Lookout records
// each the first time it sees it reached and never takes one back; the app celebrates the ones it hasn't acknowledged.
// Milestones found in history read at first run carry their real dates, long before Lookout noticed them.

public struct Milestone: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case tokens, sessions, streak, anniversary, firstAgent
    }

    public var id: String
    public var kind: Kind
    /// "1B tokens", "30-day streak", "First Codex session".
    public var title: String
    /// One line of copy: "A billion tokens processed."
    public var detail: String
    /// Tokens, sessions, streak days, or months since the first activity. Zero for first-agent milestones.
    public var threshold: Int64
    public var agent: AgentKind?

    public static let catalog: [Milestone] = {
        var all: [Milestone] = [
            Milestone(id: "tokens.1M", kind: .tokens, title: "1M tokens", detail: "A million tokens processed.", threshold: 1_000_000),
            Milestone(id: "tokens.10M", kind: .tokens, title: "10M tokens", detail: "Ten million tokens processed.", threshold: 10_000_000),
            Milestone(id: "tokens.100M", kind: .tokens, title: "100M tokens", detail: "A hundred million tokens processed.", threshold: 100_000_000),
            Milestone(id: "tokens.1B", kind: .tokens, title: "1B tokens", detail: "A billion tokens processed.", threshold: 1_000_000_000),
            Milestone(id: "tokens.10B", kind: .tokens, title: "10B tokens", detail: "Ten billion tokens processed.", threshold: 10_000_000_000),
            Milestone(id: "sessions.100", kind: .sessions, title: "100 sessions", detail: "A hundred agent sessions.", threshold: 100),
            Milestone(id: "sessions.1000", kind: .sessions, title: "1,000 sessions", detail: "A thousand agent sessions.", threshold: 1_000),
            Milestone(id: "sessions.10000", kind: .sessions, title: "10,000 sessions", detail: "Ten thousand agent sessions.", threshold: 10_000),
            Milestone(id: "streak.7", kind: .streak, title: "7-day streak", detail: "Agents at work seven days running.", threshold: 7),
            Milestone(id: "streak.30", kind: .streak, title: "30-day streak", detail: "Agents at work thirty days running.", threshold: 30),
            Milestone(id: "streak.100", kind: .streak, title: "100-day streak", detail: "Agents at work a hundred days running.", threshold: 100),
            Milestone(id: "anniversary.1m", kind: .anniversary, title: "One month", detail: "A month of agent history in Lookout.", threshold: 1),
            Milestone(id: "anniversary.6m", kind: .anniversary, title: "Six months", detail: "Half a year of agent history in Lookout.", threshold: 6),
            Milestone(id: "anniversary.1y", kind: .anniversary, title: "One year", detail: "A year of agent history in Lookout.", threshold: 12),
        ]
        all += AgentKind.allCases.map {
            Milestone(id: "first.\($0.rawValue)", kind: .firstAgent, title: "First \($0.name) session",
                      detail: "The first time Lookout saw \($0.name) at work.", threshold: 0, agent: $0)
        }
        return all
    }()

    public static func named(_ id: String) -> Milestone? { catalog.first { $0.id == id } }
}

public struct EarnedMilestone: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// When the history shows it was reached.
    public var earnedAt: Date
    /// When Lookout recorded it.
    public var recordedAt: Date

    public init(id: String, earnedAt: Date, recordedAt: Date) {
        self.id = id
        self.earnedAt = earnedAt
        self.recordedAt = recordedAt
    }

    public var milestone: Milestone? { Milestone.named(id) }
    /// Reached well before Lookout recorded it, i.e. found in history read at first run: worth listing, not a party.
    public var isRetroactive: Bool { recordedAt.timeIntervalSince(earnedAt) > 2 * 86_400 }
}

public extension UsageHistory {
    /// Whether an anniversary of the first activity has arrived and isn't recorded yet.
    func anniversaryDue(now: Date, calendar: Calendar = .current) -> Bool {
        guard let first = firstActivityAt else { return false }
        return Milestone.catalog.contains { milestone in
            guard milestone.kind == .anniversary, milestones[milestone.id] == nil,
                  let date = calendar.date(byAdding: .month, value: Int(milestone.threshold), to: first) else { return false }
            return date <= now
        }
    }

    /// Records every milestone reached and not yet recorded, dated when the history shows it was reached. Returns
    /// the new ones, earliest first. Recorded milestones are never revisited.
    @discardableResult
    mutating func updateMilestones(now: Date = .now, calendar: Calendar = .current) -> [EarnedMilestone] {
        guard milestones.count < Milestone.catalog.count else { return [] }
        let reached = includingPending(calendar: calendar).milestoneDates(now: now, calendar: calendar)
        var added: [EarnedMilestone] = []
        for milestone in Milestone.catalog where milestones[milestone.id] == nil {
            guard let date = reached[milestone.id] else { continue }
            let earned = EarnedMilestone(id: milestone.id, earnedAt: date, recordedAt: now)
            milestones[milestone.id] = earned
            added.append(earned)
        }
        return added.sorted { ($0.earnedAt, $0.id) < ($1.earnedAt, $1.id) }
    }

    /// Recorded milestones the app hasn't celebrated yet, earliest first.
    var unacknowledgedMilestones: [EarnedMilestone] {
        milestones.values.filter { !acknowledgedMilestones.contains($0.id) }.sorted { ($0.earnedAt, $0.id) < ($1.earnedAt, $1.id) }
    }

    /// Recorded milestones, earliest first.
    var earnedMilestones: [EarnedMilestone] {
        milestones.values.sorted { ($0.earnedAt, $0.id) < ($1.earnedAt, $1.id) }
    }

    mutating func acknowledgeMilestones<S: Sequence>(_ ids: S) where S.Element == String {
        acknowledgedMilestones.formUnion(ids.filter { milestones[$0] != nil })
    }

    /// When each reachable milestone was reached, from the history as it stands.
    private func milestoneDates(now: Date, calendar: Calendar) -> [String: Date] {
        var dates: [String: Date] = [:]
        let ordered = days.keys.sorted().compactMap { key in UsageHistory.date(forDayKey: key, calendar: calendar).map { (key, $0) } }

        // Tokens: the hour the running total crossed each threshold.
        var tokenTargets = Milestone.catalog.filter { $0.kind == .tokens }.sorted { $0.threshold < $1.threshold }
        var running: Int64 = 0
        outer: for (key, start) in ordered {
            guard let day = days[key] else { continue }
            var hours = [Int64](repeating: 0, count: 24)
            for bucket in day.buckets {
                for cell in bucket.hours where (0..<24).contains(cell.hour) { hours[cell.hour] += cell.tally.processed }
            }
            for hour in 0..<24 where hours[hour] > 0 {
                running += hours[hour]
                while let target = tokenTargets.first, running >= target.threshold {
                    dates[target.id] = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: start) ?? start
                    tokenTargets.removeFirst()
                }
                if tokenTargets.isEmpty { break outer }
            }
        }

        // Sessions: when the nth session began.
        let starts = sessions.values.filter { $0.tally.events > 0 }.map(\.firstAt).sorted()
        for milestone in Milestone.catalog where milestone.kind == .sessions && starts.count >= Int(milestone.threshold) {
            dates[milestone.id] = starts[Int(milestone.threshold) - 1]
        }

        // Streaks: the day a run of consecutive active days reached each length.
        var run = 0
        var previous: Date?
        for (key, start) in ordered where (days[key]?.tally.events ?? 0) > 0 {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous), calendar.isDate(next, inSameDayAs: start) {
                run += 1
            } else {
                run = 1
            }
            previous = start
            for milestone in Milestone.catalog where milestone.kind == .streak && run == Int(milestone.threshold) && dates[milestone.id] == nil {
                dates[milestone.id] = start
            }
        }

        // Anniversaries of the first activity, once they've arrived.
        if let first = firstActivityAt {
            for milestone in Milestone.catalog where milestone.kind == .anniversary {
                if let date = calendar.date(byAdding: .month, value: Int(milestone.threshold), to: first), date <= now {
                    dates[milestone.id] = date
                }
            }
        }

        // Each agent's first session.
        for session in sessions.values where session.tally.events > 0 {
            let id = "first.\(session.agent.rawValue)"
            dates[id] = min(dates[id] ?? session.firstAt, session.firstAt)
        }
        return dates
    }
}
