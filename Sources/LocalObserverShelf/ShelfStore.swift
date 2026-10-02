import AppKit
import Combine

/// The Shelf pillar: things dragged in, kept until removed, and a history of what was copied, pruned by count and
/// age. Pinned items are exempt from both limits. Everything stays under `Shelf/`; nothing is sent anywhere.
@MainActor
public final class ShelfStore: ObservableObject {
    public static let shared = ShelfStore()

    public static let shelfLimit = 200
    public static let historyLimits = [100, 250, 500, 1_000]
    public static let historyMaxAge: TimeInterval = 30 * 86_400

    /// Newest first, as stored. Views put pinned items first.
    @Published public private(set) var shelf: [ShelfItem] = []
    @Published public private(set) var history: [ShelfItem] = []
    @Published public var isPaused: Bool {
        didSet {
            defaults.set(isPaused, forKey: Keys.paused)
            updateCapture()
        }
    }
    @Published public var historyLimit: Int {
        didSet {
            defaults.set(historyLimit, forKey: Keys.historyLimit)
            pruneHistory()
            save()
        }
    }
    /// Bundle ids of apps whose copies are never recorded.
    @Published public var excludedApps: [String] { didSet { defaults.set(excludedApps, forKey: Keys.excludedApps) } }

    /// Runs after the widget's snapshot file changes, so the app can ask WidgetKit to reload the Shelf widget.
    public var widgetDidChange: (() -> Void)?

    public let directory: URL
    private var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private var archiveURL: URL { directory.appendingPathComponent("history.json") }
    private let defaults: UserDefaults
    private let publishesWidget: Bool
    /// The system clipboard, except in verification, which uses a private one.
    private let pasteboard: NSPasteboard
    private lazy var monitor = ClipboardMonitor(pasteboard: pasteboard) { [weak self] in self?.pasteboardChanged($0) }
    private var started = false
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0
    private var publishedShelf: [ShelfItem]?

    private enum Keys {
        static let paused = "LocalObserver.shelf.paused"
        static let historyLimit = "LocalObserver.shelf.historyLimit"
        static let excludedApps = "LocalObserver.shelf.excludedApps"
    }

    public init(directory: URL = ShelfPaths.root, defaults: UserDefaults = .standard, publishesWidget: Bool = true,
                pasteboard: NSPasteboard = .general) {
        self.directory = directory
        self.defaults = defaults
        self.publishesWidget = publishesWidget
        self.pasteboard = pasteboard
        isPaused = defaults.bool(forKey: Keys.paused)
        let limit = defaults.integer(forKey: Keys.historyLimit)
        historyLimit = Self.historyLimits.contains(limit) ? limit : 500
        excludedApps = defaults.stringArray(forKey: Keys.excludedApps) ?? []
        if let archive = ShelfArchive.load(from: archiveURL) {
            shelf = archive.shelf
            history = archive.history
        }
        pruneHistory()
        removeOrphanedFiles()
    }

    /// Starts recording the clipboard (unless paused) and keeps the widget's snapshot current.
    public func start() {
        started = true
        updateCapture()
        publishWidgetIfNeeded()
    }

    public func stop() {
        started = false
        monitor.stop()
    }

    // MARK: Adding

    /// Adds dropped content to the top of the shelf. Files are copied in, so moving or deleting the original is fine.
    public func add(_ contents: [ShelfContent], sourceApp: String? = nil) {
        guard !contents.isEmpty else { return }
        let blobs = self.blobs
        Task {
            var items: [ShelfItem] = []
            for content in contents {
                if let item = await ShelfItemBuilder.make(content, sourceApp: sourceApp, blobs: blobs, copyFiles: true) {
                    items.append(item)
                }
            }
            guard !items.isEmpty else { return }
            shelf.insert(contentsOf: items, at: 0)
            let (kept, dropped) = Self.pruned(shelf, limit: Self.shelfLimit, maxAge: nil)
            shelf = kept
            dropped.forEach(discardFiles)
            save()
        }
    }

    /// Reads a drop and adds what it carries. Returns false when there was nothing to read.
    @discardableResult
    public func add(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        // During a drag the frontmost app is the one it started in.
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Task {
            let contents = await ShelfDrop.contents(of: providers)
            add(contents, sourceApp: source)
        }
        return true
    }

    /// Copies a clipboard entry onto the shelf, where it stays until removed.
    public func keep(_ item: ShelfItem) {
        switch item.kind {
        case .text: add([.text(item.text ?? "")], sourceApp: item.sourceApp)
        case .link: if let url = item.linkURL { add([.link(url)], sourceApp: item.sourceApp) }
        case .color: add([.color(hex: item.colorHex ?? "", original: item.text)], sourceApp: item.sourceApp)
        case .file: if let url = item.fileURL { add([.file(url)], sourceApp: item.sourceApp) }
        case .image:
            let path = item.degraded == true ? item.thumbnailPath : item.filePath
            guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
            add([.image(data, ext: URL(fileURLWithPath: path).pathExtension.lowercased())], sourceApp: item.sourceApp)
        }
    }

