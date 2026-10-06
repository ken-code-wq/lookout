import SwiftUI
import LocalObserverRepos
import LocalObserverCore

/// GitHub inside Lookout: your repositories, then a repository's code, pull requests, branches and commits, then a
/// pull request's conversation, commits, checks and diff. Laid out and coloured the way github.com does it, with
/// what's on this Mac (clones, worktrees, checked-out branches) folded in.
struct GitHubPage: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore
    var agents: AgentStore

    var body: some View {
        Group {
            switch store.route {
            case nil:
                GHRepositoryList(store: store, repos: repos)
            case .repo(let slug, let tab):
                GHRepoView(store: store, repos: repos, slug: slug, tab: tab)
            case .pull(let slug, let number):
                GHPullView(store: store, repos: repos, agents: agents, slug: slug, number: number)
            case .issue(let slug, let number):
                GHIssueView(store: store, slug: slug, number: number)
            }
        }
        // Loads once signed in; while GitHub is off or gh is missing, the status banner says why the page is empty.
        .onAppear { if repos.settings.gitHubEnabled { store.loadRepositories() } }
        .onChange(of: repos.gitHub.login) { _, login in if login != nil { store.loadRepositories() } }
    }
}

/// Page scaffold shared by every GitHub screen: a breadcrumb trail, then the content, with the app's margins.
struct GHScaffold<Content: View>: View {
    @ObservedObject var store: GitHubStore
    var maxWidth: CGFloat = 1280
    @ViewBuilder var content: (CGFloat) -> Content
    @State private var width: CGFloat = 900

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GHBreadcrumb(store: store)
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                content(min(width - 2 * margin, maxWidth))
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, margin)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    private var margin: CGFloat { width > 1100 ? 48 : (width > 800 ? 32 : 20) }
}

/// "‹  GitHub / acme / aurora-api / Pull requests / #214": every step clickable.
struct GHBreadcrumb: View {
    @ObservedObject var store: GitHubStore

    var body: some View {
        HStack(spacing: 6) {
            Button { store.back() } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(store.path.isEmpty)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")

            crumb("GitHub", symbol: "chevron.left.forwardslash.chevron.right", current: store.path.isEmpty) { store.home() }
            if let route = store.route {
                separator
                let (owner, name) = parts(route.slug)
                Text(owner).font(.system(size: 13)).foregroundStyle(N.text2)
                separator
                crumb(name, current: { if case .repo(_, .code) = route { return true }; return false }()) {
                    open(.repo(route.slug, .code))
                }
                switch route {
                case .repo(_, let tab) where tab != .code:
                    separator
                    crumb(tab.rawValue, current: true) {}
                case .pull(let slug, let number):
                    separator
                    crumb("Pull requests", current: false) { open(.repo(slug, .pulls)) }
                    separator
                    crumb("#\(number)", current: true) {}
                case .issue(let slug, let number):
                    separator
                    crumb("Issues", current: false) { open(.repo(slug, .issues)) }
                    separator
                    crumb("#\(number)", current: true) {}
                default:
                    EmptyView()
                }
            }
            Spacer()
        }
    }

    private var separator: some View { Text("/").font(.system(size: 13)).foregroundStyle(N.text3) }

    private func parts(_ slug: String) -> (String, String) {
        let p = slug.split(separator: "/", maxSplits: 1).map(String.init)
        return (p.first ?? slug, p.count > 1 ? p[1] : slug)
    }

    /// Jumps back to an earlier step, trimming the trail to it.
    private func open(_ route: GHRoute) {
        if let index = store.path.firstIndex(where: { $0.slug == route.slug }) {
            store.path = Array(store.path.prefix(index + 1))
            store.path[index] = route
        } else {
            store.open(route)
        }
    }

    private func crumb(_ title: String, symbol: String? = nil, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: current ? .semibold : .regular))
            }
            .foregroundStyle(current ? N.text : GH.link)
            .padding(.horizontal, 4)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current)
    }
}

/// A failed load, with a retry.
struct GHErrorBox: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(GH.attention)
            Text(message).font(NFont.small).foregroundStyle(N.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Try again", action: retry).buttonStyle(SecondaryButtonStyle())
        }
        .padding(12)
        .background(GH.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.attention.opacity(0.4)))
    }
}

