import SwiftUI
import LocalObserverRepos
import LocalObserverCore

/// One pull request, GitHub-style: title and state, then Conversation / Commits / Checks / Files changed, with the
/// merge box, reviews and comments working through `gh`.
struct GHPullView: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore
    var agents: AgentStore
    var slug: String
    var number: Int
    var initialTab: GHPullTab = .conversation
    @State private var tab: GHPullTab = .conversation

    private var detail: GHPullDetail? { store.pull(slug, number) }
    private var local: Repo? { repos.localRepo(slug: slug) }

    var body: some View {
        GHScaffold(store: store) { width in
            VStack(alignment: .leading, spacing: 0) {
                if let detail {
                    header(detail)
                    GHTabBar(tabs: GHPullTab.allCases, selection: tab, title: \.rawValue, symbol: \.symbol, count: { count($0, detail) }) {
                        tab = $0
                    }
                    .overlay(alignment: .trailing) {
                        GHDiffStat(additions: detail.additions, deletions: detail.deletions).padding(.bottom, 6)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                    switch tab {
                    case .conversation: GHConversation(store: store, repos: repos, agents: agents, detail: detail, width: width)
                    case .commits: GHPullCommits(slug: slug, commits: detail.commits)
                    case .checks: GHChecksList(checks: detail.checks, url: detail.summary.url)
                    case .files: GHFilesChanged(store: store, slug: slug, number: number, detail: detail)
                    }
                } else if let error = store.error(GitHubStore.pullKey(slug, number)) {
                    GHErrorBox(message: error) { store.loadPull(slug, number, force: true) }
                } else {
                    GHLoading(text: "Loading #\(number)…")
                }
            }
        }
        .task(id: "\(slug)#\(number)") {
            tab = initialTab
            store.loadPull(slug, number)
            store.loadFiles(slug, number)
            store.loadReviewComments(slug, number)
        }
    }

    private func count(_ tab: GHPullTab, _ detail: GHPullDetail) -> Int? {
        switch tab {
        case .conversation: return detail.timeline.count
        case .commits: return detail.commits.count
        case .checks: return detail.checks.count
        case .files: return detail.changedFiles
        }
    }

    private func header(_ detail: GHPullDetail) -> some View {
        let pull = detail.summary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                (Text(pull.title).foregroundStyle(N.text) + Text("  #\(pull.number)").foregroundStyle(N.text3))
                    .font(.system(size: 26))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                HStack(spacing: 8) {
                    if let local, pull.state.isOpen {
                        if local.checkedOutBranches.contains(pull.headRef) {
                            Button {
                                let wt = local.worktrees.first { $0.branch == pull.headRef }
                                RepoActions.openEditor(wt?.path ?? local.root)
                            } label: { Label("Open in editor", systemImage: "laptopcomputer") }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("\(pull.headRef) is checked out on this Mac")
                        } else {
                            Button {
                                store.checkout(slug, number, in: local.root) { repos.refresh(quiet: true) }
                            } label: { Label("Check out", systemImage: "arrow.down.to.line") }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(store.working.contains(GitHubStore.pullKey(slug, number) + ":checkout"))
                            .help("Switch \(local.displayPath) to this pull request (gh pr checkout)")
                        }
                    }
                    Button { ProcessManager.openURL(pull.url) } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                GHStateBadge(state: pull.state)
                Group {
                    Text(pull.author).fontWeight(.semibold).foregroundStyle(N.text)
                    Text(pull.state == .merged ? "merged" : (pull.state == .closed ? "wanted to merge" : "wants to merge"))
                    Text("\(detail.commits.count) commit\(detail.commits.count == 1 ? "" : "s") into")
                }
                .font(.system(size: 13.5))
                .foregroundStyle(N.text2)
                GHBranchName(name: pull.baseRef)
                Text("from").font(.system(size: 13.5)).foregroundStyle(N.text2)
                GHBranchName(name: pull.headRef, worktree: local?.worktrees.contains { $0.branch == pull.headRef } ?? false)
                if let date = detail.mergedAt ?? detail.closedAt {
                    Text(RepoFormat.ago(date)).font(.system(size: 13.5)).foregroundStyle(N.text2)
                }
            }
            .lineLimit(1)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Conversation

struct GHConversation: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore
    var agents: AgentStore
    var detail: GHPullDetail
    var width: CGFloat

    private var pull: GHPullSummary { detail.summary }

    var body: some View {
        if width > 900 {
            HStack(alignment: .top, spacing: 28) {
                timeline.frame(maxWidth: .infinity)
                GHPullSidebar(store: store, agents: agents, detail: detail).frame(width: 250)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                GHPullSidebar(store: store, agents: agents, detail: detail)
                timeline
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 18) {
            GHCommentBox(author: pull.author, avatar: detail.authorAvatar, date: pull.createdAt, html: detail.bodyHTML,
                         isAuthor: true, empty: "No description provided.")
            ForEach(detail.timeline) { item in
                switch item.kind {
                case .comment:
                    GHCommentBox(author: item.author, avatar: item.avatarURL, date: item.date, html: item.bodyHTML,
                                 isAuthor: item.author == pull.author)
                case .review(let state):
                    GHReviewEventRow(item: item, state: state, isAuthor: item.author == pull.author)
                }
            }
            if !detail.commits.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "smallcircle.filled.circle").font(.system(size: 13)).foregroundStyle(N.text3)
                        .frame(width: 40)
                    Text("\(pull.author) added \(detail.commits.count) commit\(detail.commits.count == 1 ? "" : "s")")
                        .font(.system(size: 13)).foregroundStyle(N.text2)
                    if let last = detail.commits.last {
                        Text("· latest \(last.short)").font(NFont.monoSmall).foregroundStyle(N.text3)
                        if last.checks != .none { CheckGlyph(state: last.checks, size: 11) }
                    }
                }
            }
            Rectangle().fill(GH.borderMuted).frame(height: 2).padding(.vertical, 4)
            GHMergeBox(store: store, detail: detail)
            GHCommentComposer(store: store, detail: detail)
        }
    }
}

