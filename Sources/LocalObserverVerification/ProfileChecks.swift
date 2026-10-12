import Foundation
import LocalObserverCore

/// The You page: the permanent history merges idempotently and never double counts, periods slice by day and hour,
/// the rhythm matrix and records add up, archetypes follow their stated thresholds (and say when there's too little
/// to go on), and milestones are earned once with the date they were reached.
enum ProfileChecks {
    @MainActor
    static func run() {
        checkIdempotentMerge()
        checkPendingAndRevisions()
        checkClosedDays()
        checkTimeZoneChange()
        checkScanOrdering()
        checkSpans()
        checkPeriodSlicing()
        checkRhythm()
        checkRecords()
        checkTrendsAndFirsts()
        checkModelNames()
        checkEffort()
        checkArchetypeRules()
        checkArchetypeSelection()
        checkInsufficientData()
        checkMilestones()
        checkStore()
    }

    private static let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }()

    /// 2026: October 5 and 12 are Mondays.
    private static func at(_ day: Int, _ hour: Int = 12, _ minute: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func event(_ id: String, _ at: Date, agent: AgentKind = .claude, session: String = "s1", tokens: Int64 = 1_000,
                              cached: Int64 = 0, cost: Double? = 0.5, model: String = "opus", project: String = "aurora",
                              effort: String? = nil) -> AgentUsageEvent {
        AgentUsageEvent(id: id, agent: agent, sessionID: session, projectPath: "/p/\(project)", projectName: project, model: model,
                        observedAt: at, usage: TokenUsage(inputTokens: tokens, cachedInputTokens: cached), cost: cost, requests: 1,
                        sourcePath: "/logs/\(session).jsonl", sourceKind: .transcript, effort: effort)
    }

    private static func recorded(_ events: [AgentUsageEvent], now: Date, createdAt: Date? = nil) -> UsageHistory {
        var history = UsageHistory(createdAt: createdAt ?? now)
        history.merge(events, now: now, calendar: cal)
        return history
    }

    private static func total(_ history: UsageHistory) -> UsageTally {
        history.days.values.reduce(into: UsageTally()) { $0.add($1.tally) }
    }

    // MARK: Ledger

    private static func checkIdempotentMerge() {
        let now = at(12, 9)
        let events = (1...5).flatMap { day in
            [event("a\(day)", at(day, 10), tokens: 1_000 * Int64(day)), event("b\(day)", at(day, 23, 30), agent: .codex, session: "c\(day)", tokens: 500, cost: nil, model: "gpt-5")]
        }
        var once = UsageHistory(createdAt: now)
        let first = once.merge(events, now: now, calendar: cal)
        precondition(first.folded == 10 && first.repeats == 0 && once.pending.isEmpty, "Settled events fold straight in")

        var twice = once
        let second = twice.merge(events, now: now, calendar: cal)
        precondition(!second.changed && second.repeats == 10 && twice == once, "Merging the same events again must change nothing")

        // Overlapping batches, in any order, land on the same totals.
        var halves = UsageHistory(createdAt: now)
        halves.merge(Array(events.suffix(6)), now: now, calendar: cal)
        halves.merge(events.reversed(), now: now, calendar: cal)
        let a = total(once), b = total(halves)
        precondition(a.processed == 17_500 && a.processed == b.processed && a.requests == b.requests && abs(a.cost - b.cost) < 1e-9,
                     "Overlapping merges should count each event once (got \(b.processed))")
        precondition(halves.days == once.days && halves.sessions.count == once.sessions.count, "Rollup layout shouldn't depend on arrival order")

        // A day keeps a bucket per agent, model, project and effort, and a cell per active hour.
        let day1 = once.days["2026-10-01"]!
        precondition(day1.buckets.count == 2 && day1.buckets.map(\.agent) == [.claude, .codex], "Buckets per agent and model")
        precondition(day1.buckets[1].hours.map(\.hour) == [23], "Hour cells in local time")

        // Storage round-trips exactly, and file paths never reach it.
        let data = try! JSONEncoder().encode(once)
        let decoded = try! JSONDecoder().decode(UsageHistory.self, from: data)
        precondition(decoded == once, "History should survive encoding")
        precondition(!String(decoding: data, as: UTF8.self).contains("/logs/"), "History shouldn't store transcript paths")
    }

    private static func checkPendingAndRevisions() {
        let now = at(12, 15)
        // A reply still streaming: 100 tokens, then revised to 300 under the same id.
        var history = recorded([event("live", at(12, 14), tokens: 100)], now: now)
        precondition(history.pending.count == 1 && history.days.isEmpty, "Recent events wait in pending")
        let revised = history.merge([event("live", at(12, 14), tokens: 300)], now: now, calendar: cal)
        precondition(revised.pendingChanged == 1 && history.pending["live"]?.usage.inputTokens == 300, "Pending events take revisions")
        precondition(history.profile(for: .week, now: now, calendar: cal).totals.tally.processed == 300, "Profiles count pending events")

        // An older copy replayed from the raw ledger doesn't overwrite what the scan just said.
        history.merge([event("live", at(12, 14), tokens: 100)], now: now, calendar: cal, keepPending: true)
        precondition(history.pending["live"]?.usage.inputTokens == 300, "Replays keep pending events as they are")

        // A day later it settles with its last counts; the stale copy arriving again is a repeat.
        let later = at(13, 16)
        let settled = history.merge([], now: later, calendar: cal)
        precondition(settled.folded == 1 && history.pending.isEmpty && total(history).processed == 300, "Pending events settle with their latest counts")
        let stale = history.merge([event("live", at(12, 14), tokens: 100)], now: later, calendar: cal)
        precondition(stale.repeats == 1 && total(history).processed == 300, "A settled event isn't counted twice")
    }

    private static func checkClosedDays() {
        let now = at(12)
        let old = event("old", at(1, 10, month: 1, year: 2025))
        var history = recorded([old], now: now)
        // Not backfilled yet: the day still remembers ids.
        precondition(!history.closeOldDays(now: now, calendar: cal), "Days stay open until the agent's backfill is done")
        history.backfilledAgents = [.claude]
        precondition(history.closeOldDays(now: now, calendar: cal), "Old days close once the agent is backfilled")
        let again = history.merge([old], now: now, calendar: cal)
        precondition(again.closed == 1 && total(history).events == 1, "Closed days ignore repeats without their ids")
        // An agent never backfilled can still bring that day's history in.
        let codex = history.merge([event("codex-old", at(1, 11, month: 1, year: 2025), agent: .codex, session: "c")], now: now, calendar: cal)
        precondition(codex.folded == 1 && total(history).events == 2, "Closed days stay open to agents not backfilled yet")
    }

    /// Travel, DST and calendar settings move day keys; ids re-read under them must still be repeats.
    private static func checkTimeZoneChange() {
        // 23:30 and 00:30 in Paris fall on the next day in Tokyo and the day before in Los Angeles.
        let events = [event("late", at(5, 23, 30)), event("early", at(6, 0, 30)), event("noon", at(6, 12))]
        let now = at(12)
        var history = recorded(events, now: now)
        let before = total(history)
        for zone in ["Asia/Tokyo", "America/Los_Angeles", "Pacific/Kiritimati"] {
            var away = cal
            away.timeZone = TimeZone(identifier: zone)!
            let again = history.merge(events, now: now, calendar: away)
            precondition(again.folded == 0 && again.repeats == 3, "Events re-read in \(zone) must be repeats (folded \(again.folded))")
        }
        // A Buddhist calendar in the same zone keys the same Gregorian days.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = cal.timeZone
        let other = history.merge(events, now: now, calendar: buddhist)
        precondition(other.folded == 0 && total(history) == before, "A different calendar must not renumber the days")
        precondition(UsageHistory.dayKey(at(6), calendar: buddhist) == "2026-10-06" && history.days.keys.sorted() == ["2026-10-05", "2026-10-06"],
                     "Day keys are Gregorian")
        precondition(UsageHistory.date(forDayKey: "2026-10-06", calendar: buddhist) == cal.startOfDay(for: at(6)), "Day keys read back in any calendar")
    }

    private static func checkScanOrdering() {
        let now = at(12)
        // The raw ledger still has a Claude event from 200 days ago whose transcript is gone, and last week's event
        // without effort. The backfill scan has last week's event with its effort, and old Codex history.
        let ledger = [event("gone", now.addingTimeInterval(-200 * 86_400), session: "gone"), event("recent", at(5, 10))]
        let scanned = [event("recent", at(5, 10), effort: "high"),
                       event("codex-old", now.addingTimeInterval(-300 * 86_400), agent: .codex, session: "cx")]
        let enabled: Set<AgentKind> = [.claude, .codex]
        var history = UsageHistory(createdAt: now)
        // Codex is still indexing: no replay yet, and nothing closes.
        let first = history.absorb(.init(events: scanned, warnings: ["Codex history is still indexing (3 files left)"], enabled: enabled, backfill: enabled),
                                   replaying: ledger, rememberDays: 125, now: now, calendar: cal)
        precondition(first.changed && !first.replayed && history.backfilledAgents == [.claude], "Replay waits for every backfill")
        precondition(history.milestones.isEmpty, "Milestones wait for every backfill, so they aren't dated off half the history")
        // Backfill done: the ledger replays before old days close, so the deleted transcript's event still lands.
        let second = history.absorb(.init(events: scanned, enabled: enabled, backfill: [.codex]), replaying: ledger, rememberDays: 125, now: now, calendar: cal)
        precondition(second.replayed && total(history).events == 3, "Events whose logs are gone are replayed in")
        precondition(history.days["2026-10-05"]?.buckets.map(\.effort) == ["high"], "The scan's copy wins over the ledger's")
        // The next launch replays again and changes nothing.
        let third = history.absorb(.init(events: scanned, enabled: enabled), replaying: ledger, rememberDays: 125, now: now, calendar: cal)
        precondition(third.replayed && !third.changed && total(history).events == 3, "Replays are idempotent")
        precondition(history.milestones["first.codex"] != nil, "Milestones follow the scan")
    }

    private static func checkSpans() {
        // Requests ≤15 minutes apart join one stretch; a 20-minute gap starts another. Order of arrival doesn't matter.
        let t = at(5, 10)
        let times = [0, 600, 1_200, 2_400, 3_000].map { t.addingTimeInterval(TimeInterval($0)) }
        let events = times.enumerated().map { event("e\($0.offset)", $0.element) }
        let forward = recorded(events, now: at(12))
        let backward = recorded(events.reversed(), now: at(12))
        let session = forward.sessions.values.first!
        precondition(session.intervals.count == 2 && session.activeSeconds == 1_800, "Spans should join within the idle gap (got \(session.activeSeconds))")
        precondition(backward.sessions.values.first == session, "Spans shouldn't depend on arrival order")
        // A late request bridging the gap merges the two stretches.
        var bridged = forward
        bridged.merge([event("bridge", t.addingTimeInterval(1_800))], now: at(12), calendar: cal)
        precondition(bridged.sessions.values.first?.intervals.count == 1 && bridged.sessions.values.first?.activeSeconds == 3_000, "A late event should bridge spans")
    }

    // MARK: Periods

    private static func checkPeriodSlicing() {
        // Now: Wednesday 14 October, 15:30. This week runs Monday the 12th to the 19th.
        let now = at(14, 15, 30)
        let events = [
            event("lastMon", at(5, 10), tokens: 1_000), event("lastWed3pm", at(7, 15), tokens: 2_000), event("lastWed4pm", at(7, 16), tokens: 4_000),
            event("lastSun", at(11, 12), tokens: 8_000), event("mon", at(12, 10), tokens: 16_000), event("wed", at(14, 9), tokens: 32_000),
            event("sept", at(10, 12, month: 9), tokens: 64_000), event("2025", at(3, 12, month: 3, year: 2025), tokens: 128_000),
        ]
        let history = recorded(events, now: now)

        let week = history.profile(for: .week, now: now, calendar: cal)
        precondition(week.interval.start == at(12, 0) && week.interval.end == at(19, 0) && week.covered.end == now && week.isPartial, "Week bounds")
        precondition(week.totals.tally.processed == 48_000 && week.coveredDays == 3, "Week totals (got \(week.totals.tally.processed))")
        // Last week cut to Monday → Wednesday 15:30: the 15:00 hour is in, 16:00 and Sunday are out.
        precondition(week.trends?.previous.end == at(7, 15, 30) && week.trends?.previousTotals.tally.processed == 3_000,
                     "Previous week should be cut to the same stretch (got \(week.trends?.previousTotals.tally.processed ?? -1))")
        precondition(week.trends?.tokens == 15, "Token change against the cut week")

        let month = history.profile(for: .month, now: now, calendar: cal)
        precondition(month.totals.tally.processed == 63_000 && month.trends?.previousTotals.tally.processed == 64_000, "Month and the same stretch of September")
        precondition(history.profile(for: .lastDays(7), now: now, calendar: cal).totals.tally.processed == 56_000, "Last 7 days")
        let year2025 = history.profile(for: .calendarYear(2025, calendar: cal), now: now, calendar: cal)
        precondition(year2025.totals.tally.processed == 128_000 && !year2025.isPartial, "A past year in review")
        let wrapped = ProfilePeriod.calendarYear(2025, calendar: cal), wrappedSpan = wrapped.interval(now: now, calendar: cal)
        precondition(wrapped.previous(of: wrappedSpan, covered: wrappedSpan, calendar: cal) == DateInterval(start: at(1, 0, month: 1, year: 2024), end: at(1, 0, month: 1, year: 2025)),
                     "A calendar year compares with the whole year before, leap day and all")
        precondition(year2025.trends == nil, "No trends against a year with no activity")
        let all = history.profile(for: .allTime, now: now, calendar: cal)
        precondition(all.totals.tally.processed == 255_000 && all.trends == nil && all.interval.start == at(3, 0, month: 3, year: 2025), "All time")
        precondition(all.firsts.memberSince == at(3, 0, month: 3, year: 2025), "Member since is the first active day")
        let empty = UsageHistory(createdAt: now).profile(for: .allTime, now: now, calendar: cal)
        precondition(empty.isEmpty && empty.totals.activeDays == 0 && empty.records.longestStreak == nil, "An empty history profiles as empty")
    }

    private static func checkRhythm() {
        // Week of the 12th: Saturday 23:00 ×3, Monday 06:00 ×1, Tuesday 14:00 ×2.
        let events = (0..<3).map { event("sat\($0)", at(17, 23, $0)) } + [event("mon", at(12, 6))] + (0..<2).map { event("tue\($0)", at(13, 14, $0)) }
        let history = recorded(events, now: at(30))
        let rhythm = history.profile(for: .custom(DateInterval(start: at(12, 0), end: at(19, 0))), now: at(30), calendar: cal).rhythm
        precondition(rhythm.requests[6][23] == 3 && rhythm.requests[1][6] == 1 && rhythm.requests[2][14] == 2 && rhythm.total == 6, "Weekday × hour matrix")
        precondition(rhythm.busiestWeekday == 7 && rhythm.peakHour == 23, "Busiest weekday and peak hour")
        precondition(abs(rhythm.nightShare - 0.5) < 1e-9 && abs(rhythm.earlyShare - 1.0 / 6) < 1e-9 && abs(rhythm.weekendShare - 0.5) < 1e-9 && rhythm.weekendDays == 1,
                     "Night, early and weekend shares")
        precondition(rhythm.rows(firstWeekday: 2).map(\.weekday) == [2, 3, 4, 5, 6, 7, 1], "Rows start on the first weekday")
    }

    private static func checkRecords() {
        let base = at(5, 10)
        func t(_ minutes: Int) -> Date { base.addingTimeInterval(TimeInterval(minutes * 60)) }
        let events = [
            // Three sessions overlap at 10:12: A 10:00→10:20, B 10:05→10:15, C a lone request at 10:12.
            event("a1", t(0), session: "A", tokens: 2_000), event("a2", t(10), session: "A", tokens: 2_000), event("a3", t(20), session: "A", tokens: 1_000, cost: 1),
            event("b1", t(5), agent: .codex, session: "B", cost: nil), event("b2", t(15), agent: .codex, session: "B", cost: nil),
            event("c1", t(12), session: "C"),
            // Tuesday: fewer tokens, more money.
            event("d1", at(6, 9), session: "D", tokens: 3_000, cost: 4),
            // Thursday and Friday: a break on Wednesday, so the longest run is Monday–Tuesday... then Thu–Fri–Sat.
            event("e1", at(8, 9), session: "E"), event("f1", at(9, 9), session: "F"), event("g1", at(10, 9), session: "G"),
        ]
        let now = at(10, 20)
        let profile = recorded(events, now: at(12)).profile(for: .allTime, now: now, calendar: cal)
        let records = profile.records
        precondition(records.biggestDayByTokens?.date == at(5, 0) && records.biggestDayByTokens?.tally.processed == 8_000, "Biggest day by tokens")
        precondition(records.biggestDayByCost?.date == at(6, 0) && records.biggestDayByCost?.tally.cost == 4, "Biggest day by cost")
        precondition(records.longestSession?.sessionID == "A" && records.longestSession?.activeSeconds == 1_200, "Longest session")
        precondition(records.peakConcurrent?.sessions == 3 && records.peakConcurrent?.at == t(12), "Peak concurrency (got \(records.peakConcurrent?.sessions ?? 0))")
        precondition(profile.days(withAtLeast: 3) == 1 && profile.dailyPeakConcurrency[at(5, 0)] == 3, "Days with 3+ at once")
        precondition(records.longestStreak?.days == 3 && records.longestStreak?.start == at(8, 0), "Longest streak")
        precondition(records.currentStreak == 3, "Current streak through today")
        precondition(profile.totals.activeSeconds == 1_200 && profile.totals.sessions == 7, "Active time merges overlapping sessions")
        precondition(profile.providers.first?.agent == .claude && profile.providers.first?.activeSeconds == 1_200
                     && profile.providers.last?.activeSeconds == 600, "Active time per agent")
        // The day after, nothing yet: yesterday's streak still stands. Two days after, it's gone.
        let history = recorded(events, now: at(12))
        precondition(history.profile(for: .allTime, now: at(11, 8), calendar: cal).records.currentStreak == 3, "Streak survives until today ends")
        precondition(history.profile(for: .allTime, now: at(12, 8), calendar: cal).records.currentStreak == 0, "A missed day ends the streak")
    }

    private static func checkTrendsAndFirsts() {
        // Last week on Sonnet through Claude Code; this week on Opus, with Codex for the first time.
        let last = (5...9).flatMap { day in (0..<4).map { event("l\(day)-\($0)", at(day, 10, $0), session: "l\(day)", model: "claude-sonnet-4-5") } }
        let this = (12...16).flatMap { day in (0..<6).map { event("t\(day)-\($0)", at(day, 10, $0), session: "t\(day)", model: "claude-opus-4-1") } }
            + [event("codex", at(14, 11), agent: .codex, session: "x", model: "gpt-5")]
        let profile = recorded(last + this, now: at(19)).profile(for: .week, now: at(18, 23), calendar: cal)
        precondition(profile.trends?.topModel?.from == "Sonnet 4.5" && profile.trends?.topModel?.to == "Opus 4.1", "Top model shift")
        precondition(profile.trends?.topModel?.sentence == "Moved from Sonnet 4.5 to Opus 4.1", "Shift sentence")
        precondition(profile.trends?.topProvider == nil && abs((profile.trends?.requests ?? 0) - 0.55) < 1e-9, "Provider unchanged; requests up 55%")
        precondition(profile.firsts.newModels.sorted() == ["GPT-5", "Opus 4.1"] && profile.firsts.newProviders == [.codex], "Firsts this period")
        precondition(profile.firsts.providers.map(\.agent) == [.claude, .codex] && profile.firsts.providers.first?.date == at(5, 10), "First use per agent")
        precondition(profile.models.first?.agent == .claude && abs(profile.models.first!.share - 30.0 / 31) < 1e-9, "Model shares by requests")
    }

    private static func checkModelNames() {
        let names: [(raw: String, friendly: String)] = [
            ("claude-opus-4-1", "Opus 4.1"), ("claude-sonnet-4-5-20250929", "Sonnet 4.5"), ("claude-opus-5-5", "Opus 5.5"),
            ("claude-haiku-4-5", "Haiku 4.5"), ("claude-haiku-4.5", "Haiku 4.5"), ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
            ("anthropic/claude-opus-4-1", "Opus 4.1"), ("gpt-5-codex", "GPT-5 Codex"), ("gpt-5", "GPT-5"),
            ("gpt-4o-2024-08-06", "GPT-4o"), ("gemini-2.5-pro", "Gemini 2.5 Pro"), ("gemini-3-flash-preview", "Gemini 3 Flash Preview"),
            ("o3", "o3"), ("o4-mini", "o4 Mini"), ("qoder-auto", "Qoder Auto"), ("MyModel", "MyModel"), ("", ""),
        ]
        for name in names {
            precondition(AgentFormat.modelDisplayName(name.raw) == name.friendly, "Friendly name for \(name.raw)")
        }
        // Dated and undated ids of one model are one row, named once.
        let dated = [event("h1", at(12, 10), model: "claude-haiku-4-5"), event("h2", at(12, 11), model: "claude-haiku-4-5-20251001")]
        let profile = recorded(dated, now: at(19)).profile(for: .month, now: at(19), calendar: cal)
        precondition(profile.models.map(\.title) == ["Haiku 4.5"] && profile.models.first?.tally.requests == 2, "Dated variants merge into one model row")
    }

    private static func checkEffort() {
        // 4 high, 2 low, 4 unknown: effort covers 60% of requests; high is 4 of the 6 known.
        let efforts: [String?] = ["high", "high", "High", "high", "low", "low", nil, nil, nil, nil]
        let events = efforts.enumerated().map { event("e\($0.offset)", at(5, 10, $0.offset), effort: $0.element) }
        let effort = recorded(events, now: at(12)).profile(for: .allTime, now: at(12), calendar: cal).effort
        precondition(abs(effort.coverage - 0.6) < 1e-9 && effort.knownRequests == 6, "Effort coverage counts only known levels")
        precondition(effort.levels.map(\.id) == ["high", "low"] && abs(effort.levels[0].share - 4.0 / 6) < 1e-9, "Effort shares are of known requests")
        precondition(abs((effort.highShare ?? 0) - 4.0 / 6) < 1e-9, "High-effort share")
        let unknown = recorded([event("u", at(5, 10))], now: at(12)).profile(for: .allTime, now: at(12), calendar: cal).effort
        precondition(unknown.coverage == 0 && unknown.levels.isEmpty && unknown.highShare == nil, "Unknown effort is never guessed")
    }

    // MARK: Archetypes

    private static func checkArchetypeRules() {
        let night = ProfileArchetypes.rule(for: .nightShift)!
        precondition(night.strength(0.25) == 0 && night.strength(0.2499) == nil && night.strength(0.6) == 1, "Rising rule edges")
        let sprinter = ProfileArchetypes.rule(for: .sprinter)!
        precondition(sprinter.strength(300) == 0 && sprinter.strength(301) == nil && sprinter.strength(30) == 1, "Falling rule edges")
        precondition(ProfileArchetypes.rules.count == ProfileArchetype.allCases.count - 2, "Every archetype but the defaults has a rule")
        for archetype in ProfileArchetype.allCases {
            precondition(!archetype.name.isEmpty && !archetype.tagline.isEmpty, "\(archetype) needs a name and tagline")
        }
    }

    /// Four weekdays of 25 single-request sessions each; `night` of the 100 requests at 23:00, the rest at noon.
    private static func nightHistory(night: Int, providers: [AgentKind] = [.claude]) -> UsageHistory {
        let events = (0..<100).map { i -> AgentUsageEvent in
            let day = 5 + i % 4
            let agent = providers[i % providers.count]
            return event("n\(i)", at(day, i < night ? 23 : 12, i / 4), agent: agent, session: "n\(i)")
        }
        return recorded(events, now: at(12), createdAt: at(1))
    }

    private static func checkArchetypeSelection() {
        let period = ProfilePeriod.custom(DateInterval(start: at(5, 0), end: at(9, 0)))
        // Exactly at the threshold qualifies, and a habit leads over a trait however strong.
        let edge = nightHistory(night: 25).profile(for: period, now: at(30), calendar: cal).archetype
        precondition(edge.primary?.archetype == .nightShift && edge.primary?.strength == 0, "25% at night is Night Shift (got \(String(describing: edge.primary?.archetype)))")
        precondition(edge.secondary?.archetype == .loyalist && edge.secondary?.strength == 1, "Loyalty is the secondary trait")
        precondition(edge.primary?.sentence == "25% of requests between 22:00 and 04:00" && edge.primary?.facts.first?.id == "nightShare", "Evidence sentence and facts")
        // Just under: no habit qualifies, so the trait leads.
        let under = nightHistory(night: 24).profile(for: period, now: at(30), calendar: cal).archetype
        precondition(under.primary?.archetype == .loyalist && under.secondary == nil && under.qualified.count == 1, "Traits lead only without a habit")
        // Two agents half and half, nothing else: the All-Rounder, not an invented archetype.
        let even = nightHistory(night: 0, providers: [.claude, .codex]).profile(for: period, now: at(30), calendar: cal).archetype
        precondition(even.primary?.archetype == .allRounder && even.qualified.isEmpty && even.insufficientData == nil, "Nothing stands out")

        // Conductor: three sessions at once on 2 of 8 active days is exactly 25%.
        func conductor(parallelDays: Int) -> ArchetypeResult {
            let events = (0..<8).flatMap { d -> [AgentUsageEvent] in
                let day = 5 + d
                let lanes = d < parallelDays ? 3 : 1
                return (0..<lanes).flatMap { lane in
                    (0..<7).map { i in event("c\(d)-\(lane)-\(i)", at(day, 10 + lane * (d < parallelDays ? 0 : 1), i * 5), agent: lane == 1 ? .codex : .claude, session: "c\(d)-\(lane)") }
                }
            }
            return recorded(events, now: at(30), createdAt: at(1)).profile(for: .custom(DateInterval(start: at(5, 0), end: at(13, 0))), now: at(30), calendar: cal).archetype
        }
        let parallel = conductor(parallelDays: 2)
        precondition(parallel.primary?.archetype == .conductor && parallel.primary?.strength == 0, "2 of 8 days with 3 at once is a Conductor")
        precondition(parallel.primary?.sentence == "3+ agents at once on 2 of 8 active days, up to 3 at once", "Conductor evidence")
        precondition(conductor(parallelDays: 1).qualified.allSatisfy { $0.archetype != .conductor }, "One parallel day isn't enough")
    }

    private static func checkInsufficientData() {
        // Two days in: just getting started, and the model says why.
        let fresh = recorded([event("a", at(10, 10)), event("b", at(11, 10))], now: at(12), createdAt: at(10))
            .profile(for: .allTime, now: at(12), calendar: cal).archetype
        precondition(fresh.primary?.archetype == .gettingStarted && fresh.insufficientData != nil && fresh.qualified.isEmpty, "New users are just getting started")
        precondition(fresh.primary?.sentence == "2 active days so far", "Getting started evidence")

        // A long history, but one quiet day this period: no archetype, and a reason.
        let old = (1...20).map { event("o\($0)", at($0, 10, month: 8), session: "o\($0)") } + [event("now", at(13, 10))]
        let quiet = recorded(old, now: at(14), createdAt: at(1, 0, month: 8)).profile(for: .week, now: at(14), calendar: cal).archetype
        precondition(quiet.primary == nil && quiet.insufficientData?.hasPrefix("Not enough activity in this period") == true, "Thin periods say so")
        let empty = recorded(old, now: at(14), createdAt: at(1, 0, month: 8)).profile(for: .custom(DateInterval(start: at(1, 0, month: 9), end: at(8, 0, month: 9))), now: at(14), calendar: cal).archetype
        precondition(empty.primary == nil && empty.insufficientData == "No agent activity in this period.", "Empty periods say so")

        // Deep Thinker reads effort only where it's known for half the requests.
        func thinker(known: Int) -> ArchetypeResult {
            let events = (0..<60).map { i in event("t\(i)", at(5 + i % 3, 12, i), session: "t\(i)", effort: i < known ? "xhigh" : nil) }
            return recorded(events, now: at(30), createdAt: at(1)).profile(for: .custom(DateInterval(start: at(5, 0), end: at(8, 0))), now: at(30), calendar: cal).archetype
        }
        precondition(thinker(known: 30).primary?.archetype == .deepThinker, "Effort known for half the requests is enough")
        precondition(thinker(known: 29).qualified.allSatisfy { $0.archetype != .deepThinker }, "Too little known effort")
    }

    // MARK: Milestones

    private static func checkMilestones() {
        // 600K on the 1st, 500K on the 2nd at 09:00 crosses 1M; seven days running; Codex first seen on the 3rd.
        var events = [event("m1", at(1, 10), tokens: 600_000), event("m2", at(2, 9), session: "s2", tokens: 500_000)]
        events += (3...7).map { event("d\($0)", at($0, 10), session: "d\($0)") }
        events.append(event("cx", at(3, 11), agent: .codex, session: "cx"))
        events += (0..<93).map { event("s\($0)", at(20, 10, $0 % 60), session: "many\($0)") }
        var history = recorded(events, now: at(25), createdAt: at(25))

        let recorded = at(25)
        let earned = history.updateMilestones(now: recorded, calendar: cal)
        let byID = Dictionary(uniqueKeysWithValues: earned.map { ($0.id, $0) })
        precondition(byID["tokens.1M"]?.earnedAt == at(2, 9) && byID["tokens.10M"] == nil, "1M tokens reached in the hour it was crossed")
        precondition(byID["streak.7"]?.earnedAt == at(7, 0) && byID["streak.30"] == nil, "7-day streak on its seventh day")
        precondition(byID["first.claude"]?.earnedAt == at(1, 10) && byID["first.codex"]?.earnedAt == at(3, 11), "First use per agent")
        precondition(byID["sessions.100"] != nil && byID["sessions.1000"] == nil, "100 sessions")
        precondition(byID["anniversary.1m"] == nil, "No anniversary before its day")
        precondition(byID["tokens.1M"]?.isRetroactive == true && earned.map(\.earnedAt) == earned.map(\.earnedAt).sorted(), "Backfilled milestones carry their real dates")

        // Earned once: a later check adds only what's new and never re-dates.
        let later = history.updateMilestones(now: at(2, 12, month: 11), calendar: cal)
        precondition(later.map(\.id) == ["anniversary.1m"] && later[0].earnedAt == at(1, 10, month: 11), "Anniversaries arrive on their day")
        precondition(history.milestones["tokens.1M"]?.recordedAt == recorded, "Recorded milestones never change")

        // Celebrated ones drop out of the new list, and all of it persists.
        precondition(history.unacknowledgedMilestones.count == earned.count + 1, "Everything starts uncelebrated")
        history.acknowledgeMilestones(["tokens.1M", "streak.7", "nonexistent"])
        precondition(history.unacknowledgedMilestones.count == earned.count - 1 && history.acknowledgedMilestones == ["tokens.1M", "streak.7"], "Acknowledged milestones")
        var decoded = try! JSONDecoder().decode(UsageHistory.self, from: try! JSONEncoder().encode(history))
        precondition(decoded.milestones == history.milestones && decoded.acknowledgedMilestones == history.acknowledgedMilestones, "Milestones persist")
        precondition(decoded.updateMilestones(now: at(3, 12, month: 11), calendar: cal).isEmpty, "Nothing is earned twice after reloading")
    }

    @MainActor
    private static func checkStore() {
        // Demo data fills the history in memory, so the You page renders in snapshots without touching disk.
        let defaults = UserDefaults(suiteName: "LocalObserver.ProfileChecks")!
        let store = AgentStore(defaults: defaults, autoStart: false, persistsLedger: false)
        let snapshot = AgentSnapshot(discoveredAt: at(12), processes: [], sessions: [], usageEvents: [], limitReports: [], integrations: [], warnings: [])
        store.loadDemo(snapshot: snapshot, ledger: (1...9).map { event("demo\($0)", at($0, 10), session: "demo\($0)", tokens: 200_000) }, limits: [])
        precondition(store.history.days.count == 9 && store.historyRevision > 0, "Demo history")
        precondition(store.newMilestones.contains { $0.id == "tokens.1M" }, "Demo milestones")
        store.acknowledgeMilestones(["tokens.1M"])
        precondition(!store.newMilestones.contains { $0.id == "tokens.1M" }, "Acknowledging through the store")
        defaults.removePersistentDomain(forName: "LocalObserver.ProfileChecks")
    }
}
