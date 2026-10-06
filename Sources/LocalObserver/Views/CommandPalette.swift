import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverRepos
import LocalObserverDisk

/// One thing the palette can do: go somewhere or run something.
struct PaletteItem: Identifiable {
    enum Group: String, CaseIterable {
        case actions = "Actions", pages = "Pages", agents = "Agent sessions", pulls = "Pull requests", repos = "Repositories"
        case github = "On GitHub", servers = "Servers", launchers = "Launchers", ci = "CI runs"
    }
    var id: String
    var group: Group
    var title: String
    var subtitle: String = ""
    var symbol: String
    var keywords: String = ""
    var run: () -> Void

    /// Subsequence match with bonuses for word starts and contiguous runs; nil when the query doesn't match at all.
    func score(_ query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let haystack = (title + " " + subtitle + " " + keywords).lowercased()
        let title = self.title.lowercased()
        if title.hasPrefix(query) { return 1000 - title.count }
        if title.contains(query) { return 800 - title.count }
        if haystack.contains(query) { return 500 - haystack.count / 4 }
        var score = 0, run = 0
        var index = haystack.startIndex
        var previous: Character = " "
        for ch in query {
            guard let found = haystack[index...].firstIndex(of: ch) else { return nil }
            run = found == index ? run + 1 : 0
            if found > haystack.startIndex { previous = haystack[haystack.index(before: found)] }
            score += 10 + run * 5 + (previous == " " || previous == "/" || previous == "-" ? 15 : 0)
            index = haystack.index(after: found)
        }
        return score
    }
}

