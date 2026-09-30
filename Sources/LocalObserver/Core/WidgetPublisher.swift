import AppKit
import WidgetKit
import LocalObserverCore

/// Keeps the desktop widgets fed. Writes a `WidgetSnapshot` the sandboxed extension can read, and asks WidgetKit
/// to reload only when something a glance would notice has changed. WidgetKit budgets reloads from apps that
/// aren't frontmost (a menu bar app almost never is), so token counts ticking up don't trigger one; the widgets
/// re-read the file on their own every half hour anyway.
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    /// Rewrite the file at least this often so the widgets can tell a quiet app from a stopped one.
    private static let heartbeat: TimeInterval = 5 * 60
    private static let minReloadGap: TimeInterval = 60
    /// A new "needs you" is worth spending a reload on sooner.
    private static let urgentReloadGap: TimeInterval = 10

    private var pending: Task<Void, Never>?
    private var lastPayload: Data?
    private var lastWrite = Date.distantPast
    private var lastReloadKey: Int?
    private var lastAttention: Set<String> = []
    private var lastReload = Date.distantPast
    private var reloadTask: Task<Void, Never>?
    /// Icon files already on disk, so each is encoded once rather than on every publish.
    private var writtenIcons: Set<String> = []
    private var resolvingIcons: Set<String> = []

    /// Coalesces bursts of store changes into one publish a couple of seconds later.
    func schedule(state: AppState, agentStore: AgentStore) {
        guard pending == nil else { return }
        pending = Task { [weak self, weak state, weak agentStore] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let state, let agentStore else { return }
            self.pending = nil
            self.publish(state: state, agentStore: agentStore)
        }
    }

    func publish(state: AppState, agentStore: AgentStore) {
        var snapshot = Self.snapshot(state: state, agentStore: agentStore, prefs: .shared)
        snapshot.servers = attachIcons(to: snapshot.servers, from: state, agentStore: agentStore)
        // Compare content only, so an unchanged snapshot isn't rewritten on every refresh.
        var comparable = snapshot
        comparable.generatedAt = .distantPast
        let payload = try? WidgetSnapshot.encoder.encode(comparable)
        let now = Date.now
        guard payload != lastPayload || now.timeIntervalSince(lastWrite) >= Self.heartbeat else { return }
        do {
            try snapshot.write()
            lastPayload = payload
            lastWrite = now
        } catch {
            return
        }
        requestReload(for: snapshot)
    }

    private func requestReload(for snapshot: WidgetSnapshot) {
        let key = Self.reloadKey(snapshot)
        guard key != lastReloadKey else { return }
        let attention = Set(snapshot.sessions.filter(\.needsAttention).map(\.id))
        let urgent = !attention.subtracting(lastAttention).isEmpty
        lastAttention = attention
        let gap = urgent ? Self.urgentReloadGap : Self.minReloadGap
        let wait = max(0, gap - Date.now.timeIntervalSince(lastReload))
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            WidgetCenter.shared.reloadAllTimelines()
            self.lastReload = .now
            self.lastReloadKey = key
        }
    }

    /// What a glance would notice: which sessions exist and their state, limits in 5% steps, servers and health.
    private static func reloadKey(_ snapshot: WidgetSnapshot) -> Int {
        var hasher = Hasher()
        for session in snapshot.sessions { hasher.combine(session.id); hasher.combine(session.state) }
        for provider in snapshot.providers {
            for window in provider.windows { hasher.combine(window.id); hasher.combine(Int(window.usedPercent / 5)) }
        }
        for server in snapshot.servers { hasher.combine(server.port); hasher.combine(server.health); hasher.combine(server.icon) }
        hasher.combine(snapshot.glanceProviders)
        return hasher.finalize()
    }

    // MARK: Icons

    /// Points each server at a PNG of the icon the Servers page shows. The sandboxed widget can't fetch favicons
    /// itself, so the app writes the ones it has resolved; missing ones are resolved now and published after.
    private func attachIcons(to servers: [WidgetSnapshot.Server], from state: AppState, agentStore: AgentStore) -> [WidgetSnapshot.Server] {
        let entries = Dictionary(state.visibleServers.map { ($0.port, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        var names: Set<String> = []
        let result = servers.map { server -> WidgetSnapshot.Server in
            guard let entry = entries[server.port] else { return server }
            guard let image = IconStore.shared.cached(for: entry) else {
                resolveIcon(for: entry, state: state, agentStore: agentStore)
                return server
            }
            let name = Self.iconName(entry.iconKey)
            guard writtenIcons.contains(name) || Self.writePNG(image, name: name) else { return server }
            writtenIcons.insert(name)
            names.insert(name)
            var server = server
            server.icon = name
            return server
        }
        pruneIcons(keeping: names)
        return result
    }

    private func resolveIcon(for entry: ServerEntry, state: AppState, agentStore: AgentStore) {
        guard resolvingIcons.insert(entry.iconKey).inserted else { return }
        Task { [weak self, weak state, weak agentStore] in
            let image = await IconStore.shared.icon(for: entry)
            guard let self else { return }
            self.resolvingIcons.remove(entry.iconKey)
            if image != nil, let state, let agentStore { self.schedule(state: state, agentStore: agentStore) }
        }
    }

    /// Drops icons for servers that have gone, so the folder doesn't collect every project ever run.
    private func pruneIcons(keeping names: Set<String>) {
        let stale = writtenIcons.subtracting(names)
        guard !stale.isEmpty else { return }
        for name in stale {
            try? FileManager.default.removeItem(at: WidgetSnapshot.iconsDirectory.appendingPathComponent(name))
        }
        writtenIcons = names
    }

    /// Stable across launches (Swift's Hasher is seeded per process), so an icon keeps its file name.
    private static func iconName(_ key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16) + ".png"
    }

    private static func writePNG(_ image: NSImage, name: String) -> Bool {
        var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: WidgetSnapshot.iconsDirectory, withIntermediateDirectories: true)
            try data.write(to: WidgetSnapshot.iconsDirectory.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Building

    private static var hourlyCache: (key: [AnyHashable], buckets: [WidgetSnapshot.Bucket])?

    /// Last 24 hours by agent. Walking the whole ledger for it on every publish was the costliest part of
    /// publishing, so it's rebuilt only when the ledger changes or the hour turns over.
    private static func hourlyBuckets(_ agentStore: AgentStore, now: Date) -> [WidgetSnapshot.Bucket] {
        let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let key: [AnyHashable] = [agentStore.ledgerRevision, hour, agentStore.settings.enabledAgents]
        if let hourlyCache, hourlyCache.key == key { return hourlyCache.buckets }
        var lastDay = AgentUsageFilter()
        AgentGlanceRange.last24h.apply(to: &lastDay)
        lastDay.metric = .tokens
        lastDay.grouping = .agent
        let buckets = AgentStore.buildReport(events: agentStore.ledgerEvents, filter: lastDay,
                                             enabledAgents: agentStore.settings.enabledAgents, now: now)
            .buckets.map { WidgetSnapshot.Bucket(date: $0.date, agent: $0.agent, value: $0.value) }
        hourlyCache = (key, buckets)
        return buckets
    }

    static func snapshot(state: AppState, agentStore: AgentStore, prefs: Preferences, now: Date = .now) -> WidgetSnapshot {
        // Same set as the Dock: desktop chat apps aren't sessions you jump back into.
        let sessions = agentStore.runningSessions
            .filter { !($0.process.map { AgentDiscovery.isDesktopApp($0.processName) } ?? false) }
            .map { session in
                WidgetSnapshot.Session(id: session.id, agent: session.agent, project: session.projectName, title: session.title,
                                       model: session.model, state: session.state,
                                       startedAt: session.process?.startedAt ?? session.startedAt,
                                       tokens: session.usage?.processedTokens)
            }

        let allWindows = agentStore.limitReports.flatMap(\.windows)
        let providers = agentStore.limitReports.map { report in
            WidgetSnapshot.Provider(agent: report.agent, plan: report.plan, windows: report.windows.map(WidgetSnapshot.Window.init),
                                    headlineID: prefs.primaryWindow(for: report.agent, in: allWindows)?.id)
        }

        let totals = agentStore.todayTotals
        let modelTotal = agentStore.todayModels.reduce(Int64(0)) { $0 + $1.totals.processed }
        let models = agentStore.todayModels.prefix(6).map { row in
            WidgetSnapshot.Model(title: row.title, agent: row.agent ?? row.agents.first, tokens: row.totals.processed,
                                 cost: row.totals.hasCost ? row.totals.cost : nil,
                                 share: modelTotal > 0 ? Double(row.totals.processed) / Double(modelTotal) : 0)
        }
        let hourly = hourlyBuckets(agentStore, now: now)
        let today = WidgetSnapshot.Usage(processed: totals.processed, cost: totals.hasCost ? totals.cost : nil,
                                         costIsEstimated: totals.costIsEstimated, sessions: totals.sessions,
                                         cacheHitRate: totals.cacheHitRate, hourly: hourly, models: models)

        let servers = state.visibleServers
            .filter { $0.projectType != .app }
            .sorted { $0.port < $1.port }
            .map { server -> WidgetSnapshot.Server in
                let tag = server.statusTag
                let health: WidgetSnapshot.Server.Health
                switch tag.color {
                case .green: health = .live
                case .orange, .yellow: health = .warning
                case .red: health = .failing
                default: health = .quiet
                }
                return WidgetSnapshot.Server(port: server.port, name: server.projectName, url: server.urlString,
                                             symbol: server.projectType.symbol, health: health, status: tag.text,
                                             uptime: server.uptime)
            }

        return WidgetSnapshot(generatedAt: now, sessions: sessions, providers: providers, glanceProviders: prefs.limitProviders,
                              today: today, servers: servers)
    }
}
