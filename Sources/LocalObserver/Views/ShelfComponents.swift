import SwiftUI
import AppKit
import LocalObserverShelf

/// Which half of the Shelf is showing, shared by the notch page, the menu bar, and the shortcut that opens it.
@MainActor
final class ShelfPresentation: ObservableObject {
    static let shared = ShelfPresentation()

    enum Section: String, CaseIterable, Identifiable {
        case shelf, clipboard
        var id: String { rawValue }
        var title: String { self == .shelf ? "Shelf" : "Clipboard" }
        var symbol: String { self == .shelf ? "tray.full" : "doc.on.clipboard" }
    }

    @Published var section: Section = .shelf
    /// Bumped to ask the search field for focus; `wantsFocus` survives until a page that can take it appears.
    @Published private(set) var focusRequest = 0
    var wantsFocus = false

    func focusSearch() {
        wantsFocus = true
        focusRequest += 1
    }
}

/// Decoded thumbnails, so scrolling a long history doesn't re-read PNGs from disk.
@MainActor
enum ShelfImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(atPath path: String) -> NSImage? {
        if let image = cache.object(forKey: path as NSString) { return image }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// Name and icon of the app an item came from, looked up once per bundle id.
@MainActor
enum SourceApps {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func name(_ bundleID: String) -> String? {
        if let name = names[bundleID] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[bundleID] = name
        return name
    }

    static func icon(_ bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        icons[bundleID] = icon
        return icon
    }
}

/// The picture for an item: its thumbnail, a colour swatch, or the kind's symbol on a quiet tile.
struct ShelfThumb: View {
    var item: ShelfItem
    var side: CGFloat
    var missing = false

    var body: some View {
        Group {
            if item.kind == .color, let hex = item.colorHex, let color = ShelfPasteboard.color(hex: hex) {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .fill(Color(nsColor: color))
                    .overlay(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                    .padding(side * 0.08)
            } else if let path = item.thumbnailPath, let image = ShelfImageCache.image(atPath: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .opacity(missing ? 0.4 : 1)
            } else {
                Image(systemName: missing ? "questionmark.folder" : item.symbol)
                    .font(.system(size: side * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Right-click menu for an item, the same everywhere it appears.
struct ShelfItemMenu: View {
    var item: ShelfItem
    @ObservedObject var store: ShelfStore

    var body: some View {
        Button("Copy") { store.copy(item) }
        if item.linkURL != nil || (item.fileURL != nil && !store.isMissing(item)) {
            Button(item.kind == .link ? "Open Link" : "Open") { store.open(item) }
        }
        if item.fileURL != nil && !store.isMissing(item) {
            Button("Show in Finder") { store.reveal(item) }
        }
        if store.history.contains(where: { $0.id == item.id }) {
            Button("Keep on Shelf") { store.keep(item) }
        }
        Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
        Divider()
        Button("Delete", role: .destructive) { store.remove(item) }
    }
}

/// Small icon buttons revealed on hover. `tone` is the resting colour of the glyphs.
struct ShelfItemActions: View {
    var item: ShelfItem
    @ObservedObject var store: ShelfStore
    var inHistory: Bool
    var tone: Color = .secondary
    var onCopy: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            if inHistory {
                action("tray.and.arrow.down", "Keep on Shelf") { store.keep(item) }
            }
            action(item.pinned ? "pin.slash" : "pin", item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
            action("doc.on.doc", "Copy") {
                store.copy(item)
                onCopy()
            }
            if item.fileURL != nil && !store.isMissing(item) {
                action("magnifyingglass", "Show in Finder") { store.reveal(item) }
            }
            action("trash", "Delete") { store.remove(item) }
        }
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        ShelfActionButton(symbol: symbol, help: help, tone: tone, action: run)
    }
}

private struct ShelfActionButton: View {
    var symbol: String
    var help: String
    var tone: Color
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hover ? Color.primary : tone)
                .frame(width: 22, height: 22)
                .background(hover ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension ShelfItem {
    /// Up to two lines for the history list: the text itself, a link's address, a file's name.
    var preview: String {
        switch kind {
        case .text:
            // The start is all two lines can show; don't split a huge paste on every render.
            return (text ?? "").prefix(400)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .link: return text ?? title
        default: return title
        }
    }
}
