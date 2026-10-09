import SwiftUI
import LocalObserverRepos
import LocalObserverCore

// MARK: - Conversation

/// A pull request's Conversation tab, Lookout-style: whether it can merge up top, the agents working on its branch,
/// then one activity feed where GitHub's comments, reviews and pushes sit beside the agent sessions behind them.
struct GHConversation: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore
    @ObservedObject var agents: AgentStore
    var detail: GHPullDetail
    var width: CGFloat

    private var pull: GHPullSummary { detail.summary }
    private var sessions: [AgentSession] {
        AgentLinks.sessions(slug: pull.repo, branch: pull.headRef, agents: agents, repos: repos)
    }

    var body: some View {
        let sessions = sessions
        if width > 900 {
            HStack(alignment: .top, spacing: 32) {
                main(sessions).frame(maxWidth: .infinity)
                GHPullSidebar(store: store, agents: agents, detail: detail).frame(width: 240)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                main(sessions)
                GHPullSidebar(store: store, agents: agents, detail: detail)
            }
        }
    }

    private func main(_ sessions: [AgentSession]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            GHMergeBox(store: store, detail: detail)
            if !sessions.isEmpty { GHPullAgentsCard(agents: agents, sessions: sessions, branch: pull.headRef) }
            GHActivityFeed(agents: agents, detail: detail, sessions: sessions)
            GHCommentComposer(store: store, detail: detail)
        }
    }
}

// MARK: - Activity feed

/// One thing that happened on a pull request, from GitHub or from an agent on this Mac.
private enum GHFeedEntry: Identifiable {
    case comment(GHTimelineItem)
    case review(GHTimelineItem, String)
    case commits([GHCommit])
    case agent(AgentSession)

    var id: String {
        switch self {
        case .comment(let item), .review(let item, _): return item.id
        case .commits(let list): return "commits-" + (list.first?.oid ?? "")
        case .agent(let session): return "agent-" + session.id
        }
    }

    var date: Date {
        switch self {
        case .comment(let item), .review(let item, _): return item.date ?? .distantPast
        case .commits(let list): return list.first?.date ?? .distantPast
        case .agent(let session): return session.startedAt
        }
    }

    /// GitHub's events and agent sessions in time order, with back-to-back pushes folded into one entry.
    static func build(_ detail: GHPullDetail, _ sessions: [AgentSession]) -> [GHFeedEntry] {
        var raw: [(Date, GHFeedEntry?, GHCommit?)] = []
        for item in detail.timeline {
            switch item.kind {
            case .comment: raw.append((item.date ?? .distantPast, .comment(item), nil))
            case .review(let state): raw.append((item.date ?? .distantPast, .review(item, state), nil))
            }
        }
        for commit in detail.commits { raw.append((commit.date ?? .distantPast, nil, commit)) }
        for session in sessions { raw.append((session.startedAt, .agent(session), nil)) }
        raw.sort { $0.0 < $1.0 }

        var entries: [GHFeedEntry] = []
        var run: [GHCommit] = []
        func flush() { if !run.isEmpty { entries.append(.commits(run)); run = [] } }
        for (_, entry, commit) in raw {
            if let commit { run.append(commit); continue }
            flush()
            if let entry { entries.append(entry) }
        }
        flush()
        return entries
    }
}

struct GHActivityFeed: View {
    var agents: AgentStore
    var detail: GHPullDetail
    var sessions: [AgentSession]

    private var pull: GHPullSummary { detail.summary }

    var body: some View {
        let entries = GHFeedEntry.build(detail, sessions)
        VStack(alignment: .leading, spacing: 0) {
            GHFeedRow(last: entries.isEmpty) {
                GHAvatar(login: pull.author, size: 24, url: detail.authorAvatar)
            } header: {
                GHFeedHeader(actor: pull.author, action: "opened this pull request", date: pull.createdAt)
            } content: {
                GHFeedCard(html: detail.bodyHTML, empty: "No description provided.")
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(entry, last: index == entries.count - 1)
            }
        }
    }

