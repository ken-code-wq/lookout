import SwiftUI
import WidgetKit
import LocalObserverCore
import LocalObserverWidgetUI
import LocalObserverShelf

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
}

/// Every widget renders the snapshot the app last wrote. The snapshot changes when the app says so
/// (WidgetCenter reloads); between those, entries every five minutes keep reset times and pace ticks moving,
/// and after half an hour the widget re-reads the file on its own. Keep this span under FreshnessNote.staleAfter.
struct SnapshotProvider: TimelineProvider {
    private static let step: TimeInterval = 5 * 60
    private static let steps = 6

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        // The gallery shows real data when there is some, and a believable sample otherwise.
        let snapshot = WidgetSnapshot.load() ?? (context.isPreview ? .sample() : nil)
        completion(SnapshotEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let now = Date.now
        let entries = (0..<Self.steps).map {
            SnapshotEntry(date: now.addingTimeInterval(Double($0) * Self.step), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// Shared chrome: the widget background and the family, so each view only decides layout.
private struct WidgetFrame<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    var entry: SnapshotEntry
    var content: (WidgetSnapshot?, Date, WidgetFamily) -> Content

    var body: some View {
        content(entry.snapshot, entry.date, family)
            .containerBackground(for: .widget) { WidgetBackground() }
    }
}

struct AgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.localobserver.agents", provider: SnapshotProvider()) { entry in
            WidgetFrame(entry: entry) { AgentsWidgetView(snapshot: $0, now: $1, family: $2) }
        }
        .configurationDisplayName("Agents")
        .description("Coding agents running now, with the ones waiting on you first.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.localobserver.limits", provider: SnapshotProvider()) { entry in
            WidgetFrame(entry: entry) { LimitsWidgetView(snapshot: $0, now: $1, family: $2) }
        }
        .configurationDisplayName("Plan Limits")
        .description("How much of each plan window is used, and whether you're burning it faster than it resets.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.localobserver.usage", provider: SnapshotProvider()) { entry in
            WidgetFrame(entry: entry) { UsageWidgetView(snapshot: $0, now: $1, family: $2) }
        }
        .configurationDisplayName("Today's Usage")
        .description("Tokens and spend today, with the last 24 hours by agent.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ServersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.localobserver.servers", provider: SnapshotProvider()) { entry in
            WidgetFrame(entry: entry) { ServersWidgetView(snapshot: $0, now: $1, family: $2) }
        }
        .configurationDisplayName("Servers")
        .description("Local servers by port. Click one to open it in your browser.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.localobserver.overview", provider: SnapshotProvider()) { entry in
            WidgetFrame(entry: entry) { OverviewWidgetView(snapshot: $0, now: $1, family: $2) }
        }
        .configurationDisplayName("Overview")
        .description("Agents, plan limits, today's usage, and servers in one place.")
        .supportedFamilies([.systemLarge, .systemExtraLarge])
    }
}

// MARK: - Shelf

struct ShelfEntry: TimelineEntry {
    var date: Date
    var snapshot: ShelfWidgetSnapshot?
}

/// Same rhythm as `SnapshotProvider`, reading the Shelf's own snapshot. The app reloads this widget when the shelf
/// changes; the half-hourly entries only move the "4m ago" captions along.
struct ShelfSnapshotProvider: TimelineProvider {
    private static let step: TimeInterval = 5 * 60
    private static let steps = 6

    func placeholder(in context: Context) -> ShelfEntry {
        ShelfEntry(date: .now, snapshot: .sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (ShelfEntry) -> Void) {
        let snapshot = ShelfWidgetSnapshot.load() ?? (context.isPreview ? .sample() : nil)
        completion(ShelfEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ShelfEntry>) -> Void) {
        let snapshot = ShelfWidgetSnapshot.load()
        let now = Date.now
        let entries = (0..<Self.steps).map { ShelfEntry(date: now.addingTimeInterval(Double($0) * Self.step), snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// `WidgetFrame` for the Shelf's entry type.
private struct ShelfWidgetFrame: View {
    @Environment(\.widgetFamily) private var family
    var entry: ShelfEntry

    var body: some View {
        ShelfWidgetView(snapshot: entry.snapshot, now: entry.date, family: family)
            .containerBackground(for: .widget) { WidgetBackground() }
    }
}

struct ShelfWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ShelfWidgetSnapshot.widgetKind, provider: ShelfSnapshotProvider()) { entry in
            ShelfWidgetFrame(entry: entry)
        }
        .configurationDisplayName("Shelf")
        .description("What you've parked on the Shelf. Click to open it in the notch.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct LocalObserverWidgets: WidgetBundle {
    var body: some Widget {
        OverviewWidget()
        AgentsWidget()
        LimitsWidget()
        UsageWidget()
        ServersWidget()
        ShelfWidget()
    }
}
