import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalObserverCore
import LocalObserverRepos

/// The weekly report sheet: week navigation, the shareable card in light or dark, and export.
struct WeeklyReportSheet: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var model: WeeklyReportModel = .shared
    @ObservedObject var github: GitHubStore = .shared
    @Environment(\.colorScheme) private var systemScheme
    @State private var dark: Bool?
    @State private var copied: String?

    private var isDark: Bool { dark ?? (systemScheme == .dark) }

    var body: some View {
        let (report, previous) = model.reports(store: agentStore, github: github)
        VStack(spacing: 0) {
            header(report)
            Rectangle().fill(N.divider).frame(height: 1)
            ScrollView {
                WeeklyReportCard(report: report, previous: previous, palette: .init(dark: isDark))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(N.divider))
                    .padding(24)
            }
            .background(N.bgSoft)
            Rectangle().fill(N.divider).frame(height: 1)
            footer(report, previous)
        }
        .frame(width: WeeklyReportCard.width + 48, height: 820)
        .background(N.bg)
        .onAppear { load(report) }
        .onChange(of: model.weekStart) { _, _ in load(model.reports(store: agentStore, github: github).current) }
        .onKeyPress(.leftArrow) { model.step(-1); return .handled }
        .onKeyPress(.rightArrow) { model.step(1); return .handled }
    }

    private func load(_ report: WeeklyReport) {
        model.loadPulls(for: report.week)
        model.loadPulls(for: WeeklyReport.week(offset: -1, from: report.week.start))
        if github.contributions.isEmpty, RepoGitHub.cliPath != nil { github.loadContributions(year: nil) }
    }

    private func header(_ report: WeeklyReport) -> some View {
        HStack(spacing: 8) {
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(GhostButtonStyle())
                .help("Previous week")
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(GhostButtonStyle())
                .disabled(model.isCurrentWeek)
                .help("Next week")
            Text(WeeklyReportFormat.range(report.week)).font(NFont.bodyMedium).foregroundStyle(N.text)
            if !model.isCurrentWeek {
                Button("This week") { model.open() }.buttonStyle(GhostButtonStyle(tint: N.blue))
            }
            Spacer()
            Picker("Appearance", selection: Binding(get: { isDark }, set: { dark = $0 })) {
                Text("Light").tag(false)
                Text("Dark").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("How the card looks here and when exported")
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private func footer(_ report: WeeklyReport, _ previous: WeeklyReport) -> some View {
        HStack(spacing: 8) {
            if let copied {
                Label(copied, systemImage: "checkmark").font(NFont.small).foregroundStyle(N.text2).labelStyle(TightLabelStyle())
            } else if case .unavailable(let reason)? = model.pulls[report.week.start] {
                Text("Pull requests not included: \(reason)").font(NFont.caption).foregroundStyle(N.text3).lineLimit(1)
            }
            Spacer()
            Button("Copy as Markdown") {
                copy(string: WeeklyReportFormat.markdown(report, previous: previous))
                flash("Markdown copied")
            }
            .buttonStyle(GhostButtonStyle())
            Button("Copy image") {
                guard let image = render(report, previous) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                flash("Image copied")
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("Export PNG…") { export(report, previous) }
                .buttonStyle(SecondaryButtonStyle())
            Button("Done") { model.isPresented = false }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private func flash(_ message: String) {
        withAnimation(.snappy(duration: 0.2)) { copied = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy(duration: 0.2)) { if copied == message { copied = nil } }
        }
    }

    private func copy(string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// The card at 2x, in the chosen appearance regardless of the app's.
    private func render(_ report: WeeklyReport, _ previous: WeeklyReport) -> NSImage? {
        let renderer = ImageRenderer(content: WeeklyReportCard(report: report, previous: previous, palette: .init(dark: isDark)))
        renderer.scale = 2
        return renderer.nsImage
    }

    private func export(_ report: WeeklyReport, _ previous: WeeklyReport) {
        guard let image = render(report, previous), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Lookout week of \(WeeklyReport.dayKey(report.week.start)).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            flash("Saved \(url.lastPathComponent)")
        } catch {
            flash("Couldn't save: \(error.localizedDescription)")
        }
    }
}

/// The card's colours, fixed per appearance so an exported image looks the same whatever the app is set to.
/// Values are Lookout's own tokens (see Theme.swift) plus GitHub's contribution greens.
struct WeeklyReportPalette {
    var dark: Bool

    private func hex(_ light: UInt32, _ dark: UInt32, _ lightAlpha: Double = 1, _ darkAlpha: Double = 1) -> Color {
        let value = self.dark ? dark : light
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255, opacity: self.dark ? darkAlpha : lightAlpha)
    }

    var bg: Color { hex(0xFFFFFF, 0x191919) }
    var soft: Color { hex(0xF7F7F5, 0x202020) }
    var text: Color { hex(0x37352F, 0xFFFFFF, 1, 0.81) }
    var text2: Color { hex(0x787774, 0x9B9B9B) }
    var text3: Color { hex(0x37352F, 0xFFFFFF, 0.35, 0.28) }
    var divider: Color { hex(0x37352F, 0xFFFFFF, 0.09, 0.094) }
    var bar: Color { hex(0x2383E2, 0x2383E2) }
    var track: Color { hex(0x37352F, 0xFFFFFF, 0.06, 0.07) }
    var scheme: ColorScheme { dark ? .dark : .light }

    /// GitHub's contribution graph greens, empty first.
    func contribution(_ count: Int) -> Color {
        let light: [UInt32] = [0xEBEDF0, 0x9BE9A8, 0x40C463, 0x30A14E, 0x216E39]
        let dark: [UInt32] = [0x2D333B, 0x0E4429, 0x006D32, 0x26A641, 0x39D353]
        let level = count <= 0 ? 0 : count < 3 ? 1 : count < 6 ? 2 : count < 10 ? 3 : 4
        return hex(light[level], dark[level])
    }
}

/// The shareable card: the week's numbers against the week before, the days, and where the tokens went.
struct WeeklyReportCard: View {
    var report: WeeklyReport
    var previous: WeeklyReport
    var palette: WeeklyReportPalette

    static let width: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            stats.padding(.top, 22)
            rule
            if report.isEmpty {
                Text(report.isPartial ? "No agent activity yet this week." : "No agent activity this week.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.text2)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                days
                rule
                breakdown
            }
            rule
            footer
        }
        .padding(28)
        .frame(width: Self.width, alignment: .leading)
        .background(palette.bg)
        .environment(\.colorScheme, palette.scheme)
    }

    private var rule: some View { Rectangle().fill(palette.divider).frame(height: 1).padding(.vertical, 20) }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WEEKLY REPORT").font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(palette.text3)
                Text(WeeklyReportFormat.range(report.week)).font(.system(size: 22, weight: .bold)).foregroundStyle(palette.text)
                Text(scopeLine).font(.system(size: 12)).foregroundStyle(palette.text2)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "binoculars.fill").font(.system(size: 11))
                Text("Lookout").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(palette.text3)
        }
    }

    private var scopeLine: String {
        guard report.isPartial else { return "Compared with the week before" }
        let first = report.days.first.map { WeeklyReportFormat.weekday($0.date) } ?? ""
        let last = report.days.last { !$0.isFuture }.map { WeeklyReportFormat.weekday($0.date) } ?? first
        let span = first == last ? first : "\(first) to \(last)"
        return "\(span) so far, compared with the same days last week"
    }

    // MARK: Stats

    private var stats: some View {
        HStack(alignment: .top, spacing: 0) {
            stat("Tokens", AgentFormat.compact(Double(report.totals.processed)),
                 change: WeeklyReport.change(Double(report.totals.processed), Double(previous.totals.processed)), empty: previous.totals.processed == 0)
            stat("Cost", report.totals.hasCost ? AgentFormat.cost(report.totals.cost, estimated: report.totals.costIsEstimated) : "–",
                 change: WeeklyReport.change(report.totals.cost, previous.totals.cost), empty: !previous.totals.hasCost)
            stat("Agent time", WeeklyReportFormat.hours(report.activeSeconds),
                 change: WeeklyReport.change(report.activeSeconds, previous.activeSeconds), empty: previous.activeSeconds == 0)
            stat("Sessions", "\(report.totals.sessions)",
                 change: WeeklyReport.change(Double(report.totals.sessions), Double(previous.totals.sessions)), empty: previous.totals.sessions == 0)
        }
    }

    private func stat(_ title: String, _ value: String, change: Double?, empty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(palette.text2)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(palette.text)
            WeeklyChange(change: change, noBaseline: empty, palette: palette)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Days

    private var days: some View {
        let peak = max(report.days.map(\.processed).max() ?? 0, 1)
        let showsContributions = report.contributions != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tokens by day").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
                Spacer()
                Text("\(report.activeDays) of \(report.coveredDays) day\(report.coveredDays == 1 ? "" : "s") active")
                    .font(.system(size: 11.5)).foregroundStyle(palette.text2)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(report.days) { day in
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(palette.divider).frame(height: 1)
                            if day.isFuture {
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(palette.divider, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            } else if day.processed > 0 {
                                RoundedRectangle(cornerRadius: 3).fill(palette.bar)
                                    .frame(height: max(3, 72 * CGFloat(Double(day.processed) / Double(peak))))
                            }
                        }
                        .frame(height: 72, alignment: .bottom)
                        Text(day.isFuture || day.processed == 0 ? "–" : AgentFormat.compact(Double(day.processed)))
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(palette.text2)
                        Text(WeeklyReportFormat.weekday(day.date)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(palette.text3)
                        if showsContributions {
                            HStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 2).fill(day.isFuture ? palette.track : palette.contribution(day.contributions ?? 0))
                                    .frame(width: 10, height: 10)
                                Text(day.contributions.map(String.init) ?? "–").font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.text3)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if showsContributions {
                Text("Squares are GitHub contributions that day.").font(.system(size: 10.5)).foregroundStyle(palette.text3)
            }
        }
    }

    // MARK: Breakdown

    private var breakdown: some View {
        HStack(alignment: .top, spacing: 24) {
            column("Agents", report.byAgent)
            column("Models", report.byModel)
            column("Projects", report.byProject)
        }
    }

    private func column(_ title: String, _ rows: [WeeklyReport.Row]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
            ForEach(rows.prefix(4)) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if let agent = row.agent, title != "Projects" { icon(agent) }
                        Text(row.title).font(.system(size: 12)).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(AgentFormat.compact(Double(row.processed))).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(palette.text2)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.track)
                            Capsule().fill(palette.bar.opacity(0.75)).frame(width: max(2, proxy.size.width * row.share))
                        }
                    }
                    .frame(height: 3)
                }
            }
            if rows.count > 4 {
                Text("+\(rows.count - 4) more").font(.system(size: 11)).foregroundStyle(palette.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func icon(_ agent: AgentKind) -> some View {
        Group {
            if let image = AgentIcons.image(for: agent) {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(palette.text)
            }
        }
        .frame(width: 12, height: 12)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(facts.joined(separator: "  ·  ")).font(.system(size: 12)).foregroundStyle(palette.text)
            if report.totals.costIsEstimated {
                Text("Costs are estimates at public API prices; subscription plans bill differently.")
                    .font(.system(size: 10.5)).foregroundStyle(palette.text3)
            }
        }
    }

    private var facts: [String] {
        var facts = ["\(report.streak)-day streak"]
        if let pulls = report.pulls {
            facts.append("\(pulls.merged) PR\(pulls.merged == 1 ? "" : "s") merged")
            facts.append("\(pulls.opened) opened")
        }
        if let contributions = report.contributions {
            facts.append("\(contributions) contribution\(contributions == 1 ? "" : "s")")
        }
        if report.totals.requests > 0 { facts.append("\(AgentFormat.compact(Double(report.totals.requests))) requests") }
        return facts
    }
}

