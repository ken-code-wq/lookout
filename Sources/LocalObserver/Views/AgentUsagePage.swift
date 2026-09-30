import SwiftUI
import Charts
import LocalObserverCore

/// Token, cost, and request history across agents, modelled on T3 Code's usage view and widened with filters.
struct AgentUsagePage: View {
    @ObservedObject var store: AgentStore
    @State private var width: CGFloat = 900
    @State private var hoveredDate: Date?

    private var report: AgentUsageReport { store.usage }
    private var metric: AgentMetricKind { store.filter.metric }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: "chart.xyaxis.line", title: "Usage", subtitle: AnyView(subtitle))
                filterBar
                Rectangle().fill(N.divider).frame(height: 1)

                if !store.hasUsageHistory && store.lastRefresh == nil {
                    UsageSkeleton().padding(.top, 28)
                } else if report.totals.events == 0 {
                    emptyState
                } else {
                    overview.padding(.top, 28)
                    heatmapSection.padding(.top, 36)
                    totals.padding(.top, 32)
                    breakdown.padding(.top, 36)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    private var horizontalPadding: CGFloat { width > 1100 ? 64 : (width > 800 ? 44 : 24) }
    private var contentWidth: CGFloat { width - horizontalPadding * 2 }

    private var subtitle: some View {
        HStack(spacing: 14) {
            Label(scopeDescription, systemImage: "line.3.horizontal.decrease")
            RelativeTimeText(date: store.lastRefresh)
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .labelStyle(TightLabelStyle())
    }

    private var scopeDescription: String {
        let agents: String
        if store.filter.agents.isEmpty {
            agents = store.settings.enabledAgents.count == 1 ? (store.enabledAgentsSorted.first?.name ?? "") : "All agents"
        } else if store.filter.agents.count == 1, let only = store.filter.agents.first {
            agents = only.name
        } else {
            agents = "\(store.filter.agents.count) agents"
        }
        return "\(agents), \(store.filter.periodPhrase())"
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 2) {
            HeaderTab(title: "Tokens", symbol: "number", active: metric == .tokens) { store.filter.metric = .tokens }
            HeaderTab(title: "Cost", symbol: "dollarsign.circle", active: metric == .cost) { store.filter.metric = .cost }
            HeaderTab(title: "Requests", symbol: "arrow.left.arrow.right", active: metric == .requests) { store.filter.metric = .requests }
            Spacer(minLength: 12)
            ViewThatFits(in: .horizontal) {
                chips(compact: false)
                chips(compact: true)
            }
        }
        .padding(.bottom, 6)
    }

    private func chips(compact: Bool) -> some View {
        HStack(spacing: 6) {
            PeriodChip(filter: $store.filter)
            FilterChip(title: agentChipTitle(compact), symbol: "sparkles", active: !store.filter.agents.isEmpty) {
                Button("All agents") { store.filter.agents = [] }
                Divider()
                ForEach(store.enabledAgentsSorted) { agent in
                    Toggle(agent.name, isOn: Binding(
                        get: { store.filter.agents.isEmpty || store.filter.agents.contains(agent) },
                        set: { _ in store.toggleFilterAgent(agent) }
                    ))
                }
            }
            if !compact || !store.filter.projects.isEmpty {
                FilterChip(title: setChipTitle("Project", store.filter.projects), symbol: "folder", active: !store.filter.projects.isEmpty) {
                    setMenu(options: report.availableProjects, selection: $store.filter.projects, all: "All projects")
                }
            }
            if !compact || !store.filter.models.isEmpty {
                FilterChip(title: setChipTitle("Model", store.filter.models), symbol: "cpu", active: !store.filter.models.isEmpty) {
                    setMenu(options: report.availableModels, selection: $store.filter.models, all: "All models")
                }
            }
            if store.filter.isNarrowed || !store.searchText.isEmpty {
                Button("Clear") { store.clearFilters() }
                    .buttonStyle(GhostButtonStyle())
                    .help("Show every agent, project, and model")
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func setMenu(options: [String], selection: Binding<Set<String>>, all: String) -> some View {
        Button(all) { selection.wrappedValue = [] }
        if !options.isEmpty { Divider() }
        ForEach(options, id: \.self) { option in
            Toggle(option, isOn: Binding(
                get: { selection.wrappedValue.contains(option) },
                set: { on in
                    if on { selection.wrappedValue.insert(option) } else { selection.wrappedValue.remove(option) }
                }
            ))
        }
    }

    private func agentChipTitle(_ compact: Bool) -> String {
        let agents = store.filter.agents
        if agents.isEmpty { return compact ? "Agents" : "All agents" }
        if agents.count == 1, let only = agents.first { return only.shortName }
        return "\(agents.count) agents"
    }

    private func setChipTitle(_ noun: String, _ set: Set<String>) -> String {
        if set.isEmpty { return noun }
        if set.count == 1, let only = set.first { return only }
        return "\(set.count) \(noun.lowercased())s"
    }

    // MARK: Overview

    @ViewBuilder private var overview: some View {
        if contentWidth > 820 {
            HStack(alignment: .top, spacing: 40) {
                headline.frame(width: 290, alignment: .leading)
                chart.frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 28) {
                headline
                chart
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headlineValue)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(N.text)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(headlineCaption)
                .font(NFont.small)
                .foregroundStyle(N.text2)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(report.byAgent) { row in
                    AgentShareRow(row: row, metric: metric) {
                        guard let agent = row.agent else { return }
                        store.filter.agents = store.filter.agents == [agent] ? [] : [agent]
                    }
                }
            }
            .padding(.top, 22)
        }
    }

    private var headlineValue: String {
        switch metric {
        case .tokens: return AgentFormat.compact(Double(report.totals.processed))
        case .cost: return report.totals.hasCost
            ? AgentFormat.cost(report.totals.cost, estimated: report.totals.costIsEstimated)
            : AgentFormat.unavailable
        case .requests: return report.totals.requests.formatted()
        }
    }

    private var headlineCaption: String {
        let sessions = report.totals.sessions
        let sessionText = "\(sessions.formatted()) session\(sessions == 1 ? "" : "s")"
        switch metric {
        case .tokens: return "\(sessionText), \(report.totals.requests.formatted()) requests"
        case .cost: return report.totals.costIsEstimated ? "\(sessionText), estimated at API prices" : sessionText
        case .requests: return sessionText
        }
    }

    private var chartTitle: String {
        let unit = report.isHourly ? "Hourly" : "Daily"
        switch metric {
        case .tokens: return "\(unit) processed tokens"
        case .cost: return "\(unit) cost"
        case .requests: return "\(unit) requests"
        }
    }

    private var seriesAgents: [AgentKind] { report.byAgent.compactMap(\.agent) }

    @ViewBuilder private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(chartTitle).font(NFont.bodyMedium).foregroundStyle(N.text)
                Spacer()
            }
            if !report.metricHasData {
                Text(metric == .cost
                     ? "None of the selected sessions have a price. Cost appears for models in the price table or when the agent reports it."
                     : "No \(metric.rawValue.lowercased()) were recorded for this selection.")
                    .font(NFont.small).foregroundStyle(N.text2)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                let unit: Calendar.Component = report.isHourly ? .hour : .day
                Chart {
                    ForEach(report.buckets) { bucket in
                        areaMark(for: bucket, unit: unit)
                    }
                    if let hoveredDate {
                        RuleMark(x: .value("Selected", hoveredDate, unit: unit))
                            .foregroundStyle(N.text3)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top, spacing: 6,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                ChartTooltip(title: hoverTitle(hoveredDate), rows: hoverRows(hoveredDate), metric: metric)
                            }
                    }
                }
                .chartForegroundStyleScale(domain: seriesAgents.map(\.name), range: seriesAgents.map(\.tag.fg))
                .chartLegend(.hidden)
                .chartXSelection(value: $hoveredDate)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(N.divider)
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(AgentFormat.metric(number, metric)).font(.system(size: 10.5)).foregroundStyle(N.text3)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(N.divider)
                        if report.isHourly {
                            AxisValueLabel(format: .dateTime.hour()).foregroundStyle(N.text3)
                        } else {
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(N.text3)
                        }
                    }
                }
                .frame(height: 230)
                .animation(.easeOut(duration: 0.2), value: hoveredDate)
                .accessibilityLabel(chartTitle)
                .accessibilityValue(accessibilityChartSummary)
            }
        }
    }

    /// Split out so the compiler doesn't have to type-check the whole stacked-area chart as one expression.
    /// Each agent is drawn from zero (not stacked), so every line shows that agent's own value.
    @ChartContentBuilder
    private func areaMark(for bucket: AgentUsageBucket, unit: Calendar.Component) -> some ChartContent {
        AreaMark(
            x: .value("Date", bucket.date, unit: unit),
            y: .value(metric.rawValue, bucket.value),
            series: .value("Agent", bucket.agent.name),
            stacking: .unstacked
        )
        .foregroundStyle(by: .value("Agent", bucket.agent.name))
        .interpolationMethod(.monotone)
        .opacity(0.14)
        LineMark(
            x: .value("Date", bucket.date, unit: unit),
            y: .value(metric.rawValue, bucket.value),
            series: .value("Agent", bucket.agent.name)
        )
        .foregroundStyle(by: .value("Agent", bucket.agent.name))
        .interpolationMethod(.monotone)
        .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
    }

    private func hoverRows(_ date: Date) -> [AgentUsageBucket] {
        let calendar = Calendar.current
        return report.buckets.filter {
            report.isHourly
                ? calendar.isDate($0.date, equalTo: date, toGranularity: .hour)
                : calendar.isDate($0.date, inSameDayAs: date)
        }
        .sorted { $0.value > $1.value }
    }

    private func hoverTitle(_ date: Date) -> String {
        report.isHourly
            ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var accessibilityChartSummary: String {
        guard let busiest = report.busiest else { return "No activity" }
        return "Peak \(AgentFormat.metric(busiest.value, metric)) on \(busiest.date.formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: Daily activity

    /// The year grid follows the tab's metric, but not the period, project, model, or search filters.
    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Daily activity") {
                Text("Last 12 months").font(NFont.caption).foregroundStyle(N.text3)
            }
            UsageHeatmapView(days: store.heatmap, metric: metric)
            if store.filter.isNarrowed || !store.searchText.isEmpty {
                Text("The grid covers every project and model for the selected agents.")
                    .font(NFont.caption)
                    .foregroundStyle(N.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: Totals

    private var totals: some View {
        let t = report.totals
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Totals")
            let grid = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20, alignment: .topLeading)]
            LazyVGrid(columns: grid, alignment: .leading, spacing: 20) {
                TotalCell(label: "Processed tokens", value: AgentFormat.compact(Double(t.processed)),
                          help: "Uncached input, cache reads, cache writes, and output")
                TotalCell(label: "Cached input", value: AgentFormat.tokens(t.tokens.cachedInputTokens),
                          help: "Prompt tokens served from the provider's cache")
                TotalCell(label: "Uncached input", value: AgentFormat.compact(Double(t.uncachedInput)),
                          help: "Prompt tokens billed at the full input rate")
                if let writes = t.tokens.cacheCreationTokens, writes > 0 {
                    TotalCell(label: "Cache writes", value: AgentFormat.compact(Double(writes)),
                              help: "Prompt tokens written to the cache")
                }
                TotalCell(label: "Output", value: AgentFormat.tokens(t.tokens.outputTokens))
                if let reasoning = t.tokens.reasoningTokens, reasoning > 0 {
                    TotalCell(label: "Reasoning", value: AgentFormat.compact(Double(reasoning)),
                              help: "Reported separately by some agents; already part of output")
                }
                TotalCell(label: "Cache savings", value: t.cacheSavings > 0 ? AgentFormat.cost(t.cacheSavings) : "–",
                          help: "What cached input would have cost at the full input rate")
                TotalCell(label: t.costIsEstimated ? "Estimated cost" : "Cost",
                          value: t.hasCost ? AgentFormat.cost(t.cost) : "–",
                          help: t.costIsEstimated ? "Public API prices. Subscription plans bill differently." : "Reported by the agents")
            }

            Rectangle().fill(N.divider).frame(height: 1).padding(.vertical, 20)

            LazyVGrid(columns: grid, alignment: .leading, spacing: 20) {
                if let busiest = report.busiest {
                    TotalCell(label: report.isHourly ? "Busiest hour" : "Busiest day",
                              value: AgentFormat.metric(busiest.value, metric),
                              caption: report.isHourly
                                ? busiest.date.formatted(.dateTime.hour().minute())
                                : busiest.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                }
                TotalCell(label: report.isHourly ? "Per active hour" : "Per active day",
                          value: AgentFormat.metric(report.average, metric),
                          caption: "\(report.activeBuckets) of \(report.bucketDates.count) \(report.isHourly ? "hours" : "days") active")
                if let hit = t.cacheHitRate {
                    TotalCell(label: "Cache hit rate", value: AgentFormat.percent(hit),
                              caption: "of prompt tokens")
                }
                if t.requests > 0 {
                    TotalCell(label: "Per request", value: AgentFormat.compact(Double(t.processed) / Double(t.requests)),
                              caption: "tokens on average")
                }
                if t.sessions > 0 {
                    TotalCell(label: "Per session", value: AgentFormat.compact(Double(t.processed) / Double(t.sessions)),
                              caption: "tokens on average")
                }
            }
            if t.costIsEstimated {
                Text("Costs are estimated from public API prices, so they show what this work would cost on pay-as-you-go. Subscription plans bill differently.")
                    .font(NFont.caption)
                    .foregroundStyle(N.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
            }
        }
    }

    // MARK: Breakdown

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Breakdown", count: report.rows.count) {
                Picker("Group by", selection: $store.filter.grouping) {
                    ForEach(AgentUsageGrouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            BreakdownHeader(grouping: store.filter.grouping, metric: metric, wide: contentWidth > 700)
            LazyVStack(spacing: 1) {
                ForEach(report.rows.prefix(60)) { row in
                    BreakdownRow(row: row, metric: metric, wide: contentWidth > 700) {
                        applyDrillDown(row)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func applyDrillDown(_ row: AgentUsageRow) {
        switch store.filter.grouping {
        case .agent: if let agent = row.agent { store.filter.agents = [agent] }
        case .model: store.filter.models = [row.id]
        case .project: store.filter.projects = [row.id]
        }
    }

    // MARK: Empty

    @ViewBuilder private var emptyState: some View {
        if store.filter.isNarrowed || !store.searchText.isEmpty {
            EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches these filters",
                           message: "No usage \(store.filter.periodPhrase()) for the selected agents, projects, or models.") {
                Button("Clear filters") { store.clearFilters() }.buttonStyle(SecondaryButtonStyle())
            }
        } else if (store.filter.isCustom || store.filter.range != .oneYear) && store.hasUsageHistory {
            EmptyStateView(symbol: "calendar", title: "No usage \(store.filter.periodPhrase())",
                           message: "Earlier activity is still recorded.") {
                Button("Show 90 days") { store.filter.setPreset(.ninetyDays) }.buttonStyle(SecondaryButtonStyle())
            }
        } else {
            EmptyStateView(symbol: "chart.xyaxis.line", title: "No usage recorded yet",
                           message: "Usage appears after an enabled agent finishes a request. Claude Code, Codex, OpenCode, and Pi keep token counts locally.") {
                Button("Refresh now") { store.refresh() }.buttonStyle(SecondaryButtonStyle())
                SettingsLink { Text("Choose agents") }.buttonStyle(GhostButtonStyle())
            }
        }
    }
}

// MARK: - Pieces

private struct AgentShareRow: View {
    var row: AgentUsageRow
    var metric: AgentMetricKind
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(row.agent?.tag.fg ?? N.text3).frame(width: 7, height: 7)
                    if let agent = row.agent { AgentIconView(agent: agent, size: 16) }
                    Text(row.title).font(NFont.body).foregroundStyle(N.text).lineLimit(1)
                    Text("\(row.totals.sessions) session\(row.totals.sessions == 1 ? "" : "s")")
                        .font(NFont.caption).foregroundStyle(N.text3).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(AgentFormat.metric(row.totals.value(for: metric), metric))
                        .font(NFont.bodyMedium).monospacedDigit().foregroundStyle(N.text)
                }
                Text(caption)
                    .font(NFont.caption)
                    .foregroundStyle(N.text2)
                    .padding(.leading, 14)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hover = $0 }
        .help("Show only \(row.title)")
    }

    private var caption: String {
        var parts = ["\(AgentFormat.percent(row.share)) of \(metric.rawValue.lowercased())"]
        if metric != .cost, row.totals.hasCost {
            parts.append(AgentFormat.cost(row.totals.cost, estimated: row.totals.costIsEstimated))
        }
        if metric == .cost { parts.append(AgentFormat.compact(Double(row.totals.processed)) + " tokens") }
        return parts.joined(separator: ", ")
    }
}

private struct TotalCell: View {
    var label: String
    var value: String
    var caption: String? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(NFont.small).foregroundStyle(N.text2)
            Text(value)
                .font(.system(size: 18, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(value == "–" ? N.text3 : N.text)
                .contentTransition(.numericText())
                .lineLimit(1)
            if let caption {
                Text(caption).font(NFont.caption).foregroundStyle(N.text3).lineLimit(1)
            }
        }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

private struct BreakdownHeader: View {
    var grouping: AgentUsageGrouping
    var metric: AgentMetricKind
    var wide: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(grouping.rawValue).frame(maxWidth: .infinity, alignment: .leading)
            if wide {
                Text("Sessions").frame(width: 76, alignment: .trailing)
                Text("Requests").frame(width: 80, alignment: .trailing)
            }
            Text("Tokens").frame(width: 84, alignment: .trailing)
            Text("Share of \(metric.rawValue.lowercased())").frame(width: 170, alignment: .leading).padding(.leading, 24)
            Text("Cost").frame(width: 84, alignment: .trailing)
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(N.divider).frame(height: 1) }
    }
}

private struct BreakdownRow: View {
    var row: AgentUsageRow
    var metric: AgentMetricKind
    var wide: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if let agent = row.agent {
                    AgentIconView(agent: agent, size: 16)
                } else {
                    HStack(spacing: -4) {
                        ForEach(AgentKind.allCases.filter { row.agents.contains($0) }.prefix(3)) { agent in
                            AgentIconView(agent: agent, size: 14)
                                .background(N.bg, in: Circle())
                        }
                    }
                }
                Text(row.title).font(NFont.body).foregroundStyle(N.text).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if wide {
                Text(row.totals.sessions.formatted()).frame(width: 76, alignment: .trailing)
                Text(row.totals.requests.formatted()).frame(width: 80, alignment: .trailing)
            }
            Text(AgentFormat.compact(Double(row.totals.processed)))
                .foregroundStyle(N.text)
                .frame(width: 84, alignment: .trailing)
            HStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(N.divider)
                        Capsule().fill(row.agent?.tag.fg ?? N.text2)
                            .frame(width: max(2, proxy.size.width * min(row.share, 1)))
                    }
                }
                .frame(height: 5)
                Text(AgentFormat.percent(row.share))
                    .frame(width: 48, alignment: .trailing)
            }
            .frame(width: 170)
            .padding(.leading, 24)
            Text(row.totals.hasCost ? AgentFormat.cost(row.totals.cost, estimated: row.totals.costIsEstimated) : "–")
                .frame(width: 84, alignment: .trailing)
        }
        .font(NFont.small)
        .monospacedDigit()
        .foregroundStyle(N.text2)
        .padding(.horizontal, 8)
        .frame(height: N.rowHeight)
        .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .help("Filter to \(row.title)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct UsageSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(N.bgSoft).frame(width: 160, height: 34)
                RoundedRectangle(cornerRadius: 3).fill(N.bgSoft).frame(width: 110, height: 10)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3).fill(N.bgSoft).frame(width: 240, height: 14).padding(.top, 10)
                }
            }
            RoundedRectangle(cornerRadius: N.radius).fill(N.bgSoft).frame(height: 230)
        }
        .accessibilityLabel("Reading usage history")
    }
}


