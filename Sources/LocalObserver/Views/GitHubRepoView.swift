import SwiftUI
import LocalObserverRepos

/// One repository, GitHub-style: header, tab strip, then Code / Pull requests / Branches / Commits.
struct GHRepoView: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore
    var slug: String
    var tab: GHRepoTab

    private var repo: GHRepository? { store.repository(slug) }
    private var detail: GHRepoDetail? { store.details[slug] }
    private var local: Repo? { repos.localRepo(slug: slug) }

    var body: some View {
        GHScaffold(store: store) { width in
            VStack(alignment: .leading, spacing: 0) {
                header
                GHTabBar(tabs: GHRepoTab.allCases, selection: tab, title: \.rawValue, symbol: \.symbol, count: count) { t in
                    store.open(.repo(slug, t))
                }
                .padding(.top, 10)
                .padding(.bottom, 20)
                content(width: width)
            }
        }
        .task(id: "\(slug)|\(tab.rawValue)") { load() }
    }

    private func load() {
        store.loadDetail(slug)
        switch tab {
        case .code: store.loadBranches(slug)
        case .issues: store.loadIssues(slug, open: true); store.loadIssues(slug, open: false)
        case .pulls: store.loadPulls(slug, open: true); store.loadPulls(slug, open: false)
        case .branches: store.loadBranches(slug)
        case .commits: store.loadBranches(slug)
        }
    }

    private func count(_ tab: GHRepoTab) -> Int? {
        switch tab {
        case .issues: return store.openIssues[slug]?.count ?? repo?.openIssues
        case .pulls: return store.openPulls[slug]?.count ?? repo?.openPulls
        case .branches: return store.branches[slug]?.count
        default: return nil
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "book.closed").font(.system(size: 16)).foregroundStyle(N.text2)
            Text(slug.split(separator: "/").last.map(String.init) ?? slug)
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(N.text)
                .textSelection(.enabled)
            if let repo { GHVisibilityBadge(text: repo.visibilityLabel) }
            Spacer(minLength: 12)
            if let local {
                Button { RepoActions.openEditor(local.root) } label: {
                    Label("Open in editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(local.displayPath)
            }
            if let repo, repo.stars > 0 || repo.forks > 0 {
                HStack(spacing: 0) {
                    stat("star", repo.stars, "Stars")
                    Rectangle().fill(GH.border).frame(width: 1, height: 28)
                    stat("tuningfork", repo.forks, "Forks")
                }
                .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
            }
            Button { ProcessManager.openURL("https://github.com/\(slug)/\(urlSuffix)") } label: {
                Label("Open on GitHub", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var urlSuffix: String {
        switch tab {
        case .code: return ""
        case .issues: return "issues"
        case .pulls: return "pulls"
        case .branches: return "branches"
        case .commits: return "commits"
        }
    }

    private func stat(_ symbol: String, _ value: Int, _ help: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(GHFormat.count(value)).monospacedDigit()
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(N.text)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .help(help)
    }

    @ViewBuilder private func content(width: CGFloat) -> some View {
        if let error = store.error(GitHubStore.repoKey(slug)), detail == nil {
            GHErrorBox(message: error) { store.loadDetail(slug, force: true) }
        }
        switch tab {
        case .code: GHCodeTab(store: store, repos: repos, slug: slug, width: width)
        case .issues: GHIssuesTab(store: store, slug: slug)
        case .pulls: GHPullsTab(store: store, slug: slug)
        case .branches: GHBranchesTab(store: store, repos: repos, slug: slug)
        case .commits: GHCommitsTab(store: store, slug: slug)
        }
    }
}

// MARK: - Code

struct GHCodeTab: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore
    var slug: String
    var width: CGFloat

    private var detail: GHRepoDetail? { store.details[slug] }
    private var repo: GHRepository? { store.repository(slug) }
    private var local: Repo? { repos.localRepo(slug: slug) }

    var body: some View {
        if width > 860 {
            HStack(alignment: .top, spacing: 24) {
                main.frame(maxWidth: .infinity)
                sidebar.frame(width: 280)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                main
                sidebar
            }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            if let detail {
                commitsBox(detail)
                readme(detail)
            } else if store.isLoading(GitHubStore.repoKey(slug)) {
                GHLoading()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { store.open(.repo(slug, .branches)) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                    Text(store.defaultBranch(slug)).font(.system(size: 12.5, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(N.text2)
                }
                .foregroundStyle(N.text)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(GH.canvasSubtle, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Default branch. Click to see every branch.")
            Button { store.open(.repo(slug, .branches)) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                    Text("\(store.branches[slug]?.count ?? local?.branchCount ?? 0)").fontWeight(.semibold)
                    Text("Branches").foregroundStyle(N.text2)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(N.text)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            Spacer()
            Menu {
                Section("Clone") {
                    Button("Copy HTTPS URL") { RepoActions.copy("https://github.com/\(slug).git") }
                    Button("Copy SSH URL") { RepoActions.copy("git@github.com:\(slug).git") }
                    Button("Copy GitHub CLI Command") { RepoActions.copy("gh repo clone \(slug)") }
                }
                if let local {
                    Section("On this Mac") {
                        Button("Open in Editor") { RepoActions.openEditor(local.root) }
                        Button("Open in Terminal") { RepoActions.openTerminal(local.root) }
                        Button("Reveal in Finder") { RepoActions.reveal(local.root) }
                    }
                }
                Divider()
                Button("Download ZIP") { ProcessManager.openURL("https://github.com/\(slug)/archive/refs/heads/\(store.defaultBranch(slug)).zip") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 11, weight: .bold))
                    Text("Code").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(GH.openButton, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
            }
            .menuStyle(.button)
        .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func commitsBox(_ detail: GHRepoDetail) -> some View {
        GHBox {
            if let last = detail.commits.first {
                HStack(spacing: 8) {
                    GHAvatar(login: last.author, size: 22)
                    Text(last.author).font(.system(size: 13, weight: .semibold)).foregroundStyle(N.text)
                    Text(last.headline).font(.system(size: 13)).foregroundStyle(N.text2).lineLimit(1)
                    if last.checks != .none { CheckGlyph(state: last.checks, size: 11) }
                    Spacer(minLength: 8)
                    Text(last.short).font(NFont.monoSmall).foregroundStyle(N.text2)
                    Text("·").foregroundStyle(N.text3)
                    Text(RepoFormat.ago(last.date)).font(NFont.small).foregroundStyle(N.text2)
                    Button { store.open(.repo(slug, .commits)) } label: {
                        Label("Commits", systemImage: "clock.arrow.circlepath").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(N.text)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
            } else {
                Text("No commits yet").font(NFont.small).foregroundStyle(N.text2).padding(14)
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(detail.commits.dropFirst().enumerated()), id: \.element.id) { index, commit in
                    if index > 0 { Rectangle().fill(GH.borderMuted).frame(height: 1) }
                    GHCommitRow(slug: slug, commit: commit, compact: true)
                }
                if detail.commits.count <= 1 {
                    Text("Recent commits appear here.").font(NFont.small).foregroundStyle(N.text3).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private func readme(_ detail: GHRepoDetail) -> some View {
        if let html = detail.readmeHTML, !html.isEmpty {
            GHBox {
                HStack(spacing: 6) {
                    Image(systemName: "book").font(.system(size: 12))
                    Text("README").font(.system(size: 13, weight: .semibold))
                    if let license = detail.license {
                        Image(systemName: "scalemass").font(.system(size: 11)).padding(.leading, 10)
                        Text("\(license) license").font(.system(size: 13))
                    }
                }
                .foregroundStyle(N.text)
                .padding(.horizontal, 14)
                .frame(height: 42)
            } content: {
                GHHTMLView(html: html)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
            }
        } else {
            GHBox {
                VStack(spacing: 6) {
                    Image(systemName: "book").font(.system(size: 22, weight: .light)).foregroundStyle(N.text3)
                    Text("Add a README").font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                    Text("Help people interested in this repository understand your project.")
                        .font(NFont.small).foregroundStyle(N.text2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About").font(.system(size: 15, weight: .semibold)).foregroundStyle(N.text).padding(.bottom, 12)
            let description = detail?.description ?? repo?.description
            Text(description?.isEmpty == false ? description! : "No description, website, or topics provided.")
                .font(.system(size: 13.5))
                .foregroundStyle(description?.isEmpty == false ? N.text : N.text2)
                .italic(description?.isEmpty != false)
                .fixedSize(horizontal: false, vertical: true)
            if let homepage = detail?.homepage ?? repo?.homepage {
                Button { ProcessManager.openURL(homepage) } label: {
                    Label(homepage.replacingOccurrences(of: "https://", with: ""), systemImage: "link")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(GH.link).lineLimit(1)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
            if let topics = detail?.topics, !topics.isEmpty {
                FlowLayout(spacing: 6) { ForEach(topics, id: \.self) { GHTopic(name: $0) } }
                    .padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 9) {
                if let license = detail?.license { aboutRow("scalemass", "\(license) license") }
                aboutRow("star", "\(GHFormat.count(repo?.stars ?? 0)) stars")
                aboutRow("eye", "\(GHFormat.count(detail?.watchers ?? 0)) watching")
                aboutRow("tuningfork", "\(GHFormat.count(repo?.forks ?? 0)) forks")
                if let repo, repo.openIssues > 0 { aboutRow("smallcircle.filled.circle", "\(repo.openIssues) open issues") }
            }
            .padding(.top, 16)

            if let languages = detail?.languages, !languages.isEmpty, let total = detail?.languageTotal, total > 0 {
                divider
                Text("Languages").font(.system(size: 15, weight: .semibold)).foregroundStyle(N.text).padding(.bottom, 10)
                GHLanguageBar(languages: languages, total: total)
            }

            if let local {
                divider
                GHLocalPanel(repos: repos, local: local)
            }
        }
    }

    private var divider: some View { Rectangle().fill(GH.borderMuted).frame(height: 1).padding(.vertical, 20) }

    private func aboutRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
            Text(text).font(.system(size: 13))
        }
        .foregroundStyle(N.text2)
    }
}

/// GitHub's language bar and its legend with percentages.
struct GHLanguageBar: View {
    var languages: [GHLanguage]
    var total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(languages, id: \.name) { language in
                        Rectangle()
                            .fill(GH.hex(language.color) ?? N.text3)
                            .frame(width: max(2, geo.size.width * Double(language.size) / Double(total) - 2))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            FlowLayout(spacing: 12, lineSpacing: 6) {
                ForEach(languages, id: \.name) { language in
                    HStack(spacing: 5) {
                        Circle().fill(GH.hex(language.color) ?? N.text3).frame(width: 9, height: 9)
                        Text(language.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text)
                        Text(String(format: "%.1f%%", Double(language.size) / Double(total) * 100))
                            .font(.system(size: 12)).foregroundStyle(N.text2)
                    }
                }
            }
        }
    }
}

/// The clone on this Mac: where it is, what's checked out, every worktree's branch, and unsaved work.
struct GHLocalPanel: View {
    @ObservedObject var repos: RepoStore
    var local: Repo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer").font(.system(size: 12))
                Text("On this Mac").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(N.text)
            Text(local.displayPath).font(NFont.monoSmall).foregroundStyle(N.text2).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                GHBranchName(name: local.refLabel, maxWidth: 200)
                RepoStateChips(changes: local.changes, unpushed: local.unpushedCount, behind: local.status.behind, stashes: local.stashes)
            }
            if !local.worktrees.isEmpty {
                Text("Worktrees").font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text2).padding(.top, 4)
                ForEach(local.worktrees) { wt in
                    HStack(spacing: 6) {
                        GHBranchName(name: wt.refLabel, worktree: true, maxWidth: 170)
                        if let owner = wt.owner { Text(owner).font(NFont.caption).foregroundStyle(N.text3) }
                        Spacer(minLength: 4)
                        if let changes = wt.changes, !changes.isClean {
                            Text("\(changes.total)").font(.system(size: 11, weight: .medium)).foregroundStyle(TagColor.orange.fg)
                                .help(changes.summary)
                        }
                        if wt.ahead > 0 {
                            Text("↑\(wt.ahead)").font(.system(size: 11, weight: .medium)).foregroundStyle(TagColor.blue.fg)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { RepoActions.openEditor(wt.path) }
                    .help("Open \(wt.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) in your editor")
                }
            }
            HStack(spacing: 6) {
                Button("Editor") { RepoActions.openEditor(local.root) }
                Button("Terminal") { RepoActions.openTerminal(local.root) }
                Button("Fetch") { repos.fetch(local) }.disabled(repos.busy.contains(local.root))
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 4)
        }
    }
}

// MARK: - Pull requests

struct GHPullsTab: View {
    @ObservedObject var store: GitHubStore
    var slug: String
    @State private var showOpen = true

    var body: some View {
        let open = store.openPulls[slug] ?? []
        let closed = store.closedPulls[slug] ?? []
        let q = store.query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = (showOpen ? open : closed).filter {
            q.isEmpty || $0.title.lowercased().contains(q) || $0.headRef.lowercased().contains(q) || "#\($0.number)".contains(q)
                || $0.author.lowercased().contains(q)
        }
        let key = GitHubStore.pullsKey(slug, open: showOpen)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Button { store.pullDraft = .init(slug: slug) } label: {
                    Text("New pull request")
                }
                .buttonStyle(GHPrimaryButtonStyle())
            }
            if let error = store.error(key) {
                GHErrorBox(message: error) { store.loadPulls(slug, open: showOpen, force: true) }
            }
            GHBox {
                HStack(spacing: 16) {
                    toggle(open: true, count: open.count)
                    toggle(open: false, count: closed.count)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
            } content: {
                if list.isEmpty {
                    if store.isLoading(key) {
                        GHLoading()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.pull").font(.system(size: 26, weight: .light)).foregroundStyle(N.text3)
                            Text(showOpen ? "There aren’t any open pull requests." : "No recently closed pull requests.")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(N.text)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, pull in
                            if index > 0 { Rectangle().fill(GH.borderMuted).frame(height: 1) }
                            GHPullListRow(pull: pull) { store.open(.pull(slug, pull.number)) }
                        }
                    }
                }
            }
        }
    }

    private func toggle(open: Bool, count: Int) -> some View {
        Button { showOpen = open } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "arrow.triangle.pull" : "checkmark").font(.system(size: 12, weight: .semibold))
                Text("\(count) \(open ? "Open" : "Closed")")
            }
            .font(.system(size: 13.5, weight: showOpen == open ? .semibold : .regular))
            .foregroundStyle(showOpen == open ? N.text : N.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A pull request in GitHub's list style.
struct GHPullListRow: View {
    var pull: GHPullSummary
    var showRepo = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: pull.state.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(pull.state.tint)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if showRepo { Text(pull.repo).font(.system(size: 14)).foregroundStyle(N.text2) }
                    Text(pull.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(hover ? GH.link : N.text)
                        .lineLimit(2)
                    if pull.checks != .none { CheckGlyph(state: pull.checks, size: 12) }
                }
                HStack(spacing: 4) {
                    Text(verbatim: "#\(pull.number)")
                    Text(subtitle)
                    if pull.state.isOpen, let review = reviewText {
                        Text("•")
                        Text(review.0).foregroundStyle(review.1)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(N.text2)
                .lineLimit(1)
                HStack(spacing: 6) {
                    GHBranchName(name: pull.headRef, maxWidth: 220, copyable: false)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(N.text3)
                    GHBranchName(name: pull.baseRef, maxWidth: 140, copyable: false)
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 10)
            if pull.comments > 0 {
                Label("\(pull.comments)", systemImage: "bubble.left")
                    .font(.system(size: 12)).foregroundStyle(N.text2).labelStyle(TightLabelStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(hover ? GH.canvasSubtle : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .contextMenu {
            Button("Open") { action() }
            Button("Open on GitHub") { ProcessManager.openURL(pull.url) }
            Button("Copy URL") { RepoActions.copy(pull.url) }
            Button("Copy Branch Name") { RepoActions.copy(pull.headRef) }
        }
    }

    private var subtitle: String {
        switch pull.state {
        case .open, .draft: return "opened \(RepoFormat.ago(pull.createdAt)) by \(pull.author)"
        case .merged: return "by \(pull.author) was merged \(RepoFormat.ago(pull.updatedAt))"
        case .closed: return "by \(pull.author) was closed \(RepoFormat.ago(pull.updatedAt))"
        }
    }

    private var reviewText: (String, Color)? {
        if pull.state == .draft { return ("Draft", N.text2) }
        switch pull.review {
        case .approved: return ("Approved", GH.open)
        case .changesRequested: return ("Changes requested", GH.closed)
        case .required: return ("Review required", N.text2)
        case .none: return nil
        }
    }
}

// MARK: - Branches

struct GHBranchesTab: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore
    var slug: String
    @State private var section: GHBranchSection = .overview

    private var local: Repo? { repos.localRepo(slug: slug) }

    var body: some View {
        let all = filtered(store.branches[slug] ?? [])
        let viewer = repos.gitHub.login
        let mine = all.filter { !$0.isDefault && viewer != nil && $0.commit?.authorLogin?.caseInsensitiveCompare(viewer!) == .orderedSame }
        let active = all.filter { !$0.isDefault && !$0.isStale() }
        let stale = all.filter { !$0.isDefault && $0.isStale() }
        let key = GitHubStore.branchesKey(slug)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 0) {
                ForEach(GHBranchSection.allCases) { s in
                    Button { section = s } label: {
                        Text(s.rawValue)
                            .font(.system(size: 13, weight: section == s ? .semibold : .regular))
                            .foregroundStyle(section == s ? Color.white : N.text)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(section == s ? GH.link : .clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if s != GHBranchSection.allCases.last { Rectangle().fill(GH.border).frame(width: 1, height: 30) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
            .fixedSize()

            if let error = store.error(key) {
                GHErrorBox(message: error) { store.loadBranches(slug, force: true) }
            }
            if store.branches[slug] == nil, store.isLoading(key) {
                GHLoading(text: "Comparing branches…")
            } else {
                switch section {
                case .overview:
                    box("Default", all.filter(\.isDefault), limit: 1)
                    if !mine.isEmpty { box("Your branches", mine, limit: 5, more: .yours) }
                    box("Active branches", active, limit: 5, more: .active)
                case .yours: box("Your branches", mine)
                case .active: box("Active branches", active)
                case .stale: box("Stale branches", stale)
                case .all: box("All branches", all)
                }
            }
        }
    }

    private func filtered(_ list: [GHBranch]) -> [GHBranch] {
        let q = store.query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? list : list.filter { $0.name.lowercased().contains(q) }
    }

    @ViewBuilder private func box(_ title: String, _ branches: [GHBranch], limit: Int? = nil, more: GHBranchSection? = nil) -> some View {
        let shown = limit.map { Array(branches.prefix($0)) } ?? branches
        let scale = max(branches.map { max($0.ahead, $0.behind) }.max() ?? 1, 1)
        GHBox {
            HStack(spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                Text("Updated").frame(width: 150, alignment: .leading)
                Text("Check status").frame(width: 90, alignment: .center)
                Text("Behind | Ahead").frame(width: 130, alignment: .center)
                Text("Pull request").frame(width: 110, alignment: .leading)
                Spacer().frame(width: 76)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(N.text2)
            .padding(.horizontal, 16)
            .frame(height: 40)
        } content: {
            VStack(spacing: 0) {
                if shown.isEmpty {
                    Text(title == "Your branches" ? "You haven’t pushed to any branches here recently." : "No branches here.")
                        .font(NFont.small).foregroundStyle(N.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, branch in
                    if index > 0 { Rectangle().fill(GH.borderMuted).frame(height: 1) }
                    GHBranchRow(store: store, repos: repos, slug: slug, branch: branch, scale: scale, local: local)
                }
                if let more, let limit, branches.count > limit {
                    Rectangle().fill(GH.borderMuted).frame(height: 1)
                    Button { section = more } label: {
                        Text("View more branches (\(branches.count - limit))")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(GH.link)
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct GHBranchRow: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore
    var slug: String
    var branch: GHBranch
    var scale: Int
    var local: Repo?
    @State private var hover = false

    private var worktree: RepoWorktree? { local?.worktrees.first { $0.branch == branch.name } }
    private var isCheckedOutHere: Bool { local?.status.branch == branch.name }
    private var workingKey: String { "branch:\(slug):\(branch.name)" }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                GHBranchName(name: branch.name, worktree: worktree != nil, maxWidth: 260)
                if branch.isDefault { GHVisibilityBadge(text: "Default") }
                if branch.isProtected {
                    Image(systemName: "lock.shield").font(.system(size: 11)).foregroundStyle(N.text2).help("Protected branch")
                }
                if isCheckedOutHere {
                    Image(systemName: "laptopcomputer").font(.system(size: 10.5)).foregroundStyle(N.text2)
                        .help("Checked out in \(local?.displayPath ?? "the local clone")")
                }
                if let worktree, let owner = worktree.owner {
                    Text(owner).font(NFont.caption).foregroundStyle(TagColor.purple.fg)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let commit = branch.commit { GHAvatar(login: commit.author, size: 18) }
                Text(RepoFormat.ago(branch.commit?.date)).font(.system(size: 12)).foregroundStyle(N.text2)
            }
            .frame(width: 150, alignment: .leading)
            .help(branch.commit.map { "\($0.headline)\n\($0.author) · \($0.short)" } ?? "")

            ZStack {
                if let checks = branch.commit?.checks, checks != .none { CheckGlyph(state: checks, size: 13) }
            }
            .frame(width: 90)

            ZStack {
                if branch.isDefault {
                    Text("Default").font(.system(size: 11.5)).foregroundStyle(N.text3)
                } else {
                    GHAheadBehind(behind: branch.behind, ahead: branch.ahead, scale: scale)
                }
            }
            .frame(width: 130)

            ZStack(alignment: .leading) {
                if let pull = branch.pull {
                    Button { store.open(.pull(slug, pull.number)) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: pull.state.symbol).font(.system(size: 11, weight: .semibold))
                            Text(verbatim: "#\(pull.number)").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(pull.state.color, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(pull.title)
                }
            }
            .frame(width: 110, alignment: .leading)

            HStack(spacing: 2) {
                if store.working.contains(workingKey) {
                    ProgressView().controlSize(.small).frame(width: 26)
                } else if !branch.isDefault && !branch.isProtected && branch.pull?.state.isOpen != true && worktree == nil && !isCheckedOutHere {
                    GHArmedDelete { store.deleteBranch(slug, branch.name) }
                        .opacity(hover ? 1 : 0.55)
                }
                Menu {
                    Button("Copy Branch Name") { RepoActions.copy(branch.name) }
                    Button("Open on GitHub") { ProcessManager.openURL("https://github.com/\(slug)/tree/\(branch.name)") }
                    if !branch.isDefault {
                        Button("Compare") { ProcessManager.openURL("https://github.com/\(slug)/compare/\(branch.name)") }
                        if branch.pull == nil || branch.pull?.state.isOpen == false {
                            Button("New Pull Request…") { store.pullDraft = .init(slug: slug, head: branch.name) }
                        }
                    }
                    Button("Commits") { ProcessManager.openURL("https://github.com/\(slug)/commits/\(branch.name)") }
                    if let local {
                        Divider()
                        if let worktree {
                            Button("Open Worktree in Editor") { RepoActions.openEditor(worktree.path) }
                        } else if !isCheckedOutHere {
                            Button("Check Out in \(local.name)") {
                                store.checkoutBranch(slug, branch.name, in: local.root) { repos.refresh(quiet: true) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text2)
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.button)
        .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(hover ? GH.canvasSubtle : .clear)
        .onHover { hover = $0 }
    }
}

/// GitHub's diverging bar: commits behind the default branch grow left, commits ahead grow right.
struct GHAheadBehind: View {
    var behind: Int
    var ahead: Int
    var scale: Int

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 0) {
                Text("\(behind)").frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4)
                Rectangle().fill(GH.border).frame(width: 1, height: 10)
                Text("\(ahead)").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
            }
            .font(.system(size: 11)).monospacedDigit()
            .foregroundStyle(N.text2)
            HStack(spacing: 1) {
                HStack { Spacer(minLength: 0); bar(behind) }.frame(maxWidth: .infinity)
                HStack { bar(ahead); Spacer(minLength: 0) }.frame(maxWidth: .infinity)
            }
            .frame(height: 4)
        }
        .frame(width: 100)
        .help("\(behind) behind, \(ahead) ahead of the default branch")
    }

    private func bar(_ value: Int) -> some View {
        // Square root keeps one huge branch from flattening the rest.
        let fraction = value == 0 ? 0 : max(0.08, (Double(value) / Double(scale)).squareRoot())
        return RoundedRectangle(cornerRadius: 1)
            .fill(GH.neutralBox)
            .frame(width: 50 * fraction)
    }
}

/// Trash icon that asks once more before deleting.
struct GHArmedDelete: View {
    var action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed { armed = false; action() } else {
                withAnimation(.snappy(duration: 0.2)) { armed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation(.snappy(duration: 0.2)) { armed = false } }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "trash").font(.system(size: 11.5, weight: .medium))
                if armed { Text("Delete?").font(.system(size: 12, weight: .medium)) }
            }
            .foregroundStyle(armed ? .white : GH.closed)
            .padding(.horizontal, armed ? 8 : 0)
            .frame(minWidth: 26, minHeight: 26)
            .background(armed ? GH.closed : .clear, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(armed ? "Click again to delete the branch on GitHub" : "Delete branch")
    }
}

// MARK: - Commits

struct GHCommitsTab: View {
    @ObservedObject var store: GitHubStore
    var slug: String
    @State private var branch: String?

    var body: some View {
        let current = branch ?? store.defaultBranch(slug)
        let commits = store.commits(slug, branch: current) ?? []
        let key = GitHubStore.commitsKey(slug, branch: current)
        let q = store.query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = commits.filter { q.isEmpty || $0.headline.lowercased().contains(q) || $0.author.lowercased().contains(q) || $0.oid.hasPrefix(q) }
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date ?? .distantPast) }
            .sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                GHMenuButton(title: current, value: nil) {
                    ForEach(store.branches[slug]?.map(\.name) ?? [current], id: \.self) { name in
                        Button(name) { branch = name }
                    }
                }
                Spacer()
            }
            if let error = store.error(key) {
                GHErrorBox(message: error) { store.loadCommits(slug, branch: current, force: true) }
            }
            if commits.isEmpty, store.isLoading(key) { GHLoading() }
            ForEach(days, id: \.key) { day, list in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "smallcircle.filled.circle").font(.system(size: 11)).foregroundStyle(N.text3)
                        Text("Commits on \(GHFormat.dayTitle(day))").font(.system(size: 13, weight: .medium)).foregroundStyle(N.text2)
                    }
                    GHBox {
                        VStack(spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, commit in
                                if index > 0 { Rectangle().fill(GH.borderMuted).frame(height: 1) }
                                GHCommitRow(slug: slug, commit: commit)
                            }
                        }
                    }
                }
            }
        }
        .task(id: current) { store.loadCommits(slug, branch: current) }
    }
}

struct GHCommitRow: View {
    var slug: String
    var commit: GHCommit
    var compact = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.headline)
                    .font(.system(size: compact ? 13 : 14, weight: compact ? .regular : .semibold))
                    .foregroundStyle(N.text)
                    .lineLimit(1)
                if !compact {
                    HStack(spacing: 6) {
                        GHAvatar(login: commit.author, size: 16)
                        Text(commit.author).font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text)
                        Text("committed \(RepoFormat.ago(commit.date))").font(.system(size: 12)).foregroundStyle(N.text2)
                    }
                }
            }
            Spacer(minLength: 10)
            if commit.checks != .none { CheckGlyph(state: commit.checks, size: 12) }
            if compact {
                GHAvatar(login: commit.author, size: 16)
                Text(RepoFormat.ago(commit.date)).font(.system(size: 12)).foregroundStyle(N.text2).frame(width: 60, alignment: .trailing)
            }
            Button { RepoActions.copy(commit.oid) } label: {
                Text(commit.short).font(.system(size: 12, design: .monospaced)).foregroundStyle(N.text2)
                    .padding(.horizontal, 8).frame(height: 24)
                    .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
            }
            .buttonStyle(.plain)
            .help("Copy the full SHA")
            if !compact {
                Button { ProcessManager.openURL("https://github.com/\(slug)/tree/\(commit.oid)") } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 11))
                        .foregroundStyle(N.text2).frame(width: 26, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
                }
                .buttonStyle(.plain)
                .help("Browse the repository at this point in the history")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 9 : 11)
        .background(hover ? GH.canvasSubtle : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { ProcessManager.openURL("https://github.com/\(slug)/commit/\(commit.oid)") }
        .contextMenu {
            Button("Open Commit on GitHub") { ProcessManager.openURL("https://github.com/\(slug)/commit/\(commit.oid)") }
            Button("Copy SHA") { RepoActions.copy(commit.oid) }
            Button("Copy Message") { RepoActions.copy(commit.headline) }
        }
        .help("Double-click to open on GitHub")
    }
}
