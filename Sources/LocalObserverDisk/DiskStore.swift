import Foundation
import Combine

public enum DiskSort: String, CaseIterable, Identifiable, Sendable {
    case size = "Largest"
    case age = "Oldest"
    case name = "Name"
    public var id: String { rawValue }
}

/// The Disk pillar: how full the drive is, what's taking the space that Lookout can explain (build artifacts,
/// worktrees, caches, Xcode, Docker, agent data), and clearing the safe parts. Stands alone: the app tells it which
/// project folders and worktrees exist and what's in use; it never reads the other stores.
@MainActor
public final class DiskStore: ObservableObject {
    public static let shared = DiskStore()

    @Published public private(set) var volume: DiskVolume?
    @Published public private(set) var items: [DiskItem] = []
    @Published public private(set) var isScanning = false
    /// Items measured so far, out of all found, while a scan runs.
    @Published public private(set) var measured = 0
    @Published public private(set) var lastScan: Date?
    @Published public private(set) var clearing: Set<String> = []
    /// Space freed this session, for the page header.
    @Published public private(set) var freed: Int64 = 0
    @Published public var selection: Set<String> = []
    @Published public var sort: DiskSort = .size
    @Published public var searchText = ""
    @Published public var settings: DiskSettings {
        didSet { if settings != oldValue, let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) } }
    }

    /// Result of a cleanup, for the app to show as a toast: message, succeeded.
    public var onActionResult: ((String, Bool) -> Void)?
    /// Called after worktrees are removed, so the app can rescan repositories.
    public var onWorktreesChanged: (() -> Void)?

    private let defaults: UserDefaults
    private static let settingsKey = "LocalObserver.diskSettings"
    private var scanTask: Task<Void, Never>?
    private var isDemo = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(DiskSettings.self, from: $0) } ?? DiskSettings()
    }

    // MARK: Volume

    public func refreshVolume() {
        guard !isDemo else { return }
        Task {
            let v = await Task.detached(priority: .utility) { DiskScanner.volume() }.value
            if v != self.volume { self.volume = v }
        }
    }

    public var isLowOnSpace: Bool {
        guard let volume else { return false }
        return volume.available < Int64(settings.lowSpaceGB) * 1_000_000_000
    }

    // MARK: Scanning

    /// Finds everything, shows it at once, then measures sizes four at a time, filling the list in as they land.
    public func scan(projects: [DiskProject], worktrees: [DiskWorktree]) {
        guard !isDemo, scanTask == nil else { return }
        isScanning = true
        measured = 0
        refreshVolume()
        let previous = Dictionary(items.map { ($0.id, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        scanTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [DiskItem] in
                DiskScanner.fixedItems() + DiskScanner.worktreeItems(worktrees) + DiskScanner.artifacts(in: projects) + DiskScanner.dockerItems()
            }.value
            guard let self else { return }
            // Keep last scan's sizes visible while re-measuring, so the list doesn't flash to "…".
            self.items = found.map { item in
                var item = item
                if item.bytes == nil, let old = previous[item.id] { item.bytes = old }
                return item
            }
            self.selection = self.selection.filter { id in found.contains { $0.id == id } }
            // Docker reports its own sizes; everything with a folder is measured.
            let toMeasure = found.filter { !$0.path.isEmpty && $0.kind != .prunableWorktree }
            self.measured = found.count - toMeasure.count
            await self.measure(toMeasure)
            self.lastScan = Date()
            self.isScanning = false
            self.scanTask = nil
        }
    }

    private func measure(_ list: [DiskItem]) async {
        await withTaskGroup(of: (String, Int64?).self) { group in
            var iterator = list.makeIterator()
            for _ in 0..<4 {
                guard let item = iterator.next() else { break }
                group.addTask(priority: .utility) { (item.id, DiskScanner.size(item.path)) }
            }
            for await (id, bytes) in group {
                if let index = items.firstIndex(where: { $0.id == id }) { items[index].bytes = bytes ?? 0 }
                measured += 1
                if let item = iterator.next() {
                    group.addTask(priority: .utility) { (item.id, DiskScanner.size(item.path)) }
                }
            }
        }
    }

    // MARK: Derived

    public func items(in category: DiskCategory) -> [DiskItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return items
            .filter { $0.kind.category == category }
            // Measured and under a megabyte isn't worth a row; worktrees always show, they're about more than size.
            .filter { $0.bytes.map { $0 >= 1_000_000 } ?? true || category == .worktrees }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || ($0.project?.lowercased().contains(q) ?? false)
                || $0.path.lowercased().contains(q) }
            .sorted { a, b in
                switch sort {
                case .size: return (a.bytes ?? -1) != (b.bytes ?? -1) ? (a.bytes ?? -1) > (b.bytes ?? -1) : a.name < b.name
                case .age: return (a.lastUsed ?? .distantPast) < (b.lastUsed ?? .distantPast)
                case .name: return (a.project ?? a.name).localizedCaseInsensitiveCompare(b.project ?? b.name) == .orderedAscending
                }
            }
    }

    public func total(_ category: DiskCategory) -> Int64 {
        items.filter { $0.kind.category == category }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    /// Everything that can be cleared without a second thought.
    public var safeBytes: Int64 { items.filter { $0.canClear && $0.safety == .safe }.reduce(0) { $0 + ($1.bytes ?? 0) } }
    public var clearableBytes: Int64 { items.filter(\.canClear).reduce(0) { $0 + ($1.bytes ?? 0) } }

    /// Safe items nobody has touched in `staleDays`: what "Select suggested" picks.
    public var suggested: [DiskItem] {
        items.filter { $0.canClear && $0.safety == .safe && $0.isStale(days: settings.staleDays) && ($0.bytes ?? 0) > 1_000_000 }
    }

    public var selectedItems: [DiskItem] { items.filter { selection.contains($0.id) && $0.canClear } }
    public var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + ($1.bytes ?? 0) } }

    public func toggle(_ item: DiskItem) {
        guard item.canClear else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    public func selectSuggested() { selection = Set(suggested.map(\.id)) }

    // MARK: Clearing

    public func clear(_ targets: [DiskItem]) {
        let targets = targets.filter { $0.canClear && !clearing.contains($0.id) }
        guard !targets.isEmpty else { return }
        if isDemo {
            onActionResult?("Cleared \(targets.count) item\(targets.count == 1 ? "" : "s") (demo)", true)
            return
        }
        clearing.formUnion(targets.map(\.id))
        Task { [weak self] in
            var freedNow: Int64 = 0
            var failures: [String] = []
            var cleared: Set<String> = []
            var worktreesChanged = false
            // Two at a time: deletes are disk-bound, and Docker/git commands shouldn't pile up.
            await withTaskGroup(of: (DiskItem, Result<Int64, DiskScanner.Failure>).self) { group in
                var iterator = targets.makeIterator()
                for _ in 0..<2 { if let t = iterator.next() { group.addTask(priority: .userInitiated) { (t, DiskScanner.clear(t)) } } }
                for await (item, result) in group {
                    switch result {
                    case .success(let bytes):
                        freedNow += bytes
                        cleared.insert(item.id)
                        if item.kind.category == .worktrees { worktreesChanged = true }
                    case .failure(let failure):
                        failures.append("\(item.name): \(failure.message)")
                    }
                    if let t = iterator.next() { group.addTask(priority: .userInitiated) { (t, DiskScanner.clear(t)) } }
                }
            }
            guard let self else { return }
            self.clearing.subtract(targets.map(\.id))
            self.selection.subtract(cleared)
            // Docker totals stay (with nothing left to reclaim); folders that are gone leave the list.
            self.items = self.items.compactMap { item in
                guard cleared.contains(item.id) else { return item }
                if item.kind.category == .docker { var i = item; i.bytes = 0; return i }
                return nil
            }
            self.freed += freedNow
            self.refreshVolume()
            if worktreesChanged { self.onWorktreesChanged?() }
            if failures.isEmpty {
                self.onActionResult?("Freed \(DiskFormat.bytes(freedNow))", true)
            } else {
                let head = cleared.isEmpty ? "" : "Freed \(DiskFormat.bytes(freedNow)). "
                self.onActionResult?(head + failures.prefix(2).joined(separator: "; "), false)
            }
        }
    }

    // MARK: Demo

    public func loadDemo(volume: DiskVolume, items: [DiskItem]) {
        isDemo = true
        self.volume = volume
        self.items = items
        lastScan = Date()
    }
}
