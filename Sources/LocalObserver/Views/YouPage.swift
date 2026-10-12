import SwiftUI
import LocalObserverCore

/// The You page: a personal profile read off Lookout's permanent usage history. `PersonalProfile` does the reading;
/// this view lays it out. Shares are of requests, not tokens, and the labels say so.
struct YouPage: View {
    @ObservedObject var agentStore: AgentStore
    @State private var period: ProfilePeriod = .month
    @State private var loaded: Loaded?
    /// Milestones that arrived before or while this page was open, marked "New" until the page is left.
    @State private var freshMilestones: Set<String> = []
    @State private var showingRule = false
    @State private var sharing = false
    @State private var width: CGFloat = 900
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Loaded {
        var profile: PersonalProfile
        /// All time, for how close the next milestone is.
        var lifetime: PersonalProfile
    }

    private struct LoadKey: Hashable {
        var period: ProfilePeriod
        var revision: Int
    }

    private struct PeriodTab: Identifiable {
        var title: String
        var symbol: String
        var period: ProfilePeriod
        var id: String { title }
    }

    private static let periodTabs = [
        PeriodTab(title: "This week", symbol: "calendar", period: .week),
        PeriodTab(title: "This month", symbol: "calendar", period: .month),
        PeriodTab(title: "This year", symbol: "calendar.badge.clock", period: .year),
        PeriodTab(title: "All time", symbol: "infinity", period: .allTime),
    ]

    private var horizontalPadding: CGFloat { width > 1100 ? 64 : (width > 800 ? 44 : 24) }
    private var contentWidth: CGFloat { width - horizontalPadding * 2 }
    /// Columns side by side where there's room, stacked otherwise.
    private var wide: Bool { contentWidth > 820 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: "person.crop.circle", title: "You", subtitle: AnyView(subtitle))
                controls
                Rectangle().fill(N.divider).frame(height: 1)
                if let loaded {
                    content(loaded)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .task(id: LoadKey(period: period, revision: agentStore.historyRevision)) { await load() }
        .onAppear(perform: latchMilestones)
        .onChange(of: agentStore.historyRevision) { _, _ in latchMilestones() }
        .sheet(isPresented: $sharing) {
            ProfileShareSheet(agentStore: agentStore, period: period)
        }
    }

    // MARK: Loading

    private func load() async {
        let profile = await agentStore.profile(for: period)
        let lifetime = period == .allTime ? profile : await agentStore.profile(for: .allTime)
        guard !Task.isCancelled else { return }
        loaded = Loaded(profile: profile, lifetime: lifetime)
    }

    /// Acknowledging clears the store's "new" list at once, so the page keeps its own copy to mark them with.
    private func latchMilestones() {
        let ids = agentStore.newMilestones.map(\.id)
        guard !ids.isEmpty else { return }
        freshMilestones.formUnion(ids)
        agentStore.acknowledgeMilestones(ids)
    }

    // MARK: Header and period

    private var subtitle: some View {
        HStack(spacing: 14) {
            if let profile = loaded?.profile {
                Text(scope(profile))
            }
            if agentStore.isBackfillingHistory {
                Text("Reading older history…").foregroundStyle(N.text3)
            }
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            ForEach(Self.periodTabs) { tab in
                HeaderTab(title: tab.title, symbol: tab.symbol, active: period == tab.period) { period = tab.period }
            }
            Spacer(minLength: 12)
            Button { sharing = true } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(loaded?.profile.isEmpty ?? true)
            .help("Make a card of this period")
        }
        .padding(.bottom, 6)
    }

