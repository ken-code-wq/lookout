import Foundation
import Combine

@MainActor
public final class AgentStore: ObservableObject {
    @Published public private(set) var snapshot = AgentStore.emptySnapshot
    @Published public private(set) var ledgerEvents: [AgentUsageEvent] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var isRefreshingLimits = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var accountReports: [AgentKind: AgentLimitReport] = [:]
    @Published public private(set) var usage = AgentUsageReport(filter: AgentUsageFilter())
    @Published public var settings: AgentSettings
    @Published public var filter = AgentUsageFilter() { didSet { if filter != oldValue { rebuildUsage() } } }
    @Published public var searchText = "" { didSet { if searchText != oldValue { rebuildUsage() } } }
    /// Everything recorded today across enabled agents, regardless of the Usage page filters. Drives the menu bar and Dock.
    @Published public private(set) var todayTotals = AgentUsageTotals()
    /// Today's usage per model, most tokens first.
    @Published public private(set) var todayModels: [AgentUsageRow] = []
    /// Daily totals for the last 365 days across the agents the Usage page filter keeps
    /// (enabled ∩ selected). Ignores project, model, search, and period filters — feeds the heatmap grid.
    @Published public private(set) var heatmap: [AgentHeatmapDay] = []
    @Published public var activityFilter = AgentActivityFilter()
    /// Compact chart shown in the menu bar panel and the notch, independent of the Usage page filters.
    @Published public var glanceRange: AgentGlanceRange { didSet { if glanceRange != oldValue { saveGlance(); rebuildGlance() } } }
    @Published public var glanceMetric: AgentMetricKind { didSet { if glanceMetric != oldValue { saveGlance(); rebuildGlance() } } }
    /// Empty means every enabled agent.
    @Published public var glanceAgents: Set<AgentKind> = [] { didSet { if glanceAgents != oldValue { saveGlance(); rebuildGlance() } } }
    @Published public private(set) var glanceUsage = AgentUsageReport(filter: AgentUsageFilter())
    @Published public var selectedSessionID: String?
    @Published public var isSettingsPresented = false

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var limitsTask: Task<Void, Never>?
    private var ledgerSignature = 0
    /// Bumped whenever `ledgerEvents` changes, so consumers can cache what they derive from it.
    public private(set) var ledgerRevision = 0
    /// When the usage reports were last rebuilt. Rolling windows ("today", "last 24 hours") move with the clock,
    /// so they're rebuilt at least this often even when no new usage arrived.
    private var usageBuiltAt = Date.distantPast

    private enum Keys {
        static let settings = "LocalObserver.agentSettings"
        static let glanceRange = "LocalObserver.glanceRange"
        static let glanceMetric = "LocalObserver.glanceMetric"
        static let glanceAgents = "LocalObserver.glanceAgents"
    }

    private struct Ledger: Codable {
        var version: Int
        var events: [AgentUsageEvent]
    }

    /// Bumped whenever event ids or token semantics change, so stale (e.g. double-counted) history is discarded.
    private static let ledgerVersion = 2

    public init(defaults: UserDefaults = .standard, fileManager: FileManager = .default, autoStart: Bool = true) {
        self.defaults = defaults
        self.fileManager = fileManager
        if let data = defaults.data(forKey: Keys.settings),
           let stored = try? JSONDecoder().decode(AgentSettings.self, from: data) {
            settings = stored
        } else {
            settings = AgentSettings()
        }
        glanceRange = AgentGlanceRange(rawValue: defaults.string(forKey: Keys.glanceRange) ?? "") ?? .last24h
        glanceMetric = AgentMetricKind(rawValue: defaults.string(forKey: Keys.glanceMetric) ?? "") ?? .tokens
        glanceAgents = Set((defaults.stringArray(forKey: Keys.glanceAgents) ?? []).compactMap(AgentKind.init(rawValue:)))
        ledgerEvents = Self.loadLedger(fileManager: fileManager)
        ledgerSignature = Self.signature(ledgerEvents)
        rebuildUsage()
        guard autoStart else { return }
        scheduleTimer()
        refresh()
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
        limitsTask?.cancel()
    }

    // MARK: - Refresh

