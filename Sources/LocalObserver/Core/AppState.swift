import Foundation
import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case all
    case favorites
    case launchers
    case agentActivity
    case agentUsage
    case agentLimits
    case group(TypeGroup)

    var title: String {
        switch self {
        case .all: return "All servers"
        case .favorites: return "Favorites"
        case .launchers: return "Launchers"
        case .agentActivity: return "Activity"
        case .agentUsage: return "Usage"
        case .agentLimits: return "Limits"
        case .group(let g): return g.rawValue
        }
    }

    var symbol: String {
        switch self {
        case .all: return "server.rack"
        case .favorites: return "star"
        case .launchers: return "play.square.stack"
        case .agentActivity: return "waveform.path.ecg"
        case .agentUsage: return "chart.xyaxis.line"
        case .agentLimits: return "gauge.with.dots.needle.33percent"
        case .group(let g): return g.symbol
        }
    }

    var isAgentPage: Bool {
        switch self {
        case .agentActivity, .agentUsage, .agentLimits: return true
        default: return false
        }
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case table = "Table"
    case gallery = "Gallery"
    var id: String { rawValue }
    var symbol: String { self == .table ? "list.bullet" : "square.grid.2x2" }
}

enum SortKey: String, CaseIterable, Identifiable {
    case port = "Port"
    case name = "Name"
    case uptime = "Uptime"
    case memory = "Memory"
    case cpu = "CPU"
    case latency = "Response time"
    var id: String { rawValue }
}

struct Toast: Identifiable {
    enum Tone { case neutral, success, danger }
    let id = UUID()
    var message: String
    var symbol: String = "info.circle"
    var tone: Tone = .neutral
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
}

/// Form state for creating or editing a launcher.
struct LauncherDraft: Identifiable {
    let id = UUID()
    var editingID: UUID? = nil
    var name = ""
    var folder = ""
    var command = ""
    var port = ""
    var startNow = true
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var servers: [ServerEntry] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date? = nil
    @Published private(set) var stopping: Set<String> = []
    @Published var searchText = ""
    @Published var sidebar: SidebarItem = .all
    @Published var selection: String? = nil
    @Published var toast: Toast? = nil
    @Published var draft: LauncherDraft? = nil
    @Published var sortKey: SortKey = .port
    @Published var sortDescending = false
    @Published var serverFilter = ServerFilter()
    @Published var viewMode: ViewMode { didSet { defaults.set(viewMode.rawValue, forKey: Keys.viewMode) } }
    @Published var showSystem: Bool { didSet { defaults.set(showSystem, forKey: Keys.showSystem) } }
    @Published var autoRefresh: Bool { didSet { defaults.set(autoRefresh, forKey: Keys.autoRefresh); scheduleTimer() } }
    @Published private(set) var favorites: Set<Int>
    @Published private(set) var managed: [ManagedServer] = []

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    /// Consecutive failed probes per server — a single slow response shouldn't flip a row to "TCP".
    private var probeFailures: [String: Int] = [:]

    private enum Keys {
        static let favorites = "LocalObserver.favorites"
        static let managed = "LocalObserver.managed"
        static let viewMode = "LocalObserver.viewMode"
        static let showSystem = "LocalObserver.showSystem"
        static let autoRefresh = "LocalObserver.autoRefresh"
    }