/// A comment as GitHub draws it: avatar outside, a header strip (blue for the author), the rendered body.
struct GHCommentBox: View {
    var author: String
    var avatar: String?
    var date: Date?
    var html: String
    var isAuthor: Bool
    var empty: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GHAvatar(login: author, size: 40, url: avatar)
            GHBox(headerTint: isAuthor ? GH.authorHeader : GH.canvasSubtle, borderTint: isAuthor ? GH.authorBorder : GH.border) {
                HStack(spacing: 5) {
                    Text(author).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(N.text)
                    Text("commented \(RepoFormat.ago(date))").font(.system(size: 13.5)).foregroundStyle(N.text2)
                    Spacer()
                    if isAuthor { GHVisibilityBadge(text: "Author") }
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
            } content: {
                Group {
                    if html.isEmpty, let empty {
                        Text(empty).font(.system(size: 13.5)).italic().foregroundStyle(N.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        GHHTMLView(html: html)
                    }
                }
                .padding(16)
            }
        }
    }
}

/// "sam approved these changes 2h ago", with the review's text below when there is any.
struct GHReviewEventRow: View {
    var item: GHTimelineItem
    var state: String
    var isAuthor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint)
                    Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                .frame(width: 40)
                GHAvatar(login: item.author, size: 20, url: item.avatarURL)
                Text(item.author).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(N.text)
                Text("\(verb) \(RepoFormat.ago(item.date))").font(.system(size: 13.5)).foregroundStyle(N.text2)
            }
            if !item.bodyHTML.isEmpty {
                GHBox(borderTint: GH.border) {
                    GHHTMLView(html: item.bodyHTML).padding(14)
                }
                .padding(.leading, 54)
            }
        }
    }

    private var verb: String {
        switch state {
        case "APPROVED": return "approved these changes"
        case "CHANGES_REQUESTED": return "requested changes"
        case "DISMISSED": return "had a review dismissed"
        default: return "reviewed"
        }
    }
    private var symbol: String {
        switch state {
        case "APPROVED": return "checkmark"
        case "CHANGES_REQUESTED": return "doc.badge.ellipsis"
        default: return "eye"
        }
    }
    private var tint: Color {
        switch state {
        case "APPROVED": return GH.openButton
        case "CHANGES_REQUESTED": return GH.closed
        default: return GH.draft
        }
    }
}

// MARK: - Merge box

struct GHMergeBox: View {
    @ObservedObject var store: GitHubStore
    var detail: GHPullDetail
    @State private var method: GHMergeMethod?
    @State private var confirming = false
    @State private var showChecks = false

