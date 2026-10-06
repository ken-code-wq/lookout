import Foundation

// The weekly report: one calendar week of agent usage from the ledger, by agent, model and project, with active agent
// time, active days and the streak, plus GitHub numbers when the app has them. Pure; the app renders and shares it.

/// Pull requests you opened and merged in a week, from GitHub.
public struct WeeklyPulls: Hashable, Sendable {
    public var opened: Int
    public var merged: Int

    public init(opened: Int, merged: Int) {
        self.opened = opened
        self.merged = merged
    }
}

public struct WeeklyReport: Hashable, Sendable {
    public struct Row: Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        /// Set for agent rows, and for model rows used by a single agent.
        public var agent: AgentKind?
        public var processed: Int64
        public var cost: Double
        public var costIsEstimated: Bool
        /// Share of the week's tokens, 0...1.
        public var share: Double
    }

    public struct Day: Identifiable, Hashable, Sendable {
        public var id: Date { date }
        public var date: Date
        public var processed: Int64 = 0
        public var cost: Double = 0
        public var activeSeconds: TimeInterval = 0
        /// GitHub contributions that day, when the graph covers it.
        public var contributions: Int?
        /// After `through`: not happened yet in a partial week.
        public var isFuture = false
    }

    /// The whole calendar week, `start` on the calendar's first weekday.
    public var week: DateInterval
    /// What the numbers cover: the whole week, or up to now in the current one.
    public var through: Date
    public var totals = AgentUsageTotals()
    public var byAgent: [Row] = []
    public var byModel: [Row] = []
    public var byProject: [Row] = []
    /// Seven days, first weekday first.
    public var days: [Day] = []
    /// Wall-clock time with at least one agent at work. See `activeSpans`.
    public var activeSeconds: TimeInterval = 0
    public var activeDays = 0
    /// Consecutive active days ending at the last covered day (today may still be empty), counting back past the week.
    public var streak = 0
    /// Sum of GitHub contributions in the covered days; nil unless the graph covers every one of them.
    public var contributions: Int?
    public var pulls: WeeklyPulls?

    public var isPartial: Bool { through < week.end }
    public var isEmpty: Bool { totals.events == 0 }
    /// Days of the week the numbers cover so far (1...7).
    public var coveredDays: Int { days.filter { !$0.isFuture }.count }

    /// Two requests from the same session this close together count as continuous work; a longer gap is idle time.
    public static let idleGap: TimeInterval = 15 * 60

    // MARK: Weeks

    /// The calendar week containing `date`, starting on the calendar's first weekday (the user's setting for `.current`).
    public static func week(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        if let interval = calendar.dateInterval(of: .weekOfYear, for: date) { return interval }
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400))
    }

    /// The week before (or after, with a positive offset) the one containing `date`.
    public static func week(offset: Int, from date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = week(containing: date, calendar: calendar).start
        let shifted = calendar.date(byAdding: .weekOfYear, value: offset, to: start) ?? start.addingTimeInterval(Double(offset) * 7 * 86_400)
        return week(containing: shifted, calendar: calendar)
    }

    // MARK: Building

    /// Builds the week containing `date` as of `now`. A current week covers up to `now`; a future week covers nothing.
    /// `contributions` is GitHub's graph keyed `yyyy-MM-dd`; pass nil when it isn't loaded.
    public static func build(events: [AgentUsageEvent], weekOf date: Date, now: Date = .now, calendar: Calendar = .current,
                             contributions: [String: Int]? = nil, pulls: WeeklyPulls? = nil) -> WeeklyReport {
        let week = week(containing: date, calendar: calendar)
        return build(events: events, week: week, through: min(max(now, week.start), week.end), calendar: calendar,
                     contributions: contributions, pulls: pulls)
    }

    /// The week before `report`, cut to the same stretch of days and hours when `report` is a partial week, so
    /// "Monday and Tuesday so far" compares with last Monday and Tuesday rather than a whole week.
    public static func previous(to report: WeeklyReport, events: [AgentUsageEvent], calendar: Calendar = .current,
                                contributions: [String: Int]? = nil, pulls: WeeklyPulls? = nil) -> WeeklyReport {
        let week = week(offset: -1, from: report.week.start, calendar: calendar)
        let elapsed = report.through.timeIntervalSince(report.week.start)
        let through = report.isPartial ? min(week.start.addingTimeInterval(elapsed), week.end) : week.end
        return build(events: events, week: week, through: through, calendar: calendar, contributions: contributions, pulls: pulls)
    }

    public static func build(events: [AgentUsageEvent], week: DateInterval, through: Date, calendar: Calendar = .current,
                             contributions: [String: Int]? = nil, pulls: WeeklyPulls? = nil) -> WeeklyReport {
        var report = WeeklyReport(week: week, through: through)
        report.pulls = pulls

        var days: [Day] = []
        var cursor = week.start
        while cursor < week.end, days.count < 7 {
            days.append(Day(date: cursor, isFuture: cursor >= through))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? week.end
        }

        let inWeek = events.filter { $0.observedAt >= week.start && $0.observedAt < through }
        var agents: [AgentKind: AgentUsageTotals] = [:]
        var models: [String: (AgentUsageTotals, Set<AgentKind>)] = [:]
        var projects: [String: AgentUsageTotals] = [:]
        var sessions: Set<String> = []
        for event in inWeek {
            report.totals.add(event)
            agents[event.agent, default: AgentUsageTotals()].add(event)
            let model = event.model.isEmpty ? "Unknown model" : event.model
            var entry = models[model] ?? (AgentUsageTotals(), [])
            entry.0.add(event)
            entry.1.insert(event.agent)
            models[model] = entry
            projects[event.projectName.isEmpty ? "No project" : event.projectName, default: AgentUsageTotals()].add(event)
            sessions.insert("\(event.agent.rawValue)|\(event.sessionID)")
            if let index = dayIndex(event.observedAt, in: days) {
                let usage = event.usage.normalized()
                days[index].processed += usage.processedTokens ?? 0
                days[index].cost += event.cost ?? 0
            }
        }
        report.totals.sessions = sessions.count

        let total = Double(max(report.totals.processed, 1))
        func row(_ id: String, _ title: String, _ agent: AgentKind?, _ t: AgentUsageTotals) -> Row {
            Row(id: id, title: title, agent: agent, processed: t.processed, cost: t.cost, costIsEstimated: t.costIsEstimated,
                share: Double(t.processed) / total)
        }
        let byTokens: (Row, Row) -> Bool = { $0.processed != $1.processed ? $0.processed > $1.processed : $0.title < $1.title }
        report.byAgent = agents.map { row($0.key.rawValue, $0.key.name, $0.key, $0.value) }.sorted(by: byTokens)
        report.byModel = models.map { row($0.key, $0.key, $0.value.1.count == 1 ? $0.value.1.first : nil, $0.value.0) }.sorted(by: byTokens)
        report.byProject = projects.map { row($0.key, $0.key, nil, $0.value) }.sorted(by: byTokens)

        for span in activeSpans(inWeek) {
            report.activeSeconds += span.duration
            if let index = dayIndex(span.start, in: days) { days[index].activeSeconds += span.duration }
        }

        if let contributions {
            let covered = days.filter { !$0.isFuture }
            let counts = covered.map { contributions[dayKey($0.date, calendar: calendar)] }
            if !covered.isEmpty, counts.allSatisfy({ $0 != nil }) {
                for index in days.indices where !days[index].isFuture {
                    days[index].contributions = contributions[dayKey(days[index].date, calendar: calendar)]
                }
                report.contributions = counts.compactMap { $0 }.reduce(0, +)
            }
        }

        report.days = days
        report.activeDays = days.filter { $0.processed > 0 }.count
        report.streak = streak(events: events, through: through, calendar: calendar, todayMayBeEmpty: report.isPartial)
        return report
    }

    /// Stretches of continuous agent work: per session, consecutive requests no more than `idleGap` apart join into
    /// one span; spans from agents working side by side are merged, so two agents for an hour count as an hour.
    public static func activeSpans(_ events: [AgentUsageEvent], idleGap: TimeInterval = idleGap) -> [DateInterval] {
        var spans: [DateInterval] = []
        for (_, group) in Dictionary(grouping: events, by: { "\($0.agent.rawValue)|\($0.sessionID)" }) {
            let times = group.map(\.observedAt).sorted()
            guard var start = times.first else { continue }
            var end = start
            for time in times.dropFirst() {
                if time.timeIntervalSince(end) <= idleGap {
                    end = time
                } else {
                    if end > start { spans.append(DateInterval(start: start, end: end)) }
                    start = time
                    end = time
                }
            }
            if end > start { spans.append(DateInterval(start: start, end: end)) }
        }
        var merged: [DateInterval] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Consecutive days with usage, ending on the day of `through`. In a week still under way that day is today, and an
    /// empty today doesn't break the streak yet.
    static func streak(events: [AgentUsageEvent], through: Date, calendar: Calendar, todayMayBeEmpty: Bool) -> Int {
        let last = calendar.startOfDay(for: through.addingTimeInterval(-1))
        var active: Set<Date> = []
        for event in events where event.observedAt < through { active.insert(calendar.startOfDay(for: event.observedAt)) }
        var cursor = last
        if todayMayBeEmpty, !active.contains(cursor), let previous = calendar.date(byAdding: .day, value: -1, to: cursor) { cursor = previous }
        var count = 0
        while active.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    private static func dayIndex(_ date: Date, in days: [Day]) -> Int? {
        days.lastIndex { $0.date <= date }
    }

    /// `yyyy-MM-dd` in the calendar's time zone, the way GitHub keys its contribution days.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Comparing

    /// Relative change from `previous` to `current`; nil when there's nothing to compare against.
    public static func change(_ current: Double, _ previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }
}
