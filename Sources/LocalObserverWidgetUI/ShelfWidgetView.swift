import SwiftUI
import AppKit
import WidgetKit
import LocalObserverCore
import LocalObserverShelf

/// The drop shelf on the desktop. Small: the newest item, large, with the count. Medium: a row of recent items.
/// Clipboard history never appears here; the desktop is visible to anyone at the desk.
public struct ShelfWidgetView: View {
    var snapshot: ShelfWidgetSnapshot?
    var now: Date
    var family: WidgetFamily

    public init(snapshot: ShelfWidgetSnapshot?, now: Date, family: WidgetFamily) {
        self.snapshot = snapshot
        self.now = now
        self.family = family
    }

    public var body: some View {
        Group {
            if let snapshot {
                if snapshot.items.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        heading(snapshot)
                        WidgetEmpty(symbol: "tray", title: "Nothing here yet",
                                    detail: "Drag files onto the notch to keep them here.")
                    }
                } else if family == .systemSmall {
                    small(snapshot)
                } else {
                    medium(snapshot)
                }
            } else {
                WidgetEmpty(symbol: "tray.full", title: "Open Lookout",
                            detail: family == .systemSmall ? nil : "Things you drop on the Shelf appear here.")
            }
        }
        .widgetURL(WidgetLink.shelf)
    }

    private func heading(_ snapshot: ShelfWidgetSnapshot) -> some View {
        WidgetHeading(title: "Shelf", symbol: "tray.full") {
            if snapshot.total > 0 { Text("\(snapshot.total)").monospacedDigit() }
        }
    }

    // MARK: Small

    private func small(_ snapshot: ShelfWidgetSnapshot) -> some View {
        let item = snapshot.items[0]
        return VStack(alignment: .leading, spacing: 0) {
            heading(snapshot)
            Spacer(minLength: 8)
            ShelfWidgetThumb(item: item, side: 56)
            Spacer(minLength: 8)
            Text(item.title)
                .font(WFont.bodyMedium)
                .lineLimit(1)
                .truncationMode(item.kind == .file ? .middle : .tail)
            HStack(spacing: 4) {
                if snapshot.pinned > 0 {
                    Label("\(snapshot.pinned) pinned", systemImage: "pin.fill").labelStyle(TightLabel())
                } else {
                    Text(ago(item.createdAt))
                }
            }
            .font(WFont.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    // MARK: Medium

    private func medium(_ snapshot: ShelfWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeading(title: "Shelf", symbol: "tray.full") {
                Text(snapshot.pinned > 0 ? "\(snapshot.total) items, \(snapshot.pinned) pinned" : "\(snapshot.total) item\(snapshot.total == 1 ? "" : "s")")
                    .monospacedDigit()
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(snapshot.items.prefix(4)) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        ShelfWidgetThumb(item: item, side: 64)
                            .overlay(alignment: .topTrailing) {
                                if item.pinned {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .padding(4)
                                }
                            }
                        Text(item.title)
                            .font(WFont.caption)
                            .lineLimit(1)
                            .truncationMode(item.kind == .file ? .middle : .tail)
                        Text(ago(item.createdAt))
                            .font(WFont.micro)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Keep tiles the same width when there are fewer than four.
                ForEach(0..<max(0, 4 - snapshot.items.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func ago(_ date: Date) -> String { AgentFormat.ago(date, now: now) }
}

/// Thumbnail from the snapshot's folder, a colour swatch, or the kind's symbol on a quiet tile.
private struct ShelfWidgetThumb: View {
    var item: ShelfWidgetSnapshot.Item
    var side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
        Group {
            if let hex = item.colorHex, let color = ShelfPasteboard.color(hex: hex) {
                shape.fill(Color(nsColor: color))
                    .overlay(shape.strokeBorder(WTheme.rule))
                    .widgetAccentable()
            } else if let name = item.thumbnail,
                      let image = NSImage(contentsOf: ShelfWidgetSnapshot.thumbnailsDirectory.appendingPathComponent(name)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.symbol)
                    .font(.system(size: side * 0.36, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
                    .background(WTheme.track, in: shape)
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel(item.title)
    }
}
