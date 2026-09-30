import SwiftUI
import WidgetKit
import LocalObserverCore

extension WidgetSnapshot {
    /// Providers that report windows, the ones picked for the notch first.
    var limitProviders: [Provider] {
        let reporting = providers.filter { !$0.windows.isEmpty }
        return reporting.sorted { lhs, rhs in
            let l = glanceProviders.firstIndex(of: lhs.agent) ?? Int.max
            let r = glanceProviders.firstIndex(of: rhs.agent) ?? Int.max
            if l != r { return l < r }
            return (lhs.headline?.usedPercent ?? 0) > (rhs.headline?.usedPercent ?? 0)
        }
    }

    /// The single window the menu bar and Dock would show: the tightest of the chosen providers' headlines.
    var glanceWindow: Window? {
        let chosen = glanceProviders.isEmpty ? providers : providers.filter { glanceProviders.contains($0.agent) }
        let pool = chosen.compactMap(\.headline)
        return (pool.isEmpty ? providers.flatMap(\.windows) : pool).max { $0.usedPercent < $1.usedPercent }
    }
}

extension WidgetSnapshot.Window {
    /// "5-hour", "Weekly", "Monthly": the window's length alone, for places a third of a widget wide.
    var shortLabel: String {
        switch kind {
        case .session:
            if let duration = windowDuration, duration > 0, duration < 86_400 { return "\(Int((duration / 3_600).rounded()))-hour" }
            return "Session"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        default: return label
        }
    }
}

/// Plan limits. Small: the one window closest to running out. Medium: a ring per provider.
/// Large: every window of every provider as pace bars.
public struct LimitsWidgetView: View {
    var snapshot: WidgetSnapshot?
    var now: Date
    var family: WidgetFamily

    public init(snapshot: WidgetSnapshot?, now: Date, family: WidgetFamily) {
        self.snapshot = snapshot
        self.now = now
        self.family = family
    }

    public var body: some View {
        Group {
            if let snapshot, !snapshot.limitProviders.isEmpty {
                switch family {
                case .systemSmall: small(snapshot)
                case .systemMedium: medium(snapshot)
                default: large(snapshot)
                }
            } else if snapshot == nil {
                WidgetEmpty(symbol: "gauge.with.dots.needle.33percent", title: "Open Lookout",
                            detail: family == .systemSmall ? nil : "Plan limits appear here once the app has read them.")
            } else {
                WidgetEmpty(symbol: "gauge.with.dots.needle.0percent", title: "No plan limits yet",
                            detail: family == .systemSmall ? nil : "Connect providers in Settings › Limits.")
            }
        }
        .widgetURL(WidgetLink.limits)
    }

    // MARK: Small

    @ViewBuilder private func small(_ snapshot: WidgetSnapshot) -> some View {
        if let window = snapshot.glanceWindow {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    LimitRing(window: window, now: now, lineWidth: 7, figureSize: 19)
                        .frame(width: 66, height: 66)
                    Spacer(minLength: 0)
                    WAgentIcon(agent: window.agent, size: 15)
                }
                Spacer(minLength: 6)
                Text(window.agent.widgetShortName)
                    .font(WFont.title)
                    .lineLimit(1)
                Text(window.label)
                    .font(WFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 3)
                if FreshnessNote.isStale(snapshot.generatedAt, now: now) {
                    FreshnessNote(generatedAt: snapshot.generatedAt, now: now)
                } else {
                    PaceNote(window: window, now: now)
                }
            }
        }
    }

    // MARK: Medium

    @ViewBuilder private func medium(_ snapshot: WidgetSnapshot) -> some View {
        let providers = Array(snapshot.limitProviders.prefix(3))
        if providers.count == 1, let provider = providers.first, let headline = provider.headline {
            single(provider, headline: headline, snapshot: snapshot)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(providers) { provider in
                        if let headline = provider.headline {
                            ProviderColumn(provider: provider, headline: headline, now: now)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Spacer(minLength: 0)
                FreshnessNote(generatedAt: snapshot.generatedAt, now: now)
            }
        }
    }

    /// One provider gets the room of a medium widget: big ring left, its other windows as bars right.
    private func single(_ provider: WidgetSnapshot.Provider, headline: WidgetSnapshot.Window, snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                LimitRing(window: headline, now: now, lineWidth: 8, figureSize: 22)
                    .frame(width: 78, height: 78)
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    WAgentIcon(agent: provider.agent, size: 13)
                    Text(provider.agent.widgetShortName).font(WFont.title).lineLimit(1)
                }
                Text(headline.label).font(WFont.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 9) {
                PaceNote(window: headline, now: now)
                let others = provider.windows.filter { $0.id != headline.id }.sorted { $0.usedPercent > $1.usedPercent }
                ForEach(others.prefix(3)) { PaceBar(window: $0, now: now) }
                Spacer(minLength: 0)
                FreshnessNote(generatedAt: snapshot.generatedAt, now: now)
            }
        }
    }

    // MARK: Large

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        // Roughly ten bar rows fit; share them out so every provider gets its headline and as many others as fit.
        let providers = Array(snapshot.limitProviders.prefix(4))
        let budget = max(10 - providers.count, providers.count)
        let perProvider = max(1, budget / max(providers.count, 1))
        return VStack(alignment: .leading, spacing: 12) {
            WidgetHeading(title: "Plan limits", symbol: "gauge.with.dots.needle.67percent") {
                if FreshnessNote.isStale(snapshot.generatedAt, now: now) {
                    FreshnessNote(generatedAt: snapshot.generatedAt, now: now)
                } else if let tight = snapshot.glanceWindow {
                    Text("Tightest \(Int(tight.usedPercent.rounded()))%").monospacedDigit()
                }
            }
            ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                if index > 0 { Rectangle().fill(WTheme.rule).frame(height: 1) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        WAgentIcon(agent: provider.agent, size: 14)
                        Text(provider.agent.widgetShortName).font(WFont.title)
                        if !provider.plan.isEmpty {
                            Text(provider.plan).font(WFont.caption).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 6)
                        if let headline = provider.headline { PaceNote(window: headline, now: now, font: WFont.micro) }
                    }
                    .lineLimit(1)
                    let windows = orderedWindows(provider)
                    ForEach(windows.prefix(perProvider)) { PaceBar(window: $0, now: now) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Headline first, then the rest by how close they are to running out.
    private func orderedWindows(_ provider: WidgetSnapshot.Provider) -> [WidgetSnapshot.Window] {
        let headline = provider.headline
        let rest = provider.windows.filter { $0.id != headline?.id }.sorted { $0.usedPercent > $1.usedPercent }
        return (headline.map { [$0] } ?? []) + rest
    }
}

/// Ring over name, window, and reset: one provider in the medium widget.
private struct ProviderColumn: View {
    var provider: WidgetSnapshot.Provider
    var headline: WidgetSnapshot.Window
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LimitRing(window: headline, now: now, lineWidth: 6, figureSize: 16)
                .frame(width: 54, height: 54)
                .padding(.bottom, 9)
            HStack(spacing: 4) {
                WAgentIcon(agent: provider.agent, size: 12)
                Text(provider.agent.widgetShortName).font(WFont.title)
            }
            .lineLimit(1)
            Text(headline.label)
                .font(WFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 2)
            PaceNote(window: headline, now: now, font: WFont.micro)
        }
    }
}
