import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverShelf
import LocalObserverRepos

/// The window's front page: what needs you, the day at a glance, the year of agent activity, then one card per
/// pillar with a way into it.
struct HomePage: View {
    @ObservedObject var state: AppState
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var shelf: ShelfStore
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject var repos: RepoStore = .shared
    @State private var width: CGFloat = 1000
    @State private var heatmapMetric: AgentMetricKind = .tokens

    private var wide: Bool { width > 900 }
    private var horizontalPadding: CGFloat { width > 1100 ? 64 : (width > 800 ? 44 : 24) }

    var body: some View {
        // Computed once per render; each is a filter over the stores.
        let sessions = agentStore.runningSessions
            .filter { !($0.process.map { AgentDiscovery.isDesktopApp($0.processName) } ?? false) }
            .sorted { ($0.needsAttention ? 0 : 1, $1.updatedAt) < ($1.needsAttention ? 0 : 1, $0.updatedAt) }
        let waiting = sessions.filter(\.needsAttention)
        let servers = state.visibleServers.filter { $0.projectType != .app }.sorted {
            let fa = state.favorites.contains($0.port), fb = state.favorites.contains($1.port)
            return fa != fb ? fa : $0.port < $1.port
        }
        let windows = limitWindows

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: SidebarItem.home.symbol, title: SidebarItem.home.title, subtitle: AnyView(summary(sessions: sessions, waiting: waiting, servers: servers)))

                DigestCard(agentStore: agentStore, navigate: navigate)

                if !waiting.isEmpty {
                    NeedsYouCard(sessions: waiting, open: open)
                        .padding(.bottom, 20)
                }

                OverviewStrip(sessions: sessions, servers: servers, today: agentStore.todayTotals,
                              tightest: windows.max { $0.usedPercent < $1.usedPercent }, navigate: navigate)
                    .padding(.bottom, 16)

                DashboardActivityCard(store: agentStore, metric: $heatmapMetric) { day, agent in
                    openUsage(day: day, agent: agent)
                }
                .padding(.bottom, 16)

                pair {
                    HomeCard(title: "Agents", symbol: "sparkles", count: sessions.count,
                             link: "All sessions", action: { navigate(.agentActivity) }) {
                        agentsCard(sessions)
                    }
                } and: {
                    HomeCard(title: "Servers", symbol: "server.rack", count: servers.count,
                             link: "All servers", action: { navigate(.all) }) {
                        serversCard(servers)
                    }
                }
                .padding(.bottom, 16)

                pair {
                    HomeCard(title: "Pull requests", symbol: "arrow.triangle.pull", count: repos.pulls.count,
                             link: "All pull requests", action: { navigate(.pullRequests) }) {
                        pullsCard
                    }
                } and: {
                    HomeCard(title: "Unsaved work", symbol: "pencil.and.list.clipboard", count: repos.attentionRepos.count,
                             link: "Repositories", action: { navigate(.repos) }) {
                        unsavedCard
                    }
                }
                .padding(.bottom, 16)

                pair {
                    HomeCard(title: "Usage", symbol: "chart.xyaxis.line", count: nil,
                             link: "Usage", action: { navigate(.agentUsage) }) {
                        if agentStore.hasUsageHistory {
                            GlanceUsageChart(store: agentStore, chartHeight: 120) {
                                agentStore.filter = agentStore.glanceFilter
                                navigate(.agentUsage)
                            }
                        } else {
                            HomeEmpty(symbol: "chart.bar", text: "Usage appears once your agents have run.")
                        }
                    }
                } and: {
                    HomeCard(title: "Plan limits", symbol: "gauge.with.dots.needle.33percent", count: nil,
                             link: "Plan limits", action: { navigate(.agentLimits) }) {
                        limitsCard(windows)
                    }
                }
                .padding(.bottom, 16)

