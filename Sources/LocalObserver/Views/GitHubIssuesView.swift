import SwiftUI
import LocalObserverRepos

extension GHIssueState {
    var symbol: String {
        switch self {
        case .open: return "smallcircle.filled.circle"
        case .completed: return "checkmark.circle"
        case .notPlanned: return "slash.circle"
        }
    }
    var color: Color {
        switch self {
        case .open: return GH.openButton
        case .completed: return GH.merged
        case .notPlanned: return GH.draft
        }
    }
    var tint: Color { self == .open ? GH.open : color }
}

// MARK: - Issues tab

struct GHIssuesTab: View {
    @ObservedObject var store: GitHubStore
    var slug: String
    @State private var showOpen = true
    @State private var composing = false
    @State private var newTitle = ""
    @State private var newBody = ""

    var body: some View {
        let open = store.openIssues[slug] ?? []
        let closed = store.closedIssues[slug] ?? []
        let q = store.query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = (showOpen ? open : closed).filter {
            q.isEmpty || $0.title.lowercased().contains(q) || "#\($0.number)".contains(q) || $0.author.lowercased().contains(q)
                || $0.labels.contains { $0.name.lowercased().contains(q) }
        }
        let key = GitHubStore.issuesKey(slug, open: showOpen)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Button("New issue") { withAnimation(.snappy(duration: 0.2)) { composing.toggle() } }.buttonStyle(GHPrimaryButtonStyle())
            }
            if composing { composer }
            if let error = store.error(key) { GHErrorBox(message: error) { store.loadIssues(slug, open: showOpen, force: true) } }
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
                    if store.isLoading(key) { GHLoading() } else {
                        VStack(spacing: 8) {
                            Image(systemName: "smallcircle.filled.circle").font(.system(size: 26, weight: .light)).foregroundStyle(N.text3)
                            Text(showOpen ? "No open issues." : "No closed issues.").font(.system(size: 15, weight: .semibold)).foregroundStyle(N.text)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 44)
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, issue in
                            if index > 0 { Rectangle().fill(GH.borderMuted).frame(height: 1) }
                            GHIssueRow(issue: issue) { store.open(.issue(slug, issue.number)) }
                        }
                    }
                }
            }
        }
        .task(id: slug) {
            store.loadIssues(slug, open: true)
            store.loadIssues(slug, open: false)
        }
    }

    private var composer: some View {
        GHBox {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder).font(.system(size: 14))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $newBody).font(.system(size: 13.5)).scrollContentBackground(.hidden).padding(6).frame(minHeight: 110)
                    if newBody.isEmpty {
                        Text("Describe it… Markdown works.").font(.system(size: 13.5)).foregroundStyle(N.text3)
                            .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
                .background(GH.canvasSubtle, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
                HStack {
                    Spacer()
                    Button("Cancel") { composing = false }.buttonStyle(SecondaryButtonStyle())
                    Button("Submit new issue") {
                        store.createIssue(slug, title: newTitle, body: newBody)
                        newTitle = ""; newBody = ""; composing = false
                    }
                    .buttonStyle(GHPrimaryButtonStyle())
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func toggle(open: Bool, count: Int) -> some View {
        Button { showOpen = open } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "smallcircle.filled.circle" : "checkmark").font(.system(size: 12, weight: .semibold))
                Text("\(count) \(open ? "Open" : "Closed")")
            }
            .font(.system(size: 13.5, weight: showOpen == open ? .semibold : .regular))
            .foregroundStyle(showOpen == open ? N.text : N.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct GHIssueRow: View {
    var issue: GHIssueSummary
    var showRepo = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.state.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(issue.state.tint)
                .frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if showRepo { Text(issue.repo).font(.system(size: 14)).foregroundStyle(N.text2) }
                    Text(issue.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(hover ? GH.link : N.text).lineLimit(2)
                    ForEach(issue.labels.prefix(4), id: \.name) { GHLabelPill(label: $0) }
                }
                Text(issue.state.isOpen ? "#\(issue.number) opened \(RepoFormat.ago(issue.createdAt)) by \(issue.author)"
                     : "#\(issue.number) by \(issue.author) was closed \(RepoFormat.ago(issue.updatedAt))")
                    .font(.system(size: 12)).foregroundStyle(N.text2)
            }
            Spacer(minLength: 10)
            HStack(spacing: -6) { ForEach(issue.assignees.prefix(3), id: \.self) { GHAvatar(login: $0, size: 20) } }
            if issue.comments > 0 {
                Label("\(issue.comments)", systemImage: "bubble.left").font(.system(size: 12)).foregroundStyle(N.text2).labelStyle(TightLabelStyle())
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
            Button("Open on GitHub") { ProcessManager.openURL(issue.url) }
            Button("Copy URL") { RepoActions.copy(issue.url) }
        }
    }
}

// MARK: - Issue page

struct GHIssueView: View {
    @ObservedObject var store: GitHubStore
    var slug: String
    var number: Int
    @State private var text = ""
    @ObservedObject private var repos = RepoStore.shared

    var body: some View {
        GHScaffold(store: store, maxWidth: 1080) { width in
            VStack(alignment: .leading, spacing: 18) {
                if let detail = store.issue(slug, number) {
                    header(detail)
                    Rectangle().fill(GH.borderMuted).frame(height: 1)
                    if width > 860 {
                        HStack(alignment: .top, spacing: 28) {
                            thread(detail).frame(maxWidth: .infinity)
                            sidebar(detail).frame(width: 230)
                        }
                    } else {
                        sidebar(detail)
                        thread(detail)
                    }
                } else if let error = store.error(GitHubStore.issueKey(slug, number)) {
                    GHErrorBox(message: error) { store.loadIssue(slug, number, force: true) }
                } else {
                    GHLoading(text: "Loading #\(number)…")
                }
            }
        }
        .task(id: "\(slug)#\(number)") { store.loadIssue(slug, number) }
    }

    private func header(_ detail: GHIssueDetail) -> some View {
        let issue = detail.summary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                (Text(issue.title).foregroundStyle(N.text) + Text("  #\(issue.number)").foregroundStyle(N.text3))
                    .font(.system(size: 26)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button { ProcessManager.openURL(issue.url) } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                    .buttonStyle(SecondaryButtonStyle()).fixedSize()
            }
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: issue.state.symbol).font(.system(size: 12, weight: .semibold))
                    Text(issue.state.title).font(.system(size: 13.5, weight: .medium))
                }
                .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 30).background(issue.state.color, in: Capsule())
                Text(issue.author).fontWeight(.semibold).foregroundStyle(N.text)
                Text("opened this issue \(RepoFormat.ago(issue.createdAt)) · \(issue.comments) comment\(issue.comments == 1 ? "" : "s")")
                    .foregroundStyle(N.text2)
            }
            .font(.system(size: 13.5))
        }
    }

    private func thread(_ detail: GHIssueDetail) -> some View {
        let issue = detail.summary
        let busy = store.working.contains(GitHubStore.issueKey(slug, number))
        return VStack(alignment: .leading, spacing: 18) {
            GHCommentBox(author: issue.author, avatar: detail.authorAvatar, date: issue.createdAt, html: detail.bodyHTML,
                         isAuthor: true, empty: "No description provided.")
            ForEach(detail.timeline) { item in
                GHCommentBox(author: item.author, avatar: item.avatarURL, date: item.date, html: item.bodyHTML, isAuthor: item.author == issue.author)
            }
            Rectangle().fill(GH.borderMuted).frame(height: 2)
            HStack(alignment: .top, spacing: 14) {
                GHAvatar(login: repos.gitHub.login ?? "you", size: 40)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add a comment").font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                    TextEditor(text: $text).font(.system(size: 13.5)).scrollContentBackground(.hidden).padding(8).frame(minHeight: 110)
                        .background(GH.canvasSubtle, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
                    HStack(spacing: 8) {
                        Spacer()
                        if detail.viewerCanUpdate {
                            if issue.state.isOpen {
                                Menu {
                                    Button("Close as completed") { closeWithComment(notPlanned: false) }
                                    Button("Close as not planned") { closeWithComment(notPlanned: true) }
                                } label: {
                                    Label(text.isEmpty ? "Close issue" : "Close with comment", systemImage: "checkmark.circle")
                                        .font(.system(size: 13, weight: .medium)).foregroundStyle(GH.merged)
                                        .padding(.horizontal, 10).frame(height: 28)
                                        .overlay(RoundedRectangle(cornerRadius: N.radius, style: .continuous).strokeBorder(N.divider))
                                }
                                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                            } else {
                                Button("Reopen issue") { store.reopenIssue(slug, number) }.buttonStyle(SecondaryButtonStyle())
                            }
                        }
                        Button("Comment") { store.commentIssue(slug, number, body: text); text = "" }
                            .buttonStyle(GHPrimaryButtonStyle())
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                    .disabled(busy)
                }
            }
        }
    }

    private func closeWithComment(notPlanned: Bool) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.commentIssue(slug, number, body: text) }
        store.closeIssue(slug, number, notPlanned: notPlanned)
        text = ""
    }

    private func sidebar(_ detail: GHIssueDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Assignees").font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text2)
                if detail.summary.assignees.isEmpty { Text("No one assigned").font(.system(size: 12.5)).foregroundStyle(N.text2) }
                ForEach(detail.summary.assignees, id: \.self) { login in
                    HStack(spacing: 7) { GHAvatar(login: login, size: 20); Text(login).font(.system(size: 12.5, weight: .semibold)) }
                }
            }
            Rectangle().fill(GH.borderMuted).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("Labels").font(.system(size: 12, weight: .semibold)).foregroundStyle(N.text2)
                if detail.summary.labels.isEmpty { Text("None yet").font(.system(size: 12.5)).foregroundStyle(N.text2) }
                FlowLayout(spacing: 5) { ForEach(detail.summary.labels, id: \.name) { GHLabelPill(label: $0) } }
            }
            Rectangle().fill(GH.borderMuted).frame(height: 1)
            Button {
                RepoActions.copy("Fix \(detail.summary.url): \(detail.summary.title)")
            } label: { Label("Copy as a task for an agent", systemImage: "sparkles") }
                .buttonStyle(GhostButtonStyle(tint: N.blue))
                .help("The issue's title and link, ready to paste into an agent")
        }
    }
}

