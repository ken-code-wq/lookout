import Foundation

// The You page: a period of the permanent history read as a person's habits. Favourite agents, models, projects and
// effort levels, the weekly rhythm, records, the change from the period before, firsts, and an archetype that
// explains itself. Pure; built from `UsageHistory` by `PersonalProfile.build` or `UsageHistory.profile(for:)`.
//
// Shares count requests (model calls), not tokens: agents count cache reads very differently, so tokens would crown
// whichever agent re-reads the most context. Token, cost and cache numbers ride along on every row.

/// A stretch of history to profile.
public enum ProfilePeriod: Hashable, Sendable {
    /// The calendar week, month or year under way (weeks start on the calendar's first weekday).
    case week, month, year
    /// The last `n` days, today included.
    case lastDays(Int)
    /// Everything since the first activity Lookout has.
    case allTime
    /// Any span, e.g. `.calendarYear(2026)` for a year in review.
    case custom(DateInterval)

    /// A whole calendar year, January 1 to January 1.
    public static func calendarYear(_ year: Int, calendar: Calendar = .current) -> ProfilePeriod {
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? start
        return .custom(DateInterval(start: start, end: max(start, end)))
    }

    /// The whole span the period names. One still under way ends in the future; its numbers cover up to now.
    public func interval(now: Date = .now, calendar: Calendar = .current, memberSince: Date? = nil) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        switch self {
        case .week: return WeeklyReport.week(containing: now, calendar: calendar)
        case .month: return calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: today, end: tomorrow)
        case .year: return calendar.dateInterval(of: .year, for: now) ?? DateInterval(start: today, end: tomorrow)
        case .lastDays(let days):
            let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
            return DateInterval(start: start, end: tomorrow)
        case .allTime:
            let start = calendar.startOfDay(for: min(memberSince ?? now, now))
            return DateInterval(start: start, end: tomorrow)
        case .custom(let interval): return interval
        }
    }

    /// The equal stretch just before `interval`, cut to the length of what `covered` covers so far, so "Monday to
    /// Wednesday" compares with last Monday to Wednesday. Nil for all time.
    public func previous(of interval: DateInterval, covered: DateInterval, calendar: Calendar = .current) -> DateInterval? {
        let start: Date?
        switch self {
        case .week: start = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start)
        case .month: start = calendar.date(byAdding: .month, value: -1, to: interval.start)
        case .year: start = calendar.date(byAdding: .year, value: -1, to: interval.start)
        case .lastDays(let days): start = calendar.date(byAdding: .day, value: -max(days, 1), to: interval.start)
        case .allTime: return nil
        case .custom(let custom):
            // A whole calendar year, month or week compares with the one before; anything else with as many days.
            if let unit = [Calendar.Component.year, .month, .weekOfYear].first(where: { calendar.dateInterval(of: $0, for: custom.start) == custom }) {
                start = calendar.date(byAdding: unit, value: -1, to: custom.start)
            } else {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: custom.start), to: calendar.startOfDay(for: custom.end)).day ?? 0
                start = days > 0 ? calendar.date(byAdding: .day, value: -days, to: custom.start)
                                 : custom.start.addingTimeInterval(-max(custom.duration, 1))
            }
        }
        guard let start, start < interval.start else { return nil }
        let elapsed = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: interval.start, to: covered.end)
        let end = min(interval.start, calendar.date(byAdding: elapsed, to: start) ?? interval.start)
        return DateInterval(start: start, end: max(start, end))
    }
}

/// One row of a ranked share: an agent, model, project or effort level.
public struct ProfileShare: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// Set for agent rows, and for model and effort rows that only one agent used.
    public var agent: AgentKind?
    public var tally: UsageTally
    /// Share of the period's requests (for effort rows, of requests whose effort is known), 0...1.
    public var share: Double
    /// Share of the period's processed tokens, 0...1.
    public var tokenShare: Double
    /// Days in the period with any use.
    public var activeDays: Int
    /// Wall-clock time this agent's sessions were working; agent rows only.
    public var activeSeconds: TimeInterval?
    /// Sessions; agent and project rows only.
    public var sessions: Int?
}