                HomeCard(title: "Shelf", symbol: "tray.full", count: shelf.shelf.count,
                         link: "Open Shelf", action: { navigate(.shelf) }) {
                    ShelfStrip(store: shelf) { navigate(.clipboard) }
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

    /// Two cards side by side when there's room, stacked when there isn't.
    @ViewBuilder private func pair<A: View, B: View>(@ViewBuilder _ a: () -> A, @ViewBuilder and b: () -> B) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 16) {
                a().frame(maxWidth: .infinity)
                b().frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 16) { a(); b() }
        }
    }

    private func summary(sessions: [AgentSession], waiting: [AgentSession], servers: [ServerEntry]) -> some View {
        HStack(spacing: 14) {
            if waiting.isEmpty {
                Label("Nothing needs you", systemImage: "checkmark.circle")
            } else {
                Label("\(waiting.count) need\(waiting.count == 1 ? "s" : "") you", systemImage: "hand.raised.fill")
                    .foregroundStyle(TagColor.orange.fg)
            }
            Label("\(sessions.count) agent\(sessions.count == 1 ? "" : "s") running", systemImage: "sparkles")
            Label("\(servers.count) server\(servers.count == 1 ? "" : "s") listening", systemImage: "dot.radiowaves.left.and.right")
            RelativeTimeText(date: agentStore.lastRefresh)
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .labelStyle(TightLabelStyle())
    }

    /// One window per provider, as the notch and menu bar choose it (Settings › Menu Bar & Notch).
    private var limitWindows: [AgentQuotaWindow] {
        let all = agentStore.limitReports.flatMap(\.windows)
        let agents = AgentKind.allCases.filter { agent in all.contains { $0.agent == agent } }
        return agents.compactMap { prefs.primaryWindow(for: $0, in: all) }
    }

    // MARK: Cards

    @ViewBuilder private func agentsCard(_ sessions: [AgentSession]) -> some View {
        if agentStore.settings.enabledAgents.isEmpty {
            HomeEmpty(symbol: "sparkles", text: "Choose the agents Lookout watches in Settings.")
        } else if sessions.isEmpty {
            HomeEmpty(symbol: "moon.zzz", text: "No agents running.")
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 1) {
                    ForEach(sessions.prefix(5)) { session in
                        HomeSessionRow(session: session, now: context.date) { open(session) }
                    }
                    if sessions.count > 5 { moreLine(sessions.count - 5) { navigate(.agentActivity) } }
                }
            }
        }
    }

    @ViewBuilder private func serversCard(_ servers: [ServerEntry]) -> some View {
        if servers.isEmpty {
            HomeEmpty(symbol: "moon.zzz", text: state.lastScan == nil ? "Looking for local servers…" : "Nothing is listening.") {
                Button("Start a server…") { state.draft = LauncherDraft() }.buttonStyle(SecondaryButtonStyle())
            }
        } else {
            VStack(spacing: 1) {
                ForEach(servers.prefix(5)) { server in
                    HomeServerRow(state: state, server: server)
                }
                if servers.count > 5 { moreLine(servers.count - 5) { navigate(.all) } }
            }
        }
    }

    @ViewBuilder private var pullsCard: some View {
        let pulls = Array((repos.pullsNeedingYou + repos.runningPulls + repos.myPulls)
            .reduce(into: [PullRequest]()) { list, pr in if !list.contains(where: { $0.url == pr.url }) { list.append(pr) } }
            .prefix(5))
        if repos.gitHub.login == nil, pulls.isEmpty {
            switch repos.gitHub {
            case .missingCLI: HomeEmpty(symbol: "terminal", text: "Install the GitHub CLI to see pull requests and checks.")
            case .signedOut: HomeEmpty(symbol: "person.crop.circle.badge.questionmark", text: "Run gh auth login to see your pull requests.")
            case .off: HomeEmpty(symbol: "powersleep", text: "GitHub is off in Settings › Repos.")
            case .error(let message): HomeEmpty(symbol: "exclamationmark.triangle", text: message)
            default: HomeEmpty(symbol: "arrow.triangle.pull", text: "Asking GitHub…")
            }
        } else if pulls.isEmpty {
            HomeEmpty(symbol: "checkmark.circle", text: "No open pull requests, and no one waiting on you.")
        } else {
            VStack(spacing: 1) {
                ForEach(pulls) { HomePullRow(pull: $0) }
            }
        }
    }

    @ViewBuilder private var unsavedCard: some View {
        let list = repos.attentionRepos.sorted { ($0.lastTouched ?? .distantPast) > ($1.lastTouched ?? .distantPast) }
        if repos.lastScan == nil {
            HomeEmpty(symbol: "square.stack.3d.up", text: "Looking for repositories…")
        } else if list.isEmpty {
            HomeEmpty(symbol: "checkmark.circle", text: "Everything is committed and pushed.")
        } else {
            VStack(spacing: 1) {
                ForEach(list.prefix(5)) { repo in
                    HomeRepoRow(repo: repo, forgotten: repo.isForgotten(days: repos.settings.forgottenDays)) {
                        repos.selection = repo.root
                        navigate(.repos)
                    }
                }
                if list.count > 5 { moreLine(list.count - 5) { navigate(.repos) } }
            }
        }
    }

    @ViewBuilder private func limitsCard(_ windows: [AgentQuotaWindow]) -> some View {
        if windows.isEmpty {
            HomeEmpty(symbol: "gauge.with.dots.needle.0percent", text: "Connect a provider to see its 5-hour and weekly limits.") {
                SettingsLink { Text("Connect") }.buttonStyle(SecondaryButtonStyle())
            }
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(spacing: 14) {
                    ForEach(windows) { HomeLimitRow(window: $0, now: context.date) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func moreLine(_ count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(count) more").font(NFont.caption).foregroundStyle(N.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func navigate(_ page: SidebarItem) {
        // The Shelf has no page in the window: it lives in the notch, or the menu bar panel without one.
        if page.isShelfPage {
            if !NotchController.shared.openShelf(page == .clipboard ? .clipboard : .shelf) { LiveSurfaces.shared.toggleMenuBarPanel() }
            return
        }
        withAnimation(.snappy(duration: 0.2)) { state.sidebar = page }
    }

    /// The Usage page narrowed to what the dashboard was showing: one day or the whole year, one agent or all.
    private func openUsage(day: Date?, agent: AgentKind?) {
        var filter = AgentUsageFilter()
        if let day { filter.setCustom(from: day, to: day) } else { filter.setPreset(.oneYear) }
        filter.agents = agent.map { [$0] } ?? []
        filter.metric = heatmapMetric
        filter.grouping = .model
        agentStore.filter = filter
        navigate(.agentUsage)
    }

    private func open(_ session: AgentSession) {
        if !AgentActions.jump(to: session) {
            agentStore.selectedSessionID = session.id
            navigate(.agentActivity)
        }
    }
}

// MARK: - Pieces

/// A bordered card with its title and a link to the page it summarises.
private struct HomeCard<Content: View>: View {
    var title: String
    var symbol: String
    var count: Int?
    var link: String
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hoverLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                if let count { Text("\(count)").font(NFont.small).foregroundStyle(N.text3).monospacedDigit() }
                Spacer(minLength: 8)
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(link)
                        Image(systemName: "arrow.right").font(.system(size: 9.5, weight: .semibold))
                    }
                    .font(NFont.caption)
                    .foregroundStyle(hoverLink ? N.text : N.text2)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(hoverLink ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoverLink = $0 }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(N.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(N.divider))
    }
}

private struct HomeEmpty<Actions: View>: View {
    var symbol: String
    var text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15, weight: .light)).foregroundStyle(N.text3)
            Text(text).font(NFont.small).foregroundStyle(N.text2)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 64)
    }
}