/// "▲ 12% vs last week", with the arrow and the words carrying the direction, not colour.
private struct WeeklyChange: View {
    var change: Double?
    var noBaseline: Bool
    var palette: WeeklyReportPalette

    var body: some View {
        Group {
            if let change {
                let flat = abs(change) < 0.005
                HStack(spacing: 3) {
                    Image(systemName: flat ? "equal" : (change > 0 ? "arrow.up.right" : "arrow.down.right"))
                        .font(.system(size: 9, weight: .semibold))
                    Text(flat ? "Same as last week" : "\(AgentFormat.percent(abs(change), digits: 0)) \(change > 0 ? "more" : "less")")
                }
            } else {
                Text(noBaseline ? "Nothing last week" : "–")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.text2)
    }
}

enum WeeklyReportFormat {
    /// "Sep 28 – Oct 4, 2026", "Oct 5 – 11, 2026", in the user's locale.
    static func range(_ week: DateInterval) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: week.start, to: week.end.addingTimeInterval(-1))
    }

    static func weekday(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated)) }

    /// "14h 20m", "45m", "0m": agent time reads in hours even past a day.
    static func hours(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    static func markdown(_ report: WeeklyReport, previous: WeeklyReport) -> String {
        func change(_ a: Double, _ b: Double) -> String {
            guard let c = WeeklyReport.change(a, b) else { return "–" }
            return abs(c) < 0.005 ? "same" : (c > 0 ? "+" : "−") + AgentFormat.percent(abs(c), digits: 0)
        }
        let cost: (WeeklyReport) -> String = { $0.totals.hasCost ? AgentFormat.cost($0.totals.cost, estimated: $0.totals.costIsEstimated) : "–" }
        var lines = [
            "## Weekly report: \(range(report.week))",
            "",
            report.isPartial ? "_\(report.coveredDays) of 7 days so far, compared with the same days last week._" : "_Compared with the week before._",
            "",
            "| | This week | Last week | Change |",
            "|---|---:|---:|---:|",
            "| Tokens | \(AgentFormat.compact(Double(report.totals.processed))) | \(AgentFormat.compact(Double(previous.totals.processed))) | \(change(Double(report.totals.processed), Double(previous.totals.processed))) |",
            "| Cost | \(cost(report)) | \(cost(previous)) | \(change(report.totals.cost, previous.totals.cost)) |",
            "| Agent time | \(hours(report.activeSeconds)) | \(hours(previous.activeSeconds)) | \(change(report.activeSeconds, previous.activeSeconds)) |",
            "| Sessions | \(report.totals.sessions) | \(previous.totals.sessions) | \(change(Double(report.totals.sessions), Double(previous.totals.sessions))) |",
            "| Active days | \(report.activeDays) | \(previous.activeDays) | |",
        ]
        if let pulls = report.pulls {
            lines.append("| PRs merged / opened | \(pulls.merged) / \(pulls.opened) | \(previous.pulls.map { "\($0.merged) / \($0.opened)" } ?? "–") | |")
        }
        if let contributions = report.contributions {
            lines.append("| GitHub contributions | \(contributions) | \(previous.contributions.map(String.init) ?? "–") | |")
        }
        for (title, rows) in [("Agents", report.byAgent), ("Models", report.byModel), ("Projects", report.byProject)] where !rows.isEmpty {
            lines += ["", "**\(title)**", ""]
            lines += rows.prefix(5).map { row in
                "- \(row.title): \(AgentFormat.compact(Double(row.processed))) tokens (\(AgentFormat.percent(row.share, digits: 0)))"
                    + (row.cost > 0 ? ", \(AgentFormat.cost(row.cost, estimated: row.costIsEstimated))" : "")
            }
        }
        lines += ["", "\(report.streak)-day streak." + (report.totals.costIsEstimated ? " Costs are estimates at public API prices." : "")]
        return lines.joined(separator: "\n")
    }
}

