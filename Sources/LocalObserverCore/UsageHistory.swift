import Foundation

// Lookout's permanent usage history. Agents delete their own logs (Claude Code after about 30 days) and the raw usage
// ledger keeps one year of events, so this is the record that outlives both: every day rolled up by agent, model,
// project and effort, hour by hour, plus a summary per session. It only grows, and merging events it already holds
// changes nothing. Pure value type: AgentStore keeps it on disk and feeds it every scan; `PersonalProfile` reads it.
//
// Idempotency rests on event ids, the same stable keys the raw ledger dedupes on. Recent events wait in `pending`
// under their id until they settle (a streaming reply rewrites its counts), then fold into their day, which remembers
// the id so a later scan reading the same event again skips it. Once a day is older than any scan reaches and the
// agent's whole history has been read once, the day forgets that agent's ids and closes to it: anything the agent
// reports there again can only be a repeat.

public struct UsageHistory: Codable, Hashable, Sendable {
    /// Bumped only for a layout older builds can't read. History is never thrown away over a version; migrate it.
    public static let formatVersion = 1
    /// Events this recent can still change, so they wait in `pending` and fold into the rollup once older.
    public static let settleAfter: TimeInterval = 24 * 3_600
    /// Days a folded event's id is remembered by default: longer than the longest window a scan reads (365 days).
    /// Readers drop events older than their window, so a caller that knows its window can pass a shorter one.
    public static let rememberIDsDays = 400
    /// How far back the one-time backfill reads each agent's logs: everything still on disk.
    public static let backfillDays = 3_650

    public private(set) var version = UsageHistory.formatVersion
    /// When Lookout started keeping this history. Earlier days come from whatever the agents still had on disk.
    public private(set) var createdAt: Date
    /// First and last activity folded in. `includingPending()` counts events still settling too.
    public private(set) var firstActivityAt: Date?
    public private(set) var lastActivityAt: Date?
    /// Days keyed `yyyy-MM-dd` in the calendar they were recorded in.
    public private(set) var days: [String: Day] = [:]
    /// Sessions keyed `agent|sessionID`.
    public private(set) var sessions: [String: Session] = [:]
    /// Events still settling, by id. Kept without file paths.
    public private(set) var pending: [String: AgentUsageEvent] = [:]
    /// Agents whose whole on-disk history has been read once. Until then their old days stay open to them.
    public var backfilledAgents: Set<AgentKind> = []
    /// Per agent (raw value), the first day that still remembers ids. Earlier days ignore the agent's events.
    private(set) var closedBefore: [String: String] = [:]
    /// Milestones reached, by milestone id. See `ProfileMilestones.swift`.
    public internal(set) var milestones: [String: EarnedMilestone] = [:]
    /// Milestones the app has already celebrated.
    public internal(set) var acknowledgedMilestones: Set<String> = []

    public init(createdAt: Date = .now) {
        self.createdAt = createdAt
    }

    public var isEmpty: Bool { days.isEmpty && pending.isEmpty }

    // MARK: Days and sessions

    /// One day: a bucket per agent, model, project and effort, each with a cell per active hour.
    public struct Day: Codable, Hashable, Sendable {
        /// Sorted by agent, model, project and effort, so the layout doesn't depend on the order events arrived in.
        public internal(set) var buckets: [Bucket] = []
        /// Hashed ids of the events folded in, per agent, while the day still remembers them.
        var seen: [String: EventIDSet] = [:]

        public var tally: UsageTally { buckets.reduce(into: UsageTally()) { $0.add($1.tally) } }

        mutating func add(_ event: AgentUsageEvent, hour: Int) {
            let key = Bucket.Key(event)
            if let index = buckets.firstIndex(where: { $0.key >= key }), buckets[index].key == key {
                buckets[index].add(event, hour: hour)
            } else {
                var bucket = Bucket(agent: event.agent, model: event.model, project: event.projectName, effort: event.effort)
                bucket.add(event, hour: hour)
                buckets.insert(bucket, at: buckets.firstIndex { $0.key > key } ?? buckets.endIndex)
            }
        }