    // MARK: Clipboard

    private func updateCapture() {
        if started && !isPaused { monitor.start() } else { monitor.stop() }
    }

    private func pasteboardChanged(_ pasteboard: NSPasteboard) {
        guard !isPaused else { return }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let app, excludedApps.contains(app) { return }
        capture(ShelfPasteboard.read(pasteboard), sourceApp: app)
    }

    /// Records clipboard content at the top of the history. The same thing copied again moves up instead of repeating.
    public func capture(_ contents: [ShelfContent], sourceApp: String?) {
        guard !contents.isEmpty else { return }
        // Apps that rewrite the clipboard with the same text over and over cost nothing past this check.
        if contents.count == 1, let newest = history.first, Self.isSame(contents[0], newest) { return }
        let blobs = self.blobs
        Task {
            var items: [ShelfItem] = []
            for content in contents {
                if let item = await ShelfItemBuilder.make(content, sourceApp: sourceApp, blobs: blobs, copyFiles: false) {
                    items.append(item)
                }
            }
            insertIntoHistory(items)
        }
    }

    private func insertIntoHistory(_ items: [ShelfItem]) {
        var changed = false
        for item in items.reversed() {
            if let newest = history.first, newest.hasSameContent(as: item) {
                discardFiles(item)
                continue
            }
            if history.contains(where: { $0.pinned && $0.hasSameContent(as: item) }) {
                discardFiles(item)
                continue
            }
            if let older = history.firstIndex(where: { $0.hasSameContent(as: item) }) {
                discardFiles(history.remove(at: older))
            }
            history.insert(item, at: 0)
            changed = true
        }
        guard changed else { return }
        pruneHistory()
        save()
    }

    private static func isSame(_ content: ShelfContent, _ item: ShelfItem) -> Bool {
        switch content {
        case .text(let text): return item.kind == .text && item.text == text
        case .link(let url): return item.kind == .link && item.text == url.absoluteString
        case .color(let hex, _): return item.kind == .color && item.colorHex == hex
        case .file(let url): return item.kind == .file && item.filePath == url.path
        case .image: return false
        }
    }

    // MARK: Actions

    /// Puts the item on the clipboard. A history entry moves to the top, as the most recent copy.
    public func copy(_ item: ShelfItem) {
        ShelfPasteboard.write(item, to: pasteboard)
        monitor.skip(pasteboard.changeCount)
        if let index = history.firstIndex(where: { $0.id == item.id }) {
            var moved = history.remove(at: index)
            moved.createdAt = .now
            history.insert(moved, at: 0)
            save()
        }
    }

    public func togglePin(_ item: ShelfItem) {
        update(item.id) { $0.pinned.toggle() }
    }

    public func remove(_ item: ShelfItem) {
        let before = shelf.count + history.count
        shelf.removeAll { $0.id == item.id }
        history.removeAll { $0.id == item.id }
        guard shelf.count + history.count != before else { return }
        discardFiles(item)
        save()
    }

    /// Removes everything on the shelf except pinned items.
    public func clearShelf() {
        let dropped = shelf.filter { !$0.pinned }
        guard !dropped.isEmpty else { return }
        shelf.removeAll { !$0.pinned }
        dropped.forEach(discardFiles)
        save()
    }

    /// Removes the clipboard history except pinned items.
    public func clearHistory() {
        let dropped = history.filter { !$0.pinned }
        guard !dropped.isEmpty else { return }
        history.removeAll { !$0.pinned }
        dropped.forEach(discardFiles)
        save()
    }

    public func open(_ item: ShelfItem) {
        if let url = item.linkURL ?? item.fileURL { NSWorkspace.shared.open(url) }
    }

