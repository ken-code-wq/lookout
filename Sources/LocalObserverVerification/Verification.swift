import Foundation
import LocalObserverCore

@main
struct LocalObserverVerification {
    @MainActor
    static func main() {
        let now = Date(timeIntervalSince1970: 100_000)
        let processes = AgentDiscovery.parseProcessTable("321 12 02:03:04 ttys001 opencode serve\n", now: now)
        precondition(processes.count == 1, "Process parsing failed")
        precondition(processes[0].startedAt == now.addingTimeInterval(-7_384), "Elapsed time parsing failed")
        precondition(AgentDiscovery.classify(processName: "opencode.exe", arguments: "opencode serve") == .openCode, "OpenCode classification failed")
        precondition(AgentDiscovery.classify(processName: "Code - Insiders", arguments: "helper @github/copilot-darwin-arm64/index.js --headless") == .copilot, "Copilot classification failed")

        let usage = TokenUsage(
            inputTokens: 12_000,
            cachedInputTokens: 3_000,
            cacheCreationTokens: 1_000,
            outputTokens: 2_000,
            reportedTotalTokens: 16_000
        )
        let normalizedUsage = usage.normalized()
        precondition(normalizedUsage.processedTokens == 14_000, "Token normalization double-counted provider totals")
        let mixed = normalizedUsage.adding(TokenUsage(reportedTotalTokens: 1_000))
        precondition(mixed.processedTokens == 15_000, "Reported-only usage was lost during aggregation")

        let events = [
            AgentUsageEvent(
                id: "claude",
                agent: .claude,
                sessionID: "one",
                projectPath: "/tmp/project",
                projectName: "project",
                model: "opus",
                observedAt: now,
                usage: TokenUsage(inputTokens: 100, outputTokens: 10),
                cost: 0.25,
                requests: 1,
                sourcePath: "/tmp/claude.jsonl",
                sourceKind: .transcript
            ),
            AgentUsageEvent(
                id: "codex",
                agent: .codex,
                sessionID: "two",
                projectPath: "/tmp/project",
                projectName: "project",
                model: "gpt",
                observedAt: now,
                usage: TokenUsage(inputTokens: 200, outputTokens: 20),
                cost: nil,
                requests: 1,
                sourcePath: "/tmp/codex.jsonl",
                sourceKind: .transcript
            )
        ]
        var filter = AgentUsageFilter()
        filter.range = .sevenDays
        let report = AgentStore.buildReport(events: events, filter: filter, enabledAgents: Set(AgentKind.allCases), now: now)
        precondition(report.totals.processed == 330, "Usage report token total failed")
        precondition(report.totals.requests == 2, "Usage report request total failed")
        precondition(abs(report.totals.cost - 0.25) < 0.0001, "Usage report cost total failed")
        precondition(report.totals.sessions == 2, "Usage report session count failed")
        precondition(report.byAgent.first?.agent == .codex, "Agent share rows should sort by the selected metric")
        precondition(report.bucketDates.count == 7, "Daily axis should be zero-filled across the range")

        var codexOnly = filter
        codexOnly.agents = [.codex]
        let narrowed = AgentStore.buildReport(events: events, filter: codexOnly, enabledAgents: Set(AgentKind.allCases), now: now)
        precondition(narrowed.totals.processed == 220 && narrowed.availableModels == ["gpt"], "Agent filter failed")

        // Custom ranges: inclusive days, zero-filled, and a range that ends before today excludes today's events.
        let calendar = Calendar.current
        var custom = filter
        custom.setCustom(from: calendar.date(byAdding: .day, value: -4, to: now)!, to: calendar.date(byAdding: .day, value: -2, to: now)!)
        let past = AgentStore.buildReport(events: events, filter: custom, enabledAgents: Set(AgentKind.allCases), now: now)
        precondition(past.bucketDates.count == 3 && past.totals.events == 0, "Custom range should cover exactly its days")
        custom.setCustom(from: now, to: now)
        let single = AgentStore.buildReport(events: events, filter: custom, enabledAgents: Set(AgentKind.allCases), now: now)
        precondition(single.isHourly && single.totals.processed == 330, "Single-day custom range should chart by hour")

        // Rolling 24 hours: hourly, exactly 24 buckets ending in the current hour, includes events from now.
        var rolling = filter
        rolling.setRolling(hours: 24)
        let last24 = AgentStore.buildReport(events: events, filter: rolling, enabledAgents: Set(AgentKind.allCases), now: now)
        precondition(last24.isHourly && last24.bucketDates.count == 24 && last24.totals.processed == 330, "Rolling 24h window failed")
        rolling.setPreset(.today)
        precondition(!rolling.isRolling, "Choosing a preset should clear the rolling window")

        // Host apps come from ps's full-path column; padding must not leak into the bundle path.
        let hosts = AgentDiscovery.currentHostApps(now: now)
        precondition(hosts.allSatisfy { $0.bundlePath.hasPrefix("/") }, "Host bundle paths should be absolute, without padding")

        // Process discovery: Windows-style .exe names, daemons, and nested launchers.
        precondition(AgentDiscovery.classify(processName: "/x/claude-code/bin/claude.exe", arguments: "claude.exe --output-format stream-json") == .claude, "claude.exe classification failed")
        precondition(AgentDiscovery.classify(processName: "/x/bin/codex", arguments: "codex app-server --listen unix:// --managed-daemon") == nil, "Codex daemon should not be a session")
        precondition(AgentDiscovery.classify(processName: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper", arguments: "") == nil, "App helpers should not count")
        precondition(AgentDiscovery.classify(processName: "/Applications/Cursor.app/Contents/MacOS/Cursor", arguments: "") == .cursor, "Cursor app classification failed")
        precondition(AgentDiscovery.classify(processName: "/Applications/Qoder.app/Contents/MacOS/Qoder", arguments: "") == .qoder, "Qoder app classification failed")
        precondition(AgentDiscovery.classify(processName: "/Applications/Qoder.app/Contents/Frameworks/Qoder Helper.app/Contents/MacOS/Qoder Helper", arguments: "") == nil, "Qoder helpers should not count")

        // Pace marker: 60% used with 40% of a 5-hour window elapsed runs out before the reset.
        let window = AgentQuotaWindow(
            id: "w", agent: .claude, label: "5-hour session", kind: .session, usedPercent: 60,
            resetsAt: now.addingTimeInterval(3 * 3_600), windowDuration: 5 * 3_600,
            observedAt: now, source: "test", account: ""
        )
        precondition(abs((window.elapsedFraction(now: now) ?? 0) - 0.4) < 0.001, "Window elapsed fraction failed")

        ParsingChecks.checkQoder()

        // Dashboard streaks: active today and the two days before (current 3), a 4-day run earlier (longest 4).
        let heatCalendar = Calendar.current
        let today = heatCalendar.startOfDay(for: now)
        func heatDay(_ offset: Int, _ tokens: Int64) -> AgentHeatmapDay {
            var day = AgentHeatmapDay(date: heatCalendar.date(byAdding: .day, value: -offset, to: today)!)
            day.processed = tokens
            return day
        }
        let stats = AgentHeatmapStats(days: [0, 1, 2, 10, 11, 12, 13, 20].map { heatDay($0, $0 == 11 ? 900 : 100) }, metric: .tokens, now: now)
        precondition(stats.currentStreak == 3 && stats.longestStreak == 4, "Heatmap streaks (\(stats.currentStreak), \(stats.longestStreak))")
        precondition(stats.activeDays == 8 && stats.total == 1_600 && stats.busiestValue == 900, "Heatmap totals")
        let yesterdayOnly = AgentHeatmapStats(days: [heatDay(1, 5), heatDay(2, 5)], metric: .tokens, now: now)
        precondition(yesterdayOnly.currentStreak == 2, "A streak survives until today ends")
        LimitChecks.run()
        ShelfChecks.run()
        RepoChecks.run()
        DiskChecks.run()
        ReplayChecks.run()
        DiffChecks.run()
        AgentTaskChecks.run()
        RoutingChecks.run()
        WeeklyReportChecks.run()
        HookChecks.run()
        AutomationChecks.run()

        for agent in AgentKind.allCases {
            precondition(AgentIconStore.image(for: agent) != nil, "Missing official icon for \(agent.name)")
        }

        print("Lookout core verification passed")
    }
}
