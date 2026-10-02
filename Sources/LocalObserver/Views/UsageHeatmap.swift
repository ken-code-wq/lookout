import SwiftUI
import LocalObserverCore

/// GitHub-style year grid: one column per week, one row per weekday, each cell tinted by that
/// day's usage. Cell shading is relative (quartiles of active days), so a light week still reads
/// against a heavy one.
struct UsageHeatmapView: View {
    var days: [AgentHeatmapDay]
    var metric: AgentMetricKind
    /// Shade colour; the dashboard tints the grid with the agent it's showing.
    var tint: Color = N.blue
    /// The dashboard lets cells grow to fill a wide card; the Usage page keeps them GitHub-small.
    var maxCell: CGFloat = 12
    /// When set, clicking a day selects it (clicking it again clears).
    var selection: Binding<Date?>? = nil
    /// Hide the summary line and legend when the caller shows its own.
    var showsFooter = true

    private static let gap: CGFloat = 3
    private static let labelWidth: CGFloat = 26
    private static let monthHeight: CGFloat = 15
    private static let levels: [Double] = [0, 0.25, 0.45, 0.68, 0.92]

    @State private var width: CGFloat = 700

    private struct Week: Identifiable {
        var start: Date
        var dates: [Date?]
        var id: Date { start }
    }

    private struct MonthLabel {
        var column: Int
        var text: String
    }

    var body: some View {
        let weeks = Self.grid()
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        let positives = days.compactMap { $0.value(for: metric) }.filter { $0 > 0 }.sorted()
        let total = positives.reduce(0, +)
        let cell = cellSize(weeks.count)
        let labels = Self.monthLabels(weeks)
        let shade = Self.shade(positives: positives)

        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: Self.gap) {
                    if cell >= 9 {
                        weekdayColumn(cell: cell)
                    } else {
                        Color.clear.frame(width: Self.labelWidth, height: 7 * cell + 6 * Self.gap)
                    }
                    ForEach(weeks) { week in
                        VStack(spacing: Self.gap) {
                            ForEach(Array(week.dates.enumerated()), id: \.offset) { _, date in
                                cellView(date: date, day: date.flatMap { byDate[$0] }, cell: cell, shade: shade)
                            }
                        }
                    }
                }
                .padding(.top, Self.monthHeight)
                ForEach(Array(labels.enumerated()), id: \.element.column) { _, label in
                    Text(label.text)
                        .font(.system(size: 9.5))
                        .foregroundStyle(N.text3)
                        .offset(x: Self.labelWidth + Self.gap + CGFloat(label.column) * (cell + Self.gap))
                }
            }
            if showsFooter {
                HStack(spacing: 5) {
                    Text(summary(activeDays: positives.count, total: total))
                        .font(.system(size: 10.5))
                        .foregroundStyle(N.text3)
                    Spacer(minLength: 8)
                    UsageHeatmapLegend(tint: tint, cell: min(cell, 10))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage heatmap, last 12 months, by \(metric.rawValue.lowercased())")
        .accessibilityValue(summary(activeDays: positives.count, total: total))
    }

    private func cellSize(_ columns: Int) -> CGFloat {
        let cols = CGFloat(max(columns, 1))
        let raw = (width - Self.labelWidth - Self.gap * cols) / cols
        return min(max(raw, 4), maxCell)
    }

    private func summary(activeDays: Int, total: Double) -> String {
        guard activeDays > 0 else { return "No \(metric.rawValue.lowercased()) in the last 12 months" }
        return "\(activeDays) active \(activeDays == 1 ? "day" : "days") · \(AgentFormat.metric(total, metric)) total"
    }

    // MARK: Cells

    private func cellView(date: Date?, day: AgentHeatmapDay?, cell: CGFloat, shade: (Double) -> Int) -> some View {
        HeatmapCell(date: date, day: day, cell: cell, fill: color(day: day, shade: shade),
                    selected: date != nil && selection?.wrappedValue == date) {
            guard let selection, let date else { return }
            selection.wrappedValue = selection.wrappedValue == date ? nil : date
        }
        .equatable()
    }

    private func color(day: AgentHeatmapDay?, shade: (Double) -> Int) -> Color {
        guard let day, let value = day.value(for: metric) else { return N.bgSoft }
        let level = shade(value)
        return level == 0 ? N.bgSoft : tint.opacity(Self.levels[level])
    }

    /// Quartile shading over the active days of the chosen metric.
    private static func shade(positives: [Double]) -> (Double) -> Int {
        guard !positives.isEmpty else { return { _ in 0 } }
        let q1 = positives[positives.count / 4]
        let q2 = positives[positives.count / 2]
        let q3 = positives[positives.count * 3 / 4]
        return { value in
            guard value > 0 else { return 0 }
            if value <= q1 { return 1 }
            if value <= q2 { return 2 }
            if value <= q3 { return 3 }
            return 4
        }
    }

    // MARK: Chrome

    private func weekdayColumn(cell: CGFloat) -> some View {
        VStack(spacing: Self.gap) {
            ForEach(Array(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].enumerated()), id: \.offset) { row, name in
                Text([1, 3, 5].contains(row) ? name : "")
                    .font(.system(size: 9.5))
                    .foregroundStyle(N.text3)
                    .frame(width: Self.labelWidth, height: cell, alignment: .trailing)
            }
        }
    }

    // MARK: Grid

    /// 365 days ending today, grouped into Sunday-anchored week columns.
    private static func grid(calendar: Calendar = .current) -> [Week] {
        let today = calendar.startOfDay(for: .now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(AgentDateRange.oneYear.rawValue - 1), to: today),
              let anchor = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: windowStart) - 1), to: windowStart)
        else { return [] }
        var weeks: [Week] = []
        var cursor = anchor
        while cursor <= today {
            let dates = (0..<7).map { offset -> Date? in
                guard let day = calendar.date(byAdding: .day, value: offset, to: cursor) else { return nil }
                return day >= windowStart && day <= today ? day : nil
            }
            weeks.append(Week(start: cursor, dates: dates))
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return weeks
    }

    /// Month names at the column where each month starts, kept at least three columns apart.
    private static func monthLabels(_ weeks: [Week], calendar: Calendar = .current) -> [MonthLabel] {
        var labels: [MonthLabel] = []
        var lastMonth = -1
        for (index, week) in weeks.enumerated() {
            guard let first = week.dates.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: first)
            guard month != lastMonth else { continue }
            lastMonth = month
            if labels.isEmpty || index - labels[labels.count - 1].column >= 3 {
                labels.append(MonthLabel(column: index, text: first.formatted(.dateTime.month(.abbreviated))))
            }
        }
        return labels
    }
}

