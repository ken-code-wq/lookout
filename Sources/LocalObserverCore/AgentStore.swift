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
    @Published public var searchText = "" { didSet { if searchText != oldValue { scheduleSearchRebuild() } } }
    /// Everything recorded today across enabled agents, regardless of the Usage page filters. Drives the menu bar and Dock.
    @Published public private(set) var todayTotals = AgentUsageTotals()
    /// Cost per agent today and this week, for budgets.
    @Published public private(set) var spend: [AgentKind: AgentSpend] = [:]
    /// Today's usage per model, most tokens first.
    @Published public private(set) var todayModels: [AgentUsageRow] = []
    /// Daily totals for the last 365 days across the agents the Usage page filter keeps
    /// (enabled ∩ selected). Ignores project, model, search, and period filters — feeds the heatmap grid.
    @Published public private(set) var heatmap: [AgentHeatmapDay] = []
    /// The dashboard's year: every enabled agent's daily totals for the last 365 days, regardless of the
    /// Usage page filter, so the dashboard can combine or single out agents itself.
    @Published public private(set) var dailyByAgent: [AgentKind: [AgentHeatmapDay]] = [:]
    @Published public var activityFilter = AgentActivityFilter()
    /// Compact chart shown in the menu bar panel and the notch, independent of the Usage page filters.
    @Published public var glanceRange: AgentGlanceRange { didSet { if glanceRange != oldValue { saveGlance(); rebuildGlance() } } }
    @Published public var glanceMetric: AgentMetricKind { didSet { if glanceMetric != oldValue { saveGlance(); rebuildGlance() } } }
    /// Empty means every enabled agent.
    @Published public var glanceAgents: Set<AgentKind> = [] { didSet { if glanceAgents != oldValue { saveGlance(); rebuildGlance() } } }
    @Published public private(set) var glanceUsage = AgentUsageReport(filter: AgentUsageFilter())
    @Published public var selectedSessionID: String?
    @Published public var isSettingsPresented = false
    /// Lookout's permanent usage history, never trimmed, so it outlives the agents' own logs. Feeds the You page:
    /// see `profile(for:)` and `newMilestones`. Empty until `isHistoryLoaded`; it loads off the main thread.
    @Published public private(set) var history = UsageHistory()
    @Published public private(set) var isHistoryLoaded = false
    /// Bumped whenever `history` changes, so consumers can cache profiles built from it.
    public private(set) var historyRevision = 0

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
    private var usageGeneration = 0
    private var glanceGeneration = 0
    private var appliedUsageGeneration = 0
    private var appliedGlanceGeneration = 0
    private var searchRebuildTask: Task<Void, Never>?
    /// Signature of the last scan's usage events, so an unchanged scan skips the merge entirely.
    private var lastFreshSignature: Int?
    private var lastMergeAt = Date.distantPast
    private var lastCounts: [AgentKind: Int] = [:]
    /// A ledger waiting to be written. Writing a year of events is ~20 MB of JSON, so writes are spaced out.
    private var quitObserver: NSObjectProtocol?
    private var pendingLedger: [AgentUsageEvent]?
    private var ledgerWriteTask: Task<Void, Never>?
    private var lastLedgerWrite = Date()
    private static let ledgerWriteInterval: TimeInterval = 300
    /// False for stores that must never touch the on-disk ledger (snapshot demo data).
    private let persistsLedger: Bool
    /// Set by `loadDemo`: the store shows injected data and never scans, fetches, or writes.
    private var isDemo = false
    /// Running sessions as the last scan found them, before hook states are laid over them.
    private var scannedProcesses: [AgentSession] = []
    /// States agents reported through hooks, keyed by running session id. See `AgentHookOverlay`.
    public private(set) var hookStates: [String: AgentHookState] = [:]
    /// False when the history file was written by a newer Lookout: it stays untouched and this one lives in memory.
    private var persistsHistory = true
    private var historyLoad: Task<Void, Never>?
    private var pendingHistory: UsageHistory?
    /// Shown with the scan warnings when the history on disk couldn't be read.
    private var historyWarning: String?
    /// The raw ledger is replayed into the history once per launch, after any backfill, to recover events whose logs
    /// are gone and anything a crash kept from being saved.
    private var historyNeedsReplay = true

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
    /// `UsageHistory` is never discarded and dedupes on the same ids: an id change there counts still-readable
    /// events twice, so it needs its own migration.
    nonisolated private static let ledgerVersion = 2

    public init(defaults: UserDefaults = .standard, fileManager: FileManager = .default, autoStart: Bool = true,
                persistsLedger: Bool = true) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.persistsLedger = persistsLedger
        if let data = defaults.data(forKey: Keys.settings),
           let stored = try? JSONDecoder().decode(AgentSettings.self, from: data) {
            settings = stored
        } else {
            settings = AgentSettings()
        }
        glanceRange = AgentGlanceRange(rawValue: defaults.string(forKey: Keys.glanceRange) ?? "") ?? .last24h
        glanceMetric = AgentMetricKind(rawValue: defaults.string(forKey: Keys.glanceMetric) ?? "") ?? .tokens
        glanceAgents = Set((defaults.stringArray(forKey: Keys.glanceAgents) ?? []).compactMap(AgentKind.init(rawValue:)))
        ledgerEvents = persistsLedger ? Self.loadLedger(fileManager: fileManager) : []
        ledgerSignature = Self.signature(ledgerEvents)
        applyUsage(Self.computeUsage(
            events: ledgerEvents, filter: filter, enabledAgents: settings.enabledAgents,
            search: searchText, glance: glanceFilter
        ), usage: true, glance: true)
        usageBuiltAt = Date()
        if persistsLedger {
            historyLoad = Task { [weak self] in await self?.loadHistory() }
        } else {
            isHistoryLoaded = true
        }
        guard autoStart else { return }
        // The app delegate can't reach this store, so it flushes the pending ledger itself when the app quits.
        quitObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        scheduleTimer()
        refresh()
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
        limitsTask?.cancel()
        searchRebuildTask?.cancel()
        ledgerWriteTask?.cancel()
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }

    // MARK: - Refresh

    public func refresh(quiet: Bool = false, forceLimits: Bool = false) {
        guard !isDemo else { return }
        refreshLimits(force: forceLimits || !quiet)
        guard refreshTask == nil else { return }
        if !quiet && !isScanning { isScanning = true }
        let enabled = settings.enabledAgents
        let historyDays = settings.historyDays
        refreshTask = Task { [weak self] in
            await self?.historyLoad?.value
            // Agents whose old logs aren't in the history yet are read as far back as their logs go, once.
            let backfill = self?.agentsToBackfill(enabled) ?? []
            let fresh = await AgentDiscovery.scan(enabledAgents: enabled, historyDays: backfill.isEmpty ? historyDays : UsageHistory.backfillDays)
            guard let self else { return }
            // Merging, sorting, and counting a year of events is real work; keep it off the main thread.
            let previous = self.ledgerEvents
            let lastFresh = self.lastFreshSignature
            let mergedRecently = Date().timeIntervalSince(self.lastMergeAt) < 600
            let previousHistory = self.history
            let historyStep = HistoryStep(enabled: enabled, backfill: backfill, replay: self.historyNeedsReplay && self.persistsLedger,
                                          rememberDays: historyDays + 35)
            let outcome = await Task.detached(priority: .utility) { () -> ScanMerge in
                var result = ScanMerge()
                // A backfill pass reaches past the history window; the raw ledger and Usage page keep to the window.
                let windowStart = Date().addingTimeInterval(-Double(historyDays) * 86_400)
                let events = backfill.isEmpty ? fresh.usageEvents : fresh.usageEvents.filter { $0.observedAt >= windowStart }
                let freshSignature = Self.signature(events)
                // Same events as last scan and merged recently (the 365-day trim still runs periodically): nothing to do.
                if !(mergedRecently && freshSignature == lastFresh) {
                    let cutoff = Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? .distantPast
                    let merged = Self.merge(previous, events).filter { $0.observedAt >= cutoff }
                    let counts = Dictionary(grouping: merged, by: \.agent).mapValues(\.count)
                    result.ledger = (merged, Self.signature(merged), counts, freshSignature)
                }
                guard result.ledger != nil || !backfill.isEmpty || historyStep.replay else { return result }
                (result.history, result.replayed) = Self.mergeHistory(previousHistory, fresh: fresh, ledger: previous, step: historyStep)
                return result
            }.value
            var ledgerChanged = false
            if let ledger = outcome.ledger {
                self.lastFreshSignature = ledger.freshSignature
                self.lastMergeAt = Date()
                self.lastCounts = ledger.counts
                ledgerChanged = ledger.signature != self.ledgerSignature
                if ledgerChanged {
                    self.ledgerEvents = ledger.merged
                    self.ledgerSignature = ledger.signature
                    self.ledgerRevision += 1
                    self.persistLedger(ledger.merged)
                }
            }
            if outcome.replayed { self.historyNeedsReplay = false }
            if var history = outcome.history {
                // Milestones celebrated while the merge ran.
                history.acknowledgeMilestones(self.history.acknowledgedMilestones)
                self.history = history
                self.historyRevision += 1
                self.persistHistory(history)
            }
            let counts = self.lastCounts
            var snapshot = fresh
            snapshot.usageEvents = []
            if !backfill.isEmpty {
                // The backfill read years of sessions; the session list keeps to the usual window.
                let start = fresh.discoveredAt.addingTimeInterval(-Double(historyDays) * 86_400)
                snapshot.sessions = fresh.sessions.filter { $0.updatedAt >= start }
            }
            self.scannedProcesses = snapshot.processes.map(Self.withCheckout)
            snapshot.processes = AgentHookOverlay.apply(self.hookStates, to: self.scannedProcesses)
            snapshot.integrations = fresh.integrations.map { integration in
                var updated = integration
                updated.usageEventCount = counts[integration.agent] ?? 0
                if !backfill.isEmpty { updated.sessionCount = snapshot.sessions.filter { $0.agent == integration.agent }.count }
                return updated
            }
            // Assigning an @Published property always notifies observers, so only publish real changes.
            if !Self.sameContent(snapshot, self.snapshot) { self.snapshot = snapshot }
            if self.lastRefresh != fresh.discoveredAt { self.lastRefresh = fresh.discoveredAt }
            let warnings = fresh.warnings + [self.historyWarning].compactMap { $0 }
            let error = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            if self.lastError != error { self.lastError = error }
            self.refreshTask = nil
            if self.isScanning { self.isScanning = false }
            if ledgerChanged || Date().timeIntervalSince(self.usageBuiltAt) > 60 { self.rebuildUsage() }
        }
    }

    private struct ScanMerge: Sendable {
        var ledger: (merged: [AgentUsageEvent], signature: Int, counts: [AgentKind: Int], freshSignature: Int)?
        /// Nil when the history didn't change.
        var history: UsageHistory?
        var replayed = false
    }

    private struct HistoryStep: Sendable {
        var enabled: Set<AgentKind>
        /// Agents this scan read as far back as their logs go.
        var backfill: Set<AgentKind>
        /// Replay the raw ledger once every enabled agent is backfilled.
        var replay: Bool
        /// Ids are kept a little longer than the scan window; readers drop older events.
        var rememberDays: Int
    }

    private func agentsToBackfill(_ enabled: Set<AgentKind>) -> Set<AgentKind> {
        persistsLedger && persistsHistory && isHistoryLoaded ? enabled.subtracting(history.backfilledAgents) : []
    }

    /// Folds a scan into the permanent history; nil when nothing changed. See `UsageHistory.absorb`.
    nonisolated private static func mergeHistory(_ history: UsageHistory, fresh: AgentSnapshot, ledger: [AgentUsageEvent],
                                                 step: HistoryStep) -> (UsageHistory?, Bool) {
        var updated = history
        let scan = UsageHistory.Scan(events: fresh.usageEvents, warnings: fresh.warnings, enabled: step.enabled, backfill: step.backfill)
        let result = updated.absorb(scan, replaying: step.replay ? ledger : nil, rememberDays: step.rememberDays)
        return (result.changed ? updated : nil, result.replayed)
    }

    /// Debug/demo: shows the given data instead of this Mac's. Only for stores made with `autoStart: false,
    /// persistsLedger: false`; afterwards the store never scans, fetches limits, or writes. Usage reports rebuild
    /// off the main actor; wait for `isUsageReady` before rendering.
    public func loadDemo(snapshot: AgentSnapshot, ledger: [AgentUsageEvent], limits: [AgentLimitReport]) {
        precondition(!persistsLedger, "loadDemo needs a store that never persists its ledger")
        isDemo = true
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        limitsTask?.cancel()
        self.snapshot = snapshot
        scannedProcesses = snapshot.processes
        ledgerEvents = ledger
        ledgerSignature = Self.signature(ledger)
        ledgerRevision += 1
        var demoHistory = UsageHistory(createdAt: ledger.map(\.observedAt).min() ?? snapshot.discoveredAt)
        demoHistory.merge(ledger, now: snapshot.discoveredAt)
        demoHistory.backfilledAgents = Set(AgentKind.allCases)
        demoHistory.updateMilestones(now: snapshot.discoveredAt)
        history = demoHistory
        historyRevision += 1
        accountReports = Dictionary(limits.map { ($0.agent, $0) }, uniquingKeysWith: { _, latest in latest })
        lastRefresh = snapshot.discoveredAt
        rebuildUsage()
    }

    /// True once no usage rebuild is in flight (both the main and glance reports reflect the current ledger).
    public var isUsageReady: Bool { appliedUsageGeneration == usageGeneration && appliedGlanceGeneration == glanceGeneration }

    /// Snapshots compare equal when everything but the scan timestamp matches.
    /// Attaches the live git checkout to a running session. Its branch beats the transcript's, which can lag a switch.
    static func withCheckout(_ session: AgentSession) -> AgentSession {
        guard !session.projectPath.isEmpty, let checkout = GitCheckout.locate(session.projectPath) else { return session }
        var updated = session
        updated.checkout = checkout
        if checkout.branch != nil || updated.branch.isEmpty { updated.branch = checkout.refLabel }
        return updated
    }

    private static func sameContent(_ lhs: AgentSnapshot, _ rhs: AgentSnapshot) -> Bool {
        lhs.processes == rhs.processes && lhs.sessions == rhs.sessions && lhs.limitReports == rhs.limitReports
            && lhs.integrations == rhs.integrations && lhs.warnings == rhs.warnings
    }

    /// Account limits run on their own task: some providers take seconds to answer and must never hold up the process list.
    public func refreshLimits(force: Bool = false) {
        guard !isDemo else { return }
        guard limitsTask == nil else { return }
        let enabled = settings.enabledAgents
        let accounts = settings.accountLimitAgents.intersection(enabled)
        if isRefreshingLimits != force { isRefreshingLimits = force }
        limitsTask = Task { [weak self] in
            let reports = await AgentLimitClients.read(enabledAgents: enabled, accountAgents: accounts, force: force)
            guard let self else { return }
            let updated = Dictionary(reports.map { ($0.agent, $0) }, uniquingKeysWith: { _, latest in latest })
            if updated != self.accountReports { self.accountReports = updated }
            self.limitsTask = nil
            if self.isRefreshingLimits { self.isRefreshingLimits = false }
        }
    }

    /// Replaces the hook states and re-applies them to the last scan without scanning again.
    public func setHookStates(_ states: [String: AgentHookState]) {
        guard states != hookStates else { return }
        hookStates = states
        let processes = AgentHookOverlay.apply(states, to: scannedProcesses)
        if processes != snapshot.processes { snapshot.processes = processes }
    }

    // MARK: - Settings

    public func saveSettings(_ updated: AgentSettings) {
        var normalized = updated
        normalized.historyDays = min(max(updated.historyDays, 7), 365)
        let accountsChanged = normalized.accountLimitAgents != settings.accountLimitAgents
        let agentsChanged = normalized.enabledAgents != settings.enabledAgents
        settings = normalized
        filter.agents.formIntersection(normalized.enabledAgents)
        persistSettings()
        scheduleTimer()
        if agentsChanged { rebuildUsage() }
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

    // MARK: - History

    /// The You page: a profile of `period` from the permanent history, built off the main actor. Cache it per
    /// `historyRevision`; a profile of all time over years of history takes a few milliseconds.
    public func profile(for period: ProfilePeriod, now: Date = .now) async -> PersonalProfile {
        await historyLoad?.value
        let history = history
        return await Task.detached(priority: .userInitiated) { history.profile(for: period, now: now) }.value
    }

    /// Milestones reached and not celebrated yet, earliest first. On the first run this includes everything found in
    /// the backfilled history; `EarnedMilestone.isRetroactive` tells those apart from ones reached just now.
    public var newMilestones: [EarnedMilestone] { history.unacknowledgedMilestones }

    /// True while some enabled agent's older logs are still being read into the history, so totals may still grow.
    public var isBackfillingHistory: Bool {
        persistsLedger && persistsHistory && (!isHistoryLoaded || !settings.enabledAgents.isSubset(of: history.backfilledAgents))
    }

    /// Reads the history file off the main thread. A file this build can't read is never written over.
    private func loadHistory() async {
        let url = UsageHistory.defaultURL(fileManager: fileManager)
        let manager = fileManager
        let result = await Task.detached(priority: .userInitiated) { UsageHistory.load(from: url, fileManager: manager) }.value
        switch result {
        case .loaded(let stored):
            history = stored
        case .missing:
            break
        case .newerFormat:
            persistsHistory = false
            historyWarning = "Usage history was saved by a newer Lookout; this one won't write over it"
        case .unreadable(let preservedAt):
            // Couldn't move it aside: then don't write over it either.
            persistsHistory = preservedAt != nil
            historyWarning = "Usage history could not be read" + (preservedAt.map { "; it was kept at \($0.path)" } ?? "")
        }
        historyRevision += 1
        isHistoryLoaded = true
    }

    /// Marks milestones as celebrated so `newMilestones` stops offering them.
    public func acknowledgeMilestones<S: Sequence>(_ ids: S) where S.Element == String {
        var updated = history
        updated.acknowledgeMilestones(ids)
        guard updated.acknowledgedMilestones != history.acknowledgedMilestones else { return }
        history = updated
        historyRevision += 1
        persistHistory(updated)
    }

    private struct UsageBundle: Sendable {
        var usage: AgentUsageReport
        var todayTotals: AgentUsageTotals
        var todayModels: [AgentUsageRow]
        var heatmap: [AgentHeatmapDay]
        var dailyByAgent: [AgentKind: [AgentHeatmapDay]]
        var glance: AgentUsageReport
        var spend: [AgentKind: AgentSpend]
    }

    /// Rebuilds every derived report off the main actor and publishes the result when it lands.
    /// A newer rebuild supersedes one still in flight.
    private func rebuildUsage() {
        searchRebuildTask?.cancel()
        usageBuiltAt = Date()
        usageGeneration += 1
        glanceGeneration += 1
        let generation = usageGeneration
        let glanceGen = glanceGeneration
        let events = ledgerEvents
        let filter = filter
        let enabled = settings.enabledAgents
        let search = searchText
        let glance = glanceFilter
        Task.detached(priority: .utility) { [weak self] in
            let bundle = Self.computeUsage(events: events, filter: filter, enabledAgents: enabled, search: search, glance: glance)
            await MainActor.run {
                guard let self else { return }
                self.applyUsage(
                    bundle,
                    usage: self.usageGeneration == generation,
                    glance: self.glanceGeneration == glanceGen
                )
                if self.usageGeneration == generation { self.appliedUsageGeneration = generation }
                if self.glanceGeneration == glanceGen { self.appliedGlanceGeneration = glanceGen }
            }
        }
    }

    /// Typing in the search field shouldn't rebuild a year of reports per keystroke.
    private func scheduleSearchRebuild() {
        searchRebuildTask?.cancel()
        searchRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.rebuildUsage()
        }
    }

    private func applyUsage(_ bundle: UsageBundle, usage applyMain: Bool, glance applyGlance: Bool) {
        if applyMain {
            usage = bundle.usage
            if todayTotals != bundle.todayTotals { todayTotals = bundle.todayTotals }
            if todayModels != bundle.todayModels { todayModels = bundle.todayModels }
            if heatmap != bundle.heatmap { heatmap = bundle.heatmap }
            if dailyByAgent != bundle.dailyByAgent { dailyByAgent = bundle.dailyByAgent }
            if spend != bundle.spend { spend = bundle.spend }
        }
        if applyGlance { glanceUsage = bundle.glance }
    }

    nonisolated private static func computeUsage(
        events: [AgentUsageEvent],
        filter: AgentUsageFilter,
        enabledAgents: Set<AgentKind>,
        search: String,
        glance: AgentUsageFilter
    ) -> UsageBundle {
        let usage = buildReport(events: events, filter: filter, enabledAgents: enabledAgents, search: search)
        var today = AgentUsageFilter()
        today.setPreset(.today)
        today.grouping = .model
        let todayReport = buildReport(events: events, filter: today, enabledAgents: enabledAgents)
        let (heatmap, perAgent) = computeHeatmap(events: events, filter: filter, enabledAgents: enabledAgents)
        let glanceReport = buildReport(events: events, filter: glance, enabledAgents: enabledAgents)
        return UsageBundle(
            usage: usage, todayTotals: todayReport.totals, todayModels: todayReport.rows,
            heatmap: heatmap, dailyByAgent: perAgent, glance: glanceReport,
            spend: AgentSpend.compute(events)
        )
    }

    /// Remembers the calendar interval (day or hour) the last event fell in. Events are mostly newest-first,
    /// so consecutive ones share an interval and skip the Calendar call.
    private struct IntervalCache {
        var start = Date.distantFuture
        var end = Date.distantPast

        mutating func bucketStart(of component: Calendar.Component, for date: Date, calendar: Calendar) -> Date {
            if date >= start && date < end { return start }
            guard let interval = calendar.dateInterval(of: component, for: date) else {
                return component == .day ? calendar.startOfDay(for: date) : date
            }
            start = interval.start
            end = interval.end
            return start
        }
    }

    nonisolated private static func computeHeatmap(
        events: [AgentUsageEvent],
        filter: AgentUsageFilter,
        enabledAgents: Set<AgentKind>
    ) -> ([AgentHeatmapDay], [AgentKind: [AgentHeatmapDay]]) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(AgentDateRange.oneYear.rawValue - 1), to: today) else { return ([], [:]) }
        let agents = filter.agents.isEmpty ? enabledAgents : filter.agents.intersection(enabledAgents)
        var days: [Date: AgentHeatmapDay] = [:]
        var perAgent: [AgentKind: [Date: AgentHeatmapDay]] = [:]
        var cache = IntervalCache()
        for event in events where event.observedAt >= windowStart {
            let inFilter = agents.contains(event.agent)
            let inEnabled = enabledAgents.contains(event.agent)
            guard inFilter || inEnabled else { continue }
            let day = cache.bucketStart(of: .day, for: event.observedAt, calendar: calendar)
            if inFilter { days[day, default: AgentHeatmapDay(date: day)].add(event) }
            if inEnabled { perAgent[event.agent, default: [:]][day, default: AgentHeatmapDay(date: day)].add(event) }
        }
        return (
            days.values.sorted { $0.date < $1.date },
            perAgent.mapValues { $0.values.sorted { $0.date < $1.date } }
        )
    }

    /// One day's usage for the dashboard's day detail, grouped as asked (models, projects…).
    public func dayReport(_ day: Date, agents: Set<AgentKind>, grouping: AgentUsageGrouping, metric: AgentMetricKind) -> AgentUsageReport {
        var filter = AgentUsageFilter()
        filter.setCustom(from: day, to: day)
        filter.agents = agents
        filter.grouping = grouping
        filter.metric = metric
        return Self.buildReport(events: ledgerEvents, filter: filter, enabledAgents: settings.enabledAgents)
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
        glanceGeneration += 1
        let generation = glanceGeneration
        let events = ledgerEvents
        let enabled = settings.enabledAgents
        let glance = glanceFilter
        Task.detached(priority: .utility) { [weak self] in
            let report = Self.buildReport(events: events, filter: glance, enabledAgents: enabled)
            await MainActor.run {
                guard let self, self.glanceGeneration == generation else { return }
                self.glanceUsage = report
                self.appliedGlanceGeneration = generation
            }
        }
    }

    private func saveGlance() {
        defaults.set(glanceRange.rawValue, forKey: Keys.glanceRange)
        defaults.set(glanceMetric.rawValue, forKey: Keys.glanceMetric)
        defaults.set(glanceAgents.map(\.rawValue), forKey: Keys.glanceAgents)
    }

    nonisolated public static func buildReport(
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
        var bucketCache = IntervalCache()

        for event in selected {
            let sessionKey = "\(event.agent.rawValue)|\(event.sessionID)"
            sessions.insert(sessionKey)
            report.totals.add(event)

            byAgent[event.agent, default: (AgentUsageTotals(), [])].0.add(event)
            byAgent[event.agent]!.1.insert(sessionKey)

            let key: String
            switch filter.grouping {
            case .agent: key = event.agent.rawValue
            case .model: key = event.model.isEmpty ? "Unknown model" : event.model
            case .project: key = event.projectName.isEmpty ? "Unknown workspace" : event.projectName
            }
            byGroup[key, default: (AgentUsageTotals(), [], [])].0.add(event)
            byGroup[key]!.1.insert(sessionKey)
            byGroup[key]!.2.insert(event.agent)

            let bucket = bucketCache.bucketStart(of: hourly ? .hour : .day, for: event.observedAt, calendar: calendar)
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
        // Desktop apps (Cursor, Qoder…) stay open all day and write nothing worth polling for; only CLI agents count.
        let active = snapshot.processes.contains { session in
            !(session.process.map { AgentDiscovery.isDesktopApp($0.processName) } ?? false)
        }
        let interval: TimeInterval = active ? 15 : 90
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

    /// Queues the ledger for writing. At most one write per `ledgerWriteInterval`; `flush()` writes immediately.
    private func persistLedger(_ events: [AgentUsageEvent]) {
        guard persistsLedger else { return }
        pendingLedger = events
        scheduleWrite()
    }

    /// Queues the history for writing alongside the ledger.
    private func persistHistory(_ history: UsageHistory) {
        guard persistsLedger, persistsHistory, isHistoryLoaded else { return }
        pendingHistory = history
        scheduleWrite()
    }

    private func scheduleWrite() {
        guard ledgerWriteTask == nil else { return }
        let wait = max(0, Self.ledgerWriteInterval - Date().timeIntervalSince(lastLedgerWrite))
        ledgerWriteTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            self.ledgerWriteTask = nil
            await self.writePending()
        }
    }

    private func writePending() async {
        let events = pendingLedger, history = pendingHistory
        guard events != nil || history != nil else { return }
        pendingLedger = nil
        pendingHistory = nil
        lastLedgerWrite = Date()
        let url = Self.ledgerURL(fileManager: fileManager)
        let historyURL = UsageHistory.defaultURL(fileManager: fileManager)
        let manager = fileManager
        // Encoding a year of events takes a moment; keep it off the main thread.
        let failure = await Task.detached(priority: .utility) { () -> String? in
            // Each file on its own: a failed ledger write mustn't hold back the history, which is the only copy.
            var failure: String?
            do {
                if let events { try Self.writeLedger(events, to: url, manager: manager) }
            } catch {
                failure = "Usage history could not be saved: \(error.localizedDescription)"
            }
            do {
                try history?.write(to: historyURL, fileManager: manager)
            } catch {
                failure = "Usage history could not be saved: \(error.localizedDescription)"
            }
            return failure
        }.value
        if let failure { lastError = failure }
    }

    nonisolated private static func writeLedger(_ events: [AgentUsageEvent], to url: URL, manager: FileManager) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Ledger(version: ledgerVersion, events: events))
        try data.write(to: url, options: .atomic)
    }

    /// Writes any pending ledger and history now, synchronously. Call when the app is about to quit.
    public func flush() {
        guard persistsLedger else { return }
        ledgerWriteTask?.cancel()
        ledgerWriteTask = nil
        let events = pendingLedger, history = pendingHistory
        pendingLedger = nil
        pendingHistory = nil
        guard events != nil || history != nil else { return }
        lastLedgerWrite = Date()
        if let events { try? Self.writeLedger(events, to: Self.ledgerURL(fileManager: fileManager), manager: fileManager) }
        try? history?.write(to: UsageHistory.defaultURL(fileManager: fileManager), fileManager: fileManager)
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
        // Readers can revise older events in place (same id, new counts), which the newest few alone would miss.
        hasher.combine(events.reduce(Int64(0)) { $0 &+ ($1.usage.processedTokens ?? 0) })
        // Effort arrives on history already in the ledger when a reader learns to parse it; count it so that backfill persists.
        hasher.combine(events.reduce(0) { $0 + ($1.effort == nil ? 0 : 1) })
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