// MARK: - Chart tooltip

/// Floating card over the hovered day: every agent in the series and what it used, plus the total.
struct ChartTooltip: View {
    var title: String
    var rows: [AgentUsageBucket]
    var metric: AgentMetricKind

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(NFont.caption.weight(.semibold)).foregroundStyle(N.text)
            ForEach(rows) { row in
                HStack(spacing: 7) {
                    Circle().fill(row.agent.tag.fg).frame(width: 7, height: 7)
                    AgentIconView(agent: row.agent, size: 12)
                    Text(row.agent.name).foregroundStyle(row.value > 0 ? N.text2 : N.text3)
                    Spacer(minLength: 16)
                    Text(row.value > 0 ? AgentFormat.metric(row.value, metric) : "–")
                        .monospacedDigit()
                        .foregroundStyle(row.value > 0 ? N.text : N.text3)
                }
                .font(NFont.caption)
            }
            if rows.count > 1 {
                Rectangle().fill(N.divider).frame(height: 1)
                HStack {
                    Text("Total").foregroundStyle(N.text2)
                    Spacer(minLength: 16)
                    Text(AgentFormat.metric(rows.reduce(0) { $0 + $1.value }, metric))
                        .monospacedDigit().foregroundStyle(N.text)
                }
                .font(NFont.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 170)
        .background(N.bgRaised, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: N.radius, style: .continuous).strokeBorder(N.divider))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

// MARK: - Period picker

/// Date chip with presets plus a custom from–to range, shown in a popover so it can hold date pickers.
struct PeriodChip: View {
    @Binding var filter: AgentUsageFilter
    @State private var open = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var to = Date.now

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar").font(.system(size: 10.5, weight: .medium))
                Text(filter.periodTitle()).font(NFont.small).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.7)
            }
            .foregroundStyle(filter.isCustom ? N.blue : N.text2)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(filter.isCustom ? N.selected : N.hover.opacity(0.0001),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(filter.isCustom ? N.blue.opacity(0.35) : N.divider)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $open, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Presets").font(NFont.caption.weight(.semibold)).foregroundStyle(N.text3).padding(.bottom, 4)
                presetRow("Last 24 hours", selected: filter.isRolling) { filter.setRolling(hours: 24); open = false }
                ForEach(AgentDateRange.allCases) { preset in
                    presetRow(preset.title, selected: !filter.isCustom && !filter.isRolling && filter.range == preset) {
                        filter.setPreset(preset); open = false
                    }
                }
                Rectangle().fill(N.divider).frame(height: 1).padding(.vertical, 6)
                presetRow("Yesterday", selected: false) { custom(dayOffset: -1, length: 1) }
                presetRow("This week", selected: false) { calendarPeriod(.weekOfYear, offset: 0) }
                presetRow("Last week", selected: false) { calendarPeriod(.weekOfYear, offset: -1) }
                presetRow("This month", selected: false) { calendarPeriod(.month, offset: 0) }
                presetRow("Last month", selected: false) { calendarPeriod(.month, offset: -1) }
            }
            .frame(width: 130, alignment: .leading)
            .padding(12)

            Rectangle().fill(N.divider).frame(width: 1)

            VStack(alignment: .leading, spacing: 10) {
                Text("Custom range").font(NFont.caption.weight(.semibold)).foregroundStyle(N.text3)
                DatePicker("From", selection: $from, in: ...Date.now, displayedComponents: .date)
                DatePicker("To", selection: $to, in: ...Date.now, displayedComponents: .date)
                Text("Both days are included. Single-day ranges chart by hour.")
                    .font(NFont.caption).foregroundStyle(N.text3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if filter.isCustom {
                        Button("Reset") { filter.setPreset(.thirtyDays); open = false }.buttonStyle(GhostButtonStyle())
                    }
                    Spacer()
                    Button("Apply") { filter.setCustom(from: from, to: to); open = false }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .font(NFont.small)
            .padding(12)
            .frame(width: 250)
        }
        .onAppear {
            if let s = filter.customStart, let e = filter.customEnd { from = s; to = e }
        }
    }

    private func presetRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(N.text)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(N.blue) }
            }
            .font(NFont.small)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverButtonStyle())
    }

    private func custom(dayOffset: Int, length: Int) {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: .now)) ?? .now
        let end = cal.date(byAdding: .day, value: length - 1, to: start) ?? start
        filter.setCustom(from: start, to: end)
        open = false
    }

    private func calendarPeriod(_ unit: Calendar.Component, offset: Int) {
        let cal = Calendar.current
        guard let anchor = cal.date(byAdding: unit, value: offset, to: .now),
              let interval = cal.dateInterval(of: unit, for: anchor) else { return }
        let end = min(interval.end.addingTimeInterval(-1), .now)
        filter.setCustom(from: interval.start, to: end)
        open = false
    }
}

private struct RowHoverButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
            .onHover { hover = $0 }
    }
}