    public func refresh(quiet: Bool = false, forceLimits: Bool = false) {
        refreshLimits(force: forceLimits || !quiet)
        guard refreshTask == nil else { return }
        if !quiet { isScanning = true }
        let enabled = settings.enabledAgents
        let historyDays = settings.historyDays
        refreshTask = Task { [weak self] in
            let fresh = await AgentDiscovery.scan(enabledAgents: enabled, historyDays: historyDays)
            guard let self else { return }
            // Merging, sorting, and counting a year of events is real work; keep it off the main thread.
            let previous = self.ledgerEvents
            let (merged, signature, counts) = await Task.detached(priority: .utility) {
                let cutoff = Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? .distantPast
                let merged = Self.merge(previous, fresh.usageEvents).filter { $0.observedAt >= cutoff }
                let counts = Dictionary(grouping: merged, by: \.agent).mapValues(\.count)
                return (merged, Self.signature(merged), counts)
            }.value
            let ledgerChanged = signature != self.ledgerSignature
            if ledgerChanged {
                self.ledgerEvents = merged
                self.ledgerSignature = signature
                self.ledgerRevision += 1
                self.persistLedger(merged)
            }
            var snapshot = fresh
            snapshot.usageEvents = []
            snapshot.integrations = fresh.integrations.map { integration in
                var updated = integration
                updated.usageEventCount = counts[integration.agent] ?? 0
                return updated
            }
            self.snapshot = snapshot
            self.lastRefresh = fresh.discoveredAt
            self.lastError = fresh.warnings.isEmpty ? nil : fresh.warnings.joined(separator: "\n")
            self.refreshTask = nil
            self.isScanning = false
            if ledgerChanged || Date().timeIntervalSince(self.usageBuiltAt) > 60 { self.rebuildUsage() }
        }
    }

    /// Account limits run on their own task: some providers take seconds to answer and must never hold up the process list.
    public func refreshLimits(force: Bool = false) {
        guard limitsTask == nil else { return }
        let enabled = settings.enabledAgents
        let accounts = settings.accountLimitAgents.intersection(enabled)
        isRefreshingLimits = force
        limitsTask = Task { [weak self] in
            let reports = await AgentLimitClients.read(enabledAgents: enabled, accountAgents: accounts, force: force)
            guard let self else { return }
            self.accountReports = Dictionary(reports.map { ($0.agent, $0) }, uniquingKeysWith: { _, latest in latest })
            self.limitsTask = nil
            self.isRefreshingLimits = false
        }
    }

    // MARK: - Settings

    public func saveSettings(_ updated: AgentSettings) {
        var normalized = updated
        normalized.historyDays = min(max(updated.historyDays, 7), 365)
        let accountsChanged = normalized.accountLimitAgents != settings.accountLimitAgents
        settings = normalized
        filter.agents.formIntersection(normalized.enabledAgents)
        persistSettings()
        scheduleTimer()
        refresh(quiet: true, forceLimits: accountsChanged)
    }

    public func completeSetup(enabled: Set<AgentKind>, accountLimits: Set<AgentKind>) {
        var updated = settings
        updated.enabledAgents = enabled
        updated.accountLimitAgents = accountLimits.intersection(enabled)
        updated.hasCompletedSetup = true
        saveSettings(updated)
    }

    public func setAccountLimits(_ agent: AgentKind, enabled: Bool) {
        var updated = settings
        if enabled { updated.accountLimitAgents.insert(agent) } else { updated.accountLimitAgents.remove(agent) }
        saveSettings(updated)
    }

    public func toggleFilterAgent(_ agent: AgentKind) {
        var agents = filter.agents.isEmpty ? settings.enabledAgents : filter.agents
        if agents.contains(agent) { agents.remove(agent) } else { agents.insert(agent) }
        filter.agents = agents == settings.enabledAgents ? [] : agents
    }

    public func clearFilters() {
        var cleared = AgentUsageFilter()
        cleared.range = filter.range
        cleared.customStart = filter.customStart
        cleared.customEnd = filter.customEnd
        cleared.metric = filter.metric
        cleared.grouping = filter.grouping
        filter = cleared
        searchText = ""
    }

    public func clearActivityFilters() {
        activityFilter = AgentActivityFilter()
        searchText = ""
    }

    public func integration(for agent: AgentKind) -> AgentIntegration? {
        snapshot.integrations.first { $0.agent == agent }
    }

