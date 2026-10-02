import SwiftUI
import LocalObserverCore

/// The dashboard's centrepiece: a year of agent usage as a GitHub-style grid, streaks and records under it,
/// and the day you click broken down by agent, model, and project.
struct DashboardActivityCard: View {
    @ObservedObject var store: AgentStore
    @Binding var metric: AgentMetricKind
    /// Opens the Usage page narrowed to a day (or the whole year when nil) and an agent (or all).
    var openUsage: (Date?, AgentKind?) -> Void

    @State private var focus: AgentKind?
    @State private var selectedDay: Date?
    @State private var width: CGFloat = 1000

    private var wide: Bool { width > 820 }

    var body: some View {
        let agents = store.enabledAgentsSorted.filter { !(store.dailyByAgent[$0] ?? []).isEmpty }
        let focus = self.focus.flatMap { agents.contains($0) ? $0 : nil }
        let days = Self.combined(store.dailyByAgent, agents: focus.map { [$0] } ?? agents)
        let stats = AgentHeatmapStats(days: days, metric: metric)
        let tint = focus?.tag.fg ?? N.blue

        VStack(alignment: .leading, spacing: 16) {
            header
            if agents.isEmpty {
                empty
            } else {
                if agents.count > 1 { agentChips(agents, focus: focus) }
                UsageHeatmapView(days: days, metric: metric, tint: tint, maxCell: 17, selection: $selectedDay, showsFooter: false)
                HStack(alignment: .center, spacing: 10) {
                    Text(footnote(stats, focus: focus)).font(.system(size: 10.5)).foregroundStyle(N.text3)
                    Spacer(minLength: 8)
                    UsageHeatmapLegend(tint: tint)
                }
                .padding(.top, -8)
                statsRow(stats)
                Rectangle().fill(N.divider).frame(height: 1)
                DashboardDayDetail(store: store, day: selectedDay ?? Calendar.current.startOfDay(for: .now),
                                   isPicked: selectedDay != nil, agents: focus.map { [$0] } ?? Set(agents),
                                   metric: metric, wide: wide, tint: tint,
                                   clear: { selectedDay = nil },
                                   open: { openUsage($0, focus) })
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(N.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(N.divider))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "square.grid.3x3.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
            Text("Activity").font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
            Text("Last 12 months").font(NFont.small).foregroundStyle(N.text3)
            Spacer(minLength: 8)
            Picker("Metric", selection: $metric) {
                ForEach(AgentMetricKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3").font(.system(size: 15, weight: .light)).foregroundStyle(N.text3)
            Text("The grid fills in as your agents run. Each square is a day.").font(NFont.small).foregroundStyle(N.text2)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func agentChips(_ agents: [AgentKind], focus: AgentKind?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ActivityChip(title: "All agents", icon: nil, value: nil, tint: N.blue, selected: focus == nil) {
                    withAnimation(.snappy(duration: 0.2)) { self.focus = nil }
                }
                ForEach(agents) { agent in
                    let total = (store.dailyByAgent[agent] ?? []).reduce(0) { $0 + ($1.value(for: metric) ?? 0) }
                    ActivityChip(title: agent.shortName, icon: agent, value: total > 0 ? AgentFormat.metric(total, metric) : nil,
                                 tint: agent.tag.fg, selected: focus == agent) {
                        withAnimation(.snappy(duration: 0.2)) { self.focus = focus == agent ? nil : agent }
                    }
                }
            }
        }
    }

    private func statsRow(_ stats: AgentHeatmapStats) -> some View {
        let busiest = stats.busiest.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "–"
        let items: [(String, String, String)] = [
            ("Total", stats.total > 0 ? AgentFormat.metric(stats.total, metric) : "–", "past year"),
            ("Active days", "\(stats.activeDays)", "of 365"),
            ("Current streak", "\(stats.currentStreak)", stats.currentStreak == 1 ? "day" : "days"),
            ("Longest streak", "\(stats.longestStreak)", stats.longestStreak == 1 ? "day" : "days"),
            ("Busiest day", stats.busiestValue > 0 ? AgentFormat.metric(stats.busiestValue, metric) : "–", busiest),
            ("Daily average", stats.activeDays > 0 ? AgentFormat.metric(stats.dailyAverage, metric) : "–", "on active days"),
        ]
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .leading), count: wide ? 6 : 3)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(NFont.caption).foregroundStyle(N.text2)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(item.1).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(N.text)
                        Text(item.2).font(NFont.caption).foregroundStyle(N.text3).lineLimit(1)
                    }
                    .lineLimit(1)
                }
                .onTapGesture {
                    if item.0 == "Busiest day", let day = stats.busiest?.date { selectedDay = day }
                }
                .help(item.0 == "Busiest day" ? "Click to see that day" : "")
            }
        }
    }

    private func footnote(_ stats: AgentHeatmapStats, focus: AgentKind?) -> String {
        var text = "Click a day to see what ran."
        if focus?.capabilities.estimatedTokens == true, metric == .tokens {
            text += " \(focus!.name) tokens are estimated from its transcripts."
        } else if metric == .cost {
            text += " Cost at API prices, where the agent reports or the model is priced."
        }
        return text
    }

    /// Sums the chosen agents' daily series into one.
    static func combined(_ series: [AgentKind: [AgentHeatmapDay]], agents: [AgentKind]) -> [AgentHeatmapDay] {
        if agents.count == 1 { return series[agents[0]] ?? [] }
        var byDate: [Date: AgentHeatmapDay] = [:]
        for agent in agents {
            for day in series[agent] ?? [] { byDate[day.date, default: AgentHeatmapDay(date: day.date)].add(day) }
        }
        return byDate.values.sorted { $0.date < $1.date }
    }
}

