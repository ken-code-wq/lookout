import SwiftUI
import WidgetKit
import LocalObserverCore

/// Today's tokens and spend with the last 24 hours as bars. Large adds the models that used them.
public struct UsageWidgetView: View {
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
            if let snapshot {
                switch family {
                case .systemSmall: small(snapshot)
                case .systemMedium: medium(snapshot)
                default: large(snapshot)
                }
            } else {
                WidgetEmpty(symbol: "chart.bar.xaxis", title: "Open Lookout",
                            detail: family == .systemSmall ? nil : "Token usage appears here once the app has read your agents' logs.")
            }
        }
        .widgetURL(WidgetLink.usage)
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeading(title: "Today", symbol: "chart.bar.fill")
            Spacer(minLength: 4)
            TodayFigure(usage: snapshot.today, size: 30)
            Spacer(minLength: 8)
            if hasBars(snapshot) {
                HourlyBars(buckets: snapshot.today.hourly)
                    .frame(height: 30)
            }
            FreshnessNote(generatedAt: snapshot.generatedAt, now: now).padding(.top, 4)
        }
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeading(title: "Today", symbol: "chart.bar.fill")
                Spacer(minLength: 4)
                TodayFigure(usage: snapshot.today, size: 30)
                Spacer(minLength: 8)
                TodayFacts(usage: snapshot.today)
                FreshnessNote(generatedAt: snapshot.generatedAt, now: now).padding(.top, 4)
            }
            .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("Last 24 hours").font(WFont.caption).foregroundStyle(.secondary)
                if hasBars(snapshot) {
                    HourlyBars(buckets: snapshot.today.hourly, showsAxis: true)
                } else {
                    quietDay
                }
            }
        }
    }

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetHeading(title: "Today", symbol: "chart.bar.fill")
                    TodayFigure(usage: snapshot.today, size: 34)
                }
                Spacer(minLength: 0)
                TodayFacts(usage: snapshot.today, alignment: .trailing)
            }
            if hasBars(snapshot) {
                HourlyBars(buckets: snapshot.today.hourly, showsAxis: true)
                    .frame(height: 96)
            } else {
                quietDay.frame(height: 96)
            }
            Rectangle().fill(WTheme.rule).frame(height: 1)
            if snapshot.today.models.isEmpty {
                Text("No model usage recorded today.").font(WFont.caption).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(snapshot.today.models.prefix(5)) { ModelRow(model: $0) }
                }
            }
            Spacer(minLength: 0)
            FreshnessNote(generatedAt: snapshot.generatedAt, now: now)
        }
    }

    private func hasBars(_ snapshot: WidgetSnapshot) -> Bool {
        snapshot.today.hourly.contains { $0.value > 0 }
    }

    private var quietDay: some View {
        Text("Nothing in the last 24 hours.")
            .font(WFont.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// "4.72M" over "tokens". The unit sits under the figure so the number keeps its full width.
struct TodayFigure: View {
    var usage: WidgetSnapshot.Usage
    var size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(usage.processed > 0 ? AgentFormat.compact(Double(usage.processed)) : "0")
                .font(WFont.figure(size))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .widgetAccentable()
            Text(usage.processed == 1 ? "token" : "tokens")
                .font(WFont.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Cost, sessions, and cache hits: the context that says whether the figure is good or bad.
struct TodayFacts: View {
    var usage: WidgetSnapshot.Usage
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            if let cost = usage.cost {
                fact(AgentFormat.cost(cost, estimated: usage.costIsEstimated), "spent")
            }
            if usage.sessions > 0 {
                fact("\(usage.sessions)", usage.sessions == 1 ? "session" : "sessions")
            }
            if let hit = usage.cacheHitRate {
                fact(AgentFormat.percent(hit, digits: 0), "from cache")
            }
        }
        .font(WFont.caption)
        .lineLimit(1)
    }

    private func fact(_ value: String, _ unit: String) -> some View {
        HStack(spacing: 4) {
            Text(value).fontWeight(.semibold).monospacedDigit()
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

private struct ModelRow: View {
    var model: WidgetSnapshot.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                if let agent = model.agent { WAgentIcon(agent: agent, size: 13) }
                Text(model.title).font(WFont.body).lineLimit(1)
                Spacer(minLength: 6)
                Text(AgentFormat.compact(Double(model.tokens)))
                    .font(WFont.figure(12))
                    .monospacedDigit()
                if let cost = model.cost {
                    Text(AgentFormat.cost(cost))
                        .font(WFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            GeometryReader { proxy in
                Capsule()
                    .fill((model.agent?.widgetColor ?? .secondary).opacity(0.85))
                    .frame(width: max(3, proxy.size.width * min(max(model.share, 0), 1)), height: 3)
                    .widgetAccentable()
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .combine)
    }
}