    private var pull: GHPullSummary { detail.summary }
    private var busy: Bool { store.working.contains(GitHubStore.pullKey(pull.repo, pull.number)) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: GH.radius, style: .continuous).fill(iconTint)
                Image(systemName: pull.state == .merged ? "arrow.triangle.merge" : (pull.state == .closed ? "xmark" : "arrow.triangle.pull"))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            box
        }
    }

    private var iconTint: Color {
        switch pull.state {
        case .merged: return GH.merged
        case .closed: return GH.closed
        case .draft: return GH.draft
        case .open: return canMergeCleanly ? GH.openButton : GH.draft
        }
    }

    private var canMergeCleanly: Bool {
        detail.mergeable == true && detail.checksFailed == 0 && pull.review != .changesRequested
            && ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(detail.mergeState)
    }

    @ViewBuilder private var box: some View {
        switch pull.state {
        case .merged:
            GHBox(borderTint: GH.merged.opacity(0.5)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pull request successfully merged and closed").font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                    HStack {
                        Text("You’re all set — the \(pull.headRef) branch can be safely deleted.").font(NFont.small).foregroundStyle(N.text2)
                        Spacer()
                        if detail.viewerCanUpdate {
                            Button("Delete branch") { store.deleteBranch(pull.repo, pull.headRef) }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                .padding(16)
            }
        case .closed:
            GHBox {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Closed with unmerged commits").font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                        Text("This pull request is closed.").font(NFont.small).foregroundStyle(N.text2)
                    }
                    Spacer()
                    if detail.viewerCanUpdate {
                        Button("Reopen pull request") { store.reopen(pull.repo, pull.number) }.buttonStyle(SecondaryButtonStyle()).disabled(busy)
                    }
                }
                .padding(16)
            }
        case .open, .draft:
            GHBox(borderTint: canMergeCleanly ? GH.openButton.opacity(0.6) : GH.border) {
                VStack(spacing: 0) {
                    reviewSection
                    divider
                    checksSection
                    divider
                    conflictSection
                    divider
                    footer
                }
            }
        }
    }

    private var divider: some View { Rectangle().fill(GH.borderMuted).frame(height: 1) }

    private func section<Trailing: View>(_ symbol: String, _ tint: Color, _ title: String, _ detail: String,
                                         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(tint)
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                Text(detail).font(NFont.small).foregroundStyle(N.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(16)
    }

    @ViewBuilder private var reviewSection: some View {
        let approvals = detail.reviewers.filter { $0.state == "APPROVED" }.count
        let pending = detail.reviewers.filter { $0.state == nil }.map(\.login)
        switch pull.review {
        case .approved:
            section("checkmark", GH.openButton, "Changes approved",
                    "\(approvals) approving review\(approvals == 1 ? "" : "s")" + (pending.isEmpty ? "" : ", waiting on \(pending.joined(separator: ", "))"))
        case .changesRequested:
            section("doc.badge.ellipsis", GH.closed, "Changes requested",
                    "\(detail.reviewers.filter { $0.state == "CHANGES_REQUESTED" }.map(\.login).joined(separator: ", ")) requested changes")
        case .required:
            section("exclamationmark", GH.attention, "Review required",
                    pending.isEmpty ? "At least one approving review is required by reviewers with write access." : "Waiting on \(pending.joined(separator: ", "))")
        case .none:
            section("eye", GH.draft, approvals > 0 ? "Approved" : "No reviews yet",
                    pending.isEmpty ? "Reviews aren’t required to merge." : "Requested from \(pending.joined(separator: ", "))")
        }
    }

    @ViewBuilder private var checksSection: some View {
        let failed = detail.checksFailed, running = detail.checksRunning, passed = detail.checksPassed
        let other = detail.checks.count - failed - running - passed
        let summary = [failed > 0 ? "\(failed) failing" : nil, running > 0 ? "\(running) in progress" : nil,
                       passed > 0 ? "\(passed) successful" : nil, other > 0 ? "\(other) skipped or neutral" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        VStack(spacing: 0) {
            Group {
                if detail.checks.isEmpty {
                    section("circle.dashed", GH.draft, "No checks", "Nothing ran on the latest commit.")
                } else if failed > 0 {
                    section("xmark", GH.closed, "Some checks were not successful", summary) { checksToggle }
                } else if running > 0 {
                    section("circle.dotted", GH.attention, "Some checks haven’t completed yet", summary) { checksToggle }
                } else {
                    section("checkmark", GH.openButton, "All checks have passed", summary) { checksToggle }
                }
            }
            if showChecks {
                VStack(spacing: 0) {
                    ForEach(detail.checks.sorted { order($0.state) < order($1.state) }) { check in
                        divider
                        GHCheckRow(check: check, compact: true)
                    }
                }
                .background(GH.canvasSubtle)
            }
        }
    }

    private func order(_ state: CheckState) -> Int {
        switch state {
        case .failure: return 0
        case .pending: return 1
        case .success: return 2
        case .none: return 3
        }
    }

    private var checksToggle: some View {
        Button(showChecks ? "Hide all checks" : "Show all checks") { withAnimation(.snappy(duration: 0.2)) { showChecks.toggle() } }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(GH.link)
    }

    @ViewBuilder private var conflictSection: some View {
        switch (detail.mergeable, detail.mergeState) {
        case (false, _), (_, "DIRTY"):
            section("exclamationmark", GH.closed, "This branch has conflicts that must be resolved",
                    "Resolve them on GitHub or locally, then push.") {
                Button("Resolve conflicts") { ProcessManager.openURL(pull.url + "/conflicts") }.buttonStyle(SecondaryButtonStyle())
            }
        case (_, "BEHIND"):
            section("exclamationmark", GH.attention, "This branch is out-of-date with the base branch",
                    "Merge the latest changes from \(pull.baseRef) into this branch.") {
                Button("Update branch") { ProcessManager.openURL(pull.url) }.buttonStyle(SecondaryButtonStyle())
            }
        case (nil, _):
            section("circle.dotted", GH.attention, "Checking for ability to merge automatically…", "GitHub is still working it out.")
        default:
            section("checkmark", GH.openButton, "No conflicts with base branch", "Merging can be performed automatically.")
        }
    }

    @ViewBuilder private var footer: some View {
        let chosen = method ?? (detail.mergeMethods.contains(detail.defaultMergeMethod) ? detail.defaultMergeMethod : detail.mergeMethods.first ?? .merge)
        VStack(alignment: .leading, spacing: 10) {
            if pull.state == .draft {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This pull request is still a work in progress").font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                        Text("Draft pull requests cannot be merged.").font(NFont.small).foregroundStyle(N.text2)
                    }
                    Spacer()
                    Button("Ready for review") { store.markReady(pull.repo, pull.number) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!detail.viewerCanUpdate || busy)
                }
            } else if confirming {
                Text(chosen.detail).font(NFont.small).foregroundStyle(N.text2)
                HStack(spacing: 8) {
                    Button("Confirm \(chosen.button.lowercased())") {
                        confirming = false
                        store.merge(pull.repo, pull.number, method: chosen)
                    }
                    .buttonStyle(GHPrimaryButtonStyle())
                    Button("Cancel") { confirming = false }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                HStack(spacing: 10) {
                    HStack(spacing: 0) {
                        Button(chosen.button) { confirming = true }
                            .buttonStyle(GHPrimaryButtonStyle(tint: canMergeCleanly ? GH.openButton : GH.draft))
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: GH.radius, bottomLeadingRadius: GH.radius))
                        Rectangle().fill(Color.black.opacity(0.15)).frame(width: 1, height: 30)
                        Menu {
                            ForEach(detail.mergeMethods) { m in
                                Button { method = m } label: {
                                    if m == chosen { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 28, height: 30)
                                .background(canMergeCleanly ? GH.openButton : GH.draft,
                                            in: UnevenRoundedRectangle(bottomTrailingRadius: GH.radius, topTrailingRadius: GH.radius))
                        }
                        .menuStyle(.button)
        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .disabled(!detail.viewerCanUpdate || busy || detail.mergeable == false)
                    if busy { ProgressView().controlSize(.small) }
                    if !detail.viewerCanUpdate {
                        Text("Only those with write access can merge.").font(NFont.small).foregroundStyle(N.text2)
                    } else if !canMergeCleanly && detail.mergeable != false {
                        Text("Merging may be blocked by branch rules on GitHub.").font(NFont.small).foregroundStyle(N.text2)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Composer

struct GHCommentComposer: View {
    @ObservedObject var store: GitHubStore
    var detail: GHPullDetail
    @State private var text = ""
    @ObservedObject private var repos = RepoStore.shared

    private var pull: GHPullSummary { detail.summary }
    private var busy: Bool { store.working.contains(GitHubStore.pullKey(pull.repo, pull.number)) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GHAvatar(login: repos.gitHub.login ?? "you", size: 40)
            VStack(alignment: .leading, spacing: 10) {
                Text("Add a comment").font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(size: 13.5))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 110)
                    if text.isEmpty {
                        Text("Add your comment here… Markdown works.").font(.system(size: 13.5)).foregroundStyle(N.text3)
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .background(GH.canvasSubtle, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
                HStack(spacing: 8) {
                    Spacer()
                    if detail.viewerCanUpdate {
                        if pull.state.isOpen {
                            Button {
                                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.comment(pull.repo, pull.number, body: text) }
                                store.close(pull.repo, pull.number)
                                text = ""
                            } label: {
                                Label(text.isEmpty ? "Close pull request" : "Close with comment", systemImage: "xmark.circle")
                                    .foregroundStyle(GH.closed)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        } else if pull.state == .closed {
                            Button("Reopen pull request") { store.reopen(pull.repo, pull.number) }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    Button("Comment") {
                        store.comment(pull.repo, pull.number, body: text)
                        text = ""
                    }
                    .buttonStyle(GHPrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .disabled(busy)
            }
        }
    }
}

/// "Review changes": comment, approve or request changes, as GitHub's review popover does.
struct GHReviewPopover: View {
    @ObservedObject var store: GitHubStore
    var detail: GHPullDetail
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var event: GHReviewEvent = .comment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish your review").font(.system(size: 14, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 110)
                .background(GH.canvasSubtle, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(GHReviewEvent.allCases) { option in
                    let disabled = detail.viewerDidAuthor && option != .comment
                    Button { event = option } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: event == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(event == option ? GH.link : N.text3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(N.text)
                                Text(disabled ? "Pull request authors can’t \(option == .approve ? "approve" : "request changes on") their own pull request."
                                     : option.detail)
                                    .font(.system(size: 12)).foregroundStyle(N.text2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .opacity(disabled ? 0.5 : 1)
                }
            }
            HStack {
                Spacer()
                Button("Submit review") {
                    store.review(detail.summary.repo, detail.summary.number, event: event, body: text)
                    isPresented = false
                }
                .buttonStyle(GHPrimaryButtonStyle())
                .disabled(event != .approve && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}

// MARK: - Sidebar

struct GHPullSidebar: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var agents: AgentStore
    var detail: GHPullDetail
    @State private var reviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if detail.summary.state.isOpen {
                Button { reviewing = true } label: {
                    HStack(spacing: 6) {
                        Text("Review changes")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(GHPrimaryButtonStyle())
                .popover(isPresented: $reviewing, arrowEdge: .bottom) {
                    GHReviewPopover(store: store, detail: detail, isPresented: $reviewing)
                }
                .padding(.bottom, 16)
            }
            item("Reviewers") {
                if detail.reviewers.isEmpty { none("No reviews") }
                ForEach(detail.reviewers, id: \.login) { reviewer in
                    HStack(spacing: 7) {
                        GHAvatar(login: reviewer.login, size: 20)
                        Text(reviewer.login).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(N.text)
                        Spacer()
                        reviewGlyph(reviewer.state)
                    }
                }
            }
            item("Assignees") {
                if detail.assignees.isEmpty { none("No one assigned") }
                ForEach(detail.assignees, id: \.self) { login in
                    HStack(spacing: 7) {
                        GHAvatar(login: login, size: 20)
                        Text(login).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(N.text)
                    }
                }
            }
            item("Labels") {
                if detail.labels.isEmpty { none("None yet") }
                FlowLayout(spacing: 5) { ForEach(detail.labels, id: \.name) { GHLabelPill(label: $0) } }
            }
            item("Checks") {
                HStack(spacing: 10) {
                    if detail.checks.isEmpty { none("No checks") }
                    if detail.checksPassed > 0 { count(.success, detail.checksPassed) }
                    if detail.checksFailed > 0 { count(.failure, detail.checksFailed) }
                    if detail.checksRunning > 0 { count(.pending, detail.checksRunning) }
                }
            }
            GHPullAgents(agents: agents, slug: detail.summary.repo, branch: detail.summary.headRef)
            item("Changes", last: true) {
                HStack(spacing: 8) {
                    Text("\(detail.changedFiles) file\(detail.changedFiles == 1 ? "" : "s")").font(.system(size: 12.5)).foregroundStyle(N.text2)
                    GHDiffStat(additions: detail.additions, deletions: detail.deletions)
                }
            }
        }
    }

    private func count(_ state: CheckState, _ n: Int) -> some View {
        HStack(spacing: 4) {
            CheckGlyph(state: state, size: 11)
            Text("\(n)").font(.system(size: 12.5, weight: .medium)).monospacedDigit().foregroundStyle(N.text)
        }
    }

    @ViewBuilder private func reviewGlyph(_ state: String?) -> some View {
        switch state {
        case "APPROVED": Image(systemName: "checkmark").foregroundStyle(GH.open).help("Approved")
        case "CHANGES_REQUESTED": Image(systemName: "doc.badge.ellipsis").foregroundStyle(GH.closed).help("Requested changes")
        case nil: Circle().fill(GH.attention).frame(width: 8, height: 8).help("Awaiting review")
        default: Image(systemName: "eye").foregroundStyle(N.text2).help("Commented")
        }
    }

    private func none(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(N.text2)
    }

    private func item<Content: View>(_ title: String, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text2)
            content()
            if !last { Rectangle().fill(GH.borderMuted).frame(height: 1).padding(.top, 8) }
        }
        .padding(.bottom, 8)
    }
}

/// Agent sessions that worked on this pull request's branch, and what they've used between them.
struct GHPullAgents: View {
    @ObservedObject var agents: AgentStore
    @ObservedObject private var repos = RepoStore.shared
    var slug: String
    var branch: String

    var body: some View {
        let sessions = AgentLinks.sessions(slug: slug, branch: branch, agents: agents, repos: repos)
        if !sessions.isEmpty {
            let totals = AgentLinks.totals(sessions)
            VStack(alignment: .leading, spacing: 8) {
                Text("Agents").font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text2)
                HStack(spacing: 6) {
                    Text("\(AgentFormat.compact(Double(totals.tokens))) tokens").fontWeight(.semibold).foregroundStyle(N.text)
                    if let cost = totals.cost { Text("· " + AgentFormat.cost(cost, estimated: totals.estimated)).foregroundStyle(N.text2) }
                }
                .font(.system(size: 12.5)).monospacedDigit()
                .help("Across \(sessions.count) session\(sessions.count == 1 ? "" : "s") on \(branch)")
                ForEach(sessions.prefix(5)) { session in
                    Button {
                        if session.process == nil || !AgentActions.jump(to: session) {
                            agents.selectedSessionID = session.id
                            LiveSurfaces.shared.openMain(.agentActivity)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            AgentIconView(agent: session.agent, size: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(N.text).lineLimit(1)
                                Text(session.process != nil ? session.state.title : RepoFormat.ago(session.updatedAt))
                                    .font(.system(size: 11)).foregroundStyle(session.needsAttention ? TagColor.orange.fg : N.text2)
                            }
                            Spacer(minLength: 4)
                            if session.process != nil { Circle().fill(N.green).frame(width: 6, height: 6).help("Running") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(session.process != nil ? "Jump to this session" : "Show in Sessions")
                }
                if sessions.count > 5 {
                    Text("+\(sessions.count - 5) more").font(.system(size: 11.5)).foregroundStyle(N.text3)
                }
                Rectangle().fill(GH.borderMuted).frame(height: 1).padding(.top, 8)
            }
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Commits

struct GHPullCommits: View {
    var slug: String
    var commits: [GHCommit]

    var body: some View {
        let days = Dictionary(grouping: commits) { Calendar.current.startOfDay(for: $0.date ?? .distantPast) }.sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 18) {
            if commits.isEmpty { Text("No commits.").font(NFont.small).foregroundStyle(N.text2) }
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
    }
}

// MARK: - Checks

struct GHChecksList: View {
    var checks: [GHCheck]
    var url: String

    var body: some View {
        let failed = checks.filter { $0.state == .failure }.count
        let running = checks.filter { $0.state == .pending }.count
        let passed = checks.filter { $0.state == .success }.count
        GHBox {
            HStack(spacing: 10) {
                CheckGlyph(state: failed > 0 ? .failure : (running > 0 ? .pending : (passed > 0 ? .success : .none)), size: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(failed > 0 ? "Some checks were not successful" : (running > 0 ? "Some checks haven’t completed yet"
                         : (checks.isEmpty ? "No checks" : "All checks have passed")))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                    Text("\(passed) successful, \(failed) failing, \(running) in progress, \(checks.count - passed - failed - running) skipped")
                        .font(NFont.small).foregroundStyle(N.text2)
                }
                Spacer()
                Button("Open checks on GitHub") { ProcessManager.openURL(url + "/checks") }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } content: {
            VStack(spacing: 0) {
                let sorted = checks.sorted { ($0.state == .failure ? 0 : $0.state == .pending ? 1 : 2, $0.name) < ($1.state == .failure ? 0 : $1.state == .pending ? 1 : 2, $1.name) }
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, check in
                    if index > 0 { Rectangle().fill(GH.borderMuted).frame(height: 1) }
                    GHCheckRow(check: check)
                }
            }
        }
    }
}

struct GHCheckRow: View {
    var check: GHCheck
    var compact = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            CheckGlyph(state: check.state, size: 13)
            HStack(spacing: 4) {
                if let workflow = check.workflow {
                    Text("\(workflow) /").foregroundStyle(N.text2)
                }
                Text(check.name).fontWeight(.semibold).foregroundStyle(N.text)
                Text("— \(check.detail)\(GHFormat.duration(check.duration).map { " in \($0)" } ?? "")").foregroundStyle(N.text2)
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            Spacer(minLength: 8)
            if let url = check.url {
                Button("Details") { ProcessManager.openURL(url) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(GH.link)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: compact ? 38 : 44)
        .background(hover ? GH.canvasSubtle : .clear)
        .onHover { hover = $0 }
    }
}

// MARK: - Files changed

struct GHFilesChanged: View {
    @ObservedObject var store: GitHubStore
    var slug: String
    var number: Int
    var detail: GHPullDetail
    @State private var collapsed: Set<String> = []
    @State private var viewed: Set<String> = []
    @State private var reviewing = false

    var body: some View {
        let files = store.files(slug, number)
        let key = GitHubStore.filesKey(slug, number)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let files {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s") changed").font(.system(size: 13, weight: .semibold)).foregroundStyle(N.text)
                    Text("\(viewed.count) / \(files.count) viewed").font(NFont.small).foregroundStyle(N.text2)
                    Button(collapsed.count == files.count ? "Expand all" : "Collapse all") {
                        collapsed = collapsed.count == files.count ? [] : Set(files.map(\.id))
                    }
                    .buttonStyle(GhostButtonStyle(tint: GH.link))
                }
                Spacer()
                if detail.summary.state.isOpen {
                    Button { reviewing = true } label: {
                        HStack(spacing: 6) { Text("Review changes"); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                    }
                    .buttonStyle(GHPrimaryButtonStyle())
                    .popover(isPresented: $reviewing, arrowEdge: .bottom) {
                        GHReviewPopover(store: store, detail: detail, isPresented: $reviewing)
                    }
                }
            }
            if let error = store.error(key) {
                GHErrorBox(message: error) { store.loadFiles(slug, number, force: true) }
            }
            if files == nil, store.isLoading(key) { GHLoading(text: "Loading the diff…") }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(files ?? []) { file in
                    GHFileDiff(file: file, slug: slug, headRef: detail.summary.headRef,
                               review: GHFileReview(store: store, number: number, commit: detail.commits.last?.oid,
                                                    comments: store.reviewComments(slug, number).filter { $0.path == file.filename }),
                               collapsed: Binding(get: { collapsed.contains(file.id) },
                                                  set: { if $0 { collapsed.insert(file.id) } else { collapsed.remove(file.id) } }),
                               // Marking a file viewed folds it away, as on GitHub.
                               viewed: Binding(get: { viewed.contains(file.id) },
                                               set: { v in
                                                   if v { viewed.insert(file.id); collapsed.insert(file.id) }
                                                   else { viewed.remove(file.id); collapsed.remove(file.id) }
                                               }))
                }
            }
        }
    }
}

struct GHFileDiff: View {
    var file: GHFile
    var slug: String
    var headRef: String
    var review: GHFileReview? = nil
    @Binding var collapsed: Bool
    @Binding var viewed: Bool
    @State private var showAll = false
    @State private var width: CGFloat = 600
    /// Line a new comment is being written under.
    @State private var composing: Int?

    private static let pageSize = 400

    var body: some View {
        GHBox {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy(duration: 0.18)) { collapsed.toggle() } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(N.text2)
                        .rotationEffect(.degrees(collapsed ? 0 : 90)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                GHDiffStat(additions: file.additions, deletions: file.deletions)
                statusIcon
                Group {
                    if let previous = file.previousFilename {
                        Text("\(previous) → \(file.filename)")
                    } else {
                        Text(file.filename)
                    }
                }
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(N.text)
                .lineLimit(1).truncationMode(.head)
                .textSelection(.enabled)
                Button { RepoActions.copy(file.filename) } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(N.text2)
                }
                .buttonStyle(.plain)
                .help("Copy path")
                Spacer(minLength: 8)
                if let count = review?.comments.count, count > 0 {
                    Label("\(count)", systemImage: "bubble.left").font(.system(size: 12)).foregroundStyle(N.text2).labelStyle(TightLabelStyle())
                }
                Toggle(isOn: $viewed) { Text("Viewed").font(.system(size: 12)) }
                    .toggleStyle(.checkbox)
                Button { ProcessManager.openURL("https://github.com/\(slug)/blob/\(headRef)/\(file.filename)") } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 12)).foregroundStyle(N.text2)
                }
                .buttonStyle(.plain)
                .help("View file on GitHub")
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
        } content: {
            let outdated = GHReviewComment.threads(review?.comments ?? []).filter { $0[0].line == nil }
            if !collapsed, !outdated.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(outdated.count) outdated conversation\(outdated.count == 1 ? "" : "s")").font(NFont.caption).foregroundStyle(N.text2)
                    ForEach(outdated, id: \.first!.id) { thread in
                        GHReviewThreadView(thread: thread) { body in review?.reply(slug, thread[0].id, body) }
                    }
                }
                .padding(12)
                .background(GH.canvasSubtle)
            }
            if !collapsed {
                if let patch = file.patch {
                    let lines = GHDiffLine.parse(patch)
                    let shown = showAll ? lines : Array(lines.prefix(Self.pageSize))
                    ScrollView(.horizontal, showsIndicators: false) {
                        // At least as wide as the box, so line colours run to the edge; long lines scroll sideways.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { line in
                                GHDiffLineRow(line: line, onComment: canComment(line) ? { composing = line.id } : nil)
                                ForEach(threads(at: line), id: \.first!.id) { thread in
                                    GHReviewThreadView(thread: thread) { body in review?.reply(slug, thread[0].id, body) }
                                        .frame(width: max(width - 130, 320), alignment: .leading)
                                        .padding(.leading, 112).padding(.vertical, 6)
                                }
                                if composing == line.id {
                                    GHLineComposer(placeholder: "Comment on line \(line.new ?? line.old ?? 0)") { body in
                                        if let body, let target = target(line) {
                                            review?.add(slug, file.filename, target.line, target.side, body)
                                        }
                                        composing = nil
                                    }
                                    .frame(width: max(width - 130, 320), alignment: .leading)
                                    .padding(.leading, 112).padding(.vertical, 6)
                                }
                            }
                        }
                        .frame(minWidth: width, alignment: .leading)
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
                    if lines.count > shown.count {
                        Button("Show \(lines.count - shown.count) more lines") { showAll = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(GH.link)
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .background(GH.hunkBg)
                    }
                } else {
                    Text(file.status == "renamed" ? "File renamed without changes." : "Binary file or a diff too large to show here.")
                        .font(NFont.small).foregroundStyle(N.text2)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                }
            }
        }
    }

    private func canComment(_ line: GHDiffLine) -> Bool {
        review?.commit != nil && line.kind != .hunk && (line.new != nil || line.old != nil)
    }

    /// GitHub anchors a comment to a line on one side: the new file for additions and context, the old for deletions.
    private func target(_ line: GHDiffLine) -> (line: Int, side: String)? {
        if line.kind == .deletion { return line.old.map { ($0, "LEFT") } }
        return line.new.map { ($0, "RIGHT") }
    }

    private func threads(at line: GHDiffLine) -> [[GHReviewComment]] {
        guard let review, let t = target(line) else { return [] }
        return GHReviewComment.threads(review.comments).filter { $0[0].line == t.line && $0[0].side == t.side }
    }

    @ViewBuilder private var statusIcon: some View {
        switch file.status {
        case "added": Image(systemName: "plus.square.fill").foregroundStyle(GH.open).help("Added")
        case "removed": Image(systemName: "minus.square.fill").foregroundStyle(GH.closed).help("Deleted")
        case "renamed": Image(systemName: "arrow.right.square.fill").foregroundStyle(GH.draft).help("Renamed")
        default: Image(systemName: "plusminus").foregroundStyle(GH.attention).font(.system(size: 11, weight: .bold)).help("Modified")
        }
    }
}

struct GHDiffLineRow: View {
    var line: GHDiffLine
    var onComment: (() -> Void)? = nil
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            number(line.old)
            number(line.new)
                .overlay(alignment: .trailing) {
                    if hover, let onComment {
                        Button(action: onComment) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(GH.link, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 10)
                        .help("Comment on this line")
                    }
                }
                .zIndex(1)
            HStack(spacing: 0) {
                Text(marker).frame(width: 18, alignment: .center).foregroundStyle(markerColor)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(line.kind == .hunk ? N.text2 : N.text)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(minHeight: 20)
        .textSelection(.enabled)
        .onHover { hover = $0 }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(N.text3)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 8)
            .frame(maxHeight: .infinity)
            .background(numberBackground)
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "−"
        default: return ""
        }
    }
    private var markerColor: Color { line.kind == .addition ? GH.open : (line.kind == .deletion ? GH.closed : N.text3) }
    private var background: Color {
        switch line.kind {
        case .addition: return GH.addBg
        case .deletion: return GH.delBg
        case .hunk: return GH.hunkBg
        case .context: return .clear
        }
    }
    private var numberBackground: Color {
        switch line.kind {
        case .addition: return GH.addNumBg
        case .deletion: return GH.delNumBg
        case .hunk: return GH.hunkBg
        case .context: return .clear
        }
    }
}


/// What a file's diff needs to show and add line comments.
struct GHFileReview {
    var store: GitHubStore
    var number: Int
    var commit: String?
    var comments: [GHReviewComment]

    @MainActor func add(_ slug: String, _ path: String, _ line: Int, _ side: String, _ body: String) {
        guard let commit else { return }
        store.addReviewComment(slug, number, commit: commit, path: path, line: line, side: side, body: body)
    }

    @MainActor func reply(_ slug: String, _ id: Int, _ body: String) {
        store.replyReviewComment(slug, number, to: id, body: body)
    }
}

/// A review conversation on a line: the comments in order, then a reply box.
struct GHReviewThreadView: View {
    var thread: [GHReviewComment]
    var reply: (String) -> Void
    @State private var replying = false

    var body: some View {
        GHBox {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(thread.enumerated()), id: \.element.id) { index, comment in
                    if index > 0 { Rectangle().fill(GH.borderMuted).frame(height: 1) }
                    HStack(alignment: .top, spacing: 10) {
                        GHAvatar(login: comment.author, size: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text(comment.author).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(N.text)
                                Text(RepoFormat.ago(comment.createdAt)).font(.system(size: 12)).foregroundStyle(N.text2)
                            }
                            GHHTMLView(html: comment.bodyHTML)
                        }
                    }
                    .padding(12)
                }
                Rectangle().fill(GH.borderMuted).frame(height: 1)
                if replying {
                    GHLineComposer(placeholder: "Reply…") { body in
                        if let body { reply(body) }
                        replying = false
                    }
                    .padding(10)
                } else {
                    Button { replying = true } label: {
                        Text("Reply…").font(.system(size: 12.5)).foregroundStyle(N.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).frame(height: 30)
                            .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
            }
        }
        .font(.system(size: 13))
    }
}

/// Text box with Cancel and Comment; calls back with the text, or nil when cancelled.
struct GHLineComposer: View {
    var placeholder: String
    var done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(minHeight: 80)
                    .focused($focused)
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(N.text3).padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(N.bg, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
            HStack(spacing: 8) {
                Button("Cancel") { done(nil) }.buttonStyle(SecondaryButtonStyle())
                Button("Comment") { done(text) }.buttonStyle(GHPrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .font(.system(size: 13))
        .onAppear { focused = true }
    }
}