    @ViewBuilder private func row(_ entry: GHFeedEntry, last: Bool) -> some View {
        switch entry {
        case .comment(let item):
            GHFeedRow(last: last) {
                GHAvatar(login: item.author, size: 24, url: item.avatarURL)
            } header: {
                GHFeedHeader(actor: item.author, action: "commented", date: item.date, author: item.author == pull.author)
            } content: {
                GHFeedCard(html: item.bodyHTML)
            }
        case .review(let item, let state):
            let style = GHReviewStyle(state)
            GHFeedRow(last: last) {
                GHFeedGlyph(symbol: style.symbol, tint: style.tint)
            } header: {
                GHFeedHeader(actor: item.author, action: style.verb, date: item.date, author: item.author == pull.author)
            } content: {
                if !item.bodyHTML.isEmpty { GHFeedCard(html: item.bodyHTML) }
            }
        case .commits(let list):
            GHFeedRow(last: last) {
                GHFeedGlyph(symbol: "arrow.up", tint: N.text2)
            } header: {
                GHFeedHeader(actor: Self.pusher(list), action: "pushed \(list.count) commit\(list.count == 1 ? "" : "s")",
                             date: list.last?.date)
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { commit in GHFeedCommit(slug: pull.repo, commit: commit) }
                }
            }
        case .agent(let session):
            GHFeedRow(last: last) {
                ZStack {
                    Circle().fill(N.bgSoft)
                    AgentIconView(agent: session.agent, size: 14)
                }
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(N.divider))
            } header: {
                GHFeedHeader(actor: session.agent.name, action: session.process != nil ? "is working on this branch" : "worked on this branch",
                             date: session.startedAt)
            } content: {
                GHFeedSession(agents: agents, session: session)
            }
        }
    }

    private static func pusher(_ list: [GHCommit]) -> String {
        let authors = Set(list.map(\.author))
        return authors.count == 1 ? (authors.first ?? "") : "\(authors.count) people"
    }
}

/// A feed entry: an icon on the rail, a one-line header beside it, anything else underneath.
private struct GHFeedRow<Icon: View, Header: View, Content: View>: View {
    var last: Bool
    @ViewBuilder var icon: Icon
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 8) {
                header.frame(minHeight: 24)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, last ? 0 : 20)
        }
        // The rail runs from under this icon to the next one.
        .background(alignment: .topLeading) {
            if !last {
                Rectangle().fill(N.divider).frame(width: 1).padding(.top, 28).padding(.leading, 11.5)
            }
        }
    }
}

private struct GHFeedHeader: View {
    var actor: String
    var action: String
    var date: Date?
    var author = false

    var body: some View {
        HStack(spacing: 6) {
            (Text(actor).fontWeight(.semibold).foregroundStyle(N.text) + Text(" \(action)").foregroundStyle(N.text2))
                .lineLimit(1)
            if author { GHVisibilityBadge(text: "Author") }
            Text(RepoFormat.ago(date)).foregroundStyle(N.text3)
                .help(date?.formatted(date: .abbreviated, time: .shortened) ?? "")
        }
        .font(.system(size: 13))
    }
}

/// A small tinted glyph on the rail, for events without a person's face.
private struct GHFeedGlyph: View {
    var symbol: String
    var tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.14))
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).foregroundStyle(tint)
        }
        .frame(width: 24, height: 24)
    }
}

/// Rendered Markdown on a soft card: a comment, review or description body.
private struct GHFeedCard: View {
    var html: String
    var empty: String? = nil