public struct ProfileTotals: Hashable, Sendable {
    public var tally = UsageTally()
    public var sessions = 0
    /// Wall-clock time with at least one agent at work. Two agents side by side for an hour count one hour.
    public var activeSeconds: TimeInterval = 0
    public var activeDays = 0
    /// Typical session length (median active time of sessions with more than one request), and how many it's over.
    public var medianSessionSeconds: TimeInterval?
    public var measuredSessions = 0

    public var cacheHitRate: Double? { tally.cacheHitRate }
    public var cacheSavings: Double { tally.cacheSavings }
    public var cost: Double { tally.cost }
    public var hasCost: Bool { tally.hasCost }
    public var costIsEstimated: Bool { tally.costIsEstimated }
    public var activeHours: Double { activeSeconds / 3_600 }
}

/// Effort levels where the logs record them. Unknown effort is never guessed; `coverage` says how much is known.
public struct ProfileEffort: Hashable, Sendable {
    /// Known levels, most requests first. Shares are of requests with a known effort.
    public var levels: [ProfileShare] = []
    /// Share of the period's requests whose effort is known, 0...1.
    public var coverage: Double = 0
    public var knownRequests = 0
    /// Share of known requests at high, xhigh or max; nil when none are known.
    public var highShare: Double?
}

public struct ProfileRhythm: Hashable, Sendable {
    /// Requests by weekday and hour: `requests[weekday - 1][hour]`, weekdays numbered like `Calendar` (1 is Sunday).
    public var requests: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    public var total = 0
    /// Calendar weekday (1 is Sunday) with the most requests.
    public var busiestWeekday: Int?
    /// Clock hour with the most requests.
    public var peakHour: Int?
    /// Shares of requests in `nightHours`, `earlyHours`, and on the calendar's weekend days.
    public var nightShare: Double = 0
    public var earlyShare: Double = 0
    public var weekendShare: Double = 0
    /// Active days that fell on a weekend.
    public var weekendDays = 0

    /// 22:00 to 03:59.
    public static let nightHours: Set<Int> = [22, 23, 0, 1, 2, 3]
    /// 05:00 to 08:59.
    public static let earlyHours: Set<Int> = [5, 6, 7, 8]

    /// The matrix in display order, starting on `firstWeekday` (the user's is `Calendar.current.firstWeekday`).
    public func rows(firstWeekday: Int = Calendar.current.firstWeekday) -> [(weekday: Int, hours: [Int])] {
        (0..<7).map { offset in
            let weekday = (firstWeekday - 1 + offset) % 7 + 1
            return (weekday, requests[weekday - 1])
        }
    }
}

public struct ProfileRecords: Hashable, Sendable {
    public struct DayRecord: Hashable, Sendable {
        public var date: Date
        public var tally: UsageTally
    }

    public struct SessionRecord: Hashable, Sendable {
        public var agent: AgentKind
        public var sessionID: String
        public var project: String
        public var model: String
        /// First and last moment of work inside the period.
        public var start: Date
        public var end: Date
        /// Active time inside the period.
        public var activeSeconds: TimeInterval
    }

    public struct StreakRecord: Hashable, Sendable {
        public var days: Int
        /// First and last day of the streak.
        public var start: Date
        public var end: Date
    }

    public struct ConcurrencyRecord: Hashable, Sendable {
        /// Sessions working at the same moment.
        public var sessions: Int
        /// When that many first worked at once.
        public var at: Date
    }

    public var biggestDayByTokens: DayRecord?
    /// Among days with any priced usage.
    public var biggestDayByCost: DayRecord?
    public var longestSession: SessionRecord?
    public var peakConcurrent: ConcurrencyRecord?
    public var longestStreak: StreakRecord?
    /// Consecutive active days ending today, or yesterday while today is still empty. Always as of now, across the
    /// whole history, whatever the period.
    public var currentStreak = 0
}

