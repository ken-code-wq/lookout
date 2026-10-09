import SwiftUI
import LocalObserverCore
import LocalObserverRepos
import LocalObserverDisk

/// The top of the dashboard: one prioritized list of what needs you right now, each row with its own action
/// (agents waiting, failing checks, reviews requested, pull requests ready to merge, plan limits and budgets running
/// short, low disk, GitHub notifications addressed to you), and under it a quiet one-line recap of what happened
/// since you last looked. Dismissing the recap hides it until the next morning; the actions are live and stay.
struct DigestCard: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var repos: RepoStore = .shared
    @ObservedObject var ci: CIStore = .shared
    @ObservedObject var github: GitHubStore = .shared
    @ObservedObject var disk: DiskStore = .shared
    /// Sessions waiting on you, as the dashboard lists them.
    var waiting: [AgentSession]
    var navigate: (SidebarItem) -> Void
    var open: (AgentSession) -> Void
    @AppStorage("LocalObserver.digestDismissed") private var dismissed: Double = 0

    /// How many rows of one kind before the rest fold into "N more".
    private static let perKind = 3

    /// Since the last dismissal, or 6pm yesterday when there's been none in a day.
    static func since(dismissed: Date?, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let evening = calendar.date(byAdding: .hour, value: -6, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(-86_400)
        guard let dismissed, now.timeIntervalSince(dismissed) < 86_400 else { return evening }
        return dismissed
    }

    private var since: Date { Self.since(dismissed: dismissed > 0 ? Date(timeIntervalSince1970: dismissed) : nil) }

    /// The recap is hidden after dismissing until the next calendar day.
    var isVisible: Bool {
        dismissed == 0 || !Calendar.current.isDateInToday(Date(timeIntervalSince1970: dismissed))
    }

    /// One recap item: what happened, and the page it goes to.
    struct Line: Identifiable {
        var id: String
        var symbol: String
        var tint: Color
        var text: String
        var detail: String
        var page: SidebarItem
        /// Runs instead of going to `page`, for lines that open a sheet.
        var action: (() -> Void)? = nil
    }

    /// One thing that needs you, with the button that deals with it.
    struct Action: Identifiable {
        enum Icon { case agent(AgentKind), symbol(String, Color) }
        enum Badge { case state(AgentActivityState), tag(String, TagColor, String?) }
        var id: String
        var icon: Icon
        var title: String
        var detail: String
        var badge: Badge?
        var verb: String
        var help: String
        /// The button.
        var perform: () -> Void
        /// Clicking the rest of the row: the page it lives on.
        var reveal: () -> Void
        /// For an "N more" row, how many items it stands for.
        var folded = 0
    }

    // MARK: What needs you

    var actions: [Action] {
        var actions: [Action] = []

        // 1. Agents waiting on you: the only things that are stuck until you act.
        actions += capped(waiting.map { session in
            let host = session.process?.host
            return Action(id: "agent-\(session.id)", icon: .agent(session.agent), title: session.title,
                          detail: [session.agent.shortName, session.projectName, host?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                          badge: .state(session.state), verb: host == nil ? "Show" : "Jump",
                          help: host.map { "Switch to \($0.name)" } ?? "Show it in Sessions",
                          perform: { open(session) },
                          reveal: { agentStore.selectedSessionID = session.id; navigate(.agentActivity) })
        }, kind: "agents", noun: "waiting", page: .agentActivity)

        // 2. Failing checks: your pull requests first, then workflow runs that aren't one of them.
        let failingPulls = repos.failingPulls
        let failingRuns = ci.failedRuns.filter { run in
            !failingPulls.contains { $0.branch == run.branch && run.repo.hasSuffix($0.repoName) }
        }
        let failing: [Action] = failingPulls.map { pull in
            Action(id: "ci-pr-\(pull.url)", icon: .symbol("arrow.triangle.pull", N.text2), title: pull.title,
                   detail: "\(pull.repoName) #\(pull.number) · \(pull.branch)",
                   badge: .tag("Checks failed", .red, "xmark"), verb: "Open", help: "Open the checks on GitHub",
                   perform: { ProcessManager.openURL(pull.url) }, reveal: { navigate(.ci) })
        } + failingRuns.map { run in
            Action(id: "ci-run-\(run.id)", icon: .symbol("bolt.horizontal.circle", N.text2), title: "\(run.workflow) on \(run.branch)",
                   detail: [run.repo, run.title].filter { !$0.isEmpty }.joined(separator: " · "),
                   badge: .tag("Failed", .red, "xmark"), verb: "Open", help: "Open the run on GitHub",
                   perform: { ProcessManager.openURL(run.url) }, reveal: { navigate(.ci) })
        }
        actions += capped(failing, kind: "ci", noun: "failing", page: .ci)

        // 3. Reviews other people are waiting on.
        let reviews = repos.reviewRequests
        actions += capped(reviews.map { pull in
            Action(id: "review-\(pull.url)", icon: .symbol("arrow.triangle.pull", N.text2), title: pull.title,
                   detail: "\(pull.repoName) #\(pull.number) · by \(pull.author)",
                   badge: .tag("Review requested", .blue, "eye"), verb: "Review", help: "Review it on GitHub",
                   perform: { ProcessManager.openURL(pull.url) }, reveal: { navigate(.pullRequests) })
        }, kind: "reviews", noun: "to review", page: .pullRequests)

        // 4. Your pull requests that can go in.
        actions += capped(repos.readyPulls.map { pull in
            Action(id: "ready-\(pull.url)", icon: .symbol("arrow.triangle.pull", N.text2), title: pull.title,
                   detail: "\(pull.repoName) #\(pull.number) · checks passed",
                   badge: .tag("Ready to merge", .green, "checkmark"), verb: "Open", help: "Merge it on GitHub",
                   perform: { ProcessManager.openURL(pull.url) }, reveal: { navigate(.pullRequests) })
        }, kind: "ready", noun: "ready", page: .pullRequests)

        // 5. Plan limits and budgets: which agent to reach for next.
        let advice = LimitRouting.advice(reports: agentStore.limitReports)
        if advice.isActionable {
            actions.append(Action(id: "route", icon: .symbol(advice.symbol, advice.tint), title: advice.headline, detail: advice.detail,
                                  badge: nil, verb: "Limits", help: "See every plan limit",
                                  perform: { navigate(.agentLimits) }, reveal: { navigate(.agentLimits) }))
        }
        for (agent, budget) in agentStore.settings.budgets.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let p = (agentStore.spend[agent] ?? AgentSpend()).progress(budget), p.fraction >= budget.warnAt else { continue }
            actions.append(Action(id: "budget-\(agent.rawValue)", icon: .agent(agent),
                                  title: "\(agent.name) is at \(Int(p.fraction * 100))% of its budget \(p.period)",
                                  detail: "\(AgentFormat.cost(p.spent)) of \(AgentFormat.cost(p.cap))",
                                  badge: .tag(p.fraction >= 1 ? "Over budget" : "Budget", p.fraction >= 1 ? .red : .orange, nil),
                                  verb: "Limits", help: "See budgets and plan limits",
                                  perform: { navigate(.agentLimits) }, reveal: { navigate(.agentLimits) }))
        }

        // 6. A disk that's actually running low.
        if let volume = disk.volume, disk.isLowOnSpace {
            actions.append(Action(id: "disk", icon: .symbol("internaldrive", TagColor.red.fg),
                                  title: "\(DiskFormat.bytes(volume.available)) free, running low",
                                  detail: disk.safeBytes > 0 ? "\(DiskFormat.bytes(disk.safeBytes)) is safe to clear" : "Scan to see what's safe to clear",
                                  badge: .tag("Low disk", .red, nil), verb: "Clean up", help: "Open Cleanup",
                                  perform: { navigate(.cleanup) }, reveal: { navigate(.cleanup) }))
        }

        // 7. GitHub notifications addressed to you, minus the review requests already listed above.
        let reviewTitles = Set(reviews.map(\.title))
        let forYou = github.notifications.filter { $0.unread && $0.isDirect && !($0.reason == "review_requested" && reviewTitles.contains($0.title)) }
        if !forYou.isEmpty {
            actions.append(Action(id: "inbox", icon: .symbol("tray.full", GH.link),
                                  title: "\(forYou.count) GitHub notification\(forYou.count == 1 ? "" : "s") for you",
                                  detail: forYou.prefix(2).map { "\($0.reasonTitle): \($0.title)" }.joined(separator: ", "),
                                  badge: nil, verb: "Inbox", help: "Open the GitHub inbox",
                                  perform: { navigate(.inbox) }, reveal: { navigate(.inbox) }))
        }
        return actions
    }

    /// The first few of a kind, then one row that goes to the page with the rest.
    private func capped(_ items: [Action], kind: String, noun: String, page: SidebarItem) -> [Action] {
        guard items.count > Self.perKind else { return items }
        let rest = items.count - Self.perKind
        return Array(items.prefix(Self.perKind)) + [
            Action(id: "more-\(kind)", icon: .symbol("ellipsis", N.text3), title: "\(rest) more \(noun)", detail: "",
                   badge: nil, verb: "Show all", help: "See them all",
                   perform: { navigate(page) }, reveal: { navigate(page) }, folded: rest)
        ]
    }

    // MARK: Recap

    /// What happened, not what to do: finished sessions, last week on Mondays, disk headroom.
    var recap: [Line] {
        var lines: [Line] = []
        if Calendar.current.component(.weekday, from: Date()) == 2, let week = yourWeek { lines.append(week) }
        let finished = agentStore.snapshot.sessions.filter { $0.updatedAt >= since && $0.process == nil }
        if !finished.isEmpty {
            let cost = finished.compactMap(\.cost).reduce(0, +)
            let tokens = finished.reduce(Int64(0)) { $0 + ($1.usage?.processedTokens ?? 0) }
            lines.append(Line(id: "agents", symbol: "sparkles", tint: TagColor.purple.fg,
                              text: "\(finished.count) session\(finished.count == 1 ? "" : "s") finished",
                              detail: ([finished.prefix(2).map(\.title).joined(separator: ", ")]
                                       + [AgentFormat.compact(Double(tokens)) + " tokens", cost > 0 ? AgentFormat.cost(cost) : nil].compactMap { $0 })
                                .joined(separator: " · "),
                              page: .agentActivity))
        }
        if let volume = disk.volume, !disk.isLowOnSpace, disk.safeBytes > 5_000_000_000 {
            lines.append(Line(id: "disk", symbol: "internaldrive", tint: N.text2,
                              text: "\(DiskFormat.bytes(volume.available)) free",
                              detail: "\(DiskFormat.bytes(disk.safeBytes)) is safe to clear", page: .cleanup))
        }
        return lines
    }

    // MARK: Body

    var body: some View {
        let actions = self.actions
        let recap = isVisible ? self.recap : []
        VStack(alignment: .leading, spacing: 0) {
            header(count: actions.reduce(0) { $0 + ($1.folded > 0 ? $1.folded : 1) })
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, actions.isEmpty ? 14 : 8)
            if !actions.isEmpty {
                VStack(spacing: 1) {
                    ForEach(actions) { ActionRow(action: $0) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            if !recap.isEmpty {
                Rectangle().fill(N.divider).frame(height: 1)
                recapLine(recap)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(N.bgSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(N.bg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(N.divider))
        .padding(.bottom, 16)
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if count == 0 {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(TagColor.green.fg)
                Text("Nothing needs you").font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                Text("No agents waiting, no reviews, no failing checks.").font(NFont.small).foregroundStyle(N.text2).lineLimit(1)
            } else {
                Image(systemName: "hand.raised.fill").font(.system(size: 12)).foregroundStyle(TagColor.orange.fg)
                Text("Needs you").font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                Text("\(count)").font(NFont.small).monospacedDigit().foregroundStyle(N.text3)
            }
            Spacer(minLength: 8)
        }
    }

    private func recapLine(_ lines: [Line]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.greetingSymbol).font(.system(size: 11)).foregroundStyle(TagColor.yellow.fg)
            Text("\(Self.greeting). Since \(since.formatted(date: Calendar.current.isDateInToday(since) ? .omitted : .abbreviated, time: .shortened))")
                .font(NFont.small).foregroundStyle(N.text2)
                .fixedSize()
            ForEach(lines) { line in
                Text("·").font(NFont.small).foregroundStyle(N.text3)
                RecapItem(line: line) { if let action = line.action { action() } else { navigate(line.page) } }
            }
            Spacer(minLength: 8)
            Button("Dismiss") { withAnimation(.snappy(duration: 0.2)) { dismissed = Date().timeIntervalSince1970 } }
                .buttonStyle(GhostButtonStyle(tint: N.text3))
                .font(NFont.caption)
                .help("Hide the recap until tomorrow; the next one starts from now")
        }
        .lineLimit(1)
    }

    static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
    }
    static var greetingSymbol: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "sun.max.fill" : (hour < 18 ? "sun.haze.fill" : "moon.stars.fill")
    }
}

private struct ActionRow: View {
    var action: DigestCard.Action
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch action.icon {
                case .agent(let agent): AgentIconView(agent: agent, size: 16)
                case .symbol(let name, let tint): Image(systemName: name).font(.system(size: 13)).foregroundStyle(tint)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title).font(NFont.small.weight(.medium)).foregroundStyle(N.text).lineLimit(1)
                if !action.detail.isEmpty {
                    Text(action.detail).font(NFont.caption).foregroundStyle(N.text2).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            switch action.badge {
            case .state(let state): AgentStateTag(state: state)
            case .tag(let text, let color, let symbol): Tag(text: text, color: color, symbol: symbol)
            case nil: EmptyView()
            }
            Button(action.verb, action: action.perform)
                .buttonStyle(SecondaryButtonStyle())
                .help(action.help)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action.reveal)
    }
}

private struct RecapItem: View {
    var line: DigestCard.Line
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: line.symbol).font(.system(size: 10.5)).foregroundStyle(line.tint)
                Text(line.text).font(NFont.small).foregroundStyle(hover ? N.text : N.text2)
                    .underline(hover, color: N.text3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(line.detail)
    }
}