    var body: some View {
        Group {
            if html.isEmpty, let empty {
                Text(empty).font(.system(size: 13)).italic().foregroundStyle(N.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                GHHTMLView(html: html)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(N.divider))
    }
}

private struct GHFeedCommit: View {
    var slug: String
    var commit: GHCommit
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if commit.checks != .none { CheckGlyph(state: commit.checks, size: 11) }
                else { Image(systemName: "smallcircle.filled.circle").font(.system(size: 10)).foregroundStyle(N.text3) }
            }
            .frame(width: 14)
            Text(commit.headline).font(.system(size: 13)).foregroundStyle(N.text).lineLimit(1)
            Spacer(minLength: 8)
            Button { RepoActions.copy(commit.oid) } label: {
                Text(commit.short).font(NFont.monoSmall).foregroundStyle(hover ? N.text : N.text3)
            }
            .buttonStyle(.plain)
            .help("Copy the full SHA")
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open on GitHub") { ProcessManager.openURL("https://github.com/\(slug)/commit/\(commit.oid)") }
            Button("Copy SHA") { RepoActions.copy(commit.oid) }
        }
    }
}

/// An agent session in the feed: what it was asked, how far it got and what it used.
private struct GHFeedSession: View {
    var agents: AgentStore
    var session: AgentSession

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).foregroundStyle(N.text).lineLimit(1)
                    Text(GHAgentFormat.facts(session)).font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(N.text3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(N.divider))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.process != nil ? "Jump to this session" : "Show in Sessions")
    }

    private func open() { GHAgentFormat.open(session, in: agents) }
}

private struct GHReviewStyle {
    var verb: String
    var symbol: String
    var tint: Color

    init(_ state: String) {
        switch state {
        case "APPROVED": (verb, symbol, tint) = ("approved these changes", "checkmark", GH.open)
        case "CHANGES_REQUESTED": (verb, symbol, tint) = ("requested changes", "exclamationmark", GH.closed)
        case "DISMISSED": (verb, symbol, tint) = ("had a review dismissed", "minus", GH.draft)
        default: (verb, symbol, tint) = ("reviewed", "eye", N.text2)
        }
    }
}

enum GHAgentFormat {
    /// "claude-sonnet-4-5 · 1.2M tokens · $0.84 · 48m".
    static func facts(_ session: AgentSession) -> String {
        var parts: [String] = []
        if !session.model.isEmpty { parts.append(session.model) }
        if let tokens = session.usage?.processedTokens, tokens > 0 { parts.append("\(AgentFormat.compact(Double(tokens))) tokens") }
        if let cost = session.cost { parts.append(AgentFormat.cost(cost, estimated: session.costIsEstimated)) }
        parts.append(span(session.updatedAt.timeIntervalSince(session.startedAt)))
        return parts.joined(separator: " · ")
    }

    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 1)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    @MainActor static func open(_ session: AgentSession, in agents: AgentStore) {
        if session.process == nil || !AgentActions.jump(to: session) {
            agents.selectedSessionID = session.id
            LiveSurfaces.shared.openMain(.agentActivity)
        }
    }
}

// MARK: - Agents on this branch

/// The agents behind a pull request, live ones first, with what the branch has cost so far.
struct GHPullAgentsCard: View {
    @ObservedObject var agents: AgentStore
    var sessions: [AgentSession]
    var branch: String