struct GHLoading: View {
    var text = "Loading…"
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(NFont.small).foregroundStyle(N.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// GitHub-style dropdown button: "Type: All ▾".
struct GHMenuButton<Content: View>: View {
    var title: String
    var value: String?
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 5) {
                Text(title).foregroundStyle(N.text)
                if let value { Text(value).foregroundStyle(N.text2) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(N.text2)
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(GH.canvasSubtle, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Repository list

/// github.com/<you>?tab=repositories: every repository you own or can push to.
struct GHRepositoryList: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore

    var body: some View {
        GHScaffold(store: store, maxWidth: 1080) { _ in
            VStack(alignment: .leading, spacing: 0) {
                header
                GitHubStatusBanner(store: repos)
                controls.padding(.vertical, 14)
                Rectangle().fill(GH.borderMuted).frame(height: 1)
                list
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let login = repos.gitHub.login {
                GHAvatar(login: login, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(login).font(.system(size: 22, weight: .semibold)).foregroundStyle(N.text)
                    HStack(spacing: 12) {
                        Label("\(store.repositories.count) repositories", systemImage: "book.closed")
                        let open = store.repositories.reduce(0) { $0 + $1.openPulls }
                        if open > 0 { Label("\(open) open pull requests", systemImage: "arrow.triangle.pull") }
                        let cloned = store.repositories.filter { repos.localRepo(slug: $0.slug) != nil }.count
                        if cloned > 0 { Label("\(cloned) on this Mac", systemImage: "laptopcomputer") }
                        RelativeTimeText(date: store.lastRepositories)
                    }
                    .font(NFont.small)
                    .foregroundStyle(N.text2)
                    .labelStyle(TightLabelStyle())
                }
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 26)).foregroundStyle(N.text2)
                Text("GitHub").font(NFont.pageTitle).foregroundStyle(N.text)
            }
            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Text(store.query.isEmpty ? "Search with ⌘F" : "Matching “\(store.query)”")
                .font(NFont.small).foregroundStyle(N.text3)
            Spacer()
            GHMenuButton(title: "Type", value: store.filter == .all ? nil : store.filter.rawValue) {
                Picker("Type", selection: $store.filter) {
                    ForEach(GHRepoFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            }
            GHMenuButton(title: "Language", value: store.language) {
                Button("All languages") { store.language = nil }
                Divider()
                ForEach(store.languages, id: \.self) { name in
                    Button { store.language = name } label: {
                        if store.language == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
            GHMenuButton(title: "Sort", value: store.sort.rawValue) {
                Picker("Sort", selection: $store.sort) {
                    ForEach(GHRepoSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            }
        }
    }

    @ViewBuilder private var list: some View {
        let list = store.filteredRepositories
        if let error = store.error("repositories"), store.repositories.isEmpty {
            GHErrorBox(message: error) { store.loadRepositories(force: true) }.padding(.top, 16)
        } else if store.repositories.isEmpty, store.isLoading("repositories") || repos.gitHub == .unknown {
            GHLoading(text: "Asking GitHub for your repositories…")
        } else if list.isEmpty, !store.repositories.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "No repositories match",
                           message: "Try another name, type or language.") {
                Button("Clear filters") {
                    store.query = ""
                    store.filter = .all
                    store.language = nil
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(list) { repo in
                    GHRepositoryRow(store: store, repo: repo, local: repos.localRepo(slug: repo.slug), viewer: repos.gitHub.login)
                    Rectangle().fill(GH.borderMuted).frame(height: 1)
                }
            }
        }
    }
}

struct GHRepositoryRow: View {
    @ObservedObject var store: GitHubStore
    var repo: GHRepository
    var local: Repo?
    var viewer: String?
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(repo.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(GH.link)
                        .underline(hover, color: GH.link)
                    GHVisibilityBadge(text: repo.visibilityLabel, tint: repo.isArchived ? GH.attention : N.text2)
                    if repo.isFork { Image(systemName: "tuningfork").font(.system(size: 11)).foregroundStyle(N.text2).help("Fork") }
                    if let viewer, repo.owner.caseInsensitiveCompare(viewer) != .orderedSame {
                        Text(repo.owner).font(NFont.small).foregroundStyle(N.text3)
                    }
                }
                if let description = repo.description, !description.isEmpty {
                    Text(description).font(.system(size: 13)).foregroundStyle(N.text2).lineLimit(2)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                HStack(spacing: 16) {
                    if let language = repo.language { GHLanguageDot(language: language) }
                    if repo.stars > 0 { Label(GHFormat.count(repo.stars), systemImage: "star") }
                    if repo.forks > 0 { Label(GHFormat.count(repo.forks), systemImage: "tuningfork") }
                    if repo.openPulls > 0 {
                        Label("\(repo.openPulls)", systemImage: "arrow.triangle.pull").help("\(repo.openPulls) open pull requests")
                    }
                    if repo.openIssues > 0 {
                        Label("\(repo.openIssues)", systemImage: "smallcircle.filled.circle").help("\(repo.openIssues) open issues")
                    }
                    Text("Updated \(RepoFormat.ago(repo.pushedAt))")
                }
                .font(.system(size: 12))
                .foregroundStyle(N.text2)
                .labelStyle(TightLabelStyle())
            }
            Spacer(minLength: 12)
            if let local { localBadge(local) }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.open(.repo(repo.slug, .code)) }
        .contextMenu {
            Button("Open") { store.open(.repo(repo.slug, .code)) }
            Button("Pull Requests") { store.open(.repo(repo.slug, .pulls)) }
            Button("Branches") { store.open(.repo(repo.slug, .branches)) }
            Divider()
            Button("Open on GitHub") { ProcessManager.openURL(repo.url) }
            Button("Copy Clone Command") { RepoActions.copy("gh repo clone \(repo.slug)") }
            if let local {
                Divider()
                Button("Open \(local.name) in Editor") { RepoActions.openEditor(local.root) }
                Button("Open in Terminal") { RepoActions.openTerminal(local.root) }
            }
        }
    }

    /// "On this Mac · ⑂ main · 2 worktrees", with uncommitted work flagged.
    private func localBadge(_ local: Repo) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "laptopcomputer").font(.system(size: 10.5))
                Text("On this Mac")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(N.text2)
            GHBranchName(name: local.refLabel, maxWidth: 180)
            ForEach(local.worktrees.filter { !$0.isPrunable }.prefix(3)) { wt in
                GHBranchName(name: wt.refLabel, worktree: true, maxWidth: 180)
            }
            if local.worktrees.count > 3 {
                Text("+\(local.worktrees.count - 3) more worktrees").font(NFont.caption).foregroundStyle(N.text3)
            }
            RepoStateChips(changes: local.changes, unpushed: local.unpushedCount, behind: local.status.behind)
        }
        .help(local.displayPath)
    }
}