private extension HomeEmpty where Actions == EmptyView {
    init(symbol: String, text: String) {
        self.init(symbol: symbol, text: text) { EmptyView() }
    }
}

/// Sessions waiting on you, first on the page, each with a way straight back to it.
private struct NeedsYouCard: View {
    var sessions: [AgentSession]
    var open: (AgentSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill").font(.system(size: 12))
                Text("Needs you").font(.system(size: 14, weight: .semibold))
                Text("\(sessions.count)").font(NFont.small).monospacedDigit().opacity(0.7)
            }
            .foregroundStyle(TagColor.orange.fg)
            .padding(.bottom, 4)
            ForEach(sessions.prefix(4)) { session in
                HStack(spacing: 10) {
                    AgentIconView(agent: session.agent, size: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title).font(NFont.bodyMedium).foregroundStyle(N.text).lineLimit(1)
                        Text([session.projectName, session.process?.host?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    AgentStateTag(state: session.state)
                    Button(session.process?.host == nil ? "Show" : "Jump") { open(session) }
                        .buttonStyle(SecondaryButtonStyle())
                        .help(session.process?.host.map { "Switch to \($0.name)" } ?? "Show it in Sessions")
                }
                .frame(minHeight: 40)
            }
            if sessions.count > 4 {
                Text("\(sessions.count - 4) more in Sessions").font(NFont.caption).foregroundStyle(N.text2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TagColor.orange.bg.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TagColor.orange.fg.opacity(0.25)))
    }
}

/// Four numbers that answer "how's it going": agents, servers, today's usage, and the tightest limit.
private struct OverviewStrip: View {
    var sessions: [AgentSession]
    var servers: [ServerEntry]
    var today: AgentUsageTotals
    var tightest: AgentQuotaWindow?
    var navigate: (SidebarItem) -> Void