    // MARK: - Sessions

    public var runningSessions: [AgentSession] {
        snapshot.processes.filter { settings.enabledAgents.contains($0.agent) && matchesSearch($0) }
    }

    /// Running sessions that are waiting on the user, most urgent first.
    public var attentionSessions: [AgentSession] {
        runningSessions.filter(\.needsAttention)
    }

    public var recentSessions: [AgentSession] {
        let running = Set(snapshot.processes.map(\.sessionID))
        return snapshot.sessions.filter {
            settings.enabledAgents.contains($0.agent) && !running.contains($0.sessionID) && matchesSearch($0)
        }
    }

    public var selectedSession: AgentSession? {
        guard let selectedSessionID else { return nil }
        return snapshot.processes.first { $0.id == selectedSessionID }
            ?? snapshot.sessions.first { $0.id == selectedSessionID }
    }

    // MARK: - Limits

    /// One report per enabled agent. Live account data wins; local session logs fill in when the account is not connected.
    public var limitReports: [AgentLimitReport] {
        let local = Dictionary(snapshot.limitReports.map { ($0.agent, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        return AgentKind.allCases.compactMap { agent -> AgentLimitReport? in
            guard settings.enabledAgents.contains(agent) else { return nil }
            let account = accountReports[agent]
            if let account, account.status == .connected, !account.windows.isEmpty { return account }
            if var fallback = local[agent], !fallback.windows.isEmpty {
                if let account, account.status == .error { fallback.message = account.message }
                if fallback.plan.isEmpty { fallback.plan = account?.plan ?? "" }
                return fallback
            }
            return account ?? AgentLimitReport(
                agent: agent,
                status: .notConnected,
                message: "Plan limits have not been read yet."
            )
        }
    }

    /// The window closest to running out, for glanceable surfaces like the menu bar.
    public var tightestWindow: AgentQuotaWindow? {
        limitReports.flatMap(\.windows).max { $0.usedPercent < $1.usedPercent }
    }

    // MARK: - Usage

    public var enabledAgentsSorted: [AgentKind] {
        AgentKind.allCases.filter { settings.enabledAgents.contains($0) }
    }

    public var hasUsageHistory: Bool { !ledgerEvents.isEmpty }

    private func rebuildUsage() {
        usageBuiltAt = Date()
        usage = Self.buildReport(
            events: ledgerEvents,
            filter: filter,
            enabledAgents: settings.enabledAgents,
            search: searchText
        )
        var today = AgentUsageFilter()
        today.setPreset(.today)
        today.grouping = .model
        let todayReport = Self.buildReport(events: ledgerEvents, filter: today, enabledAgents: settings.enabledAgents)
        todayTotals = todayReport.totals
        todayModels = todayReport.rows
        rebuildHeatmap()
        rebuildGlance()
    }

    private func rebuildHeatmap() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(AgentDateRange.oneYear.rawValue - 1), to: today) else { return }
        let agents = filter.agents.isEmpty ? settings.enabledAgents : filter.agents.intersection(settings.enabledAgents)
        var days: [Date: AgentHeatmapDay] = [:]
        for event in ledgerEvents where event.observedAt >= windowStart && agents.contains(event.agent) {
            let day = calendar.startOfDay(for: event.observedAt)
            var entry = days[day] ?? AgentHeatmapDay(date: day)
            entry.add(event)
            days[day] = entry
        }
        heatmap = days.values.sorted { $0.date < $1.date }
    }

    public var glanceFilter: AgentUsageFilter {
        var filter = AgentUsageFilter()
        glanceRange.apply(to: &filter)
        filter.metric = glanceMetric
        filter.agents = glanceAgents
        filter.grouping = .agent
        return filter
    }

    private func rebuildGlance() {
        glanceUsage = Self.buildReport(events: ledgerEvents, filter: glanceFilter, enabledAgents: settings.enabledAgents)
    }

    private func saveGlance() {
        defaults.set(glanceRange.rawValue, forKey: Keys.glanceRange)
        defaults.set(glanceMetric.rawValue, forKey: Keys.glanceMetric)
        defaults.set(glanceAgents.map(\.rawValue), forKey: Keys.glanceAgents)
    }

    public static func buildReport(
        events: [AgentUsageEvent],
        filter: AgentUsageFilter,
        enabledAgents: Set<AgentKind>,
        search: String = "",
        now: Date = .now,
        calendar: Calendar = .current
    ) -> AgentUsageReport {
        var report = AgentUsageReport(filter: filter)
        let start = filter.periodStart(now: now, calendar: calendar)
        let end = filter.periodEnd(now: now, calendar: calendar)
        let agents = filter.agents.isEmpty ? enabledAgents : filter.agents.intersection(enabledAgents)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Filter menus list what exists for the chosen period and agents, before project/model narrowing.
        var projects = Set<String>()
        var models = Set<String>()
        var selected: [AgentUsageEvent] = []
        for event in events where event.observedAt >= start && event.observedAt < end && agents.contains(event.agent) {
            report.hasAnyEvents = true
            if !event.projectName.isEmpty { projects.insert(event.projectName) }
            if !event.model.isEmpty { models.insert(event.model) }
            if !filter.projects.isEmpty && !filter.projects.contains(event.projectName) { continue }
            if !filter.models.isEmpty && !filter.models.contains(event.model) { continue }
            if !query.isEmpty,
               ![event.projectName, event.projectPath, event.model, event.agent.name].contains(where: { $0.lowercased().contains(query) }) {
                continue
            }
            selected.append(event)
        }
        report.availableProjects = projects.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        report.availableModels = models.sorted()

        var sessions = Set<String>()
        var byAgent: [AgentKind: (AgentUsageTotals, Set<String>)] = [:]
        var byGroup: [String: (AgentUsageTotals, Set<String>, Set<AgentKind>)] = [:]
        let hourly = filter.isHourly(calendar: calendar)
        report.isHourly = hourly
        var bucketTotals: [Date: [AgentKind: Double]] = [:]

        for event in selected {
            let sessionKey = "\(event.agent.rawValue)|\(event.sessionID)"
            sessions.insert(sessionKey)
            report.totals.add(event)

            var agentEntry = byAgent[event.agent] ?? (AgentUsageTotals(), [])
            agentEntry.0.add(event)
            agentEntry.1.insert(sessionKey)
            byAgent[event.agent] = agentEntry

            let key: String
            switch filter.grouping {
            case .agent: key = event.agent.rawValue
            case .model: key = event.model.isEmpty ? "Unknown model" : event.model
            case .project: key = event.projectName.isEmpty ? "Unknown workspace" : event.projectName
            }
            var groupEntry = byGroup[key] ?? (AgentUsageTotals(), [], [])
            groupEntry.0.add(event)
            groupEntry.1.insert(sessionKey)
            groupEntry.2.insert(event.agent)
            byGroup[key] = groupEntry

            let bucket = hourly
                ? calendar.dateInterval(of: .hour, for: event.observedAt)?.start ?? event.observedAt
                : calendar.startOfDay(for: event.observedAt)
            var single = AgentUsageTotals()
            single.add(event)
            bucketTotals[bucket, default: [:]][event.agent, default: 0] += single.value(for: filter.metric)
        }
        report.totals.sessions = sessions.count

        let metricTotal = max(report.totals.value(for: filter.metric), .leastNonzeroMagnitude)
        report.byAgent = byAgent.map { agent, entry in
            var totals = entry.0
            totals.sessions = entry.1.count
            return AgentUsageRow(
                id: agent.rawValue,
                title: agent.name,
                agent: agent,
                agents: [agent],
                totals: totals,
                share: totals.value(for: filter.metric) / metricTotal
            )
        }
        .sorted { $0.totals.value(for: filter.metric) > $1.totals.value(for: filter.metric) }

        report.rows = byGroup.map { key, entry in
            var totals = entry.0
            totals.sessions = entry.1.count
            let agent = entry.2.count == 1 ? entry.2.first : nil
            return AgentUsageRow(
                id: key,
                title: filter.grouping == .agent ? (AgentKind(rawValue: key)?.name ?? key) : key,
                agent: agent,
                agents: entry.2,
                totals: totals,
                share: totals.value(for: filter.metric) / metricTotal
            )
        }
        .sorted { $0.totals.value(for: filter.metric) > $1.totals.value(for: filter.metric) }

        // Zero-filled axis so quiet days read as zero instead of being skipped.
        var dates: [Date] = []
        if hourly {
            var cursor = start
            let last = min(now, calendar.date(byAdding: .day, value: 1, to: start) ?? now)
            while cursor <= last {
                dates.append(cursor)
                cursor = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? last.addingTimeInterval(1)
            }
        } else {
            var cursor = start
            let today = min(calendar.startOfDay(for: now), calendar.startOfDay(for: end.addingTimeInterval(-1)))
            while cursor <= today {
                dates.append(cursor)
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? today.addingTimeInterval(1)
            }
        }
        report.bucketDates = dates
        let seriesAgents = report.byAgent.compactMap(\.agent)
        report.buckets = dates.flatMap { date in
            seriesAgents.map { agent in
                AgentUsageBucket(date: date, agent: agent, value: bucketTotals[date]?[agent] ?? 0)
            }
        }
        let sums = bucketTotals.mapValues { $0.values.reduce(0, +) }
        report.activeBuckets = sums.values.filter { $0 > 0 }.count
        if let peak = sums.max(by: { $0.value < $1.value }), peak.value > 0 {
            report.busiest = (peak.key, peak.value)
        }
        return report
    }

    private func matchesSearch(_ session: AgentSession) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return [session.title, session.projectName, session.projectPath, session.model, session.branch, session.agent.name]
            .contains { $0.lowercased().contains(query) }
    }