// MARK: - Inbox

/// GitHub notifications: what's addressed to you first, then everything you watch. Opening one marks it read and
/// shows the pull request or issue in Lookout.
struct InboxPage: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore
    @State private var width: CGFloat = 900

    var body: some View {
        let q = store.query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = store.notifications.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.repo.lowercased().contains(q) }
        let direct = list.filter(\.isDirect)
        let rest = list.filter { !$0.isDirect }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: SidebarItem.inbox.symbol, title: SidebarItem.inbox.title, subtitle: AnyView(summary))
                GitHubStatusBanner(store: repos)
                if let error = store.error(GitHubStore.notificationsKey) {
                    GHErrorBox(message: error) { store.loadNotifications(force: true) }.padding(.bottom, 10)
                }
                HStack(spacing: 10) {
                    Toggle("Include read from the last week", isOn: $store.showReadNotifications).toggleStyle(.checkbox).font(NFont.small)
                    Spacer()
                    Button("Mark all as read") { store.markAllRead() }.buttonStyle(SecondaryButtonStyle())
                        .disabled(store.unreadNotifications == 0)
                }
                .padding(.bottom, 6)
                if list.isEmpty {
                    if store.isLoading(GitHubStore.notificationsKey) { GHLoading(text: "Checking your inbox…") }
                    else {
                        EmptyStateView(symbol: "tray", title: "Inbox zero", message: "Nothing new on GitHub.") { EmptyView() }
                    }
                } else {
                    if !direct.isEmpty { group("For you", direct) }
                    if !rest.isEmpty { group("Watching", rest) }
                }
            }
            .padding(.horizontal, width > 1100 ? 64 : (width > 800 ? 44 : 24))
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .onAppear { store.loadNotifications() }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            Label("\(store.unreadNotifications) unread", systemImage: "envelope.badge")
            let direct = store.notifications.filter { $0.unread && $0.isDirect }.count
            if direct > 0 { Label("\(direct) for you", systemImage: "at").foregroundStyle(TagColor.orange.fg) }
            RelativeTimeText(date: store.lastNotifications)
        }
        .font(NFont.small).foregroundStyle(N.text2).labelStyle(TightLabelStyle())
    }

    private func group(_ title: String, _ list: [GHNotification]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(N.text)
                Text("\(list.count)").font(NFont.small).foregroundStyle(N.text3)
            }
            .padding(.top, 18).padding(.bottom, 6)
            Rectangle().fill(N.divider).frame(height: 1)
            LazyVStack(spacing: 1) { ForEach(list) { InboxRow(store: store, notification: $0) } }.padding(.top, 2)
        }
    }
}