        enum CodingKeys: String, CodingKey { case buckets = "b", seen = "s" }

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            buckets = try c.decodeIfPresent([Bucket].self, forKey: .buckets) ?? []
            seen = try c.decodeIfPresent([String: EventIDSet].self, forKey: .seen) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(buckets, forKey: .buckets)
            if !seen.isEmpty { try c.encode(seen, forKey: .seen) }
        }
    }

    public struct Bucket: Codable, Hashable, Sendable {
        public var agent: AgentKind
        /// As the agent reported it; empty when it didn't.
        public var model: String
        public var project: String
        /// One of `AgentEffort.levels`, or nil when the logs don't say.
        public var effort: String?
        /// One cell per hour of the day with activity, earliest first.
        public internal(set) var hours: [HourCell] = []

        public var tally: UsageTally { hours.reduce(into: UsageTally()) { $0.add($1.tally) } }

        struct Key: Comparable {
            var agent: String, model: String, project: String, effort: String

            init(_ event: AgentUsageEvent) {
                agent = event.agent.rawValue
                model = event.model
                project = event.projectName
                effort = event.effort ?? ""
            }

            init(_ bucket: Bucket) {
                agent = bucket.agent.rawValue
                model = bucket.model
                project = bucket.project
                effort = bucket.effort ?? ""
            }

            static func < (lhs: Key, rhs: Key) -> Bool {
                (lhs.agent, lhs.model, lhs.project, lhs.effort) < (rhs.agent, rhs.model, rhs.project, rhs.effort)
            }
        }

        var key: Key { Key(self) }

        mutating func add(_ event: AgentUsageEvent, hour: Int) {
            if let index = hours.firstIndex(where: { $0.hour >= hour }), hours[index].hour == hour {
                hours[index].tally.add(event)
            } else {
                var cell = HourCell(hour: hour)
                cell.tally.add(event)
                hours.insert(cell, at: hours.firstIndex { $0.hour > hour } ?? hours.endIndex)
            }
        }

        enum CodingKeys: String, CodingKey { case agent = "a", model = "m", project = "p", effort = "e", hours = "h" }
    }

    /// An hour of the day, 0...23 on the clock where it happened, and what was used in it.
    public struct HourCell: Codable, Hashable, Sendable {
        public var hour: Int
        public var tally = UsageTally()

        init(hour: Int) { self.hour = hour }

        // `[hour, …tally]`: thousands of these, so no keys.
        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            hour = try c.decode(Int.self)
            tally = try UsageTally(from: &c)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(hour)
            try tally.encode(to: &c)
        }
    }

    public struct Session: Codable, Hashable, Sendable {
        public var agent: AgentKind
        public var sessionID: String
        /// Project and model of the earliest event that reported one.
        public var project = ""
        public var model = ""
        public var firstAt = Date.distantFuture
        public var lastAt = Date.distantPast
        public var tally = UsageTally()
        /// Days with activity, `yyyy-MM-dd`, earliest first.
        public var days: [String] = []
        /// Stretches of continuous work, Unix seconds: requests no more than `WeeklyReport.idleGap` apart join one.
        /// The result doesn't depend on the order events arrive in, so late events land where they would have.
        var spans: [Span] = []

        static func key(_ event: AgentUsageEvent) -> String { "\(event.agent.rawValue)|\(event.sessionID)" }

        init(agent: AgentKind, sessionID: String) {
            self.agent = agent
            self.sessionID = sessionID
        }

        /// Each stretch of continuous work; a lone request is a zero-length interval.
        public var intervals: [DateInterval] { spans.map(\.interval) }
        public var activeSeconds: TimeInterval { spans.reduce(0) { $0 + TimeInterval($1.end - $1.start) } }

        mutating func add(_ event: AgentUsageEvent, day: String) {
            let earliest = event.observedAt < firstAt
            if !event.projectName.isEmpty, project.isEmpty || earliest { project = event.projectName }
            if !event.model.isEmpty, model.isEmpty || earliest { model = event.model }
            firstAt = min(firstAt, event.observedAt)
            lastAt = max(lastAt, event.observedAt)
            tally.add(event)
            if !days.contains(day) {
                days.insert(day, at: days.firstIndex { $0 > day } ?? days.endIndex)
            }
            Span.insert(Int(event.observedAt.timeIntervalSince1970.rounded(.down)), into: &spans, gap: Int(WeeklyReport.idleGap))
        }

        enum CodingKeys: String, CodingKey {
            case agent = "a", sessionID = "id", project = "p", model = "m", firstAt = "f", lastAt = "l", tally = "t", days = "d", spans = "s"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agent = try c.decode(AgentKind.self, forKey: .agent)
            sessionID = try c.decode(String.self, forKey: .sessionID)
            project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
            firstAt = try c.decode(Date.self, forKey: .firstAt)
            lastAt = try c.decode(Date.self, forKey: .lastAt)
            tally = try c.decodeIfPresent(UsageTally.self, forKey: .tally) ?? UsageTally()
            days = try c.decodeIfPresent([String].self, forKey: .days) ?? []
            let flat = try c.decodeIfPresent([Int].self, forKey: .spans) ?? []
            spans = stride(from: 0, to: flat.count - 1, by: 2).map { Span(start: flat[$0], end: flat[$0 + 1]) }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(agent, forKey: .agent)
            try c.encode(sessionID, forKey: .sessionID)
            if !project.isEmpty { try c.encode(project, forKey: .project) }
            if !model.isEmpty { try c.encode(model, forKey: .model) }
            try c.encode(firstAt, forKey: .firstAt)
            try c.encode(lastAt, forKey: .lastAt)
            try c.encode(tally, forKey: .tally)
            try c.encode(days, forKey: .days)
            try c.encode(spans.flatMap { [$0.start, $0.end] }, forKey: .spans)
        }
    }

    /// Closed range of Unix seconds.
    struct Span: Hashable, Sendable {
        var start: Int
        var end: Int

        var interval: DateInterval {
            DateInterval(start: Date(timeIntervalSince1970: TimeInterval(start)), end: Date(timeIntervalSince1970: TimeInterval(end)))
        }

        /// Adds a moment to sorted, disjoint spans: it joins every span within `gap` of it, or starts its own.
        static func insert(_ time: Int, into spans: inout [Span], gap: Int) {
            var low = 0, high = spans.count
            while low < high {
                let mid = (low + high) / 2
                if spans[mid].end + gap < time { low = mid + 1 } else { high = mid }
            }
            guard low < spans.count, spans[low].start - gap <= time else {
                spans.insert(Span(start: time, end: time), at: low)
                return
            }
            spans[low].start = min(spans[low].start, time)
            spans[low].end = max(spans[low].end, time)
            while low + 1 < spans.count, spans[low + 1].start - spans[low].end <= gap {
                spans[low].end = max(spans[low].end, spans[low + 1].end)
                spans.remove(at: low + 1)
            }
        }
    }

    // MARK: Merging

    /// What a merge did.
    public struct MergeSummary: Hashable, Sendable {
        /// Events folded into the rollup for the first time.
        public var folded = 0
        /// Events the rollup already holds, recognised by id and skipped.
        public var repeats = 0
        /// Events for days already closed to their agent, skipped.
        public var closed = 0
        /// Events added to or revised in `pending`, or moved out of it.
        public var pendingChanged = 0

        public init() {}

        public var changed: Bool { folded > 0 || pendingChanged > 0 }
    }

    /// Takes in a scan's events. Recent ones wait in `pending` under their id; settled ones fold into their day
    /// unless that day already holds them. Merging the same events again changes nothing.
    ///
    /// The first copy of a settled event wins, so merge the freshest source first. `keepPending` leaves events
    /// already pending alone, for replaying an older copy such as the raw ledger after a scan.
    @discardableResult
    public mutating func merge(_ events: [AgentUsageEvent], now: Date = .now, calendar: Calendar = .current,
                               keepPending: Bool = false) -> MergeSummary {
        var summary = MergeSummary()
        var slots = SlotCache(calendar: calendar)
        let settled = now.addingTimeInterval(-Self.settleAfter)
        for event in events {
            if keepPending, pending[event.id] != nil { continue }
            if event.observedAt >= settled {
                let trimmed = Self.trimmed(event)
                if pending[event.id] != trimmed {
                    pending[event.id] = trimmed
                    summary.pendingChanged += 1
                }
                continue
            }
            // Settled since it last arrived: this copy is the latest, fold it rather than the pending one.
            if pending.removeValue(forKey: event.id) != nil { summary.pendingChanged += 1 }
            absorb(event, slots: &slots, summary: &summary)
        }
        let ripe = pending.values.filter { $0.observedAt < settled }.sorted { $0.observedAt < $1.observedAt }
        for event in ripe {
            pending.removeValue(forKey: event.id)
            summary.pendingChanged += 1
            absorb(event, slots: &slots, summary: &summary)
        }
        return summary
    }

    /// Forgets the ids of days older than `age` days for agents whose backfill is done, closing those days to them.
    /// Closing only moves forward. Returns whether anything changed.
    @discardableResult
    public mutating func closeOldDays(now: Date = .now, olderThan age: Int = UsageHistory.rememberIDsDays,
                                      calendar: Calendar = .current) -> Bool {
        guard let edge = calendar.date(byAdding: .day, value: -max(age, 1), to: now) else { return false }
        let boundary = WeeklyReport.dayKey(edge, calendar: calendar)
        var changed = false
        for agent in backfilledAgents.map(\.rawValue).sorted() where (closedBefore[agent] ?? "") < boundary {
            closedBefore[agent] = boundary
            for key in days.keys.filter({ $0 < boundary }) where days[key]?.seen[agent] != nil {
                days[key]?.seen.removeValue(forKey: agent)
            }
            changed = true
        }
        return changed
    }

    /// What one scan brings to the history.
    public struct Scan: Sendable {
        public var events: [AgentUsageEvent]
        /// The scan's warnings. "<Agent> history is still indexing" means that agent's backfill isn't finished.
        public var warnings: [String]
        /// Agents the scan covered, and those it read as far back as their logs go.
        public var enabled: Set<AgentKind>
        public var backfill: Set<AgentKind>

        public init(events: [AgentUsageEvent], warnings: [String] = [], enabled: Set<AgentKind>, backfill: Set<AgentKind> = []) {
            self.events = events
            self.warnings = warnings
            self.enabled = enabled
            self.backfill = backfill
        }
    }

    /// Takes in one scan in the order that loses nothing. The scan goes first: its copies are the freshest, effort
    /// and all. Agents with nothing left indexing are marked backfilled. Once every enabled agent is, `ledger` (the
    /// raw ledger, which still has events whose logs are gone) is replayed, and only then do days older than
    /// `rememberDays` close, so the replay can still land. Milestones are brought up to date when anything changed.
    @discardableResult
    public mutating func absorb(_ scan: Scan, replaying ledger: [AgentUsageEvent]? = nil, rememberDays: Int = UsageHistory.rememberIDsDays,
                                now: Date = .now, calendar: Calendar = .current) -> (changed: Bool, replayed: Bool) {
        var changed = merge(scan.events, now: now, calendar: calendar).changed
        for agent in scan.backfill.subtracting(backfilledAgents)
        where !scan.warnings.contains(where: { $0.hasPrefix("\(agent.name) history is still indexing") }) {
            backfilledAgents.insert(agent)
            changed = true
        }
        var replayed = false
        if let ledger, scan.enabled.isSubset(of: backfilledAgents) {
            changed = merge(ledger, now: now, calendar: calendar, keepPending: true).changed || changed
            replayed = true
        }
        if ledger == nil || replayed {
            changed = closeOldDays(now: now, olderThan: rememberDays, calendar: calendar) || changed
        }
        if changed { updateMilestones(now: now, calendar: calendar) }
        return (changed, replayed)
    }

    /// This history with every pending event folded in, for reading: profiles and milestones count today too.
    public func includingPending(calendar: Calendar = .current) -> UsageHistory {
        guard !pending.isEmpty else { return self }
        var copy = self
        var slots = SlotCache(calendar: calendar)
        var summary = MergeSummary()
        for event in pending.values.sorted(by: { $0.observedAt < $1.observedAt }) {
            copy.absorb(event, slots: &slots, summary: &summary)
        }
        copy.pending.removeAll()
        return copy
    }

    /// Folds a settled event into its day and session, unless the day already holds it or is closed to its agent.
    private mutating func absorb(_ incoming: AgentUsageEvent, slots: inout SlotCache, summary: inout MergeSummary) {
        let slot = slots.slot(for: incoming.observedAt)
        let agent = incoming.agent.rawValue
        if let boundary = closedBefore[agent], slot.day < boundary {
            summary.closed += 1
            return
        }
        guard days[slot.day, default: Day()].seen[agent, default: EventIDSet()].insert(EventIDSet.hash(incoming.id)) else {
            summary.repeats += 1
            return
        }
        let event = Self.trimmed(incoming)
        days[slot.day, default: Day()].add(event, hour: slot.hour)
        sessions[Session.key(event), default: Session(agent: event.agent, sessionID: event.sessionID)].add(event, day: slot.day)
        firstActivityAt = min(firstActivityAt ?? event.observedAt, event.observedAt)
        lastActivityAt = max(lastActivityAt ?? event.observedAt, event.observedAt)
        summary.folded += 1
    }

    /// The parts of an event the history keeps: no file paths, normalized tokens, a known effort level or none.
    static func trimmed(_ event: AgentUsageEvent) -> AgentUsageEvent {
        var trimmed = event
        trimmed.usage = event.usage.normalized()
        trimmed.projectPath = ""
        trimmed.sourcePath = ""
        trimmed.effort = AgentEffort.normalize(event.effort)
        return trimmed
    }

    /// Day key and clock hour of a moment, memoized per quarter hour (every time zone offset is a multiple of one).
    struct SlotCache {
        struct Slot { var day: String; var hour: Int }
        let calendar: Calendar
        private var memo: [Int: Slot] = [:]

        init(calendar: Calendar) { self.calendar = calendar }

        mutating func slot(for date: Date) -> Slot {
            let block = Int((date.timeIntervalSince1970 / 900).rounded(.down))
            if let hit = memo[block] { return hit }
            let slot = Slot(day: WeeklyReport.dayKey(date, calendar: calendar), hour: calendar.component(.hour, from: date))
            memo[block] = slot
            return slot
        }
    }

    /// Start of the day a `yyyy-MM-dd` key names, in `calendar`.
    public static func date(forDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: Storage

    /// `~/Library/Application Support/LocalObserver/usage-history.json`, next to the raw usage ledger.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("LocalObserver", isDirectory: true)
            .appendingPathComponent("usage-history.json", isDirectory: false)
    }

    public enum LoadResult: Sendable {
        case loaded(UsageHistory)
        case missing
        /// Written by a newer Lookout. Leave the file alone: don't write over it.
        case newerFormat
        /// Damaged. It has been moved to `preservedAt` rather than overwritten.
        case unreadable(preservedAt: URL?)
    }

    /// Reads the history at `url`. It may be the only copy of history the agents no longer have, so a file this build
    /// can't read is never overwritten: a newer format is left in place, a damaged file is moved aside.
    public static func load(from url: URL, fileManager: FileManager = .default) -> LoadResult {
        guard let data = fileManager.contents(atPath: url.path) else { return .missing }
        struct Header: Decodable { var version: Int }
        if let header = try? JSONDecoder().decode(Header.self, from: data), header.version > formatVersion { return .newerFormat }
        if let history = try? JSONDecoder().decode(UsageHistory.self, from: data) { return .loaded(history) }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent("usage-history.unreadable-\(stamp).json")
        do {
            try fileManager.moveItem(at: url, to: aside)
            return .unreadable(preservedAt: aside)
        } catch {
            return .unreadable(preservedAt: nil)
        }
    }

    public func write(to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case version, createdAt, firstActivityAt, lastActivityAt, days, sessions, pending, backfilledAgents, closedBefore
        case milestones, acknowledgedMilestones
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        firstActivityAt = try c.decodeIfPresent(Date.self, forKey: .firstActivityAt)
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        days = try c.decodeIfPresent([String: Day].self, forKey: .days) ?? [:]
        let sessionList = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        sessions = Dictionary(sessionList.map { ("\($0.agent.rawValue)|\($0.sessionID)", $0) }, uniquingKeysWith: { lhs, _ in lhs })
        let pendingList = try c.decodeIfPresent([AgentUsageEvent].self, forKey: .pending) ?? []
        pending = Dictionary(pendingList.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        backfilledAgents = try c.decodeIfPresent(Set<AgentKind>.self, forKey: .backfilledAgents) ?? []
        closedBefore = try c.decodeIfPresent([String: String].self, forKey: .closedBefore) ?? [:]
        let earned = try c.decodeIfPresent([EarnedMilestone].self, forKey: .milestones) ?? []
        milestones = Dictionary(earned.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        acknowledgedMilestones = try c.decodeIfPresent(Set<String>.self, forKey: .acknowledgedMilestones) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(firstActivityAt, forKey: .firstActivityAt)
        try c.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
        try c.encode(days, forKey: .days)
        try c.encode(sessions.values.sorted { ($0.firstAt, $0.sessionID) < ($1.firstAt, $1.sessionID) }, forKey: .sessions)
        try c.encode(pending.values.sorted { ($0.observedAt, $0.id) < ($1.observedAt, $1.id) }, forKey: .pending)
        try c.encode(backfilledAgents.sorted { $0.rawValue < $1.rawValue }, forKey: .backfilledAgents)
        try c.encode(closedBefore, forKey: .closedBefore)
        try c.encode(milestones.values.sorted { $0.id < $1.id }, forKey: .milestones)
        try c.encode(acknowledgedMilestones.sorted(), forKey: .acknowledgedMilestones)
    }
}

/// Additive usage counts. Every field sums, so tallies combine across hours, days and agents in any order.
public struct UsageTally: Hashable, Sendable {
    public var events = 0
    public var requests = 0
    /// Input plus output, cache reads included: the same "processed" the Usage page shows.
    public var processed: Int64 = 0
    public var input: Int64 = 0
    public var uncachedInput: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var output: Int64 = 0
    public var reasoning: Int64 = 0
    public var cost: Double = 0
    public var pricedEvents = 0
    public var estimatedCostEvents = 0
    public var cacheSavings: Double = 0

    public init() {}

    public var hasCost: Bool { pricedEvents > 0 }
    /// Some of the cost came from the price table rather than the agent's own report.
    public var costIsEstimated: Bool { estimatedCostEvents > 0 }
    /// Share of prompt tokens served from cache; nil without any prompt tokens.
    public var cacheHitRate: Double? {
        let prompt = cacheRead + cacheWrite + uncachedInput
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }

    /// Counts an event the way `AgentUsageTotals` does.
    public mutating func add(_ event: AgentUsageEvent) {
        let usage = event.usage.normalized()
        events += 1
        requests += event.requests ?? 1
        processed += usage.processedTokens ?? 0
        input += usage.inputTokens ?? 0
        uncachedInput += usage.derivedUncachedInputTokens ?? 0
        cacheRead += usage.cachedInputTokens ?? 0
        cacheWrite += usage.cacheCreationTokens ?? 0
        output += usage.outputTokens ?? 0
        reasoning += usage.reasoningTokens ?? 0
        if let value = event.cost {
            cost += value
            pricedEvents += 1
            if event.costIsEstimated { estimatedCostEvents += 1 }
        }
        cacheSavings += event.cacheSavings ?? 0
    }

    public mutating func add(_ other: UsageTally) {
        events += other.events
        requests += other.requests
        processed += other.processed
        input += other.input
        uncachedInput += other.uncachedInput
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        output += other.output
        reasoning += other.reasoning
        cost += other.cost
        pricedEvents += other.pricedEvents
        estimatedCostEvents += other.estimatedCostEvents
        cacheSavings += other.cacheSavings
    }

    // Unkeyed, in this order, so a cell is a short array. Missing trailing fields read as zero.
    init(from c: inout UnkeyedDecodingContainer) throws {
        func int() throws -> Int { c.isAtEnd ? 0 : try c.decode(Int.self) }
        func int64() throws -> Int64 { c.isAtEnd ? 0 : try c.decode(Int64.self) }
        func double() throws -> Double { c.isAtEnd ? 0 : try c.decode(Double.self) }
        events = try int()
        requests = try int()
        processed = try int64()
        input = try int64()
        uncachedInput = try int64()
        cacheRead = try int64()
        cacheWrite = try int64()
        output = try int64()
        reasoning = try int64()
        cost = try double()
        pricedEvents = try int()
        estimatedCostEvents = try int()
        cacheSavings = try double()
    }

    func encode(to c: inout UnkeyedEncodingContainer) throws {
        try c.encode(events)
        try c.encode(requests)
        try c.encode(processed)
        try c.encode(input)
        try c.encode(uncachedInput)
        try c.encode(cacheRead)
        try c.encode(cacheWrite)
        try c.encode(output)
        try c.encode(reasoning)
        try c.encode(cost)
        try c.encode(pricedEvents)
        try c.encode(estimatedCostEvents)
        try c.encode(cacheSavings)
    }
}

extension UsageTally: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        try self.init(from: &c)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try encode(to: &c)
    }
}

/// Hashed event ids, stored as one base64 string of sorted 64-bit FNV-1a hashes.
struct EventIDSet: Codable, Hashable, Sendable {
    private(set) var hashes: Set<UInt64> = []

    init() {}

    /// False when the hash was already there.
    mutating func insert(_ hash: UInt64) -> Bool { hashes.insert(hash).inserted }
    func contains(_ hash: UInt64) -> Bool { hashes.contains(hash) }

    /// FNV-1a: stable across launches, unlike `Hasher`.
    static func hash(_ id: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return value
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let data = Data(base64Encoded: text) else { return }
        var result = Set<UInt64>(minimumCapacity: data.count / 8)
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count - 7, by: 8) {
                result.insert(UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
            }
        }
        hashes = result
    }

    func encode(to encoder: Encoder) throws {
        var data = Data(capacity: hashes.count * 8)
        for hash in hashes.sorted() {
            withUnsafeBytes(of: hash.littleEndian) { data.append(contentsOf: $0) }
        }
        var c = encoder.singleValueContainer()
        try c.encode(data.base64EncodedString())
    }
}