extension DigestCard {
    /// Mondays: last week in one line, opening its report.
    var yourWeek: Line? {
        let lastWeek = WeeklyReport.week(offset: -1, from: Date())
        let (report, previous) = WeeklyReportModel.shared.reports(store: agentStore, github: github, weekOf: lastWeek.start)
        guard !report.isEmpty else { return nil }
        let change = WeeklyReport.change(Double(report.totals.processed), Double(previous.totals.processed)).map {
            abs($0) < 0.005 ? "as many tokens as the week before"
                : "\(AgentFormat.percent(abs($0), digits: 0)) \($0 > 0 ? "more" : "fewer") tokens than the week before"
        }
        let detail = [change, "\(report.activeDays) of 7 days active",
                      report.totals.hasCost ? AgentFormat.cost(report.totals.cost, estimated: report.totals.costIsEstimated) : nil]
        return Line(id: "week", symbol: "calendar", tint: N.blue,
                    text: "Your week: \(AgentFormat.compact(Double(report.totals.processed))) tokens, \(WeeklyReportFormat.hours(report.activeSeconds)) with agents",
                    detail: detail.compactMap { $0 }.joined(separator: " · "), page: .agentUsage,
                    action: { WeeklyReportModel.shared.open(weekOf: lastWeek.start) })
    }
}

/// "Weekly report" beside the Usage page's scope line.
struct WeeklyReportLink: View {
    var body: some View {
        Button { WeeklyReportModel.shared.open() } label: {
            Label("Weekly report", systemImage: "calendar")
        }
        .buttonStyle(.plain)
        .foregroundStyle(N.blue)
        .help("This week's usage as a card you can share")
    }
}
