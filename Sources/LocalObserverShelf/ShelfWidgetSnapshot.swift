import Foundation

/// What the Shelf desktop widget shows: the drop shelf only, never clipboard history, which stays off the desktop.
/// Its own file in its own folder, so the widget's sandbox can read exactly this and nothing else of the shelf.
public struct ShelfWidgetSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let widgetKind = "dev.localobserver.shelf"
    /// Enough for the medium widget's row.
    static let itemLimit = 6

    public var version = ShelfWidgetSnapshot.currentVersion
    public var generatedAt: Date
    public var total: Int
    public var pinned: Int
    /// Pinned first, then newest.
    public var items: [Item]

    public init(generatedAt: Date, total: Int, pinned: Int, items: [Item]) {
        self.generatedAt = generatedAt
        self.total = total
        self.pinned = pinned
        self.items = items
    }

    public struct Item: Codable, Sendable, Identifiable, Hashable {
        public var id: UUID
        public var kind: ShelfItem.Kind
        public var title: String
        public var createdAt: Date
        public var pinned: Bool
        /// PNG in `thumbnailsDirectory`.
        public var thumbnail: String?
        public var colorHex: String?

        public init(id: UUID, kind: ShelfItem.Kind, title: String, createdAt: Date, pinned: Bool, thumbnail: String?, colorHex: String?) {
            self.id = id
            self.kind = kind
            self.title = title
            self.createdAt = createdAt
            self.pinned = pinned
            self.thumbnail = thumbnail
            self.colorHex = colorHex
        }

        public var symbol: String {
            ShelfItem(kind: kind).symbol
        }
    }

    // MARK: Storage

    /// `Shelf/Widget/`. The widget's sandbox has a read-only exception for this folder (packaging/Widgets.entitlements).
    public static var directory: URL { ShelfPaths.root.appendingPathComponent("Widget", isDirectory: true) }
    public static var fileURL: URL { directory.appendingPathComponent("snapshot.json") }
    public static var thumbnailsDirectory: URL { directory.appendingPathComponent("thumbnails", isDirectory: true) }

    public static func load() -> ShelfWidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(ShelfWidgetSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }

    /// Builds the snapshot for `shelf`, copies the thumbnails it names next to it, and removes ones it no longer does.
    static func publish(_ shelf: [ShelfItem], now: Date = .now) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        let ordered = shelf.filter(\.pinned) + shelf.filter { !$0.pinned }
        var keep: Set<String> = []
        let items = ordered.prefix(itemLimit).map { item -> Item in
            var thumbnail: String?
            if let source = item.thumbnailPath, fm.fileExists(atPath: source) {
                let name = item.id.uuidString + ".png"
                let target = thumbnailsDirectory.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) || (try? fm.copyItem(atPath: source, toPath: target.path)) != nil {
                    thumbnail = name
                    keep.insert(name)
                }
            }
            return Item(id: item.id, kind: item.kind, title: String(item.title.prefix(80)), createdAt: item.createdAt,
                        pinned: item.pinned, thumbnail: thumbnail, colorHex: item.colorHex)
        }
        for name in (try? fm.contentsOfDirectory(atPath: thumbnailsDirectory.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: thumbnailsDirectory.appendingPathComponent(name))
        }
        let snapshot = ShelfWidgetSnapshot(generatedAt: now, total: shelf.count, pinned: shelf.filter(\.pinned).count, items: Array(items))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// For the widget gallery before the app has written anything.
    public static func sample(now: Date = .now) -> ShelfWidgetSnapshot {
        let items = [
            Item(id: UUID(), kind: .file, title: "Q3 launch brief.pdf", createdAt: now.addingTimeInterval(-240), pinned: true, thumbnail: nil, colorHex: nil),
            Item(id: UUID(), kind: .color, title: "#FF6A3D", createdAt: now.addingTimeInterval(-900), pinned: false, thumbnail: nil, colorHex: "#FF6A3D"),
            Item(id: UUID(), kind: .link, title: "developer.apple.com/documentation", createdAt: now.addingTimeInterval(-2_400), pinned: false, thumbnail: nil, colorHex: nil),
            Item(id: UUID(), kind: .text, title: "Ship the shelf before Friday", createdAt: now.addingTimeInterval(-7_200), pinned: false, thumbnail: nil, colorHex: nil),
        ]
        return ShelfWidgetSnapshot(generatedAt: now, total: 7, pinned: 1, items: items)
    }
}
