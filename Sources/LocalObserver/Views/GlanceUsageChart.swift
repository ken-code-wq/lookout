import SwiftUI
import Charts
import LocalObserverCore

/// Compact usage chart with its own period, metric, and agent filters. Used by the menu bar panel and the notch.
struct GlanceUsageChart: View {
    @ObservedObject var store: AgentStore
    var chartHeight: CGFloat = 86
    var openUsage: () -> Void

    @State private var hovered: Date?

    private var report: AgentUsageReport { store.glanceUsage }
    private var metric: AgentMetricKind { store.glanceMetric }
    private var seriesAgents: [AgentKind] { report.byAgent.compactMap(\.agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            headline
            if report.metricHasData {
                chart
                legend
            } else {
                Text(emptyText)
                    .font(NFont.caption)
                    .foregroundStyle(N.text3)
                    .frame(maxWidth: .infinity, minHeight: chartHeight)
            }
        }
    }

    private var emptyText: String {
        metric == .cost ? "No priced usage \(report.filter.periodPhrase())" : "No usage \(report.filter.periodPhrase())"
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                ForEach(AgentGlanceRange.allCases) { range in
                    let selected = store.glanceRange == range
                    Button { store.glanceRange = range } label: {
                        Text(range.title)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? N.text : N.text2)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(selected ? N.pressed : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(range.longTitle)
                }
            }
            .padding(1)
            .background(N.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Spacer(minLength: 4)
            Menu {
                Picker("Measure", selection: $store.glanceMetric) {
                    ForEach(AgentMetricKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Section("Agents") {
                    ForEach(store.enabledAgentsSorted) { agent in
                        Toggle(agent.name, isOn: Binding(
                            get: { store.glanceAgents.isEmpty || store.glanceAgents.contains(agent) },
                            set: { on in toggle(agent, on: on) }
                        ))
                    }
                    if !store.glanceAgents.isEmpty {
                        Button("All agents") { store.glanceAgents = [] }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(metric.rawValue)
                    if !store.glanceAgents.isEmpty {
                        Text("· \(store.glanceAgents.count == 1 ? store.glanceAgents.first!.shortName : "\(store.glanceAgents.count) agents")")
                            .foregroundStyle(N.blue)
                    }
                }
                .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Measure and agents")
        }
    }

    /// Unchecking an agent while "all" is implied switches to an explicit list of the others.
    private func toggle(_ agent: AgentKind, on: Bool) {
        var selected = store.glanceAgents.isEmpty ? Set(store.enabledAgentsSorted) : store.glanceAgents
        if on { selected.insert(agent) } else { selected.remove(agent) }
        store.glanceAgents = selected.isEmpty || selected == Set(store.enabledAgentsSorted) ? [] : selected
    }

    // MARK: Headline

    private var headline: some View {
        Button(action: openUsage) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value(report.totals.value(for: metric), totals: report.totals))
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(N.text)
                Text(caption).font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the Usage page")
    }

    private var caption: String {
        let totals = report.totals
        var parts: [String] = []
        switch metric {
        case .tokens:
            if totals.hasCost { parts.append(AgentFormat.cost(totals.cost, estimated: totals.costIsEstimated)) }
            parts.append("\(totals.requests.formatted()) req")
        case .cost:
            parts.append("\(AgentFormat.compact(Double(totals.processed))) tokens")
        case .requests:
            parts.append("\(totals.sessions.formatted()) sessions")
        }
        if let busiest = report.busiest {
            let when = report.isHourly
                ? busiest.date.formatted(.dateTime.hour().minute())
                : busiest.date.formatted(.dateTime.weekday(.abbreviated))
            parts.append("peak \(when)")
        }
        return parts.joined(separator: " · ")
    }

    private func value(_ number: Double, totals: AgentUsageTotals? = nil) -> String {
        if metric == .cost, let totals { return AgentFormat.cost(number, estimated: totals.costIsEstimated) }
        return AgentFormat.metric(number, metric)
    }

    // MARK: Chart

    private var unit: Calendar.Component { report.isHourly ? .hour : .day }

    private var chart: some View {
        Chart {
            ForEach(report.buckets) { bucket in
                BarMark(
                    x: .value("Date", bucket.date, unit: unit),
                    y: .value(metric.rawValue, bucket.value)
                )
                .foregroundStyle(by: .value("Agent", bucket.agent.name))
                .cornerRadius(1.5)
            }
            if let hovered {
                RuleMark(x: .value("Selected", hovered, unit: unit))
                    .foregroundStyle(N.text3.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    // Beside the line, hanging from the top of the plot: never above the chart, where the menu
                    // bar panel and the notch have headers (and the top of the screen).
                    .annotation(position: onRightHalf(hovered) ? .leading : .trailing, alignment: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(title: title(for: hovered), rows: rows(for: hovered), metric: metric)
                    }
            }
        }
        .chartForegroundStyleScale(domain: seriesAgents.map(\.name), range: seriesAgents.map(\.tag.fg))
        .chartLegend(.hidden)
        .chartXSelection(value: $hovered)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(N.divider)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(AgentFormat.metric(number, metric)).font(.system(size: 9)).foregroundStyle(N.text3)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                if report.isHourly {
                    AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9)).foregroundStyle(N.text3)
                } else {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.system(size: 9)).foregroundStyle(N.text3)
                }
            }
        }
        .frame(height: chartHeight)
        .zIndex(1) // keep the tooltip above the legend
    }

    private func onRightHalf(_ date: Date) -> Bool {
        guard let first = report.bucketDates.first, let last = report.bucketDates.last, last > first else { return false }
        return date.timeIntervalSince(first) > last.timeIntervalSince(first) / 2
    }

    private func rows(for date: Date) -> [AgentUsageBucket] {
        let calendar = Calendar.current
        return report.buckets.filter { calendar.isDate($0.date, equalTo: date, toGranularity: unit) }
    }

    private func title(for date: Date) -> String {
        if report.isHourly {
            let end = Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date
            return "\(date.formatted(.dateTime.weekday(.abbreviated).hour())) – \(end.formatted(.dateTime.hour()))"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(report.byAgent.prefix(4)) { row in
                if let agent = row.agent {
                    HStack(spacing: 4) {
                        Circle().fill(agent.tag.fg).frame(width: 6, height: 6)
                        Text(agent.shortName).foregroundStyle(N.text2)
                        Text(value(row.totals.value(for: metric), totals: row.totals)).monospacedDigit().foregroundStyle(N.text)
                    }
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
    }
}