    private func scope(_ profile: PersonalProfile) -> String {
        if profile.period == .allTime {
            let since = profile.firsts.memberSince?.formatted(.dateTime.month(.abbreviated).year()) ?? "today"
            return "All time · since \(since)"
        }
        let start = profile.covered.start.formatted(.dateTime.month(.abbreviated).day())
        let end = profile.covered.end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day())
        return "\(periodName(profile.period)) · \(start) – \(end)"
    }

    private func periodName(_ period: ProfilePeriod) -> String {
        switch period {
        case .week: return "This week"
        case .month: return "This month"
        case .year: return "This year"
        case .allTime: return "All time"
        default: return "This period"
        }
    }

    /// What a trend is compared with, in words: "last month".
    private func comparison(_ period: ProfilePeriod) -> String? {
        switch period {
        case .week: return "last week"
        case .month: return "last month"
        case .year: return "last year"
        default: return nil
        }
    }

    // MARK: Content

    @ViewBuilder private func content(_ loaded: Loaded) -> some View {
        let profile = loaded.profile
        hero(profile).padding(.top, 28)
        if !profile.isEmpty {
            figures(profile).padding(.top, 32)
            mix(profile).padding(.top, 36)
            rhythmSection(profile).padding(.top, 36)
            recordsSection(profile).padding(.top, 36)
            if let trends = profile.trends {
                trendSection(trends, period: profile.period).padding(.top, 36)
            }
        }
        milestonesSection(loaded.lifetime).padding(.top, 36)
        footer(profile).padding(.top, 36)
    }

    // MARK: Hero

    @ViewBuilder private func hero(_ profile: PersonalProfile) -> some View {
        let result = profile.archetype
        let warm = result.primary.map { $0.archetype != .gettingStarted } ?? false
        VStack(alignment: .leading, spacing: 0) {
            if let match = result.primary, warm {
                archetypeBlock(match, result: result)
            } else if let match = result.primary {
                newcomerBlock(match, reason: result.insufficientData)
            } else {
                quietBlock(profile, reason: result.insufficientData)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(warm ? TagColor.orange.bg.opacity(0.6) : N.bgSoft,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func archetypeBlock(_ match: ArchetypeMatch, result: ArchetypeResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heroTitle(eyebrow: "Your archetype", name: match.archetype.name, tagline: match.archetype.tagline)
            Text(match.sentence)
                .font(NFont.body).foregroundStyle(N.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            factRows(match.facts).padding(.top, 12)
            if let secondary = result.secondary {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also").font(NFont.caption).foregroundStyle(N.text3)
                    Text(secondary.archetype.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                    Text(secondary.archetype.tagline).font(NFont.small).foregroundStyle(N.text2)
                }
                .padding(.top, 20)
            }
            ruleDisclosure(match.rule, qualified: result.qualified.count).padding(.top, 20)
        }
    }

    /// Too new to read habits, which is a fine place to be: say what it takes, not what's missing.
    private func newcomerBlock(_ match: ArchetypeMatch, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heroTitle(eyebrow: "Your archetype", name: match.archetype.name, tagline: match.archetype.tagline)
            Text(match.sentence)
                .font(NFont.body).foregroundStyle(N.text)
                .padding(.top, 18)
            factRows(match.facts).padding(.top, 12)
            if let reason {
                Text(reason)
                    .font(NFont.small).foregroundStyle(N.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
            }
        }
    }

    /// No habit to read in this stretch: explain it, and point at a longer one when that would help.
    private func quietBlock(_ profile: PersonalProfile, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your archetype").font(NFont.caption).foregroundStyle(N.text2)
            Text(profile.isEmpty ? "Quiet in this period" : "Not enough to read yet")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(N.text)
                .padding(.top, 4)
            if let reason {
                Text(reason)
                    .font(NFont.body).foregroundStyle(N.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            if profile.period != .allTime {
                Button("Show all time") { period = .allTime }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 16)
            }
        }
    }

    private func heroTitle(eyebrow: String, name: String, tagline: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow).font(NFont.caption).foregroundStyle(N.text2)
            Text(name).font(.system(size: 28, weight: .bold)).foregroundStyle(N.text)
            Text(tagline).font(.system(size: 15)).foregroundStyle(N.text2)
        }
    }

    private func factRows(_ facts: [ProfileFact]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(facts.prefix(3)) { fact in
                HStack(spacing: 10) {
                    Text(fact.label).foregroundStyle(N.text2)
                    Spacer(minLength: 12)
                    Text(fact.text).foregroundStyle(N.text).monospacedDigit()
                }
                .font(NFont.small)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func ruleDisclosure(_ rule: String, qualified: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showingRule.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showingRule ? 90 : 0))
                    Text("How we decided")
                }
                .font(NFont.small)
                .foregroundStyle(N.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showingRule {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rule it passed: \(rule).")
                    Text("\(qualified) \(qualified == 1 ? "rule" : "rules") qualified. The strongest leads, and a habit outranks a trait.")
                }
                .font(NFont.caption)
                .foregroundStyle(N.text3)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Figures

    private func figures(_ profile: PersonalProfile) -> some View {
        let t = profile.totals
        let trends = profile.trends
        let streak = profile.records.currentStreak
        let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20, alignment: .topLeading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            YouFigure(label: "Requests", value: t.tally.requests.formatted(), caption: versus(trends?.requests, profile))
            YouFigure(label: "Tokens processed", value: AgentFormat.compact(Double(t.tally.processed)),
                      caption: versus(trends?.tokens, profile))
            YouFigure(label: t.costIsEstimated ? "Estimated cost" : "Cost",
                      value: t.hasCost ? AgentFormat.cost(t.cost) : "–",
                      caption: t.hasCost ? versus(trends?.cost, profile) : "No prices recorded")
            YouFigure(label: "Active time", value: AgentFormat.duration(t.activeSeconds),
                      caption: versus(trends?.activeTime, profile))
            YouFigure(label: "Active days", value: "\(t.activeDays)", caption: "of \(profile.coveredDays) days")
            YouFigure(label: "Current streak", value: "\(streak) \(streak == 1 ? "day" : "days")",
                      caption: profile.records.longestStreak.map { "Best here: \($0.days) days" })
        }
    }

    /// "+25% vs last month", or nil when there's nothing to compare with.
    private func versus(_ change: Double?, _ profile: PersonalProfile) -> String? {
        guard let change, let phrase = comparison(profile.period) else { return nil }
        return "\(signed(change)) vs \(phrase)"
    }

    private func signed(_ change: Double) -> String {
        let percent = Int((change * 100).rounded())
        if percent == 0 { return "0%" }
        return percent > 0 ? "+\(percent)%" : "−\(abs(percent))%"
    }

    // MARK: Mix

    private func mix(_ profile: PersonalProfile) -> some View {
        let effort = profile.effort
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 40)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Your mix") {
                Text("Share of requests").font(NFont.caption).foregroundStyle(N.text3)
            }
            layout {
                MixColumn(title: "Agents", rows: profile.providers, empty: "No agent activity in this period.")
                MixColumn(title: "Models", rows: profile.models, empty: "No models recorded in this period.")
                MixColumn(title: "Effort", rows: effort.levels,
                          empty: "Effort isn't recorded for these requests.",
                          note: effortNote(effort),
                          label: { effortName($0.title) })
            }
        }
    }

    private func effortNote(_ effort: ProfileEffort) -> String? {
        guard effort.knownRequests > 0 else { return nil }
        var text = "Effort known for \(pct(effort.coverage)) of requests; shares are of those."
        if let high = effort.highShare {
            text += " \(pct(high)) at high or above."
        }
        return text
    }

    private func effortName(_ level: String) -> String {
        if level == "xhigh" { return "Extra high" }
        return level.prefix(1).uppercased() + level.dropFirst()
    }

    // MARK: Rhythm

    private func rhythmSection(_ profile: PersonalProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Rhythm") {
                Text("Requests by weekday and hour").font(NFont.caption).foregroundStyle(N.text3)
            }
            RhythmGrid(rhythm: profile.rhythm, width: contentWidth)
            HStack(alignment: .bottom, spacing: 16) {
                rhythmCallouts(profile.rhythm)
                Spacer(minLength: 12)
                UsageHeatmapLegend(tint: N.blue, cell: 10)
            }
            .padding(.top, 16)
        }
    }

    private func rhythmCallouts(_ rhythm: ProfileRhythm) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rhythmLines(rhythm)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(line.label).font(NFont.small).foregroundStyle(N.text2)
                        .frame(width: 92, alignment: .leading)
                    Text(line.text).font(NFont.small).foregroundStyle(N.text)
                }
            }
        }
    }

    /// The plain-language reading of the grid. Night owl or early bird only when one of them is real.
    private func rhythmLines(_ rhythm: ProfileRhythm) -> [RhythmLine] {
        var lines: [RhythmLine] = []
        let total = max(rhythm.total, 1)
        if let weekday = rhythm.busiestWeekday {
            let requests = rhythm.requests[weekday - 1].reduce(0, +)
            lines.append(RhythmLine(id: "day", label: "Busiest day",
                                    text: "\(Calendar.current.weekdaySymbols[weekday - 1]), \(pct(Double(requests) / Double(total))) of requests"))
        }
        if let hour = rhythm.peakHour {
            lines.append(RhythmLine(id: "hour", label: "Peak hour", text: clockText(hour)))
        }
        if rhythm.nightShare >= rhythm.earlyShare, rhythm.nightShare >= 0.1 {
            lines.append(RhythmLine(id: "owl", label: "Night owl",
                                    text: "\(pct(rhythm.nightShare)) of requests between 10 PM and 4 AM"))
        } else if rhythm.earlyShare >= 0.1 {
            lines.append(RhythmLine(id: "bird", label: "Early bird",
                                    text: "\(pct(rhythm.earlyShare)) of requests between 5 and 9 AM"))
        } else {
            lines.append(RhythmLine(id: "daytime", label: "Daytime",
                                    text: "\(pct(rhythm.nightShare)) at night, \(pct(rhythm.earlyShare)) early in the morning"))
        }
        if rhythm.weekendShare > 0 {
            lines.append(RhythmLine(id: "weekend", label: "Weekends", text: "\(pct(rhythm.weekendShare)) of requests"))
        }
        return lines
    }

    // MARK: Records

    private func recordsSection(_ profile: PersonalProfile) -> some View {
        let items = recordLines(profile.records)
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Records")
            if items.isEmpty {
                Text("Records appear once there's activity to compare.")
                    .font(NFont.small).foregroundStyle(N.text3)
            }
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.label)
                        .font(NFont.small).foregroundStyle(N.text2)
                        .frame(width: 150, alignment: .leading)
                    Text(item.value)
                        .font(NFont.bodyMedium).foregroundStyle(N.text)
                        .monospacedDigit()
                    Spacer(minLength: 12)
                    Text(item.caption)
                        .font(NFont.small).foregroundStyle(N.text3)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { Rectangle().fill(N.divider).frame(height: 1) }
            }
        }
    }

    private func recordLines(_ records: ProfileRecords) -> [RecordLine] {
        var items: [RecordLine] = []
        if let day = records.biggestDayByTokens {
            var caption = day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            if day.tally.hasCost {
                caption += " · " + AgentFormat.cost(day.tally.cost, estimated: day.tally.costIsEstimated)
            }
            items.append(RecordLine(id: "day", label: "Biggest day",
                                    value: "\(AgentFormat.compact(Double(day.tally.processed))) tokens", caption: caption))
        }
        if let session = records.longestSession {
            let project = session.project.isEmpty ? "Unknown workspace" : session.project
            items.append(RecordLine(id: "session", label: "Longest session", value: AgentFormat.duration(session.activeSeconds),
                                    caption: "\(session.agent.name) · \(project) · \(session.start.formatted(.dateTime.month(.abbreviated).day()))"))
        }
        if let peak = records.peakConcurrent, peak.sessions > 1 {
            items.append(RecordLine(id: "concurrent", label: "Most agents at once", value: "\(peak.sessions)",
                                    caption: peak.at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())))
        }
        if let streak = records.longestStreak {
            items.append(RecordLine(id: "streak", label: "Longest streak", value: "\(streak.days) days",
                                    caption: "\(streak.start.formatted(.dateTime.month(.abbreviated).day())) – \(streak.end.formatted(.dateTime.month(.abbreviated).day()))"))
        }
        return items
    }

    // MARK: Trends

    private func trendSection(_ trends: ProfileTrends, period: ProfilePeriod) -> some View {
        let then = trends.previousTotals
        let lines = [
            TrendLine(id: "requests", label: "Requests", change: trends.requests, was: then.tally.requests.formatted()),
            TrendLine(id: "tokens", label: "Tokens processed", change: trends.tokens, was: AgentFormat.compact(Double(then.tally.processed))),
            TrendLine(id: "cost", label: "Cost", change: trends.cost, was: AgentFormat.cost(then.tally.cost)),
            TrendLine(id: "time", label: "Active time", change: trends.activeTime, was: AgentFormat.duration(then.activeSeconds)),
            TrendLine(id: "days", label: "Active days", change: trends.activeDays, was: "\(then.activeDays)"),
        ].filter { $0.change != nil }
        let shifts = [
            trends.topProvider.map { ShiftLine(id: "agent", noun: "agent", shift: $0) },
            trends.topModel.map { ShiftLine(id: "model", noun: "model", shift: $0) },
            trends.topProject.map { ShiftLine(id: "project", noun: "project", shift: $0) },
        ].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Against \(comparison(period) ?? "the period before")") {
                Text("Same stretch so far").font(NFont.caption).foregroundStyle(N.text3)
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(line.label)
                        .font(NFont.small).foregroundStyle(N.text2)
                        .frame(width: 150, alignment: .leading)
                    Text(signed(line.change ?? 0))
                        .font(NFont.bodyMedium).foregroundStyle(N.text)
                        .monospacedDigit()
                    Spacer(minLength: 12)
                    Text("was \(line.was)")
                        .font(NFont.small).foregroundStyle(N.text3)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { Rectangle().fill(N.divider).frame(height: 1) }
            }
            ForEach(shifts) { entry in
                Text("Top \(entry.noun) changed: \(entry.shift.from) → \(entry.shift.to)")
                    .font(NFont.small).foregroundStyle(N.text2)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: Milestones

    private func milestonesSection(_ lifetime: PersonalProfile) -> some View {
        let earned = Array(agentStore.history.earnedMilestones.reversed()).compactMap { entry in
            entry.milestone.map { EarnedLine(entry: entry, milestone: $0) }
        }
        let next = nextMilestone(lifetime)
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Milestones", count: earned.isEmpty ? nil : earned.count)
            if let next {
                NextMilestoneRow(milestone: next.milestone, progress: next.progress)
            }
            if earned.isEmpty && next == nil {
                Text("Milestones arrive as your history grows.")
                    .font(NFont.small).foregroundStyle(N.text3)
            }
            ForEach(earned) { line in
                // Milestones found in history are listed, not celebrated: only ones reached just now get the mark.
                MilestoneRow(line: line, fresh: freshMilestones.contains(line.id) && !line.entry.isRetroactive)
            }
        }
    }

    /// The unearned milestone closest to done, with how far along it is. Counters only; first-agent milestones have
    /// no progress to show.
    private func nextMilestone(_ lifetime: PersonalProfile) -> (milestone: Milestone, progress: Double)? {
        let recorded = agentStore.history.milestones
        let now = Date.now
        let calendar = Calendar.current
        let candidates: [(index: Int, milestone: Milestone, progress: Double)] = Milestone.catalog.enumerated().compactMap { index, milestone in
            guard recorded[milestone.id] == nil,
                  let share = progressToward(milestone, lifetime, now: now, calendar: calendar),
                  share < 1 else { return nil }
            return (index, milestone, share)
        }
        guard let best = candidates.max(by: { ($0.progress, -$0.index) < ($1.progress, -$1.index) }) else { return nil }
        return (best.milestone, best.progress)
    }

    private func progressToward(_ milestone: Milestone, _ lifetime: PersonalProfile, now: Date, calendar: Calendar) -> Double? {
        let threshold = Double(milestone.threshold)
        switch milestone.kind {
        case .tokens: return Double(lifetime.totals.tally.processed) / threshold
        case .sessions: return Double(lifetime.totals.sessions) / threshold
        case .streak: return Double(lifetime.records.longestStreak?.days ?? 0) / threshold
        case .anniversary:
            guard let first = lifetime.firsts.memberSince,
                  let target = calendar.date(byAdding: .month, value: Int(milestone.threshold), to: first),
                  target > first else { return nil }
            return now.timeIntervalSince(first) / target.timeIntervalSince(first)
        case .firstAgent: return nil
        }
    }

    // MARK: Footer

    private func footer(_ profile: PersonalProfile) -> some View {
        let newThisPeriod = profile.firsts.newProviders.map(\.name) + profile.firsts.newModels
        return VStack(alignment: .leading, spacing: 8) {
            if let since = profile.firsts.memberSince {
                Text("Member since \(since.formatted(.dateTime.month(.wide).day().year()))")
                    .font(NFont.body).foregroundStyle(N.text2)
            } else {
                Text("No agent activity recorded yet.")
                    .font(NFont.body).foregroundStyle(N.text2)
            }
            if !newThisPeriod.isEmpty {
                Text("First time this period: \(newThisPeriod.joined(separator: ", "))")
                    .font(NFont.small).foregroundStyle(N.text2)
            }
            Text("Lookout has kept this history since \(profile.firsts.recordingSince.formatted(.dateTime.month(.abbreviated).day().year())). Older days come from logs your agents still have on disk.")
                .font(NFont.caption).foregroundStyle(N.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Pieces

private struct YouFigure: View {
    var label: String
    var value: String
    var caption: String?

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
        .accessibilityElement(children: .combine)
    }
}

private struct MixColumn: View {
    var title: String
    var rows: [ProfileShare]
    var empty: String
    var note: String?
    var label: (ProfileShare) -> String = { $0.title }
    private static let shown = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(NFont.bodyMedium).foregroundStyle(N.text)
            if rows.isEmpty {
                Text(empty).font(NFont.small).foregroundStyle(N.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(rows.prefix(Self.shown)) { row in
                    MixRow(share: row, label: label(row))
                }
                if rows.count > Self.shown {
                    Text("+\(rows.count - Self.shown) more").font(NFont.caption).foregroundStyle(N.text3)
                }
            }
            if let note {
                Text(note).font(NFont.caption).foregroundStyle(N.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MixRow: View {
    var share: ProfileShare
    var label: String

    var body: some View {
        HStack(spacing: 8) {
            if let agent = share.agent { AgentIconView(agent: agent, size: 14) }
            Text(label)
                .font(NFont.small).foregroundStyle(N.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            ZStack(alignment: .leading) {
                Capsule().fill(N.divider)
                Capsule().fill(share.agent?.tag.fg ?? N.text2)
                    .frame(width: max(2, 72 * min(share.share, 1)))
            }
            .frame(width: 72, height: 5)
            Text(AgentFormat.percent(share.share, digits: 0))
                .font(NFont.small).monospacedDigit().foregroundStyle(N.text2)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: 26)
        .help("\(share.tally.requests.formatted()) requests · \(AgentFormat.compact(Double(share.tally.processed))) tokens")
        .accessibilityElement(children: .combine)
    }
}

/// Requests by weekday (rows) and hour (columns), shaded in quartiles like the Usage heatmap.
private struct RhythmGrid: View {
    var rhythm: ProfileRhythm
    var width: CGFloat

    private static let gap: CGFloat = 3
    private static let labelWidth: CGFloat = 30
    private static let levels: [Double] = [0, 0.25, 0.45, 0.68, 0.92]

    var body: some View {
        let calendar = Calendar.current
        let rows = rhythm.rows(firstWeekday: calendar.firstWeekday)
        let shade = Self.shade(rhythm.requests.flatMap { $0 })
        let cell = min(22, max(8, (width - Self.labelWidth - Self.gap * 23) / 24))
        let radius = max(2, cell / 5)
        VStack(alignment: .leading, spacing: Self.gap + 3) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12)
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(hourText(hour))
                        .font(.system(size: 9.5))
                        .foregroundStyle(N.text3)
                        .fixedSize()
                        .offset(x: Self.labelWidth + CGFloat(hour) * (cell + Self.gap))
                }
            }
            ForEach(0..<7, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: Self.gap) {
                    Text(calendar.shortWeekdaySymbols[row.weekday - 1])
                        .font(.system(size: 9.5))
                        .foregroundStyle(N.text3)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let count = row.hours[hour]
                        let level = shade(count)
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(level == 0 ? N.bgSoft : N.blue.opacity(Self.levels[level]))
                            .frame(width: cell, height: cell)
                            .help("\(calendar.weekdaySymbols[row.weekday - 1]) \(hourText(hour)) · \(count.formatted()) requests")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Requests by weekday and hour")
        .accessibilityValue("\(rhythm.total.formatted()) requests in total")
    }

    /// Quartiles over the non-empty hours: 0 for none, 1 for the quietest quarter up to 4 for the busiest.
    private static func shade(_ values: [Int]) -> (Int) -> Int {
        let positives = values.filter { $0 > 0 }.sorted()
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
}

private struct NextMilestoneRow: View {
    var milestone: Milestone
    var progress: Double

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 14))
                .foregroundStyle(N.text3)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next: \(milestone.title)").font(NFont.bodyMedium).foregroundStyle(N.text)
                Text(milestone.detail).font(NFont.small).foregroundStyle(N.text2)
            }
            Spacer(minLength: 12)
            ZStack(alignment: .leading) {
                Capsule().fill(N.divider)
                Capsule().fill(N.text2).frame(width: max(2, 96 * min(max(progress, 0), 1)))
            }
            .frame(width: 96, height: 5)
            // Rounded down: 99.7% of a year is not yet a year.
            Text("\(min(Int(progress * 100), 99))%")
                .font(NFont.small).monospacedDigit().foregroundStyle(N.text2)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(N.divider).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

private struct MilestoneRow: View {
    var line: EarnedLine
    var fresh: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let agent = line.milestone.agent {
                    AgentIconView(agent: agent, size: 16)
                } else {
                    Image(systemName: line.milestone.kind.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(N.text2)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.milestone.title).font(NFont.bodyMedium).foregroundStyle(N.text)
                Text(line.milestone.detail).font(NFont.small).foregroundStyle(N.text2)
            }
            Spacer(minLength: 12)
            if fresh {
                Text("New")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(N.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(N.selected, in: Capsule())
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(line.entry.earnedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
                if line.entry.isRetroactive {
                    Text("Found in your history").font(NFont.caption).foregroundStyle(N.text3)
                }
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(N.divider).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

private struct RecordLine: Identifiable {
    var id: String
    var label: String
    var value: String
    var caption: String
}

private struct TrendLine: Identifiable {
    var id: String
    var label: String
    var change: Double?
    var was: String
}

private struct RhythmLine: Identifiable {
    var id: String
    var label: String
    var text: String
}

private struct ShiftLine: Identifiable {
    var id: String
    var noun: String
    var shift: ProfileShift
}

private struct EarnedLine: Identifiable {
    var entry: EarnedMilestone
    var milestone: Milestone
    var id: String { entry.id }
}

// MARK: - Formatting

/// "41%" for a fraction, locale-free like the archetype sentences.
private func pct(_ fraction: Double) -> String { AgentFormat.percent(fraction, digits: 0) }

/// "3 PM" for an hour of the day, in the clock the user has set.
private func hourText(_ hour: Int) -> String {
    Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?.formatted(.dateTime.hour()) ?? "\(hour):00"
}

/// "3:00 PM", or "15:00" on a 24-hour clock.
private func clockText(_ hour: Int) -> String {
    Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
}

private extension Milestone.Kind {
    var symbol: String {
        switch self {
        case .tokens: return "number"
        case .sessions: return "bubble.left"
        case .streak: return "calendar"
        case .anniversary: return "clock.arrow.circlepath"
        case .firstAgent: return "sparkle"
        }
    }
}
