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