private struct ActivityChip: View {
    var title: String
    var icon: AgentKind?
    var value: String?
    var tint: Color
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    AgentIconView(agent: icon, size: 13)
                } else {
                    Circle().fill(tint).frame(width: 7, height: 7)
                }
                Text(title).font(NFont.small.weight(.medium)).foregroundStyle(N.text)
                if let value { Text(value).font(NFont.caption).monospacedDigit().foregroundStyle(N.text2) }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(selected ? tint.opacity(0.14) : (hover ? N.hover : .clear), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.55) : N.divider))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Day detail

/// One day, by agent, model, and project. Defaults to today until a square is clicked.
private struct DashboardDayDetail: View {
    @ObservedObject var store: AgentStore
    var day: Date
    var isPicked: Bool
    var agents: Set<AgentKind>
    var metric: AgentMetricKind
    var wide: Bool
    var tint: Color
    var clear: () -> Void
    var open: (Date) -> Void

    @State private var reports: (models: AgentUsageReport, projects: AgentUsageReport)?

    private struct Key: Hashable {
        var day: Date
        var agents: Set<AgentKind>
        var metric: AgentMetricKind
        var revision: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(N.text)
                if let totals = reports?.models.totals, totals.events > 0 {
                    Text(summary(totals)).font(NFont.small).foregroundStyle(N.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                if isPicked {
                    Button("Back to today", action: clear).buttonStyle(.link).font(NFont.caption)
                }
                Button { open(day) } label: {
                    HStack(spacing: 3) {
                        Text("Open in Usage")
                        Image(systemName: "arrow.right").font(.system(size: 9.5, weight: .semibold))
                    }
                    .font(NFont.caption)
                }
                .buttonStyle(.link)
            }
            if let reports, reports.models.totals.events > 0 {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 28, alignment: .top), count: wide ? 3 : 1)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    column("By agent", rows: reports.models.byAgent, agentIcons: true)
                    column("Models", rows: reports.models.rows, agentIcons: false)
                    column("Projects", rows: reports.projects.rows, agentIcons: false)
                }
            } else if reports != nil {
                Text(isPicked ? "Nothing ran on this day." : "Nothing has run today yet.")
                    .font(NFont.small).foregroundStyle(N.text2)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                Color.clear.frame(height: 60)
            }
        }
        .task(id: Key(day: day, agents: agents, metric: metric, revision: store.ledgerRevision)) {
            let events = store.ledgerEvents, enabled = store.settings.enabledAgents
            let (day, agents, metric) = (day, agents, metric)
            let built = await Task.detached(priority: .userInitiated) {
                func report(_ grouping: AgentUsageGrouping) -> AgentUsageReport {
                    var filter = AgentUsageFilter()
                    filter.setCustom(from: day, to: day)
                    filter.agents = agents
                    filter.grouping = grouping
                    filter.metric = metric
                    return AgentStore.buildReport(events: events, filter: filter, enabledAgents: enabled)
                }
                return (report(.model), report(.project))
            }.value
            guard !Task.isCancelled else { return }
            reports = built
        }
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    private func summary(_ totals: AgentUsageTotals) -> String {
        var parts = ["\(AgentFormat.compact(Double(totals.processed))) tokens"]
        if totals.hasCost { parts.append(AgentFormat.cost(totals.cost, estimated: totals.costIsEstimated)) }
        parts.append("\(totals.requests.formatted()) request\(totals.requests == 1 ? "" : "s")")
        if totals.sessions > 0 { parts.append("\(totals.sessions) session\(totals.sessions == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func column(_ title: String, rows: [AgentUsageRow], agentIcons: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(NFont.caption.weight(.medium)).foregroundStyle(N.text2)
            let shown = rows.filter { $0.totals.value(for: metric) > 0 }.prefix(5)
            if shown.isEmpty {
                Text(metric == .cost ? "No priced usage" : "–").font(NFont.caption).foregroundStyle(N.text3)
            }
            ForEach(Array(shown)) { row in
                let color = row.agent?.tag.fg ?? tint
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if agentIcons, let agent = row.agent {
                            AgentIconView(agent: agent, size: 12)
                        } else {
                            Circle().fill(color).frame(width: 6, height: 6)
                        }
                        Text(row.title).font(NFont.small).foregroundStyle(N.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(AgentFormat.metric(row.totals.value(for: metric), metric))
                            .font(NFont.caption).monospacedDigit().foregroundStyle(N.text2)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(N.bgSoft)
                            Capsule().fill(color.opacity(0.8)).frame(width: max(3, proxy.size.width * row.share))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