    init() {
        favorites = Set(defaults.array(forKey: Keys.favorites) as? [Int] ?? [])
        viewMode = ViewMode(rawValue: defaults.string(forKey: Keys.viewMode) ?? "") ?? .table
        showSystem = defaults.bool(forKey: Keys.showSystem)
        autoRefresh = defaults.object(forKey: Keys.autoRefresh) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.managed),
           let decoded = try? JSONDecoder().decode([ManagedServer].self, from: data) {
            managed = decoded
        }
        scheduleTimer()
        refresh()
    }

    // MARK: - scanning

    private func scheduleTimer() {
        timer?.invalidate()
        guard autoRefresh else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(quiet: true) }
        }
        timer?.tolerance = 0.5
    }

    /// Coalesces: if a scan is already running, this call is a no-op.
    func refresh(quiet: Bool = false) {
        guard scanTask == nil else { return }
        if !quiet { isScanning = true }
        scanTask = Task { [weak self] in
            let result = await PortScanner.scan()
            guard let self else { return }
            self.apply(result)
            self.scanTask = nil
            self.isScanning = false
        }
    }

    /// Refresh a few times after a start/stop so the list catches the change as soon as it happens.
    private func refreshSoon(_ delays: [Double] = [0.4, 1.2, 3, 6]) {
        for d in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.refresh(quiet: true) }
        }
    }

    private func apply(_ fresh: [ServerEntry]) {
        let previous = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next = fresh
        for i in next.indices {
            let id = next[i].id
            if !next[i].isResponding, let old = previous[id], old.isResponding {
                let fails = (probeFailures[id] ?? 0) + 1
                probeFailures[id] = fails
                if fails < 3 {
                    next[i].httpState = old.httpState
                    next[i].statusCode = old.statusCode
                    next[i].latencyMs = old.latencyMs
                    next[i].pageTitle = old.pageTitle
                    next[i].iconHref = old.iconHref
                }
            } else {
                probeFailures[id] = nil
            }
            if let m = managed.first(where: { $0.lastPGID != nil && $0.lastPGID == next[i].pgid }) {
                next[i].managedID = m.id
            }
        }
        let alive = Set(next.map(\.id))
        probeFailures = probeFailures.filter { alive.contains($0.key) }
        stopping = stopping.filter { alive.contains($0) }

        if next.map(\.id) != servers.map(\.id) {
            withAnimation(.snappy(duration: 0.28)) { servers = next }
        } else if next != servers {
            servers = next
        }
        if let sel = selection, !alive.contains(sel) { selection = nil }
        lastScan = Date()
    }

    // MARK: - derived

    var visibleServers: [ServerEntry] { showSystem ? servers : servers.filter { !$0.isSystemProcess && $0.projectType != .system } }

    var filtered: [ServerEntry] {
        var list = visibleServers
        switch sidebar {
        case .all, .launchers, .agentActivity, .agentUsage, .agentLimits: break
        case .favorites: list = list.filter { favorites.contains($0.port) }
        case .group(let g): list = list.filter { $0.projectType.group == g }
        }
        if serverFilter.isNarrowed { list = list.filter(serverFilter.matches) }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                [$0.projectName, $0.processName, $0.command, String($0.port), $0.workingDirectory, $0.pageTitle]
                    .contains { $0.lowercased().contains(q) }
            }
        }
        return list.sorted { a, b in
            let fa = favorites.contains(a.port), fb = favorites.contains(b.port)
            if fa != fb { return fa }
            // Your projects first; app helpers (VS Code, Chrome…) sink below them.
            let aa = a.projectType == .app, ab = b.projectType == .app
            if aa != ab { return ab }
            let ascending: Bool
            switch sortKey {
            case .port: ascending = a.port < b.port
            case .name: ascending = a.projectName.localizedCaseInsensitiveCompare(b.projectName) == .orderedAscending
            case .uptime: ascending = a.uptime < b.uptime
            case .memory: ascending = a.rssKB > b.rssKB
            case .cpu: ascending = a.cpu > b.cpu
            case .latency: ascending = (a.latencyMs > 0 ? a.latencyMs : .max) < (b.latencyMs > 0 ? b.latencyMs : .max)
            }
            return ascending != sortDescending
        }
    }

    /// Servers in the current sidebar group before search and filters — the pool filter menus draw from.
    var groupServers: [ServerEntry] {
        switch sidebar {
        case .favorites: return visibleServers.filter { favorites.contains($0.port) }
        case .group(let g): return visibleServers.filter { $0.projectType.group == g }
        default: return visibleServers
        }
    }

    func clearServerFilters() {
        serverFilter = ServerFilter()
        searchText = ""
    }

    func count(for item: SidebarItem) -> Int {
        switch item {
        case .all: return visibleServers.count
        case .favorites: return visibleServers.filter { favorites.contains($0.port) }.count
        case .launchers: return managed.count
        case .agentActivity, .agentUsage, .agentLimits: return 0
        case .group(let g): return visibleServers.filter { $0.projectType.group == g }.count
        }
    }

    var respondingCount: Int { visibleServers.filter(\.isResponding).count }

    var selected: ServerEntry? { selection.flatMap { id in servers.first { $0.id == id } } }

    func server(for launcher: ManagedServer) -> ServerEntry? { servers.first { $0.managedID == launcher.id } }

    func isRunning(_ launcher: ManagedServer) -> Bool {
        guard let pgid = launcher.lastPGID else { return false }
        return ProcessManager.isGroupAlive(pgid: pgid)
    }

    // MARK: - feedback

    func show(_ t: Toast) {
        toastTask?.cancel()
        withAnimation(.snappy(duration: 0.25)) { toast = t }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(t.action == nil ? 2.6 : 5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self?.toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = nil }
    }

    // MARK: - server actions

    func toggleFavorite(_ server: ServerEntry) {
        if favorites.contains(server.port) { favorites.remove(server.port) } else { favorites.insert(server.port) }
        defaults.set(Array(favorites), forKey: Keys.favorites)
    }

    func stop(_ server: ServerEntry, force: Bool = false) {
        let launcher = managed.first { $0.id == server.managedID }
        let sent: Bool
        if let pgid = launcher?.lastPGID, ProcessManager.isGroupAlive(pgid: pgid) {
            sent = ProcessManager.terminateGroup(pgid: pgid, force: force)
        } else {
            sent = ProcessManager.terminate(pid: server.pid, force: force)
        }
        guard sent else {
            show(Toast(message: "Couldn’t stop \(server.projectName) — it may belong to another user",
                       symbol: "exclamationmark.triangle", tone: .danger))
            return
        }
        stopping.insert(server.id)
        refreshSoon([0.3, 1.0])

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            if ProcessManager.isAlive(pid: server.pid) && !force {
                self.show(Toast(message: "\(server.projectName) is still running", symbol: "exclamationmark.triangle",
                                tone: .danger, actionTitle: "Force quit") { [weak self] in self?.stop(server, force: true) })
            } else if let launcher {
                self.show(Toast(message: "Stopped \(server.projectName)", symbol: "stop.circle", tone: .neutral,
                                actionTitle: "Start again") { [weak self] in self?.start(launcher) })
            } else {
                self.show(Toast(message: "Stopped \(server.projectName) on :\(server.port)", symbol: "stop.circle"))
            }
        }
    }

    func open(_ server: ServerEntry) { ProcessManager.openURL(server.urlString) }
    func reveal(_ server: ServerEntry) { ProcessManager.reveal(path: server.projectRoot.isEmpty ? server.workingDirectory : server.projectRoot) }
    func openTerminal(_ server: ServerEntry) { ProcessManager.openInTerminal(path: server.workingDirectory) }
    func openEditor(_ server: ServerEntry) { ProcessManager.openInEditor(path: server.projectRoot.isEmpty ? server.workingDirectory : server.projectRoot) }

    func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(Toast(message: "Copied \(label)", symbol: "doc.on.doc", tone: .success))
    }

    /// Prefills the launcher form from a discovered server.
    func draftLauncher(from server: ServerEntry) {
        let folder = server.projectRoot.isEmpty ? server.workingDirectory : server.projectRoot
        var d = CommandSuggester.draft(for: folder)
        d.name = server.projectName
        d.port = String(server.port)
        d.startNow = false
        draft = d
    }

    func draftLauncher(folder: String) {
        draft = CommandSuggester.draft(for: folder)
    }

    // MARK: - launchers

    func save(_ d: LauncherDraft) {
        let name = d.name.trimmingCharacters(in: .whitespaces)
        var launcher: ManagedServer
        if let id = d.editingID, let i = managed.firstIndex(where: { $0.id == id }) {
            managed[i].name = name.isEmpty ? managed[i].name : name
            managed[i].workingDirectory = d.folder
            managed[i].command = d.command
            managed[i].port = Int(d.port)
            launcher = managed[i]
        } else {
            launcher = ManagedServer(name: name.isEmpty ? (d.folder as NSString).lastPathComponent : name,
                                     workingDirectory: d.folder, command: d.command, port: Int(d.port))
            managed.append(launcher)
        }
        persistManaged()
        if d.startNow { start(launcher) }
    }

    func start(_ launcher: ManagedServer) {
        if let port = launcher.port, let owner = servers.first(where: { $0.port == port }) {
            show(Toast(message: "Port \(port) is taken by \(owner.projectName)", symbol: "exclamationmark.triangle",
                       tone: .danger, actionTitle: "Stop it") { [weak self] in self?.stop(owner) })
            return
        }
        do {
            let pgid = try ProcessManager.launch(launcher)
            if let i = managed.firstIndex(where: { $0.id == launcher.id }) {
                managed[i].lastPGID = pgid
                persistManaged()
            }
            show(Toast(message: "Starting \(launcher.name)…", symbol: "play.circle", tone: .success))
            refreshSoon([0.8, 2, 4, 7, 12])
        } catch {
            show(Toast(message: error.localizedDescription, symbol: "exclamationmark.triangle", tone: .danger))
        }
    }

    func stop(_ launcher: ManagedServer) {
        if let s = server(for: launcher) { stop(s); return }
        guard let pgid = launcher.lastPGID, ProcessManager.terminateGroup(pgid: pgid) else { return }
        show(Toast(message: "Stopped \(launcher.name)", symbol: "stop.circle"))
        refreshSoon([0.3, 1.0])
    }

    func restart(_ launcher: ManagedServer) {
        guard let pgid = launcher.lastPGID, ProcessManager.isGroupAlive(pgid: pgid) else { start(launcher); return }
        ProcessManager.terminateGroup(pgid: pgid)
        Task { [weak self] in
            for _ in 0..<30 where ProcessManager.isGroupAlive(pgid: pgid) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if ProcessManager.isGroupAlive(pgid: pgid) { ProcessManager.terminateGroup(pgid: pgid, force: true) }
            try? await Task.sleep(for: .milliseconds(250))
            self?.refresh(quiet: true)
            try? await Task.sleep(for: .milliseconds(400))
            self?.start(launcher)
        }
    }

    func edit(_ launcher: ManagedServer) {
        draft = LauncherDraft(editingID: launcher.id, name: launcher.name, folder: launcher.workingDirectory,
                              command: launcher.command, port: launcher.port.map(String.init) ?? "", startNow: false)
    }

    func remove(_ launcher: ManagedServer) {
        guard let index = managed.firstIndex(where: { $0.id == launcher.id }) else { return }
        withAnimation(.snappy) { _ = managed.remove(at: index) }
        persistManaged()
        show(Toast(message: "Removed \(launcher.name)", symbol: "trash", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            withAnimation(.snappy) { self.managed.insert(launcher, at: min(index, self.managed.count)) }
            self.persistManaged()
        })
    }

    func moveLaunchers(from source: IndexSet, to destination: Int) {
        managed.move(fromOffsets: source, toOffset: destination)
        persistManaged()
    }

    private func persistManaged() {
        if let data = try? JSONEncoder().encode(managed) { defaults.set(data, forKey: Keys.managed) }
    }
}