/// The top of a ranking in the previous period and in this one, when they differ.
public struct ProfileShift: Hashable, Sendable {
    public var from: String
    public var fromShare: Double
    public var to: String
    public var toShare: Double
    /// "Moved from claude-sonnet-4-5 to claude-opus-4-1".
    public var sentence: String { "Moved from \(from) to \(to)" }
}

public struct ProfileTrends: Hashable, Sendable {
    /// The stretch compared against, cut to the same length as this period so far.
    public var previous: DateInterval
    public var previousTotals: ProfileTotals
    /// Relative changes, e.g. 0.25 for a quarter more. Nil when the previous period had none.
    public var requests: Double?
    public var tokens: Double?
    public var cost: Double?
    public var activeTime: Double?
    public var activeDays: Double?
    public var topProvider: ProfileShift?
    public var topModel: ProfileShift?
    public var topProject: ProfileShift?
}

public struct ProfileFirsts: Hashable, Sendable {
    public struct ProviderFirst: Hashable, Sendable {
        public var agent: AgentKind
        public var date: Date
    }

    /// The first day Lookout saw any activity: "member since".
    public var memberSince: Date?
    /// When Lookout started keeping the history. Days before it come from logs the agents still had on disk.
    public var recordingSince: Date
    /// The first activity Lookout has from each agent, earliest first.
    public var providers: [ProviderFirst] = []
    /// Models and agents used for the first time ever during this period (empty for all time).
    public var newModels: [String] = []
    public var newProviders: [AgentKind] = []
}

public struct PersonalProfile: Hashable, Sendable {
    public var period: ProfilePeriod
    /// The span the period names; a week under way still ends next week.
    public var interval: DateInterval
    /// What the numbers cover: `interval` up to now.
    public var covered: DateInterval
    public var totals = ProfileTotals()
    /// Ranked by share of requests.
    public var providers: [ProfileShare] = []
    public var models: [ProfileShare] = []
    public var projects: [ProfileShare] = []
    public var effort = ProfileEffort()
    public var rhythm = ProfileRhythm()
    public var records = ProfileRecords()
    /// Peak sessions at once on each active day, keyed by the day's start.
    public var dailyPeakConcurrency: [Date: Int] = [:]
    /// Nil for all time, or when the stretch before had no activity to compare with.
    public var trends: ProfileTrends?
    public var firsts: ProfileFirsts
    /// Days with activity across the whole history, to judge how much there is to go on.
    public var allTimeActiveDays = 0
    public var archetype = ArchetypeResult()

    public var isEmpty: Bool { totals.tally.events == 0 }
    public var isPartial: Bool { covered.end < interval.end }
    /// Calendar days the covered stretch touches.
    public var coveredDays: Int

    /// Active days on which at least `sessions` sessions worked at the same moment.
    public func days(withAtLeast sessions: Int) -> Int {
        dailyPeakConcurrency.values.filter { $0 >= sessions }.count
    }

    /// Profiles `period` of `history` as of `now`.
    public static func build(from history: UsageHistory, period: ProfilePeriod, now: Date = .now, calendar: Calendar = .current) -> PersonalProfile {
        let history = history.includingPending(calendar: calendar)
        let interval = period.interval(now: now, calendar: calendar, memberSince: history.firstActivityAt)
        let coveredEnd = min(max(now, interval.start), interval.end)
        let covered = DateInterval(start: interval.start, end: coveredEnd)
        var profile = PersonalProfile(
            period: period, interval: interval, covered: covered,
            firsts: ProfileFirsts(memberSince: history.firstActivityAt.map { calendar.startOfDay(for: $0) }, recordingSince: history.createdAt),
            coveredDays: Self.dayCount(covered, calendar: calendar)
        )
        let slice = ProfileSlice(history: history, interval: covered, calendar: calendar)
        slice.apply(to: &profile)
        profile.allTimeActiveDays = history.days.values.filter { $0.tally.events > 0 }.count
        profile.records.currentStreak = Self.currentStreak(history: history, now: now, calendar: calendar)
        profile.firsts = Self.firsts(history: history, profile: profile, calendar: calendar)

        if let previous = period.previous(of: interval, covered: covered, calendar: calendar) {
            var before = PersonalProfile(period: .custom(previous), interval: previous, covered: previous,
                                         firsts: profile.firsts, coveredDays: Self.dayCount(previous, calendar: calendar))
            ProfileSlice(history: history, interval: previous, calendar: calendar).apply(to: &before)
            profile.trends = Self.trends(current: profile, previous: before)
        }
        profile.archetype = ProfileArchetypes.evaluate(profile, now: now)
        return profile
    }