    var body: some View {
        let working = sessions.filter { AgentActivityBucket($0) == .working }.count
        let responding = servers.filter(\.isResponding).count
        HStack(spacing: 0) {
            stat("Agents", symbol: "sparkles", value: "\(sessions.count)", unit: "running",
                 detail: sessions.isEmpty ? "None right now" : "\(working) working") { navigate(.agentActivity) }
            divider
            stat("Servers", symbol: "server.rack", value: "\(servers.count)", unit: "listening",
                 detail: servers.isEmpty ? "None right now" : "\(responding) responding") { navigate(.all) }
            divider
            stat("Today", symbol: "number", value: AgentFormat.compact(Double(today.processed)), unit: "tokens",
                 detail: today.hasCost ? "\(AgentFormat.cost(today.cost, estimated: today.costIsEstimated)) at API prices" : "No cost reported") {
                navigate(.agentUsage)
            }
            divider
            if let tightest {
                stat("Tightest limit", symbol: "gauge.with.dots.needle.67percent", value: "\(Int(tightest.usedPercent.rounded()))%",
                     unit: tightest.agent.shortName, detail: AgentFormat.resetText(tightest.resetsAt),
                     tone: tightest.usedPercent >= 90 ? TagColor.red.fg : tightest.usedPercent >= 70 ? TagColor.orange.fg : N.text) {
                    navigate(.agentLimits)
                }
            } else {
                stat("Plan limits", symbol: "gauge.with.dots.needle.33percent", value: "–", unit: "",
                     detail: "No provider connected") { navigate(.agentLimits) }
            }
        }
        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(N.divider))
    }

    private var divider: some View {
        Rectangle().fill(N.divider).frame(width: 1).padding(.vertical, 14)
    }

    private func stat(_ label: String, symbol: String, value: String, unit: String, detail: String,
                      tone: Color = N.text, action: @escaping () -> Void) -> some View {
        OverviewStat(label: label, symbol: symbol, value: value, unit: unit, detail: detail, tone: tone, action: action)
    }
}

private struct OverviewStat: View {
    var label: String
    var symbol: String
    var value: String
    var unit: String
    var detail: String
    var tone: Color
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Label(label, systemImage: symbol).labelStyle(TightLabelStyle())
                    .font(NFont.caption).foregroundStyle(N.text2)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tone)
                    Text(unit).font(NFont.small).foregroundStyle(N.text2)
                }
                .lineLimit(1)
                Text(detail).font(NFont.caption).foregroundStyle(N.text3).lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? N.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct HomeSessionRow: View {
    var session: AgentSession
    var now: Date
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AgentIconView(agent: session.agent, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(NFont.small.weight(.medium)).foregroundStyle(N.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(session.projectName) · \(AgentFormat.duration(now.timeIntervalSince(session.startedAt)))")
                            .font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
                        if session.isInWorktree, let git = session.checkout { InlineBranch(git: git) }
                    }
                }
                Spacer(minLength: 8)
                HostAppIcon(session: session, size: 15)
                AgentStateTag(state: session.state)
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(session.process?.host.map { "Jump to \($0.name)" } ?? "Show in Sessions")
    }
}

private struct HomeServerRow: View {
    @ObservedObject var state: AppState
    var server: ServerEntry
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            FaviconView(server: server, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.projectName).font(NFont.small.weight(.medium)).foregroundStyle(N.text).lineLimit(1)
                HStack(spacing: 5) {
                    Text(server.uptimeText).font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
                    if let git = server.git { InlineBranch(git: git) }
                }
            }
            Spacer(minLength: 8)
            if state.favorites.contains(server.port) {
                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(TagColor.yellow.fg)
            }
            Text(verbatim: ":\(server.port)").font(NFont.monoSmall).foregroundStyle(N.text)
            StatusTag(server: server, stopping: state.stopping.contains(server.id))
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { state.open(server) }
        .contextMenu { ServerMenu(state: state, server: server) }
        .help("Open \(server.urlString)")
    }
}

