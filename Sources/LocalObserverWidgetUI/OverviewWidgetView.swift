import SwiftUI
import WidgetKit
import LocalObserverCore

/// The whole command center on the desktop: limits, agents, today's usage, and servers, divided by hairlines
/// rather than boxed into cards. Large stacks them; extra large gives agents and limits a column each.
public struct OverviewWidgetView: View {
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
                if family == .systemExtraLarge { extraLarge(snapshot) } else { large(snapshot) }
            } else {
                WidgetEmpty(symbol: "square.grid.2x2", title: "Open Lookout",
                            detail: "Agents, plan limits, usage, and servers appear here once the app is running.")
            }
        }
        .widgetURL(WidgetLink.activity)
    }

    // MARK: Large

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            limitStrip(snapshot)
            rule
            agents(snapshot, rows: 3)
            Spacer(minLength: 0)
            rule
            HStack(alignment: .top, spacing: 16) {
                todayCell(snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(WTheme.rule).frame(width: 1)
                serversCell(snapshot, rows: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            FreshnessNote(generatedAt: snapshot.generatedAt, now: now)
        }
    }

    // MARK: Extra large

    private func extraLarge(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                agents(snapshot, rows: 5)
                Spacer(minLength: 0)
                rule
                serversCell(snapshot, rows: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(WTheme.rule).frame(width: 1)
            VStack(alignment: .leading, spacing: 12) {
                limitColumns(snapshot)
                rule
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        WidgetHeading(title: "Today", symbol: "chart.bar.fill")
                        TodayFigure(usage: snapshot.today, size: 26)
                        TodayFacts(usage: snapshot.today)
                    }
                    .frame(width: 118, alignment: .leading)
                    if snapshot.today.hourly.contains(where: { $0.value > 0 }) {
                        HourlyBars(buckets: snapshot.today.hourly, showsAxis: true)
                    }
                }
                .frame(maxHeight: .infinity)
                FreshnessNote(generatedAt: snapshot.generatedAt, now: now)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .widgetURL(WidgetLink.activity)
    }

    // MARK: Sections

    private var rule: some View { Rectangle().fill(WTheme.rule).frame(height: 1) }

    /// Up to three providers side by side. The provider's mark sits inside its ring, so the text only needs
    /// the figure and the window: nothing has to truncate at a third of a large widget's width.
    @ViewBuilder private func limitStrip(_ snapshot: WidgetSnapshot) -> some View {
        let providers = Array(snapshot.limitProviders.prefix(3))
        if providers.isEmpty {
            RowLink(destination: WidgetLink.limits) {
                Label("No plan limits yet", systemImage: "gauge.with.dots.needle.0percent")
                    .font(WFont.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            RowLink(destination: WidgetLink.limits) {
                HStack(alignment: .center, spacing: 10) {
                    ForEach(providers) { provider in
                        if let headline = provider.headline {
                            HStack(spacing: 8) {
                                ZStack {
                                    LimitRing(window: headline, now: now, lineWidth: 4, figureSize: 0)
                                    WAgentIcon(agent: provider.agent, size: 12)
                                }
                                .frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 0) {
                                    UsedFigure(window: headline, now: now, size: 14)
                                    Text(headline.shortLabel).font(WFont.micro).foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    /// Extra large: one line per provider, ring then name then when it resets.
    @ViewBuilder private func limitColumns(_ snapshot: WidgetSnapshot) -> some View {
        let providers = Array(snapshot.limitProviders.prefix(3))
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeading(title: "Plan limits", symbol: "gauge.with.dots.needle.67percent")
            if providers.isEmpty {
                Text("Connect providers in Settings › Limits.").font(WFont.caption).foregroundStyle(.tertiary)
            }
            ForEach(providers) { provider in
                if let headline = provider.headline {
                    RowLink(destination: WidgetLink.limits) {
                        HStack(spacing: 10) {
                            LimitRing(window: headline, now: now, lineWidth: 4.5, figureSize: 11)
                                .frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    WAgentIcon(agent: provider.agent, size: 12)
                                    Text(provider.agent.widgetShortName).font(WFont.bodyMedium)
                                    Text(headline.shortLabel).font(WFont.caption).foregroundStyle(.secondary)
                                }
                                PaceNote(window: headline, now: now)
                            }
                            .lineLimit(1)
                            Spacer(minLength: 8)
                            let next = provider.windows.filter { $0.id != headline.id }.max { $0.usedPercent < $1.usedPercent }
                            if let next {
                                PaceBar(window: next, now: now, title: next.shortLabel).frame(width: 128)
                            }
                        }
                    }
                }
            }
        }
    }

    private func agents(_ snapshot: WidgetSnapshot, rows: Int) -> some View {
        let sessions = snapshot.queuedSessions
        return VStack(alignment: .leading, spacing: 9) {
            AgentsHeadline(snapshot: snapshot, compact: false)
            if sessions.isEmpty {
                Text("No agents running.").font(WFont.caption).foregroundStyle(.tertiary)
            }
            ForEach(sessions.prefix(rows)) { session in
                RowLink(destination: WidgetLink.session(session.id)) { SessionRow(session: session, now: now) }
            }
            if sessions.count > rows {
                Text("\(sessions.count - rows) more").font(WFont.micro).foregroundStyle(.tertiary)
            }
        }
    }

    private func todayCell(_ snapshot: WidgetSnapshot) -> some View {
        RowLink(destination: WidgetLink.usage) {
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeading(title: "Today", symbol: "chart.bar.fill") {
                    if let cost = snapshot.today.cost {
                        Text(AgentFormat.cost(cost, estimated: snapshot.today.costIsEstimated)).monospacedDigit()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(AgentFormat.compact(Double(snapshot.today.processed)))
                        .font(WFont.figure(20))
                        .monospacedDigit()
                        .widgetAccentable()
                    Text("tokens").font(WFont.caption).foregroundStyle(.secondary)
                }
                if snapshot.today.hourly.contains(where: { $0.value > 0 }) {
                    HourlyBars(buckets: snapshot.today.hourly).frame(height: 22)
                }
            }
        }
    }

    private func serversCell(_ snapshot: WidgetSnapshot, rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RowLink(destination: WidgetLink.servers) { ServersHeadline(servers: snapshot.servers) }
            if snapshot.servers.isEmpty {
                Text("Nothing listening.").font(WFont.caption).foregroundStyle(.tertiary)
            }
            ForEach(snapshot.servers.prefix(rows)) { server in
                if let url = URL(string: server.url) {
                    RowLink(destination: url) { ServerRow(server: server, compact: true) }
                }
            }
        }
    }
}