    public func reveal(_ item: ShelfItem) {
        if let url = item.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// Files the item points at that are gone (a copied Finder file since moved or deleted).
    public func isMissing(_ item: ShelfItem) -> Bool {
        guard item.kind == .file || (item.kind == .image && item.degraded != true), let path = item.filePath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    public func isStoredCopy(_ item: ShelfItem) -> Bool {
        item.filePath?.hasPrefix(blobs.path) ?? false
    }

    private func update(_ id: UUID, _ change: (inout ShelfItem) -> Void) {
        if let index = shelf.firstIndex(where: { $0.id == id }) { change(&shelf[index]) }
        else if let index = history.firstIndex(where: { $0.id == id }) { change(&history[index]) }
        else { return }
        save()
    }

    // MARK: Pruning

    /// Keeps every pinned item and, of the rest (newest first), those younger than `maxAge`, up to `limit`.
    public static func pruned(_ items: [ShelfItem], limit: Int, maxAge: TimeInterval?, now: Date = .now) -> (kept: [ShelfItem], dropped: [ShelfItem]) {
        var kept: [ShelfItem] = []
        var dropped: [ShelfItem] = []
        var unpinned = 0
        for item in items {
            if item.pinned { kept.append(item); continue }
            let tooOld = maxAge.map { now.timeIntervalSince(item.createdAt) > $0 } ?? false
            if tooOld || unpinned >= limit { dropped.append(item); continue }
            unpinned += 1
            kept.append(item)
        }
        return (kept, dropped)
    }

    private func pruneHistory() {
        let (kept, dropped) = Self.pruned(history, limit: historyLimit, maxAge: Self.historyMaxAge)
        guard !dropped.isEmpty else { return }
        history = kept
        dropped.forEach(discardFiles)
    }

    // MARK: Files

    /// Deletes the item's own folder under `blobs`. Files it merely points at (a copied Finder file) are never touched.
    private func discardFiles(_ item: ShelfItem) {
        try? FileManager.default.removeItem(at: blobs.appendingPathComponent(item.id.uuidString, isDirectory: true))
    }

    /// Folders left behind by a crash between writing an item's files and saving the list.
    private func removeOrphanedFiles() {
        let known = Set((shelf + history).map(\.id.uuidString))
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: blobs.path)) ?? [] where !known.contains(name) {
            try? fm.removeItem(at: blobs.appendingPathComponent(name))
        }
    }

    /// Writes any change still waiting for `save`'s delay. Called at quit, so the last seconds aren't lost.
    public func saveNow() {
        guard let pending = saveTask else { return }
        pending.cancel()
        saveTask = nil
        try? ShelfArchive(shelf: shelf, history: history).write(to: archiveURL)
    }

    /// Writes the list shortly after the last change, off the main thread.
    private func save() {
        saveTask?.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let archive = ShelfArchive(shelf: shelf, history: history)
            let url = archiveURL
            await Task.detached(priority: .utility) { try? archive.write(to: url) }.value
            if generation == saveGeneration { saveTask = nil }
            publishWidgetIfNeeded()
        }
    }

    private func publishWidgetIfNeeded() {
        guard publishesWidget, started, shelf != publishedShelf else { return }
        let shelf = self.shelf
        publishedShelf = shelf
        Task {
            let written = await Task.detached(priority: .utility) { (try? ShelfWidgetSnapshot.publish(shelf)) != nil }.value
            if written { widgetDidChange?() }
        }
    }

    // MARK: Views

    /// Pinned first, then newest, filtered by `query`.
    public static func arranged(_ items: [ShelfItem], query: String = "") -> [ShelfItem] {
        let matching = items.filter { $0.matches(query) }
        return matching.filter(\.pinned) + matching.filter { !$0.pinned }
    }
}

/// `history.json`: a versioned wrapper written atomically, read leniently so one damaged entry doesn't cost the rest.
struct ShelfArchive: Codable {
    static let currentVersion = 1

    var version = ShelfArchive.currentVersion
    var shelf: [ShelfItem]
    var history: [ShelfItem]

    init(shelf: [ShelfItem], history: [ShelfItem]) {
        self.shelf = shelf
        self.history = history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        shelf = (try? container.decode([Lenient<ShelfItem>].self, forKey: .shelf))?.compactMap(\.value) ?? []
        history = (try? container.decode([Lenient<ShelfItem>].self, forKey: .history))?.compactMap(\.value) ?? []
    }

    static func load(from url: URL) -> ShelfArchive? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let archive = try? decoder.decode(ShelfArchive.self, from: data), archive.version == currentVersion else { return nil }
        return archive
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private struct Lenient<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}

/// macOS posts nothing when the clipboard changes, so this reads its change counter about once a second.
/// That's one integer read; the timer's tolerance lets the system batch it with other wake-ups.
@MainActor
final class ClipboardMonitor {
    private static let interval: TimeInterval = 1.0
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastCount: Int
    private var skipped: Int?
    private let onChange: (NSPasteboard) -> Void

    init(pasteboard: NSPasteboard, onChange: @escaping (NSPasteboard) -> Void) {
        self.pasteboard = pasteboard
        self.onChange = onChange
        lastCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastCount = pasteboard.changeCount
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// A change this app made itself (copying an item back out), not to be recorded as new.
    func skip(_ changeCount: Int) { skipped = changeCount }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastCount else { return }
        lastCount = count
        guard count != skipped else { return }
        onChange(pasteboard)
    }
}