    var body: some View {
        let totals = AgentLinks.totals(sessions)
        let live = sessions.filter { $0.process != nil }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 11.5)).foregroundStyle(N.text2)
                Text("Agents on this branch").font(.system(size: 13, weight: .semibold)).foregroundStyle(N.text)
                if !live.isEmpty {
                    Text("\(live.count) running").font(NFont.caption).foregroundStyle(TagColor.green.fg)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("\(AgentFormat.compact(Double(totals.tokens))) tokens")
                    if let cost = totals.cost { Text("· " + AgentFormat.cost(cost, estimated: totals.estimated)) }
                    Text("· \(sessions.count) session\(sessions.count == 1 ? "" : "s")")
                }
                .font(NFont.caption).monospacedDigit().foregroundStyle(N.text2)
                .help("What every session on \(branch) has used so far")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            ForEach(Array((live.isEmpty ? Array(sessions.prefix(1)) : live).prefix(4))) { session in
                Rectangle().fill(N.divider).frame(height: 1)
                row(session)
            }
        }
        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(N.divider))
    }

    private func row(_ session: AgentSession) -> some View {
        HStack(spacing: 10) {
            AgentIconView(agent: session.agent, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.system(size: 13, weight: .medium)).foregroundStyle(N.text).lineLimit(1)
                Text(session.process != nil ? GHAgentFormat.facts(session) : "Last active \(RepoFormat.ago(session.updatedAt)) · " + GHAgentFormat.facts(session))
                    .font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
            }
            Spacer(minLength: 8)
            if session.process != nil {
                AgentStateTag(state: session.state)
                Button("Jump") { GHAgentFormat.open(session, in: agents) }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Open") { GHAgentFormat.open(session, in: agents) }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Merge readiness

/// Whether the pull request can merge, as one strip: review, checks and conflicts side by side, the merge button
/// underneath. Merged and closed pull requests collapse to a single line.
struct GHMergeBox: View {
    @ObservedObject var store: GitHubStore
    var detail: GHPullDetail
    @State private var method: GHMergeMethod?
    @State private var confirming = false
    @State private var showChecks = false

    private var pull: GHPullSummary { detail.summary }
    private var busy: Bool { store.working.contains(GitHubStore.pullKey(pull.repo, pull.number)) }

    private var canMergeCleanly: Bool {
        detail.mergeable == true && detail.checksFailed == 0 && pull.review != .changesRequested
            && ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(detail.mergeState)
    }

    var body: some View {
        switch pull.state {
        case .merged:
            banner("arrow.triangle.merge", GH.merged, "Merged \(RepoFormat.ago(detail.mergedAt))",
                   "The \(pull.headRef) branch can be safely deleted.") {
                if detail.viewerCanUpdate {
                    Button("Delete branch") { store.deleteBranch(pull.repo, pull.headRef) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        case .closed:
            banner("xmark", GH.closed, "Closed with unmerged commits", "Closed \(RepoFormat.ago(detail.closedAt)).") {
                if detail.viewerCanUpdate {
                    Button("Reopen") { store.reopen(pull.repo, pull.number) }.buttonStyle(SecondaryButtonStyle()).disabled(busy)
                }
            }
        case .open, .draft:
            card {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        reviewCell
                        Rectangle().fill(N.divider).frame(width: 1)
                        checksCell
                        Rectangle().fill(N.divider).frame(width: 1)
                        conflictCell
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if showChecks {
                        VStack(spacing: 0) {
                            ForEach(detail.checks.sorted { order($0.state) < order($1.state) }) { check in
                                Rectangle().fill(N.divider).frame(height: 1)
                                GHCheckRow(check: check, compact: true)
                            }
                        }
                        .background(N.bg)
                    }
                    Rectangle().fill(N.divider).frame(height: 1)
                    footer
                }
            }
        }
    }

    // MARK: Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(N.bgSoft)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(N.divider))
    }

    private func banner<Trailing: View>(_ symbol: String, _ tint: Color, _ title: String, _ detail: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        card {
            HStack(spacing: 12) {
                GHReadinessGlyph(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(N.text)
                    Text(detail).font(NFont.caption).foregroundStyle(N.text2)
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func cell<Trailing: View>(_ symbol: String, _ tint: Color, _ title: String, _ detail: String,
                                      @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                GHReadinessGlyph(symbol: symbol, tint: tint)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(N.text).lineLimit(1)
            }
            Text(detail).font(NFont.caption).foregroundStyle(N.text2)
                .fixedSize(horizontal: false, vertical: true)
            trailing()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var reviewCell: some View {
        let approvals = detail.reviewers.filter { $0.state == "APPROVED" }
        let pending = detail.reviewers.filter { $0.state == nil }.map(\.login)
        let waiting = pending.isEmpty ? "" : "Waiting on \(pending.joined(separator: ", "))"
        switch pull.review {
        case .approved:
            cell("checkmark", GH.open, "Approved",
                 ([approvals.map(\.login).joined(separator: ", ")] + (waiting.isEmpty ? [] : [waiting])).joined(separator: " · "))
        case .changesRequested:
            cell("exclamationmark", GH.closed, "Changes requested",
                 "By " + detail.reviewers.filter { $0.state == "CHANGES_REQUESTED" }.map(\.login).joined(separator: ", "))
        case .required:
            cell("eye", GH.attention, "Review required", waiting.isEmpty ? "Needs an approving review." : waiting)
        case .none:
            cell("eye", N.text2, approvals.isEmpty ? "No reviews" : "Approved",
                 waiting.isEmpty ? "Reviews aren’t required." : "Requested from \(pending.joined(separator: ", "))")
        }
    }

    @ViewBuilder private var checksCell: some View {
        let failed = detail.checksFailed, running = detail.checksRunning, passed = detail.checksPassed
        let other = detail.checks.count - failed - running - passed
        let summary = [failed > 0 ? "\(failed) failing" : nil, running > 0 ? "\(running) running" : nil,
                       passed > 0 ? "\(passed) passed" : nil, other > 0 ? "\(other) skipped" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        if detail.checks.isEmpty {
            cell("circle.dashed", N.text2, "No checks", "Nothing ran on the latest commit.")
        } else if failed > 0 {
            cell("xmark", GH.closed, "Checks failing", summary) { checksToggle }
        } else if running > 0 {
            cell("circle.dotted", GH.attention, "Checks running", summary) { checksToggle }
        } else {
            cell("checkmark", GH.open, "Checks passed", summary) { checksToggle }
        }
    }

    @ViewBuilder private var conflictCell: some View {
        switch (detail.mergeable, detail.mergeState) {
        case (false, _), (_, "DIRTY"):
            cell("exclamationmark", GH.closed, "Conflicts", "Resolve them on GitHub or locally, then push.") {
                link("Resolve conflicts") { ProcessManager.openURL(pull.url + "/conflicts") }
            }
        case (_, "BEHIND"):
            cell("arrow.down", GH.attention, "Behind \(pull.baseRef)", "Bring in the latest from \(pull.baseRef) first.") {
                link("Update branch") { ProcessManager.openURL(pull.url) }
            }
        case (nil, _):
            cell("circle.dotted", GH.attention, "Checking…", "GitHub is still working out whether this merges cleanly.")
        default:
            cell("checkmark", GH.open, "No conflicts", "Merges cleanly into \(pull.baseRef).")
        }
    }

    private var checksToggle: some View {
        link(showChecks ? "Hide checks" : "Show checks") { withAnimation(.snappy(duration: 0.2)) { showChecks.toggle() } }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(GH.link)
    }

    private func order(_ state: CheckState) -> Int {
        switch state {
        case .failure: return 0
        case .pending: return 1
        case .success: return 2
        case .none: return 3
        }
    }

    @ViewBuilder private var footer: some View {
        let chosen = method ?? (detail.mergeMethods.contains(detail.defaultMergeMethod) ? detail.defaultMergeMethod : detail.mergeMethods.first ?? .merge)
        HStack(spacing: 10) {
            if pull.state == .draft {
                Image(systemName: "circle.dashed").font(.system(size: 12, weight: .semibold)).foregroundStyle(GH.draft)
                Text("Draft pull requests can’t be merged.").font(NFont.small).foregroundStyle(N.text2)
                Spacer(minLength: 8)
                Button("Ready for review") { store.markReady(pull.repo, pull.number) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!detail.viewerCanUpdate || busy)
            } else if confirming {
                Text(chosen.detail).font(NFont.small).foregroundStyle(N.text2).lineLimit(2)
                Spacer(minLength: 8)
                Button("Cancel") { confirming = false }.buttonStyle(SecondaryButtonStyle())
                Button("Confirm \(chosen.button.lowercased())") {
                    confirming = false
                    store.merge(pull.repo, pull.number, method: chosen)
                }
                .buttonStyle(GHPrimaryButtonStyle(tint: GH.openButton))
            } else {
                if busy { ProgressView().controlSize(.small) }
                if !detail.viewerCanUpdate {
                    Text("Only people with write access can merge.").font(NFont.small).foregroundStyle(N.text2)
                } else if !canMergeCleanly && detail.mergeable != false {
                    Text("Branch rules on GitHub may still block this.").font(NFont.small).foregroundStyle(N.text2)
                } else if canMergeCleanly {
                    Text("Ready to merge.").font(NFont.small).foregroundStyle(N.text2)
                }
                Spacer(minLength: 8)
                mergeButton(chosen)
                    .disabled(!detail.viewerCanUpdate || busy || detail.mergeable == false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func mergeButton(_ chosen: GHMergeMethod) -> some View {
        let tint = canMergeCleanly ? GH.openButton : GH.draft
        return HStack(spacing: 0) {
            Button(chosen.button) { confirming = true }
                .buttonStyle(GHPrimaryButtonStyle(tint: tint))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: GH.radius, bottomLeadingRadius: GH.radius))
            Rectangle().fill(Color.black.opacity(0.18)).frame(width: 1, height: 28)
            Menu {
                ForEach(detail.mergeMethods) { m in
                    Button { method = m } label: {
                        if m == chosen { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 28)
                    .background(tint, in: UnevenRoundedRectangle(bottomTrailingRadius: GH.radius, topTrailingRadius: GH.radius))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct GHReadinessGlyph: View {
    var symbol: String
    var tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(tint)
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Composer

/// "Leave a comment": one bordered field with its actions inside, as Lookout's other inputs.
struct GHCommentComposer: View {
    @ObservedObject var store: GitHubStore
    var detail: GHPullDetail
    @State private var text = ""

    private var pull: GHPullSummary { detail.summary }
    private var busy: Bool { store.working.contains(GitHubStore.pullKey(pull.repo, pull.number)) }
    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        GHComposerField(text: $text, placeholder: "Leave a comment… Markdown works.") {
            if detail.viewerCanUpdate {
                if pull.state.isOpen {
                    Button {
                        if !empty { store.comment(pull.repo, pull.number, body: text) }
                        store.close(pull.repo, pull.number)
                        text = ""
                    } label: {
                        Text(empty ? "Close pull request" : "Close with comment").foregroundStyle(GH.closed)
                    }
                    .buttonStyle(GhostButtonStyle())
                } else if pull.state == .closed {
                    Button("Reopen pull request") { store.reopen(pull.repo, pull.number) }.buttonStyle(GhostButtonStyle())
                }
            }
            Button("Comment") {
                store.comment(pull.repo, pull.number, body: text)
                text = ""
            }
            .buttonStyle(GHPrimaryButtonStyle())
            .disabled(empty || busy)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .disabled(busy)
    }
}

/// A multi-line Markdown field with its buttons along the bottom edge, shared by pull requests and issues.
struct GHComposerField<Actions: View>: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 76
    @ViewBuilder var actions: Actions
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 9)
                    .padding(.top, 9)
                    .frame(minHeight: minHeight)
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(N.text3)
                        .padding(.horizontal, 14).padding(.top, 9)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 6) {
                Text("⌘↩ to send").font(NFont.caption).foregroundStyle(N.text3)
                Spacer(minLength: 8)
                actions
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? N.blue.opacity(0.6) : N.divider))
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - Comment box (issues)

/// A comment in an issue thread, drawn like the pull request feed: face on the left, header, body on a soft card.
struct GHCommentBox: View {
    var author: String
    var avatar: String?
    var date: Date?
    var html: String
    var isAuthor: Bool
    var empty: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GHAvatar(login: author, size: 24, url: avatar)
            VStack(alignment: .leading, spacing: 8) {
                GHFeedHeader(actor: author, action: "commented", date: date, author: isAuthor).frame(minHeight: 24)
                GHFeedCard(html: html, empty: empty)
            }
        }
    }
}