    // MARK: - Persistence

    private func scheduleTimer() {
        timer?.invalidate()
        guard settings.autoRefresh else { return }
        // Transcript parsing is the expensive part; a quiet machine doesn't need 15-second attention.
        let active = !snapshot.processes.isEmpty
        let interval: TimeInterval = active ? 15 : 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(quiet: true)
                self.scheduleTimer()
            }
        }
        timer?.tolerance = interval / 3
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Keys.settings)
        }
    }

    private static func ledgerURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("LocalObserver", isDirectory: true)
            .appendingPathComponent("usage-ledger.json", isDirectory: false)
    }

    private func persistLedger(_ events: [AgentUsageEvent]) {
        let url = Self.ledgerURL(fileManager: fileManager)
        let version = Self.ledgerVersion
        let manager = fileManager
        // Encoding a year of events takes a moment; keep it off the main thread.
        Task.detached(priority: .utility) {
            do {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(Ledger(version: version, events: events))
                try data.write(to: url, options: .atomic)
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "Usage history could not be saved: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func loadLedger(fileManager: FileManager) -> [AgentUsageEvent] {
        guard let data = try? Data(contentsOf: ledgerURL(fileManager: fileManager)),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
              ledger.version == ledgerVersion else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? .distantPast
        return ledger.events.filter { $0.observedAt >= cutoff }
    }

    /// Later observations of the same event id replace earlier ones; ids are stable dedupe keys from the readers.
    nonisolated static func merge(_ old: [AgentUsageEvent], _ new: [AgentUsageEvent]) -> [AgentUsageEvent] {
        var byID: [String: AgentUsageEvent] = [:]
        byID.reserveCapacity(old.count + new.count)
        for event in old { byID[event.id] = event }
        for event in new {
            var normalized = event
            normalized.usage = event.usage.normalized()
            byID[event.id] = normalized
        }
        return byID.values.sorted { $0.observedAt > $1.observedAt }
    }

    nonisolated private static func signature(_ events: [AgentUsageEvent]) -> Int {
        var hasher = Hasher()
        hasher.combine(events.count)
        for event in events.prefix(64) {
            hasher.combine(event.id)
            hasher.combine(event.usage)
        }
        return hasher.finalize()
    }

    private static var emptySnapshot: AgentSnapshot {
        AgentSnapshot(
            discoveredAt: .distantPast,
            processes: [],
            sessions: [],
            usageEvents: [],
            limitReports: [],
            integrations: AgentKind.allCases.map {
                AgentIntegration(
                    agent: $0,
                    isInstalled: false,
                    installedPath: "",
                    runningProcessCount: 0,
                    sessionCount: 0,
                    usageEventCount: 0,
                    sourceState: .unavailable,
                    message: "Not scanned yet",
                    lastUpdated: nil
                )
            },
            warnings: []
        )
    }
}