/// One day's square. Owns its hover state and builds its tooltip only when drawn, so pointing at a cell
/// re-renders that cell alone rather than the whole 371-cell grid.
private struct HeatmapCell: View, Equatable {
    var date: Date?
    var day: AgentHeatmapDay?
    var cell: CGFloat
    var fill: Color
    var selected: Bool
    var tap: () -> Void
    @State private var hovered = false

    static func == (lhs: HeatmapCell, rhs: HeatmapCell) -> Bool {
        lhs.date == rhs.date && lhs.day == rhs.day && lhs.cell == rhs.cell && lhs.fill == rhs.fill && lhs.selected == rhs.selected
    }

    var body: some View {
        if let date {
            let radius = max(2, cell / 5)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .frame(width: cell, height: cell)
                .overlay {
                    if selected || hovered {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(selected ? N.text : N.text2, lineWidth: selected ? 1.5 : 1)
                    } else if day == nil {
                        RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(N.divider)
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .onTapGesture(perform: tap)
                .help(hovered ? tooltip(date, day) : "")
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }

    private func tooltip(_ date: Date, _ day: AgentHeatmapDay?) -> String {
        let title = date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        guard let day else { return "\(title) — no usage" }
        var parts: [String] = []
        if day.processed > 0 { parts.append("\(AgentFormat.compact(Double(day.processed))) tokens") }
        if day.hasCost { parts.append(AgentFormat.cost(day.cost, estimated: day.costIsEstimated)) }
        if day.requests > 0 { parts.append("\(day.requests) request\(day.requests == 1 ? "" : "s")") }
        return parts.isEmpty ? "\(title) — no usage" : "\(title) — \(parts.joined(separator: " · "))"
    }

}

/// "Less ▢▢▢▢▢ More", matching the grid's shading.
struct UsageHeatmapLegend: View {
    var tint: Color
    var cell: CGFloat = 10

    var body: some View {
        HStack(spacing: 3) {
            Text("Less").font(.system(size: 10)).foregroundStyle(N.text3)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(level == 0 ? AnyShapeStyle(N.bgSoft) : AnyShapeStyle(tint.opacity([0, 0.25, 0.45, 0.68, 0.92][level])))
                    .overlay {
                        if level == 0 { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(N.divider) }
                    }
                    .frame(width: cell, height: cell)
            }
            Text("More").font(.system(size: 10)).foregroundStyle(N.text3)
        }
    }
}
