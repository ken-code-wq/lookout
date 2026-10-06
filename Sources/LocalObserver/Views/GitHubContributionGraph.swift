import SwiftUI
import LocalObserverCore
import LocalObserverRepos

/// GitHub's contribution colours, light and dark, level 0 (none) to 4.
enum GHContributionColor {
    static func color(_ level: Int) -> Color {
        switch level {
        case 1: return Color(light: 0x9BE9A8, dark: 0x033A16)
        case 2: return Color(light: 0x40C463, dark: 0x196C2E)
        case 3: return Color(light: 0x30A14E, dark: 0x2EA043)
        case 4: return Color(light: 0x216E39, dark: 0x56D364)
        default: return Color(light: 0xEFF2F5, dark: 0x151B23)
        }
    }
    static let agent = Color(light: 0x8250DF, dark: 0xAB7DF8)
}

/// The profile contribution graph, plus what GitHub doesn't show: the days your agents worked laid over it, how
/// many commit days had an agent behind them, streaks, which weekdays you work, and what any one day held.
struct GHContributionGraph: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var agents: AgentStore
    @State private var year: Int? = nil
    @State private var selected: GHContributionDay?
    @State private var hovered: GHContributionDay?
    @AppStorage("LocalObserver.contributionsAgentOverlay") private var showAgents = true

    private static let cell: CGFloat = 11
    private static let gap: CGFloat = 3

    private var data: GHContributionYear? { store.contributions[year ?? 0] }

    /// Days agents processed tokens, as GitHub-style date strings.
    private var agentDays: [String: Int64] {
        var days: [String: Int64] = [:]
        for d in agents.heatmap where d.processed > 0 { days[GHContributionDay.parser.string(from: d.date)] = d.processed }
        return days
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let data {
                HStack(alignment: .top, spacing: 18) {
                    graph(data)
                    Spacer(minLength: 0)
                }
                footer(data)
                if let selected { dayDetail(selected) }
                insights(data)
            } else if let error = store.error(GitHubStore.contributionsKey(year)) {
                GHErrorBox(message: error) { store.loadContributions(year: year, force: true) }
            } else {
                GHLoading(text: "Loading contributions…").frame(height: 140)
            }
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
        .task(id: year) { store.loadContributions(year: year) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let data {
                Text("\(data.total.formatted()) contributions \(year.map { "in \($0)" } ?? "in the last year")")
                    .font(.system(size: 15, weight: .regular)).foregroundStyle(N.text)
            } else {
                Text("Contributions").font(.system(size: 15)).foregroundStyle(N.text)
            }
            Spacer()
            Toggle(isOn: $showAgents) {
                HStack(spacing: 4) {
                    Circle().fill(GHContributionColor.agent).frame(width: 7, height: 7)
                    Text("Agent days").font(NFont.small)
                }
            }
            .toggleStyle(.checkbox)
            .help("Mark the days your coding agents did work")
            let years = store.contributions[0]?.years ?? data?.years ?? []
            if !years.isEmpty {
                Picker("Year", selection: $year) {
                    Text("Last 12 months").tag(Int?.none)
                    ForEach(years, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: year) { _, _ in selected = nil }
            }
        }
    }

    // MARK: Graph

    private func graph(_ data: GHContributionYear) -> some View {
        let step = Self.cell + Self.gap
        let agentDays = showAgents ? self.agentDays : [:]
        return VStack(alignment: .leading, spacing: 4) {
            // Month labels over the week where each month starts.
            ZStack(alignment: .topLeading) {
                ForEach(monthLabels(data), id: \.week) { label in
                    Text(label.name).font(.system(size: 10)).foregroundStyle(N.text2)
                        .offset(x: CGFloat(label.week) * step)
                }
            }
            .frame(width: CGFloat(data.weeks.count) * step, height: 13, alignment: .topLeading)
            .padding(.leading, 30)
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(row == 1 ? "Mon" : row == 3 ? "Wed" : row == 5 ? "Fri" : "")
                            .font(.system(size: 9.5)).foregroundStyle(N.text2).frame(width: 26, height: Self.cell, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(Array(data.weeks.enumerated()), id: \.offset) { index, week in
                        VStack(spacing: Self.gap) {
                            // The first week starts mid-week; pad it so weekdays line up.
                            if index == 0, let first = week.first {
                                ForEach(0..<first.weekday, id: \.self) { _ in Color.clear.frame(width: Self.cell, height: Self.cell) }
                            }
                            ForEach(week) { day in cell(day, agentTokens: agentDays[day.date]) }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let hovered { tooltip(hovered, agentTokens: agentDays[hovered.date]).offset(y: -30) }
        }
    }

    private func cell(_ day: GHContributionDay, agentTokens: Int64?) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(GHContributionColor.color(day.level))
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
            .overlay {
                if agentTokens != nil {
                    Circle().fill(GHContributionColor.agent).frame(width: 4, height: 4)
                }
            }
            .overlay {
                if selected?.date == day.date {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(N.text, lineWidth: 1.5)
                }
            }
            .frame(width: Self.cell, height: Self.cell)
            .contentShape(Rectangle())
            .onHover { inside in hovered = inside ? day : (hovered == day ? nil : hovered) }
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) { selected = selected == day ? nil : day }
                if selected != nil, day.count > 0 { store.loadContributionDetail(day.date) }
            }
    }

    private func tooltip(_ day: GHContributionDay, agentTokens: Int64?) -> some View {
        let date = day.day?.formatted(.dateTime.month(.wide).day().year()) ?? day.date
        let text = day.count == 0 ? "No contributions on \(date)" : "\(day.count) contribution\(day.count == 1 ? "" : "s") on \(date)"
        return HStack(spacing: 6) {
            Text(text)
            if let agentTokens { Text("· agents \(AgentFormat.compact(Double(agentTokens)))").foregroundStyle(GHContributionColor.agent) }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 8).frame(height: 24)
        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .allowsHitTesting(false)
    }

    private func monthLabels(_ data: GHContributionYear) -> [(week: Int, name: String)] {
        var labels: [(Int, String)] = []
        var last = -1
        for (index, week) in data.weeks.enumerated() {
            guard let first = week.first?.day else { continue }
            let month = Calendar.current.component(.month, from: first)
            if month != last {
                // Skip a label squeezed against the previous one in the first partial week.
                if let previous = labels.last, index - previous.0 < 3 { labels.removeLast() }
                labels.append((index, first.formatted(.dateTime.month(.abbreviated))))
                last = month
            }
        }
        return labels.map { (week: $0.0, name: $0.1) }
    }

    private func footer(_ data: GHContributionYear) -> some View {
        HStack(spacing: 4) {
            if data.restricted > 0 {
                Text("Includes \(data.restricted.formatted()) private contributions").font(NFont.caption).foregroundStyle(N.text3)
            }
            Spacer()
            Text("Less").font(.system(size: 10.5)).foregroundStyle(N.text2)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2).fill(GHContributionColor.color(level)).frame(width: 10, height: 10)
            }
            Text("More").font(.system(size: 10.5)).foregroundStyle(N.text2)
            if showAgents {
                Circle().fill(GHContributionColor.agent).frame(width: 6, height: 6).padding(.leading, 10)
                Text("Agents worked").font(.system(size: 10.5)).foregroundStyle(N.text2)
            }
        }
    }

    // MARK: Day

    private func dayDetail(_ day: GHContributionDay) -> some View {
        let detail = store.contributionDetails[day.date]
        let sessions = agentSessions(on: day)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(day.day?.formatted(.dateTime.weekday(.wide).month(.wide).day().year()) ?? day.date)
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(N.text)
                Text("\(day.count) contribution\(day.count == 1 ? "" : "s")").font(NFont.small).foregroundStyle(N.text2)
                Spacer()
                Button { selected = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(GhostButtonStyle())
            }
            if day.count > 0, detail == nil, store.isLoading("contribution:" + day.date) {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading the day…").font(NFont.small).foregroundStyle(N.text2) }
            }
            if let detail {
                ForEach(detail.commits, id: \.repo) { c in
                    HStack(spacing: 8) {
                        Image(systemName: "smallcircle.filled.circle").font(.system(size: 10)).foregroundStyle(GH.hex(c.color) ?? N.text3)
                        Text("\(c.count) commit\(c.count == 1 ? "" : "s") to").font(NFont.small).foregroundStyle(N.text2)
                        Button(c.repo) { GitHubNav.open(repo: c.repo, tab: .commits) }.buttonStyle(.plain)
                            .font(NFont.small.weight(.semibold)).foregroundStyle(GH.link)
                    }
                }
                ForEach(detail.items, id: \.url) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.kind == "Issue" ? "smallcircle.filled.circle" : (item.kind == "Reviewed" ? "eye" : "arrow.triangle.pull"))
                            .font(.system(size: 10)).foregroundStyle(GH.open)
                        Text(item.kind).font(NFont.small).foregroundStyle(N.text2)
                        Button("\(item.title)  \(item.repo)#\(item.number)") {
                            if item.kind == "Issue" { GitHubStore.shared.path = [.repo(item.repo, .issues), .issue(item.repo, item.number)]; LiveSurfaces.shared.openMain(.github) }
                            else { GitHubNav.open(pull: item.repo, number: item.number) }
                        }
                        .buttonStyle(.plain).font(NFont.small).foregroundStyle(N.text).lineLimit(1)
                    }
                }
                if detail.restricted > 0 {
                    Text("\(detail.restricted) contribution\(detail.restricted == 1 ? "" : "s") in private repositories").font(NFont.caption).foregroundStyle(N.text3)
                }
            }
            if !sessions.isEmpty {
                let tokens = sessions.reduce(Int64(0)) { $0 + ($1.usage?.processedTokens ?? 0) }
                HStack(spacing: 8) {
                    Circle().fill(GHContributionColor.agent).frame(width: 7, height: 7)
                    Text("\(sessions.count) agent session\(sessions.count == 1 ? "" : "s") · \(AgentFormat.compact(Double(tokens))) tokens")
                        .font(NFont.small).foregroundStyle(N.text2)
                    Text(sessions.prefix(3).map(\.title).joined(separator: ", ")).font(NFont.small).foregroundStyle(N.text3).lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(GH.canvasSubtle, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
        .transition(.opacity)
    }

    private func agentSessions(on day: GHContributionDay) -> [AgentSession] {
        guard let start = day.day else { return [] }
        let end = start.addingTimeInterval(86_400)
        return (agents.snapshot.processes + agents.snapshot.sessions).filter { $0.updatedAt >= start && $0.startedAt < end }
    }

    // MARK: Insights

    private func insights(_ data: GHContributionYear) -> some View {
        let streaks = data.streaks
        let weekdays = data.byWeekday
        let names = Calendar.current.shortWeekdaySymbols
        let busiestWeekday = weekdays.enumerated().max { $0.element < $1.element }?.offset ?? 0
        let commitDays = data.days.filter { $0.count > 0 }.map(\.date)
        let agentDays = self.agentDays
        let overlap = commitDays.filter { agentDays[$0] != nil }.count
        let kinds: [(String, Int, Color)] = [("Commits", data.commits, GH.open), ("Pull requests", data.pulls, GH.merged),
                                              ("Reviews", data.reviews, GH.link), ("Issues", data.issues, GH.attention)]
        let kindTotal = max(kinds.reduce(0) { $0 + $1.1 }, 1)
        return VStack(alignment: .leading, spacing: 16) {
            Rectangle().fill(GH.borderMuted).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                stat("Active days", "\(data.activeDays)", "of \(data.days.count)")
                stat("Current streak", "\(streaks.current)", streaks.current == 1 ? "day" : "days")
                stat("Longest streak", "\(streaks.longest)", streaks.longest == 1 ? "day" : "days")
                stat("Best day", "\(data.busiestDay?.count ?? 0)", data.busiestDay?.day?.formatted(.dateTime.month(.abbreviated).day()) ?? "")
                stat("Busiest weekday", names[busiestWeekday], "\(weekdays[busiestWeekday]) total")
                if !agentDays.isEmpty, !commitDays.isEmpty {
                    stat("With agents", "\(Int(Double(overlap) / Double(commitDays.count) * 100))%", "of days you committed")
                }
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity").font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text2)
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(kinds, id: \.0) { kind in
                                if kind.1 > 0 {
                                    Rectangle().fill(kind.2).frame(width: max(3, geo.size.width * Double(kind.1) / Double(kindTotal) - 2))
                                }
                            }
                        }
                    }
                    .frame(height: 8).clipShape(Capsule())
                    FlowLayout(spacing: 12) {
                        ForEach(kinds, id: \.0) { kind in
                            HStack(spacing: 5) {
                                Circle().fill(kind.2).frame(width: 8, height: 8)
                                Text(kind.0).font(.system(size: 12)).foregroundStyle(N.text)
                                Text("\(kind.1.formatted()) · \(Int((Double(kind.1) / Double(kindTotal) * 100).rounded()))%")
                                    .font(.system(size: 12)).foregroundStyle(N.text2)
                            }
                        }
                    }
                    Text("By weekday").font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text2).padding(.top, 6)
                    HStack(alignment: .bottom, spacing: 6) {
                        let peak = max(weekdays.max() ?? 1, 1)
                        ForEach(0..<7, id: \.self) { i in
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 2).fill(GHContributionColor.color(i == busiestWeekday ? 4 : 2))
                                    .frame(width: 22, height: max(2, 44 * Double(weekdays[i]) / Double(peak)))
                                Text(String(names[i].prefix(2))).font(.system(size: 10)).foregroundStyle(N.text2)
                            }
                            .help("\(names[i]): \(weekdays[i])")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !data.topRepos.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Most commits").font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text2)
                        let top = max(data.topRepos.first?.count ?? 1, 1)
                        ForEach(data.topRepos.prefix(6), id: \.repo) { r in
                            Button { GitHubNav.open(repo: r.repo) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(r.repo).font(.system(size: 12)).foregroundStyle(N.text).lineLimit(1)
                                        Spacer()
                                        Text(r.count.formatted()).font(.system(size: 12)).foregroundStyle(N.text2).monospacedDigit()
                                    }
                                    GeometryReader { geo in
                                        Capsule().fill(GH.hex(r.color) ?? GH.open)
                                            .frame(width: max(3, geo.size.width * Double(r.count) / Double(top)))
                                    }
                                    .frame(height: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 280)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(N.text2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 18, weight: .semibold)).foregroundStyle(N.text).monospacedDigit()
                Text(detail).font(.system(size: 11.5)).foregroundStyle(N.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