private struct HomeLimitRow: View {
    var window: AgentQuotaWindow
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                AgentIconView(agent: window.agent, size: 13)
                Text(window.agent.shortName).font(NFont.small.weight(.medium)).foregroundStyle(N.text)
                Text(window.label).font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
                Spacer(minLength: 8)
                Text(timeText).font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(NFont.small.weight(.semibold)).monospacedDigit().foregroundStyle(N.text)
                    .frame(width: 42, alignment: .trailing)
            }
            LimitMeter(window: window, height: 6)
        }
        .help(LimitPace(window: window, now: now).sentence)
    }

    /// Time left for a short session window, the reset otherwise.
    private var timeText: String {
        if window.kind == .session, let reset = window.resetsAt, reset > now {
            return "\(AgentFormat.duration(reset.timeIntervalSince(now))) left"
        }
        return AgentFormat.resetText(window.resetsAt, now: now)
    }
}

/// Recent shelf items as tiles, with the latest copies beside them. Drop onto it to add.
private struct ShelfStrip: View {
    @ObservedObject var store: ShelfStore
    var openClipboard: () -> Void
    @State private var targeted = false

    var body: some View {
        let items = ShelfStore.arranged(store.shelf)
        HStack(alignment: .top, spacing: 18) {
            if items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 17, weight: .light)).foregroundStyle(N.text3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop files, images, links, or text here").font(NFont.small).foregroundStyle(N.text)
                        Text("They stay until you remove them, ready to drag into any app.").font(NFont.caption).foregroundStyle(N.text2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(targeted ? N.blue : N.divider, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            } else {
                HStack(spacing: 10) {
                    ForEach(items.prefix(6)) { ShelfThumb(item: $0, side: 56) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !store.history.isEmpty {
                Rectangle().fill(N.divider).frame(width: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recently copied").font(NFont.caption).foregroundStyle(N.text2)
                    ForEach(store.history.prefix(3)) { item in
                        HStack(spacing: 7) {
                            ShelfThumb(item: item, side: 16)
                            Text(item.preview.isEmpty ? item.kindTitle : item.preview)
                                .font(NFont.caption).foregroundStyle(N.text).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { store.copy(item) }
                        .help("Click to copy it again")
                    }
                    Button("All clipboard history", action: openClipboard).buttonStyle(.link).font(NFont.caption)
                }
                .frame(width: 240, alignment: .leading)
            }
        }
        .onDrop(of: ShelfDrop.types, isTargeted: $targeted) { store.add(providers: $0) }
    }
}

private struct HomePullRow: View {
    var pull: PullRequest
    @State private var hover = false

    var body: some View {
        Button { ProcessManager.openURL(pull.url) } label: {
            HStack(spacing: 10) {
                CheckGlyph(state: pull.checks, size: 13).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pull.title).font(NFont.small.weight(.medium)).foregroundStyle(N.text).lineLimit(1)
                    Text("\(pull.repoName) #\(pull.number) · \(pull.checks.title)" + (pull.role == .reviewRequested ? " · by \(pull.author)" : ""))
                        .font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                if pull.role == .reviewRequested {
                    Tag(text: "Review", color: .blue, symbol: "eye")
                } else if pull.isReadyToMerge {
                    Tag(text: "Ready", color: .green, symbol: "checkmark")
                } else if pull.review == .changesRequested {
                    Tag(text: "Changes", color: .red)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(pull.url)
    }
}

private struct HomeRepoRow: View {
    var repo: Repo
    var forgotten: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FolderIconView(folder: repo.root, name: repo.name, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(repo.name).font(NFont.small.weight(.medium)).foregroundStyle(N.text).lineLimit(1)
                        if forgotten {
                            Image(systemName: "clock.badge.exclamationmark").font(.system(size: 10)).foregroundStyle(TagColor.orange.fg)
                                .help("Untouched for a while")
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                        Text("\(repo.refLabel) · \(RepoFormat.ago(repo.lastTouched))").lineLimit(1).truncationMode(.middle)
                    }
                    .font(NFont.caption).foregroundStyle(N.text2)
                }
                Spacer(minLength: 8)
                RepoStateChips(changes: repo.changes, unpushed: repo.unpushedCount, behind: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(repo.displayPath)
    }
}