    static func dayCount(_ interval: DateInterval, calendar: Calendar) -> Int {
        guard interval.duration > 0 else { return 0 }
        let first = calendar.startOfDay(for: interval.start)
        let last = calendar.startOfDay(for: interval.end.addingTimeInterval(-1))
        return (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
    }

    private static func currentStreak(history: UsageHistory, now: Date, calendar: Calendar) -> Int {
        let active = Set(history.days.filter { $0.value.tally.events > 0 }.keys)
        var cursor = calendar.startOfDay(for: now)
        if !active.contains(WeeklyReport.dayKey(cursor, calendar: calendar)),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) { cursor = yesterday }
        var count = 0
        while active.contains(WeeklyReport.dayKey(cursor, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    private static func firsts(history: UsageHistory, profile: PersonalProfile, calendar: Calendar) -> ProfileFirsts {
        var firsts = profile.firsts
        var agentFirst: [AgentKind: Date] = [:]
        for session in history.sessions.values where session.tally.events > 0 {
            agentFirst[session.agent] = min(agentFirst[session.agent] ?? session.firstAt, session.firstAt)
        }
        firsts.providers = agentFirst.map { ProfileFirsts.ProviderFirst(agent: $0.key, date: $0.value) }.sorted { ($0.date, $0.agent.rawValue) < ($1.date, $1.agent.rawValue) }
        guard profile.period != .allTime else { return firsts }
        let start = profile.covered.start
        firsts.newProviders = firsts.providers.filter { $0.date >= start && $0.date < profile.covered.end }.map(\.agent)
        var modelFirst: [String: String] = [:]
        for (key, day) in history.days {
            for bucket in day.buckets where !bucket.model.isEmpty {
                if let known = modelFirst[bucket.model], known <= key { continue }
                modelFirst[bucket.model] = key
            }
        }
        let startKey = WeeklyReport.dayKey(start, calendar: calendar)
        firsts.newModels = profile.models.map(\.id).filter { modelFirst[$0].map { $0 >= startKey } ?? false }
        return firsts
    }

    private static func trends(current: PersonalProfile, previous: PersonalProfile) -> ProfileTrends? {
        let now = current.totals, then = previous.totals
        guard then.tally.events > 0 else { return nil }
        func shift(_ a: [ProfileShare], _ b: [ProfileShare]) -> ProfileShift? {
            guard let old = b.first, let new = a.first, old.id != new.id else { return nil }
            return ProfileShift(from: old.title, fromShare: old.share, to: new.title, toShare: new.share)
        }
        return ProfileTrends(
            previous: previous.covered, previousTotals: then,
            requests: WeeklyReport.change(Double(now.tally.requests), Double(then.tally.requests)),
            tokens: WeeklyReport.change(Double(now.tally.processed), Double(then.tally.processed)),
            cost: now.hasCost && then.hasCost ? WeeklyReport.change(now.cost, then.cost) : nil,
            activeTime: WeeklyReport.change(now.activeSeconds, then.activeSeconds),
            activeDays: WeeklyReport.change(Double(now.activeDays), Double(then.activeDays)),
            topProvider: shift(current.providers, previous.providers),
            topModel: shift(current.models, previous.models),
            topProject: shift(current.projects, previous.projects)
        )
    }
}

public extension UsageHistory {
    /// The You page's profile for `period` as of `now`.
    func profile(for period: ProfilePeriod, now: Date = .now, calendar: Calendar = .current) -> PersonalProfile {
        PersonalProfile.build(from: self, period: period, now: now, calendar: calendar)
    }
}

/// Everything one stretch of history adds up to, before it's ranked into a profile.
private struct ProfileSlice {
    struct Group {
        var tally = UsageTally()
        var days: Set<String> = []
        var agents: Set<AgentKind> = []
        var sessions = 0
        var activeSeconds: TimeInterval?
    }

    var tally = UsageTally()
    var agents: [AgentKind: Group] = [:]
    var models: [String: Group] = [:]
    var projects: [String: Group] = [:]
    var efforts: [String: Group] = [:]
    var days: [String: (date: Date, tally: UsageTally)] = [:]
    var rhythm = ProfileRhythm()
    var night = 0, early = 0, weekend = 0
    var weekendDays: Set<String> = []
    var totals = ProfileTotals()
    var records = ProfileRecords()
    var dailyPeaks: [Date: Int] = [:]
    let calendar: Calendar

    init(history: UsageHistory, interval: DateInterval, calendar: Calendar) {
        self.calendar = calendar
        guard interval.duration > 0 else { return }
        readDays(history, interval, calendar)
        readSessions(history, interval, calendar)
    }

    private mutating func readDays(_ history: UsageHistory, _ interval: DateInterval, _ calendar: Calendar) {
        // Keys sort by date: skip far-off days without parsing them (a day's margin for keys from another time zone).
        let lowest = WeeklyReport.dayKey(interval.start.addingTimeInterval(-86_400), calendar: calendar)
        let highest = WeeklyReport.dayKey(interval.end.addingTimeInterval(86_400), calendar: calendar)
        for (key, day) in history.days where key >= lowest && key <= highest {
            guard let start = UsageHistory.date(forDayKey: key, calendar: calendar),
                  let end = calendar.date(byAdding: .day, value: 1, to: start),
                  end > interval.start, start < interval.end else { continue }
            let whole = start >= interval.start && end <= interval.end
            let weekday = calendar.component(.weekday, from: start)
            let isWeekend = calendar.isDateInWeekend(start)
            var dayTally = UsageTally()
            for bucket in day.buckets {
                var bucketTally = UsageTally()
                for cell in bucket.hours where (0..<24).contains(cell.hour) {
                    if !whole {
                        let hourStart = calendar.date(bySettingHour: cell.hour, minute: 0, second: 0, of: start) ?? start
                        guard hourStart >= interval.start, hourStart < interval.end else { continue }
                    }
                    bucketTally.add(cell.tally)
                    let requests = cell.tally.requests
                    rhythm.requests[weekday - 1][cell.hour] += requests
                    if ProfileRhythm.nightHours.contains(cell.hour) { night += requests }
                    if ProfileRhythm.earlyHours.contains(cell.hour) { early += requests }
                    if isWeekend { weekend += requests }
                }
                guard bucketTally.events > 0 else { continue }
                dayTally.add(bucketTally)
                func add(_ group: inout Group) {
                    group.tally.add(bucketTally)
                    group.days.insert(key)
                    group.agents.insert(bucket.agent)
                }
                add(&agents[bucket.agent, default: Group()])
                add(&models[bucket.model, default: Group()])
                add(&projects[bucket.project, default: Group()])
                if let effort = bucket.effort { add(&efforts[effort, default: Group()]) }
            }
            guard dayTally.events > 0 else { continue }
            tally.add(dayTally)
            days[key] = (start, dayTally)
            if isWeekend { weekendDays.insert(key) }
        }
    }

    private mutating func readSessions(_ history: UsageHistory, _ interval: DateInterval, _ calendar: Calendar) {
        let lower = interval.start.timeIntervalSince1970, upper = interval.end.timeIntervalSince1970
        var clipped: [(agent: AgentKind, start: Double, end: Double)] = []
        var lengths: [TimeInterval] = []
        var projectSessions: [String: Int] = [:]
        for session in history.sessions.values where session.firstAt < interval.end && session.lastAt >= interval.start {
            var active: TimeInterval = 0
            var first: Double?, last: Double?
            for span in session.spans {
                let start = Double(span.start), end = Double(span.end)
                guard start < upper, end >= lower else { continue }
                let from = max(start, lower), to = min(end, upper)
                clipped.append((session.agent, from, to))
                active += max(0, to - from)
                first = min(first ?? from, from)
                last = max(last ?? to, to)
            }
            guard let first, let last else { continue }
            totals.sessions += 1
            agents[session.agent, default: Group()].sessions += 1
            projectSessions[session.project, default: 0] += 1
            if active > 0 { lengths.append(active) }
            let best = records.longestSession
            if active > (best?.activeSeconds ?? 0) || (active > 0 && active == best?.activeSeconds && session.sessionID < best?.sessionID ?? "") {
                records.longestSession = .init(agent: session.agent, sessionID: session.sessionID, project: session.project,
                                               model: session.model, start: Date(timeIntervalSince1970: first),
                                               end: Date(timeIntervalSince1970: last), activeSeconds: active)
            }
        }
        for (project, count) in projectSessions where projects[project] != nil { projects[project]?.sessions = count }

        lengths.sort()
        totals.measuredSessions = lengths.count
        if !lengths.isEmpty {
            let mid = lengths.count / 2
            totals.medianSessionSeconds = lengths.count % 2 == 1 ? lengths[mid] : (lengths[mid - 1] + lengths[mid]) / 2
        }
        totals.activeSeconds = Self.unionLength(clipped.map { ($0.start, $0.end) })
        for agent in Set(clipped.map(\.agent)) {
            agents[agent, default: Group()].activeSeconds = Self.unionLength(clipped.filter { $0.agent == agent }.map { ($0.start, $0.end) })
        }
        sweepConcurrency(clipped.map { ($0.start, $0.end) }, calendar)
    }

    /// Length covered by the union of closed ranges.
    private static func unionLength(_ ranges: [(Double, Double)]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: (Double, Double)?
        for range in ranges.sorted(by: { $0.0 < $1.0 }) {
            if let open = current, range.0 <= open.1 {
                current = (open.0, max(open.1, range.1))
            } else {
                if let open = current { total += open.1 - open.0 }
                current = range
            }
        }
        if let open = current { total += open.1 - open.0 }
        return total
    }

    /// Most sessions working at one moment, overall and per day. Ranges are closed, so touching ones overlap.
    private mutating func sweepConcurrency(_ ranges: [(Double, Double)], _ calendar: Calendar) {
        var points: [(time: Double, delta: Int)] = []
        points.reserveCapacity(ranges.count * 2)
        for range in ranges {
            points.append((range.0, 1))
            points.append((range.1, -1))
        }
        // Starts before ends at the same moment.
        points.sort { lhs, rhs in lhs.time != rhs.time ? lhs.time < rhs.time : lhs.delta > rhs.delta }
        var level = 0
        var day: Date?
        var dayEnd = Date.distantPast
        for (time, delta) in points {
            let moment = Date(timeIntervalSince1970: time)
            if level == 0, moment >= dayEnd {
                day = calendar.startOfDay(for: moment)
                dayEnd = day.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? moment.addingTimeInterval(86_400)
            }
            // Work still under way at midnight counts on each day it runs into.
            while moment >= dayEnd {
                day = dayEnd
                dayEnd = calendar.date(byAdding: .day, value: 1, to: dayEnd) ?? moment.addingTimeInterval(86_400)
                if let day { dailyPeaks[day] = max(dailyPeaks[day] ?? 0, level) }
            }
            level += delta
            guard delta > 0, let day else { continue }
            dailyPeaks[day] = max(dailyPeaks[day] ?? 0, level)
            if level > (records.peakConcurrent?.sessions ?? 0) {
                records.peakConcurrent = .init(sessions: level, at: moment)
            }
        }
    }

    func apply(to profile: inout PersonalProfile) {
        var totals = self.totals
        totals.tally = tally
        totals.activeDays = days.count
        profile.totals = totals
        profile.dailyPeakConcurrency = dailyPeaks

        let requests = Double(max(tally.requests, 1)), tokens = Double(max(tally.processed, 1))
        func rows<Key>(_ groups: [Key: Group], id: (Key) -> String, title: (Key) -> String, agent: (Key, Group) -> AgentKind?,
                       of total: Double) -> [ProfileShare] {
            groups.map { key, group in
                ProfileShare(id: id(key), title: title(key), agent: agent(key, group), tally: group.tally,
                             share: Double(group.tally.requests) / total, tokenShare: Double(group.tally.processed) / tokens,
                             activeDays: group.days.count, activeSeconds: group.activeSeconds,
                             sessions: group.sessions > 0 ? group.sessions : nil)
            }
            .filter { $0.tally.events > 0 }
            .sorted { ($1.tally.requests, $1.tally.processed, $0.title) < ($0.tally.requests, $0.tally.processed, $1.title) }
        }
        let single: (Group) -> AgentKind? = { $0.agents.count == 1 ? $0.agents.first : nil }
        profile.providers = rows(agents, id: \.rawValue, title: \.name, agent: { key, _ in key }, of: requests)
        profile.models = rows(models, id: { $0 }, title: { $0.isEmpty ? "Unknown model" : $0 }, agent: { single($1) }, of: requests)
            .map { var row = $0; row.sessions = nil; return row }
        profile.projects = rows(projects, id: { $0 }, title: { $0.isEmpty ? "Unknown workspace" : $0 }, agent: { _, _ in nil }, of: requests)

        let known = efforts.values.reduce(0) { $0 + $1.tally.requests }
        var effort = ProfileEffort()
        effort.knownRequests = known
        effort.coverage = tally.requests > 0 ? Double(known) / Double(tally.requests) : 0
        effort.levels = rows(efforts, id: { $0 }, title: { $0 }, agent: { single($1) }, of: Double(max(known, 1)))
            .map { var row = $0; row.sessions = nil; return row }
        if known > 0 {
            let high = efforts.filter { ProfileArchetypes.deepEffortLevels.contains($0.key) }.values.reduce(0) { $0 + $1.tally.requests }
            effort.highShare = Double(high) / Double(known)
        }
        profile.effort = effort

        var rhythm = self.rhythm
        rhythm.total = tally.requests
        if tally.requests > 0 {
            rhythm.nightShare = Double(night) / requests
            rhythm.earlyShare = Double(early) / requests
            rhythm.weekendShare = Double(weekend) / requests
            let byWeekday = rhythm.requests.map { $0.reduce(0, +) }
            rhythm.busiestWeekday = byWeekday.indices.max { (byWeekday[$0], -$0) < (byWeekday[$1], -$1) }.map { $0 + 1 }
            let byHour = (0..<24).map { hour in rhythm.requests.reduce(0) { $0 + $1[hour] } }
            rhythm.peakHour = byHour.indices.max { (byHour[$0], -$0) < (byHour[$1], -$1) }
        }
        rhythm.weekendDays = weekendDays.count
        profile.rhythm = rhythm

        var records = self.records
        let ordered = days.values.sorted { $0.date < $1.date }
        if let top = ordered.max(by: { $0.tally.processed < $1.tally.processed }), top.tally.processed > 0 {
            records.biggestDayByTokens = .init(date: top.date, tally: top.tally)
        }
        if let top = ordered.filter({ $0.tally.hasCost }).max(by: { $0.tally.cost < $1.tally.cost }), top.tally.cost > 0 {
            records.biggestDayByCost = .init(date: top.date, tally: top.tally)
        }
        records.longestStreak = Self.longestStreak(ordered.map(\.date), calendar: calendar)
        records.currentStreak = profile.records.currentStreak
        profile.records = records
    }

    /// Longest run of consecutive days in sorted day starts.
    static func longestStreak(_ dates: [Date], calendar: Calendar) -> ProfileRecords.StreakRecord? {
        var best: ProfileRecords.StreakRecord?
        var run: ProfileRecords.StreakRecord?
        for date in dates {
            if let current = run, let next = calendar.date(byAdding: .day, value: 1, to: current.end), calendar.isDate(next, inSameDayAs: date) {
                run = .init(days: current.days + 1, start: current.start, end: date)
            } else {
                run = .init(days: 1, start: date, end: date)
            }
            if let run, run.days > (best?.days ?? 0) { best = run }
        }
        return best
    }
}
