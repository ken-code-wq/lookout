import SwiftUI
import AppKit
import LocalObserverRepos

/// Every repository under your code folders: branch, uncommitted and unpushed work, worktrees, and open pull requests.
struct ReposPage: View {
    @ObservedObject var store: RepoStore
    var github: GitHubStore = .shared
    /// Opens a repository on the GitHub page, for the ones that only exist there.
    var openOnGitHub: (String) -> Void = { _ in }
    @State private var width: CGFloat = 900
    @State private var expanded: Set<String> = []
    @FocusState private var focused: Bool

    var body: some View {
        let repos = store.filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: SidebarItem.repos.symbol, title: SidebarItem.repos.title, subtitle: AnyView(summary))
                tabs
                Rectangle().fill(N.divider).frame(height: 1)
                if store.view == .forgotten {
                    Text("Uncommitted or unpushed work nobody has touched in \(store.settings.forgottenDays) days. It exists only on this Mac.")
                        .font(NFont.small).foregroundStyle(N.text2)
                        .padding(.top, 12)
                }
                if repos.isEmpty {
                    empty
                } else {
                    header
                    LazyVStack(spacing: 1) {
                        ForEach(repos) { repo in
                            RepoRow(store: store, repo: repo, columns: columns,
                                    selected: store.selection == repo.root,
                                    expanded: expanded.contains(repo.root) || store.view == .worktrees) {
                                if expanded.contains(repo.root) { expanded.remove(repo.root) } else { expanded.insert(repo.root) }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                if store.view == .all, store.settings.gitHubEnabled {
                    ReposGitHubSection(store: store, github: github, openOnGitHub: openOnGitHub)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1, in: repos) }
        .onKeyPress(.upArrow) { move(-1, in: repos) }
        .onKeyPress(.return) {
            guard let repo = store.selected else { return .ignored }
            RepoActions.openEditor(repo.root); return .handled
        }
        .onKeyPress(.escape) {
            guard store.selection != nil else { return .ignored }
            store.selection = nil; return .handled
        }
        .onTapGesture { store.selection = nil }
        .onAppear { if store.settings.gitHubEnabled, store.gitHub.login != nil { github.loadRepositories() } }
        .onChange(of: store.gitHub.login) { _, login in if login != nil { github.loadRepositories() } }
    }

    private var horizontalPadding: CGFloat { width > 1100 ? 64 : (width > 800 ? 44 : 24) }
    private var columns: RepoColumns { RepoColumns(width: width - horizontalPadding * 2) }

    private var summary: some View {
        let all = store.visibleRepos
        let dirty = all.filter { $0.isDirty || !$0.dirtyWorktrees.isEmpty }.count
        let unpushed = all.filter { $0.hasUnpushed }.count
        return HStack(spacing: 14) {
            Label("\(all.count) repositor\(all.count == 1 ? "y" : "ies")", systemImage: "square.stack.3d.up")
            if dirty > 0 { Label("\(dirty) with uncommitted work", systemImage: "pencil") }
            if unpushed > 0 { Label("\(unpushed) unpushed", systemImage: "arrow.up.circle") }
            if !store.failingPulls.isEmpty {
                Label("\(store.failingPulls.count) failing check\(store.failingPulls.count == 1 ? "" : "s")", systemImage: "xmark.circle")
                    .foregroundStyle(TagColor.red.fg)
            }
            RelativeTimeText(date: store.lastScan)
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .labelStyle(TightLabelStyle())
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(RepoView.allCases) { view in
                        RepoTab(view: view, count: store.repos(in: view).count, active: store.view == view) {
                            withAnimation(.snappy(duration: 0.2)) { store.view = view }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 8)
            Menu {
                Picker("Sort by", selection: $store.sort) {
                    ForEach(RepoSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down").labelStyle(TightLabelStyle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(NFont.small)
            .foregroundStyle(N.text2)
            .padding(.horizontal, 8)
            Button {
                store.fetchAll()
            } label: {
                Label("Fetch all", systemImage: "arrow.down.circle").labelStyle(TightLabelStyle()).font(NFont.small)
            }
            .buttonStyle(GhostButtonStyle())
            .help("git fetch every repository with a remote, so ahead/behind is current")
        }
        .padding(.bottom, 6)
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell("textformat", "Repository").frame(maxWidth: .infinity, alignment: .leading)
            cell("circle.dashed", "State").frame(width: columns.state, alignment: .leading)
            if columns.showPull { cell("arrow.triangle.pull", "Pull request").frame(width: columns.pull, alignment: .leading) }
            if columns.showCommit { cell("text.bubble", "Last commit").frame(maxWidth: .infinity, alignment: .leading) }
            cell("clock", "Touched").frame(width: columns.touched, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(N.divider).frame(height: 1) }
    }

    private func cell(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5))
            Text(title).font(NFont.small)
        }
        .foregroundStyle(N.text2)
    }

    @ViewBuilder private var empty: some View {
        if store.lastScan == nil {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for repositories…").font(NFont.small).foregroundStyle(N.text2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 64)
        } else if !store.searchText.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "No repository matches “\(store.searchText)”.") {
                Button("Clear search") { store.searchText = "" }.buttonStyle(SecondaryButtonStyle())
            }
        } else if store.view != .all {
            EmptyStateView(symbol: "checkmark.circle", title: emptyTitle, message: "Nothing to look at here.") {
                Button("Show all repositories") { store.view = .all }.buttonStyle(SecondaryButtonStyle())
            }
        } else {
            EmptyStateView(symbol: "folder.badge.questionmark", title: "No repositories found",
                           message: "Lookout looks in \(store.settings.effectiveRoots.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")). Add the folders where you keep code.") {
                SettingsLink { Text("Choose folders…") }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var emptyTitle: String {
        switch store.view {
        case .changes: return "No uncommitted work"
        case .unpushed: return "Everything is pushed"
        case .behind: return "Nothing to pull"
        case .forgotten: return "Nothing forgotten"
        case .worktrees: return "No worktrees"
        case .all: return "No repositories"
        }
    }

    private func move(_ delta: Int, in list: [Repo]) -> KeyPress.Result {
        guard !list.isEmpty else { return .ignored }
        let current = list.firstIndex { $0.root == store.selection }
        let next = current.map { min(max($0 + delta, 0), list.count - 1) } ?? (delta > 0 ? 0 : list.count - 1)
        store.selection = list[next].root
        return .handled
    }
}

struct RepoColumns {
    var width: CGFloat
    var showPull: Bool { width > 720 }
    var showCommit: Bool { width > 940 }
    let state: CGFloat = 190
    let pull: CGFloat = 110
    let touched: CGFloat = 76
}

private struct RepoTab: View {
    var view: RepoView
    var count: Int
    var active: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: view.symbol).font(.system(size: 11))
                    Text(view.rawValue).font(.system(size: 13, weight: active ? .medium : .regular))
                    if count > 0 && view != .all {
                        Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(N.text3)
                    }
                }
                .foregroundStyle(active ? N.text : N.text2)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: N.radius))
                Rectangle().fill(active ? N.text : .clear).frame(height: 2).padding(.horizontal, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .padding(.bottom, -7)
    }
}