/// ⌘K: search everything Lookout knows about and jump there, or run an action.
struct CommandPalette: View {
    @ObservedObject var state: AppState
    var agentStore: AgentStore
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = items()
        if q.isEmpty {
            // Before typing: actions and the pages, then whatever needs you.
            return all.filter { $0.group == .actions || $0.group == .pages } + all.filter { $0.group == .agents }.prefix(5)
        }
        return all.compactMap { item in item.score(q).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(40)
            .map(\.0)
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(N.text2)
                TextField("Search pages, repositories, pull requests, sessions, servers…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { run(list) }
                Text("esc").font(NFont.caption).foregroundStyle(N.text3)
                    .padding(.horizontal, 6).frame(height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(N.divider))
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Rectangle().fill(N.divider).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if list.isEmpty {
                            Text("Nothing matches “\(query)”").font(NFont.small).foregroundStyle(N.text2).padding(16)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || list[index - 1].group != item.group {
                                Text(item.group.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(N.text3)
                                    .padding(.horizontal, 16).padding(.top, index == 0 ? 8 : 12).padding(.bottom, 4)
                            }
                            row(item, selected: index == selected)
                                .id(index)
                                .onTapGesture { selected = index; run(list) }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: selected) { _, i in proxy.scrollTo(i, anchor: .center) }
            }
        }
        .frame(width: 640, height: 440)
        .background(N.bgRaised)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(list.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { state.paletteOpen = false; return .handled }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).font(.system(size: 13)).foregroundStyle(selected ? .white : N.text2).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(NFont.body).foregroundStyle(selected ? .white : N.text).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(NFont.caption).foregroundStyle(selected ? .white.opacity(0.8) : N.text2).lineLimit(1)
                }
            }
            Spacer()
            if selected { Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8)) }
        }
        .padding(.horizontal, 10)
        .frame(height: item.subtitle.isEmpty ? 34 : 44)
        .background(selected ? N.blue : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func run(_ list: [PaletteItem]) {
        guard list.indices.contains(selected) else { return }
        let item = list[selected]
        state.paletteOpen = false
        // After the sheet is gone, so navigation and new sheets don't fight it.
        DispatchQueue.main.async { item.run() }
    }

    // MARK: Items

    private func go(_ page: SidebarItem) { state.sidebar = page }

    private func items() -> [PaletteItem] {
        var items: [PaletteItem] = []
        let repos = RepoStore.shared, github = GitHubStore.shared, ci = CIStore.shared

        items += [
            PaletteItem(id: "a:new-server", group: .actions, title: "New server…", symbol: "plus", keywords: "launcher start") { state.draft = LauncherDraft() },
            PaletteItem(id: "a:refresh", group: .actions, title: "Refresh everything", symbol: "arrow.clockwise") {
                state.refresh(); agentStore.refresh(); repos.refresh(); repos.refreshGitHub(); ci.refresh()
            },
            PaletteItem(id: "a:scan", group: .actions, title: "Scan disk for cleanup", symbol: "internaldrive", keywords: "space free clean") {
                go(.cleanup); DiskCoordinator.shared.scan()
            },
            PaletteItem(id: "a:fetch", group: .actions, title: "Fetch all repositories", symbol: "arrow.down.circle", keywords: "git") { repos.fetchAll() },
            PaletteItem(id: "a:peek", group: .actions, title: "Toggle Agent Peek", symbol: "eye") { LiveSurfaces.shared.togglePeek() },
            PaletteItem(id: "a:digest", group: .actions, title: "Morning digest", symbol: "sun.max", keywords: "today summary overnight") { go(.home) },
        ]
        items += ApprovalPalette.items(agentStore: agentStore)
        let pages: [SidebarItem] = [.home, .agentActivity, .agentUsage, .agentLimits, .repos, .inbox, .github, .ci, .pullRequests,
                                    .all, .favorites, .launchers, .cleanup]
        items += pages.map { page in
            PaletteItem(id: "p:\(page.title)", group: .pages, title: page.title, symbol: page.symbol) { go(page) }
        }

        let sessions = agentStore.runningSessions + agentStore.recentSessions.prefix(30)
        items += sessions.map { session in
            PaletteItem(id: "s:\(session.id)", group: .agents, title: session.title,
                        subtitle: [session.agent.name, session.projectName, session.process != nil ? session.state.title : RepoFormat.ago(session.updatedAt)]
                            .filter { !$0.isEmpty }.joined(separator: " · "),
                        symbol: session.needsAttention ? "exclamationmark.bubble" : "sparkles",
                        keywords: session.branch + " " + (session.checkout?.refLabel ?? "")) {
                if session.process != nil, AgentActions.jump(to: session) { return }
                agentStore.selectedSessionID = session.id
                go(.agentActivity)
            }
        }
        items += sessions.filter { SessionReplayReader.supports($0.agent) && !$0.sourcePath.isEmpty }.prefix(15).map { session in
            PaletteItem(id: "r:\(session.id)", group: .actions, title: "Replay: \(session.title)", subtitle: session.projectName,
                        symbol: "play.rectangle", keywords: "replay timeline") { state.replaySession = session }
        }

        items += repos.pulls.map { pull in
            PaletteItem(id: "pr:\(pull.url)", group: .pulls, title: pull.title, subtitle: "\(pull.repo) #\(pull.number) · \(pull.checks.title)",
                        symbol: "arrow.triangle.pull", keywords: pull.branch + " #\(pull.number)") {
                GitHubNav.open(pull: pull.repo, number: pull.number)
            }
        }
        items += repos.visibleRepos.map { repo in
            PaletteItem(id: "repo:\(repo.root)", group: .repos, title: repo.name, subtitle: "\(repo.refLabel) · \(repo.displayPath)",
                        symbol: "square.stack.3d.up", keywords: repo.worktrees.map(\.refLabel).joined(separator: " ")) {
                repos.selection = repo.root
                go(.repos)
            }
        }
        items += github.repositories.map { gh in
            PaletteItem(id: "gh:\(gh.slug)", group: .github, title: gh.slug, subtitle: gh.description ?? "",
                        symbol: "chevron.left.forwardslash.chevron.right") { GitHubNav.open(repo: gh.slug) }
        }
        items += state.visibleServers.map { server in
            PaletteItem(id: "srv:\(server.id)", group: .servers, title: server.projectName, subtitle: "\(server.urlString) · \(server.processName)",
                        symbol: "server.rack", keywords: ":\(server.port)") { state.open(server) }
        }
        items += state.managed.map { launcher in
            let running = state.isRunning(launcher)
            return PaletteItem(id: "l:\(launcher.id)", group: .launchers, title: (running ? "Stop " : "Start ") + launcher.name,
                               subtitle: launcher.command, symbol: running ? "stop.circle" : "play.circle") {
                running ? state.stop(launcher) : state.start(launcher)
            }
        }
        items += ci.runs.prefix(20).map { run in
            PaletteItem(id: "ci:\(run.id)", group: .ci, title: "\(run.workflow): \(run.title)", subtitle: "\(run.repoName) · \(run.branch) · \(run.status.title)",
                        symbol: run.status.symbol) {
                ci.selectedRun = run.id
                ci.loadJobs(run)
                go(.ci)
            }
        }
        return items
    }
}
