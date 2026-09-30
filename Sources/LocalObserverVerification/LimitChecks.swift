import Foundation
import LocalObserverCore

/// Checks the pure JSON -> window mappers in `AgentLimitClients` against trimmed real responses.
enum LimitChecks {
    @MainActor
    static func run() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        checkClaude(now)
        checkCodex(now)
        checkCopilot(now)
        checkCursor(now)
        checkAntigravity(now)
        checkPolicy()
    }

    private static func data(_ text: String) -> Data { Data(text.utf8) }

    private static func near(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 0.01) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func checkClaude(_ now: Date) {
        let json = """
        {"five_hour":{"utilization":16.0,"resets_at":"2026-09-25T19:19:59.956607+00:00"},
         "seven_day":{"utilization":2.0,"resets_at":"2026-09-25T19:59:59.956629+00:00"},
         "seven_day_opus":null,"iguana_necktie":null,
         "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250,"utilization":25.0,"currency":"USD"},
         "limits":[
          {"kind":"session","group":"session","percent":16,"resets_at":"2026-09-25T19:19:59.956607+00:00","scope":null,"is_active":true},
          {"kind":"weekly_all","group":"weekly","percent":2,"resets_at":"2026-09-25T19:59:59.956629+00:00","scope":null},
          {"kind":"weekly_scoped","group":"weekly","percent":41.5,"resets_at":"2026-09-25T20:00:00+00:00",
           "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},
          {"kind":"weekly_scoped","group":"weekly","percent":1,"resets_at":null,
           "scope":{"model":{"id":"all-models","display_name":"All models"}}},
          {"kind":"future_kind","group":"other","percent":50}
         ],
         "spend":{"enabled":false}}
        """
        let windows = AgentLimitClients.claudeWindows(from: data(json), observedAt: now)
        precondition(windows.map(\.label) == ["5-hour session", "Weekly · all models", "Weekly · Fable", "Extra usage"],
                     "Claude limits[] mapping produced \(windows.map(\.label))")
        let session = windows[0]
        precondition(session.kind == .session && session.usedPercent == 16 && session.windowDuration == 5 * 3600,
                     "Claude session window mapped wrong")
        let expectedReset = Date(timeIntervalSince1970: 1_790_363_999.956607)
        precondition(abs((session.resetsAt ?? .distantPast).timeIntervalSince(expectedReset)) < 0.01,
                     "Claude microsecond reset timestamp parsed wrong")
        let fable = windows[2]
        precondition(fable.kind == .weeklyModel && fable.usedPercent == 41.5 && fable.id == "claude-weekly-fable",
                     "Claude weekly Fable window mapped wrong")
        precondition(windows[3].kind == .monthly && windows[3].detail == "$12.50 of $50.00 used",
                     "Claude extra usage detail wrong: \(windows[3].detail)")

        let flat = """
        {"five_hour":{"utilization":70,"resets_at":"2026-09-25T19:00:00Z"},"seven_day":{"utilization":30,"resets_at":null},
         "seven_day_opus":{"utilization":12,"resets_at":null},"extra_usage":{"is_enabled":false}}
        """
        let fallback = AgentLimitClients.claudeWindows(from: data(flat), observedAt: now)
        precondition(fallback.map(\.kind) == [.session, .weekly, .weeklyModel], "Claude flat fallback mapping failed")
        precondition(AgentLimitClients.claudeWindows(from: data("not json"), observedAt: now).isEmpty, "Claude bad JSON should map to nothing")
    }

    private static func checkCodex(_ now: Date) {
        let free = """
        {"id":1,"result":{"ordinaryUsageAllowed":false,
         "rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":98,"windowDurationMins":43200,"resetsAt":1792146056},
          "secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":null},"planType":"free",
          "rateLimitReachedType":null},
         "rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":98,"windowDurationMins":43200,"resetsAt":1792146056}}}}}
        """
        let freeWindows = AgentLimitClients.codexAppServerWindows(from: data(free), observedAt: now)
        precondition(freeWindows.count == 1, "Codex free plan should have one window, got \(freeWindows.count)")
        precondition(freeWindows[0].kind == .monthly && freeWindows[0].label == "Monthly" && freeWindows[0].usedPercent == 98,
                     "Codex 30-day window mapped wrong")
        precondition(freeWindows[0].resetsAt == Date(timeIntervalSince1970: 1_792_146_056), "Codex reset time wrong")

        let plus = """
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1790003600},
          "secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1790500000},"planType":"plus",
          "credits":{"hasCredits":true,"unlimited":false,"balance":"42"}},
         "rateLimitsByLimitId":{
          "codex":{"limitId":"codex","primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1790003600}},
          "codex_spark":{"limitId":"codex_spark","limitName":"GPT-5 Spark","primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1790003600},
           "secondary":{"usedPercent":9,"windowDurationMins":10080,"resetsAt":1790500000}}}}
        """
        let plusWindows = AgentLimitClients.codexAppServerWindows(from: data(plus), observedAt: now)
        precondition(plusWindows.map(\.label) == ["5-hour session", "Weekly", "GPT-5 Spark · 5-hour", "GPT-5 Spark · Weekly"],
                     "Codex plus windows mapped wrong: \(plusWindows.map(\.label))")
        precondition(plusWindows[0].kind == .session && plusWindows[1].kind == .weekly && plusWindows[3].kind == .weeklyModel,
                     "Codex window kinds wrong")
        precondition(Set(plusWindows.map(\.id)).count == plusWindows.count, "Codex window ids must be unique")

        let wham = """
        {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
          "primary_window":{"used_percent":3,"limit_window_seconds":18000,"reset_after_seconds":100,"reset_at":1790003600},
          "secondary_window":{"used_percent":22,"limit_window_seconds":604800,"reset_at":1790500000}},
         "additional_rate_limits":null,"credits":{"has_credits":false,"unlimited":false,"balance":null}}
        """
        let whamWindows = AgentLimitClients.codexWhamWindows(from: data(wham), observedAt: now)
        precondition(whamWindows.map(\.kind) == [.session, .weekly] && whamWindows[1].usedPercent == 22,
                     "Codex wham mapping failed")
    }

    private static func checkCopilot(_ now: Date) {
        let json = """
        {"login":"octocat","copilot_plan":"individual","access_type_sku":"free_educational_quota",
         "quota_reset_date":"2026-10-01","quota_reset_date_utc":"2026-10-01T00:00:00.000Z",
         "quota_snapshots":{
          "chat":{"percent_remaining":100.0,"quota_id":"chat","unlimited":true,"entitlement":0,"remaining":0},
          "completions":{"percent_remaining":100.0,"quota_id":"completions","unlimited":true},
          "premium_interactions":{"overage_count":0,"percent_remaining":15.3,"quota_id":"premium_interactions",
           "quota_remaining":30.6,"unlimited":false,"remaining":30,"entitlement":200,"credits_used":169}}}
        """
        let windows = AgentLimitClients.copilotWindows(from: data(json), observedAt: now)
        precondition(windows.count == 1, "Copilot should skip unlimited snapshots")
        let premium = windows[0]
        precondition(premium.label == "Premium requests" && premium.kind == .monthly, "Copilot premium label wrong")
        precondition(near(premium.usedPercent, 84.7), "Copilot used percent wrong: \(premium.usedPercent)")
        precondition(premium.detail == "169 of 200 used", "Copilot detail wrong: \(premium.detail)")
        precondition(premium.resetsAt == Date(timeIntervalSince1970: 1_790_812_800), "Copilot reset date wrong")
        precondition(premium.windowDuration == 30 * 86_400, "Copilot September window should be 30 days")
        precondition(premium.account == "octocat", "Copilot account not captured")
    }

    private static func checkCursor(_ now: Date) {
        let json = """
        {"billingCycleStart":"2026-09-10T00:00:00.000Z","billingCycleEnd":"2026-10-10T00:00:00.000Z",
         "membershipType":"pro","limitType":"user","isUnlimited":false,
         "individualUsage":{
          "plan":{"enabled":true,"used":1234,"limit":2000,"remaining":766,"breakdown":{"included":2000,"bonus":0,"total":1234},
           "autoPercentUsed":20.1,"apiPercentUsed":41.6,"totalPercentUsed":61.7},
          "onDemand":{"enabled":true,"used":500,"limit":10000,"remaining":9500}},
         "teamUsage":{}}
        """
        let windows = AgentLimitClients.cursorWindows(from: data(json), observedAt: now)
        precondition(windows.map(\.label) == ["Included usage", "On-demand"], "Cursor labels wrong: \(windows.map(\.label))")
        precondition(windows[0].usedPercent == 61.7 && windows[0].detail == "$12.34 of $20.00 used", "Cursor included usage wrong")
        precondition(windows[1].usedPercent == 5 && windows[1].detail == "$5.00 of $100.00 used", "Cursor on-demand wrong")
        precondition(windows[0].windowDuration == 30 * 86_400 && windows[0].resetsAt == Date(timeIntervalSince1970: 1_791_590_400),
                     "Cursor billing cycle wrong")

        let noOnDemand = """
        {"billingCycleStart":"2026-09-10T00:00:00Z","billingCycleEnd":"2026-10-10T00:00:00Z",
         "individualUsage":{"plan":{"enabled":true,"used":0,"limit":2000},"onDemand":{"enabled":false,"used":0,"limit":null}}}
        """
        precondition(AgentLimitClients.cursorWindows(from: data(noOnDemand), observedAt: now).count == 1,
                     "Cursor should skip disabled on-demand")
    }

    private static func checkAntigravity(_ now: Date) {
        let json = """
        {"conversation_id":"","status":"SUCCESS","response":"Gemini Models\\tWeekly Limit Remaining\\t95%",
         "usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0},
         "command":{"name":"usage","data":{"description":"...","groups":[
          {"name":"Gemini Models","buckets":[
           {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.9547935724258423,"reset_time":"2026-09-30T12:06:52Z"},
           {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.8081449866294861,"reset_time":"2026-09-25T15:27:40Z"}]},
          {"name":"Claude and GPT models","buckets":[
           {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-02T14:40:24Z"},
           {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-09-25T19:40:24Z"},
           {"id":"3p-off","window":"5h","remaining_fraction":0.5,"disabled":true}]}]}}}
        """
        let windows = AgentLimitClients.antigravityWindows(from: data("Loading...\n" + json), observedAt: now)
        precondition(windows.map(\.label) == ["Gemini · Weekly", "Gemini · 5-hour", "Claude & GPT · Weekly", "Claude & GPT · 5-hour"],
                     "Antigravity labels wrong: \(windows.map(\.label))")
        precondition(windows[0].kind == .weekly && near(windows[0].usedPercent, 4.52) && windows[0].windowDuration == 7 * 86_400,
                     "Antigravity weekly bucket wrong")
        precondition(windows[1].kind == .session && near(windows[1].usedPercent, 19.19), "Antigravity 5-hour bucket wrong")
        precondition(windows[2].usedPercent == 0, "Antigravity full bucket should be 0% used")
    }

    private static func checkPolicy() {
        for agent in AgentKind.allCases {
            let expected = ![.openCode, .pi, .qoder].contains(agent)
            precondition(AgentLimitClients.supportsAccountLimits(agent) == expected, "Account limit support wrong for \(agent)")
            let description = AgentLimitClients.connectDescription(agent)
            precondition(!description.isEmpty && !description.contains("—"), "Connect description missing or uses an em dash for \(agent)")
        }
    }
}
