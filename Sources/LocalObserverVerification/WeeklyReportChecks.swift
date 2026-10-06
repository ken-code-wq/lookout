import Foundation
import LocalObserverCore

/// Weekly report: weeks start on the calendar's first weekday, empty weeks stay empty, a week under way covers up
/// to now and compares with the same stretch of last week, and active time merges overlapping agents.
enum WeeklyReportChecks {
    static func run() {
        checkBoundaries()
        checkEmptyWeek()
        checkPartialWeek()
        checkActiveTime()
        checkStreakAndContributions()
    }

    private static func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private static func date(_ calendar: Calendar, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func event(_ id: String, _ at: Date, agent: AgentKind = .claude, session: String = "s1", tokens: Int64 = 1_000,
                              cost: Double? = 0.5, model: String = "opus", project: String = "aurora") -> AgentUsageEvent {
        AgentUsageEvent(id: id, agent: agent, sessionID: session, projectPath: "/p/\(project)", projectName: project, model: model,
                        observedAt: at, usage: TokenUsage(inputTokens: tokens), cost: cost, requests: 1, sourcePath: "",
                        sourceKind: .transcript)
    }

    private static func checkBoundaries() {
        // Tuesday 6 October 2026. Monday-first weeks start on the 5th; Sunday-first on the 4th.
        let monday = calendar(firstWeekday: 2), sunday = calendar(firstWeekday: 1)
        let tuesday = date(monday, 6)
        let mondayWeek = WeeklyReport.week(containing: tuesday, calendar: monday)
        precondition(mondayWeek.start == date(monday, 5, 0) && mondayWeek.end == date(monday, 12, 0), "Monday-first week bounds wrong")
        let sundayWeek = WeeklyReport.week(containing: tuesday, calendar: sunday)
        precondition(sundayWeek.start == date(sunday, 4, 0) && sundayWeek.end == date(sunday, 11, 0), "Sunday-first week bounds wrong")
        // Sunday 11th, 23:30: last day of a Monday-first week, first day of a Sunday-first one.
        let lateSunday = date(monday, 11, 23, 30)
        precondition(WeeklyReport.week(containing: lateSunday, calendar: monday).start == date(monday, 5, 0), "Sunday belongs to Monday's week")
        precondition(WeeklyReport.week(containing: lateSunday, calendar: sunday).start == date(sunday, 11, 0), "Sunday starts a Sunday-first week")
        precondition(WeeklyReport.week(offset: -1, from: tuesday, calendar: monday).start == date(monday, 28, 0, month: 9), "Previous week across a month")

        // Events land in the week by their own time: 23:59 Sunday is in, 00:00 the next Monday is out.
        let events = [event("in", date(monday, 11, 23, 59)), event("out", date(monday, 12, 0)), event("before", date(monday, 4, 23, 59))]
        let report = WeeklyReport.build(events: events, weekOf: tuesday, now: date(monday, 20), calendar: monday)
        precondition(report.totals.events == 1 && report.days.count == 7 && report.days[6].processed == 1_000, "Week edges assigned wrong")
        precondition(report.days.first?.date == date(monday, 5, 0), "Days should start on the first weekday")

        // Across the clocks going back (25 October in Paris): still seven days, each starting at midnight.
        let dst = WeeklyReport.build(events: [], weekOf: date(monday, 22), now: date(monday, 30), calendar: monday)
        precondition(dst.days.count == 7 && dst.days.allSatisfy { monday.component(.hour, from: $0.date) == 0 }, "DST week days wrong")
    }

    private static func checkEmptyWeek() {
        let cal = calendar(firstWeekday: 2)
        let report = WeeklyReport.build(events: [event("old", date(cal, 1, month: 9))], weekOf: date(cal, 7), now: date(cal, 20), calendar: cal)
        precondition(report.isEmpty && report.byAgent.isEmpty && report.activeSeconds == 0 && report.activeDays == 0, "Empty week should be empty")
        precondition(!report.isPartial && report.coveredDays == 7, "A past week is complete")
        precondition(WeeklyReport.change(10, 0) == nil && WeeklyReport.change(15, 10) == 0.5, "Change against nothing is unknown, not infinite")
    }

    private static func checkPartialWeek() {
        let cal = calendar(firstWeekday: 2)
        // Now: Tuesday the 6th at 12:00. Last week has Monday, Tuesday-morning and Thursday events.
        let now = date(cal, 6, 12)
        let events = [
            event("lastMon", date(cal, 28, 10, month: 9), tokens: 2_000), event("lastTueAM", date(cal, 29, 9, month: 9), tokens: 3_000),
            event("lastTuePM", date(cal, 29, 15, month: 9), tokens: 4_000), event("lastThu", date(cal, 1, 10), tokens: 5_000),
            event("mon", date(cal, 5, 10), tokens: 6_000, cost: nil), event("tue", date(cal, 6, 9), agent: .codex, tokens: 1_000, model: "gpt"),
            event("future", date(cal, 6, 18), tokens: 9_000),
        ]
        let report = WeeklyReport.build(events: events, weekOf: now, now: now, calendar: cal)
        precondition(report.isPartial && report.through == now && report.coveredDays == 2, "Current week should cover up to now")
        precondition(report.totals.processed == 7_000 && report.days[2].isFuture && !report.days[1].isFuture, "Partial week totals wrong")
        precondition(report.byAgent.map(\.agent) == [.claude, .codex] && abs(report.byAgent[0].share - 6.0 / 7) < 0.0001, "Agent rows wrong")
        precondition(report.byModel.first?.title == "opus" && report.byModel.first?.agent == .claude, "Model rows wrong")
        precondition(abs(report.totals.cost - 0.5) < 0.0001 && report.totals.sessions == 2, "Cost and sessions wrong")

        // Last week cut to the same stretch: Monday plus Tuesday until noon, not the afternoon or Thursday.
        let previous = WeeklyReport.previous(to: report, events: events, calendar: cal)
        precondition(previous.through == date(cal, 29, 12, month: 9) && previous.totals.processed == 5_000,
                     "Partial comparison should match the same days and hours (got \(previous.totals.processed))")
        let full = WeeklyReport.build(events: events, weekOf: date(cal, 30, month: 9), now: now, calendar: cal)
        precondition(!full.isPartial && full.totals.processed == 14_000, "A finished week covers all of it")
        precondition(WeeklyReport.previous(to: full, events: events, calendar: cal).week.start == date(cal, 21, 0, month: 9), "Previous of a full week")
    }

    private static func checkActiveTime() {
        let cal = calendar(firstWeekday: 2)
        let t = date(cal, 5, 10)
        let events = [
            // Session A: 10:00 → 10:10 → 10:20 continuous; then a 40-minute gap; a lone request at 11:00 adds nothing.
            event("a1", t, session: "A"), event("a2", t.addingTimeInterval(600), session: "A"), event("a3", t.addingTimeInterval(1_200), session: "A"),
            event("a4", t.addingTimeInterval(3_600), session: "A"),
            // Codex working alongside 10:05 → 10:30: overlaps A, so wall-clock time is 10:00 → 10:30.
            event("b1", t.addingTimeInterval(300), agent: .codex, session: "B"), event("b2", t.addingTimeInterval(1_000), agent: .codex, session: "B"),
            event("b3", t.addingTimeInterval(1_800), agent: .codex, session: "B"),
        ]
        let spans = WeeklyReport.activeSpans(events)
        precondition(spans.count == 1 && spans[0].duration == 1_800, "Active spans should merge overlapping agents (got \(spans.map(\.duration)))")
        let report = WeeklyReport.build(events: events, weekOf: t, now: date(cal, 20), calendar: cal)
        precondition(report.activeSeconds == 1_800 && report.days[0].activeSeconds == 1_800, "Active time per day wrong")
    }

    private static func checkStreakAndContributions() {
        let cal = calendar(firstWeekday: 2)
        // Active Fri 2nd → Mon 5th; today (Tue 6th) empty so far: the streak still stands at 4.
        let events = (2...5).map { event("d\($0)", date(cal, $0, 10)) }
        let now = date(cal, 6, 8)
        let report = WeeklyReport.build(events: events, weekOf: now, now: now, calendar: cal)
        precondition(report.streak == 4, "Streak should count back past the week's start (got \(report.streak))")
        // A finished week whose last day was empty: the streak at its end is broken.
        let gap = WeeklyReport.build(events: [event("x", date(cal, 1, 10))], weekOf: date(cal, 1), now: now, calendar: cal)
        precondition(gap.streak == 0, "An empty last day ends a finished week's streak")

        // Contributions count only when the graph covers every day so far.
        let graph = ["2026-10-05": 3, "2026-10-06": 2]
        precondition(report.contributions == nil, "No graph, no contributions")
        let withGraph = WeeklyReport.build(events: events, weekOf: now, now: now, calendar: cal, contributions: graph)
        precondition(withGraph.contributions == 5 && withGraph.days[0].contributions == 3 && withGraph.days[3].contributions == nil,
                     "Contributions should sum the covered days")
        let partialGraph = WeeklyReport.build(events: events, weekOf: now, now: now, calendar: cal, contributions: ["2026-10-05": 3])
        precondition(partialGraph.contributions == nil, "A graph missing a covered day shouldn't be summed")
        precondition(WeeklyReport.dayKey(date(cal, 5, 0), calendar: cal) == "2026-10-05", "Day key format")
    }
}