struct InboxRow: View {
    @ObservedObject var store: GitHubStore
    var notification: GHNotification
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(notification.unread ? N.blue : .clear).frame(width: 7, height: 7)
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title).font(notification.unread ? NFont.bodyMedium : NFont.body)
                    .foregroundStyle(notification.unread ? N.text : N.text2).lineLimit(1)
                Text("\(notification.repo)\(notification.number.map { " #\($0)" } ?? "")").font(NFont.caption).foregroundStyle(N.text2)
            }
            Spacer(minLength: 8)
            Tag(text: notification.reasonTitle, color: notification.isDirect ? .orange : .gray)
            Text(RepoFormat.ago(notification.updatedAt)).font(NFont.small).foregroundStyle(N.text2).frame(width: 64, alignment: .trailing)
            if hover, notification.unread {
                IconButton(symbol: "checkmark", help: "Mark as read") { store.markRead(notification) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if store.open(notification) { LiveSurfaces.shared.openMain(.github) } else { ProcessManager.openURL(notification.webURL) }
        }
        .contextMenu {
            Button("Open on GitHub") { store.markRead(notification); ProcessManager.openURL(notification.webURL) }
            if notification.unread { Button("Mark as Read") { store.markRead(notification) } }
        }
    }

    private var symbol: String {
        switch notification.kind {
        case .pullRequest: return "arrow.triangle.pull"
        case .issue: return "smallcircle.filled.circle"
        case .release: return "tag"
        case .discussion: return "bubble.left.and.bubble.right"
        case .checkSuite: return "checklist"
        case .commit: return "smallcircle.circle"
        case .other: return "bell"
        }
    }
    private var tint: Color {
        switch notification.kind {
        case .pullRequest, .issue: return GH.open
        case .checkSuite: return GH.closed
        default: return N.text2
        }
    }
}