private struct RepoRow: View {
    @ObservedObject var store: RepoStore
    var repo: Repo
    var columns: RepoColumns
    var selected: Bool
    var expanded: Bool
    var toggle: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 0) {
                HStack(spacing: 9) {
                    FolderIconView(folder: repo.root, name: repo.name, size: 20)
                    Text(repo.name).font(NFont.bodyMedium).foregroundStyle(N.text).lineLimit(1).layoutPriority(1)
                    BranchTag(branch: repo.refLabel, detached: repo.branch == nil, help: branchHelp, maxWidth: 280)
                    if !repo.worktrees.isEmpty {
                        Button(action: toggle) {
                            HStack(spacing: 3) {
                                Image(systemName: "square.stack.3d.down.right").font(.system(size: 9.5, weight: .semibold))
                                Text("\(repo.worktrees.count)").font(.system(size: 11.5)).monospacedDigit()
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                    .rotationEffect(.degrees(expanded ? 90 : 0))
                            }
                            .foregroundStyle(TagColor.purple.fg)
                            .padding(.horizontal, 6).frame(height: 20)
                            .background(TagColor.purple.bg, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("\(repo.worktrees.count) worktree\(repo.worktrees.count == 1 ? "" : "s"). Click to \(expanded ? "hide" : "show") them.")
                    }
                    if store.busy.contains(repo.root) { ProgressView().controlSize(.mini) }
                }
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

                RepoStateChips(changes: repo.changes, unpushed: repo.unpushedCount, behind: repo.status.behind,
                               stashes: repo.stashes, localOnly: repo.isLocalOnly)
                    .frame(width: columns.state, alignment: .leading)
                if columns.showPull {
                    Group {
                        if let pull = store.pull(for: repo, branch: repo.branch) { PullChip(pull: pull) }
                        else { Text("–").font(NFont.small).foregroundStyle(N.text3) }
                    }
                    .frame(width: columns.pull, alignment: .leading)
                }
                if columns.showCommit {
                    Text(repo.lastCommitSubject.isEmpty ? "No commits yet" : repo.lastCommitSubject)
                        .font(NFont.small).foregroundStyle(repo.lastCommitSubject.isEmpty ? N.text3 : N.text2)
                        .lineLimit(1)
                        .padding(.trailing, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(RepoFormat.ago(repo.lastTouched))
                    .font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
                    .frame(width: columns.touched, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: N.rowHeight)
            .background(selected ? N.selected : (hover ? N.hover : .clear), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .onTapGesture {
                if NSApp.currentEvent?.clickCount == 2 { RepoActions.openEditor(repo.root) }
                store.selection = repo.root
            }
            .contextMenu { RepoMenu(store: store, repo: repo) }
            .help(repo.displayPath)

            if expanded {
                ForEach(repo.worktrees) { worktree in
                    WorktreeRow(store: store, repo: repo, worktree: worktree, columns: columns)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var branchHelp: String {
        var lines = ["\(repo.name) on \(repo.refLabel)"]
        if let upstream = repo.status.upstream { lines.append("Tracks \(upstream)") }
        else if !repo.isLocalOnly { lines.append("Not tracking a remote branch") }
        return lines.joined(separator: "\n")
    }
}

/// A linked worktree under its repository: which tool made it, its branch, and whether it holds unsaved work.
struct WorktreeRow: View {
    @ObservedObject var store: RepoStore
    var repo: Repo
    var worktree: RepoWorktree
    var columns: RepoColumns
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(N.text3)
                    .padding(.leading, 12)
                BranchTag(branch: worktree.refLabel, worktree: true, detached: worktree.branch == nil,
                          help: worktree.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), maxWidth: 320)
                Text(worktree.owner ?? worktree.name).font(NFont.small).foregroundStyle(N.text2).lineLimit(1)
                if worktree.isLocked { Image(systemName: "lock.fill").font(.system(size: 9.5)).foregroundStyle(N.text3).help("Locked") }
                if worktree.isPrunable { Tag(text: "Folder missing", color: .red).help("Its folder is gone. Prune to clean up.") }
            }
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            RepoStateChips(changes: worktree.changes, unpushed: worktree.ahead, behind: worktree.behind)
                .frame(width: columns.state, alignment: .leading)
            if columns.showPull {
                Group {
                    if let pull = store.pull(for: repo, branch: worktree.branch) { PullChip(pull: pull) } else { Color.clear }
                }
                .frame(width: columns.pull, alignment: .leading)
            }
            if columns.showCommit {
                Text(worktree.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(NFont.caption).foregroundStyle(N.text3).lineLimit(1).truncationMode(.middle)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(RepoFormat.ago(worktree.lastTouched))
                .font(NFont.small).foregroundStyle(N.text3).monospacedDigit()
                .frame(width: columns.touched, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { RepoActions.openEditor(worktree.path) }
        .contextMenu {
            Button("Open in Editor") { RepoActions.openEditor(worktree.path) }
            Button("Open in Terminal") { RepoActions.openTerminal(worktree.path) }
            Button("Reveal in Finder") { RepoActions.reveal(worktree.path) }
            Divider()
            Button("Copy Path") { RepoActions.copy(worktree.path) }
            Button("Copy Branch Name") { RepoActions.copy(worktree.refLabel) }
            if let branch = worktree.branch, let url = repo.githubBranchURL(branch) {
                Button("Open Branch on GitHub") { NSWorkspace.shared.open(url) }
            }
        }
    }
}
