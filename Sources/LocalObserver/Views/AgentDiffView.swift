import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverRepos

// Live diff per agent: what a session has changed in its checkout so far. A compact "+120 −34 · 7 files" on agent
// rows, a Changes group in the inspector, and a full GitHub-style diff with per-file actions.

/// Where a session's diff is read from.
@MainActor
enum AgentDiffs {
    /// The checkout a session works in: its live one while running, else wherever its project folder is.
    static func root(of session: AgentSession) -> String? {
        if let root = session.checkout?.root { return root }
        guard !session.projectPath.isEmpty else { return nil }
        return GitCheckout.locate(session.projectPath)?.root
    }

    static func key(_ session: AgentSession, root: String) -> String {
        RepoDiffStore.detailKey(root: root, since: session.startedAt)
    }

    static func tooltip(_ summary: RepoDiffSummary, root: String, checked: Date?) -> String {
        var lines = ["Uncommitted changes vs HEAD: \(summary.filesLabel), \(summary.additions) lines added, \(summary.deletions) removed",
                     (root as NSString).abbreviatingWithTildeInPath]
        if summary.isLarge { lines.append("That's a lot for one session: worth reviewing before you trust it.") }
        if let checked { lines.append("Checked \(AgentFormat.ago(checked))") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Row summary

/// "+120 −34 · 7 files" for a running session's uncommitted work. Each visible chip keeps its checkout's summary
/// fresh; the store reads a checkout at most once per `RepoDiffStore.summaryInterval`, and finished sessions show nothing.
struct SessionDiffChip: View {
    enum Style { case row, notch, peek }

    var session: AgentSession
    var style: Style = .row
    @ObservedObject private var diffs = RepoDiffStore.shared

    var body: some View {
        if session.process != nil, let root = AgentDiffs.root(of: session) {
            Group {
                if let summary = diffs.summaries[root], !summary.isEmpty {
                    Group {
                        if style == .row {
                            label(summary, files: true)
                        } else {
                            // Tight rows: the project name comes first, so the chip shortens, then steps aside.
                            ViewThatFits(in: .horizontal) {
                                label(summary, files: true)
                                label(summary, files: false)
                                Color.clear.frame(width: 0, height: 0)
                            }
                            .layoutPriority(-1)
                        }
                    }
                    .help(AgentDiffs.tooltip(summary, root: root, checked: diffs.summaryCheckedAt(root)))
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .task(id: root) {
                while !Task.isCancelled {
                    diffs.refreshSummary(root: root)
                    try? await Task.sleep(for: .seconds(RepoDiffStore.summaryInterval))
                }
            }
        }
    }

    private func label(_ summary: RepoDiffSummary, files: Bool) -> some View {
        HStack(spacing: 3) {
            if summary.isLarge {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size - 2)).foregroundStyle(warn)
            }
            Text(verbatim: "+\(summary.additions)").foregroundStyle(add)
            Text(verbatim: "−\(summary.deletions)").foregroundStyle(del)
            if files { Text(verbatim: "· \(summary.filesLabel)").foregroundStyle(muted) }
        }
        .font(.system(size: size, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.additions) lines added, \(summary.deletions) removed, \(summary.filesLabel) changed")
    }

    private var size: CGFloat { style == .row ? 11 : 10 }
    private var add: Color { style == .notch ? NotchColor.green : (style == .peek ? .green : GH.open) }
    private var del: Color { style == .notch ? NotchColor.red : (style == .peek ? .red : GH.closed) }
    private var muted: Color { style == .notch ? NotchColor.text3 : (style == .peek ? .secondary : N.text2) }
    private var warn: Color { style == .notch ? NotchColor.orange : TagColor.orange.fg }
}

// MARK: - Inspector

/// The inspector's Changes group: totals, the scale warning, the first few files, and the way into the full diff.
struct AgentChangesPanel: View {
    var session: AgentSession
    var root: String
    @ObservedObject private var diffs = RepoDiffStore.shared
    @State private var reviewing: ReviewTarget?

    struct ReviewTarget: Identifiable {
        var id: String { focus ?? "" }
        var focus: String?
    }

    private static let previewCount = 6

    var body: some View {
        let diff = diffs.details[AgentDiffs.key(session, root: root)]
        VStack(alignment: .leading, spacing: 8) {
            if let diff {
                content(diff)
            } else if diffs.loading.contains(AgentDiffs.key(session, root: root)) {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading the diff…") }
                    .font(NFont.small).foregroundStyle(N.text2)
            } else {
                Text("Lookout couldn't read git here.").font(NFont.small).foregroundStyle(N.text2)
            }
        }
        .task(id: root) {
            diffs.loadDetail(root: root, since: session.startedAt)
            // While the agent runs, keep the summary fresh; a change in it pulls the full diff again.
            guard session.process != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(RepoDiffStore.summaryInterval))
                diffs.refreshSummary(root: root)
            }
        }
        .onChange(of: diffs.summaries[root]) { _, summary in
            if summary != diff?.summary { diffs.loadDetail(root: root, since: session.startedAt) }
        }
        .sheet(item: $reviewing) { target in
            AgentDiffView(session: session, root: root, focus: target.focus) { reviewing = nil }
        }
    }

    @ViewBuilder private func content(_ diff: RepoWorkDiff) -> some View {
        let summary = diff.summary
        HStack(spacing: 8) {
            if summary.isEmpty {
                Text("No uncommitted changes").font(NFont.small).foregroundStyle(N.text2)
            } else {
                GHDiffStat(additions: summary.additions, deletions: summary.deletions)
                Text(summary.filesLabel).font(NFont.small).foregroundStyle(N.text2)
            }
            Spacer(minLength: 4)
            if !diff.head.isEmpty {
                Text(verbatim: "vs \(diff.head.prefix(7))").font(NFont.monoSmall).foregroundStyle(N.text3)
                    .help("Working tree compared with HEAD, \(diff.head)")
            }
        }
        if summary.isLarge { AgentDiffScaleNotice(summary: summary) }
        if !diff.uncommitted.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diff.uncommitted.prefix(Self.previewCount)) { file in
                    Button { reviewing = ReviewTarget(focus: file.path) } label: { AgentDiffFileLine(file: file) }
                        .buttonStyle(.plain)
                }
            }
            if diff.uncommitted.count > Self.previewCount {
                Text("and \(diff.uncommitted.count - Self.previewCount) more").font(NFont.caption).foregroundStyle(N.text3)
            }
        }
        if let committed = diff.committed {
            let totals = RepoDiffSummary(committed.files)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(N.text2)
                Text("\(committed.commits.count) commit\(committed.commits.count == 1 ? "" : "s") this session")
                Text(verbatim: "+\(totals.additions) −\(totals.deletions) · \(totals.filesLabel)").font(NFont.monoSmall)
            }
            .font(NFont.small).foregroundStyle(N.text2)
            .help("Committed since \(committed.base.prefix(7)), where HEAD was when the session started")
        } else if let note = diff.committedNote {
            Text(note).font(NFont.caption).foregroundStyle(N.text3).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 6) {
            if !summary.isEmpty || diff.committed != nil {
                Button { reviewing = ReviewTarget(focus: nil) } label: { Label("Review diff", systemImage: "plusminus") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if !summary.isEmpty {
                Button {
                    RepoActions.copy(diff.unifiedText)
                    LiveSurfaces.shared.toast("Copied the diff")
                } label: { Label("Copy diff", systemImage: "doc.on.doc") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.top, 2)
    }
}

/// "40 files changed": shown when a session touches enough that it deserves a careful look.
struct AgentDiffScaleNotice: View {
    var summary: RepoDiffSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(TagColor.orange.fg)
            Text("\(summary.files) files changed. That's a lot for one session; review it before trusting it.")
                .font(NFont.small).foregroundStyle(N.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TagColor.orange.bg, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
    }
}

/// A file's status as its letter in a tinted square, with the word in the tooltip.
struct AgentDiffStatusBadge: View {
    var status: RepoDiffStatus

    var body: some View {
        Text(status.letter)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 15, height: 15)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .help(status.title)
            .accessibilityLabel(status.title)
    }

    private var color: Color {
        switch status {
        case .added, .untracked, .copied: return GH.open
        case .deleted: return GH.closed
        case .renamed: return GH.merged
        case .conflicted: return GH.attention
        case .modified, .typeChanged: return GH.attention
        }
    }
}

/// One file in a compact list: status, name with its folder, and line counts.
private struct AgentDiffFileLine: View {
    var file: RepoDiffFile
    var selected = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            AgentDiffStatusBadge(status: file.status)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name).font(NFont.small).foregroundStyle(N.text).lineLimit(1)
                let folder = (file.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder).font(.system(size: 10.5)).foregroundStyle(N.text3).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            AgentDiffCounts(file: file)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(selected ? N.selected : (hover ? N.hover : .clear), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

private struct AgentDiffCounts: View {
    var file: RepoDiffFile

    var body: some View {
        Group {
            if file.isBinary {
                Text("binary").foregroundStyle(N.text3)
            } else if file.isTooLarge {
                Text("large").foregroundStyle(N.text3)
            } else {
                HStack(spacing: 3) {
                    Text(verbatim: "+\(file.additions)").foregroundStyle(GH.open)
                    Text(verbatim: "−\(file.deletions)").foregroundStyle(GH.closed)
                }
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
    }
}

// MARK: - Full diff

/// Everything a session has changed, GitHub-style: uncommitted work against HEAD, then what it committed since it
/// started. Each file can be opened, revealed, copied, or reverted.
struct AgentDiffView: View {
    var session: AgentSession
    var root: String
    var focus: String? = nil
    var close: () -> Void

    @ObservedObject private var diffs = RepoDiffStore.shared
    @State private var collapsed: Set<String> = []
    @State private var selected: String?
    @State private var initialized = false

    private var key: String { AgentDiffs.key(session, root: root) }

    var body: some View {
        let diff = diffs.details[key]
        VStack(spacing: 0) {
            header(diff)
            Rectangle().fill(N.divider).frame(height: 1)
            if let diff {
                if diff.uncommitted.isEmpty && diff.committed == nil {
                    EmptyStateView(symbol: "checkmark.circle", title: "Nothing changed",
                                   message: "The working tree matches HEAD, and nothing was committed during this session.") { EmptyView() }
                        .frame(maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        sidebar(diff).frame(width: 260)
                        Rectangle().fill(N.divider).frame(width: 1)
                        files(diff)
                    }
                }
            } else if diffs.loading.contains(key) {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "The diff isn't available",
                               message: "\((root as NSString).abbreviatingWithTildeInPath) couldn't be read as a git checkout.") { EmptyView() }
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, idealWidth: 1180, minHeight: 640, idealHeight: 820)
        .background(N.bg)
        .task { if diffs.details[key] == nil { diffs.loadDetail(root: root, since: session.startedAt) } }
        .onAppear(perform: setUp)
        .onChange(of: diff?.uncommitted.count) { _, _ in setUp() }
        .onKeyPress(.escape) { close(); return .handled }
    }

    /// Big diffs open folded, so the page lists files first; a file picked from the inspector opens on its own.
    private func setUp() {
        guard !initialized, let diff = diffs.details[key] else { return }
        initialized = true
        let all = diff.uncommitted.map { "u:" + $0.path } + (diff.committed?.files.map { "c:" + $0.path } ?? [])
        if all.count > 12 || diff.summary.isLarge { collapsed = Set(all) }
        if let focus {
            collapsed.remove("u:" + focus)
            selected = "u:" + focus
        }
    }

    // MARK: Header

    private func header(_ diff: RepoWorkDiff?) -> some View {
        HStack(spacing: 12) {
            AgentIconView(agent: session.agent, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(N.text).lineLimit(1)
                HStack(spacing: 10) {
                    Text(session.projectName)
                    if let git = session.checkout { InlineBranch(git: git) } else if !session.branch.isEmpty { Text(session.branch) }
                    if let diff {
                        let summary = diff.summary
                        if !summary.isEmpty {
                            HStack(spacing: 4) {
                                Text(verbatim: "+\(summary.additions)").foregroundStyle(GH.open)
                                Text(verbatim: "−\(summary.deletions)").foregroundStyle(GH.closed)
                            }
                            .font(NFont.monoSmall)
                            Text("\(summary.filesLabel) uncommitted").monospacedDigit()
                        }
                        if let committed = diff.committed {
                            Text("\(committed.commits.count) commit\(committed.commits.count == 1 ? "" : "s") this session").monospacedDigit()
                        }
                        Text("Read \(AgentFormat.ago(diff.checkedAt))")
                    }
                }
                .font(NFont.small)
                .foregroundStyle(N.text2)
            }
            Spacer()
            if diffs.loading.contains(key) { ProgressView().controlSize(.small) }
            Button { diffs.loadDetail(root: root, since: session.startedAt) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut("r", modifiers: .command)
                .disabled(diffs.loading.contains(key))
            if let diff, !diff.uncommitted.isEmpty {
                Button {
                    RepoActions.copy(diff.unifiedText)
                    LiveSurfaces.shared.toast("Copied the diff")
                } label: { Label("Copy diff", systemImage: "doc.on.doc") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("The uncommitted changes as one unified diff, untracked files included")
            }
            Button("Done", action: close).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Sidebar

    private func sidebar(_ diff: RepoWorkDiff) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                sideTitle("Uncommitted", count: diff.uncommitted.count)
                if diff.uncommitted.isEmpty {
                    Text("Working tree matches HEAD").font(NFont.caption).foregroundStyle(N.text3).padding(.horizontal, 8)
                }
                ForEach(diff.uncommitted) { file in sideRow(file, id: "u:" + file.path) }
                if let committed = diff.committed {
                    sideTitle("Committed this session", count: committed.files.count).padding(.top, 12)
                    ForEach(committed.files) { file in sideRow(file, id: "c:" + file.path) }
                }
            }
            .padding(10)
        }
        .background(N.bgSoft)
    }

    private func sideTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(N.text2)
            Spacer()
            Text("\(count)").font(NFont.caption).foregroundStyle(N.text3).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.bottom, 4)
    }

    private func sideRow(_ file: RepoDiffFile, id: String) -> some View {
        Button {
            collapsed.remove(id)
            selected = id
        } label: {
            AgentDiffFileLine(file: file, selected: selected == id)
        }
        .buttonStyle(.plain)
    }

    // MARK: Files

    private func files(_ diff: RepoWorkDiff) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if diff.summary.isLarge { AgentDiffScaleNotice(summary: diff.summary) }
                    if !diff.uncommitted.isEmpty {
                        sectionTitle("Uncommitted changes",
                                     detail: diff.head.isEmpty ? "No commits yet; everything is new" : "Working tree and index vs HEAD \(diff.head.prefix(7))")
                        ForEach(diff.uncommitted) { file in fileBox(file, id: "u:" + file.path, revertable: true) }
                    }
                    if let committed = diff.committed {
                        committedHeader(committed)
                        ForEach(committed.files) { file in fileBox(file, id: "c:" + file.path, revertable: false) }
                    } else if let note = diff.committedNote {
                        Text(note).font(NFont.caption).foregroundStyle(N.text3)
                    }
                }
                .padding(18)
            }
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
            }
            .onAppear {
                if let selected { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo(selected, anchor: .top) } }
            }
        }
    }

    private func fileBox(_ file: RepoDiffFile, id: String, revertable: Bool) -> some View {
        AgentFileDiff(file: file, root: root, session: session, revertable: revertable,
                      collapsed: Binding(get: { collapsed.contains(id) },
                                         set: { if $0 { collapsed.insert(id) } else { collapsed.remove(id) } }))
            .id(id)
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(N.text)
            Text(detail).font(NFont.small).foregroundStyle(N.text2)
        }
    }

    private func committedHeader(_ committed: RepoSessionCommits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Committed during this session",
                         detail: "\(committed.commits.count) commit\(committed.commits.count == 1 ? "" : "s") since \(committed.base.prefix(7)), where HEAD was when the session started")
            if !committed.baseIsAncestor {
                Text("HEAD moved off that commit during the session (a branch switch or rebase), so this may include work that isn't the agent's.")
                    .font(NFont.caption).foregroundStyle(TagColor.orange.fg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(committed.commits.prefix(12)) { commit in
                    HStack(spacing: 8) {
                        Text(verbatim: String(commit.sha.prefix(7))).font(NFont.monoSmall).foregroundStyle(N.text3)
                        Text(commit.subject).font(NFont.small).foregroundStyle(N.text).lineLimit(1)
                        Spacer(minLength: 8)
                        if let date = commit.date { Text(AgentFormat.ago(date)).font(NFont.caption).foregroundStyle(N.text3) }
                    }
                }
                if committed.commits.count > 12 {
                    Text("and \(committed.commits.count - 12) more").font(NFont.caption).foregroundStyle(N.text3)
                }
            }
        }
        .padding(.top, 8)
    }
}

/// One file's diff in a GitHub-style box, reusing the pull request view's line rendering.
private struct AgentFileDiff: View {
    var file: RepoDiffFile
    var root: String
    var session: AgentSession
    var revertable: Bool
    @Binding var collapsed: Bool
    @ObservedObject private var diffs = RepoDiffStore.shared
    @State private var showAll = false
    @State private var width: CGFloat = 600
    @State private var confirming = false

    private static let pageSize = 400
    private var fullPath: String { root + "/" + file.path }

    var body: some View {
        GHBox {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy(duration: 0.18)) { collapsed.toggle() } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(N.text2)
                        .rotationEffect(.degrees(collapsed ? 0 : 90)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show diff" : "Hide diff")
                if !file.isBinary { GHDiffStat(additions: file.additions, deletions: file.deletions) }
                AgentDiffStatusBadge(status: file.status)
                Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(N.text)
                    .lineLimit(1).truncationMode(.head)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") { ProcessManager.openInEditor(path: fullPath) }
                    .disabled(!file.status.existsOnDisk)
                IconButton(symbol: "folder", help: "Reveal in Finder") { RepoActions.reveal(fullPath) }
                    .disabled(!file.status.existsOnDisk)
                IconButton(symbol: "doc.on.doc", help: "Copy this file's diff") {
                    RepoActions.copy(file.unifiedText)
                    LiveSurfaces.shared.toast("Copied the diff of \(file.name)")
                }
                if revertable {
                    Button { confirming = true } label: { Label("Revert", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(GhostButtonStyle(tint: N.red))
                        .disabled(diffs.busy.contains(root))
                        .help(file.status == .untracked || file.status == .added ? "Move this new file to the Trash" : "Put this file back the way HEAD has it")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .contextMenu { menu }
        } content: {
            if !collapsed { diffBody }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(confirmButton, role: .destructive) {
                diffs.revert(file, root: root, since: session.startedAt) { message, ok in LiveSurfaces.shared.toast(message, ok: ok) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Open in Editor") { ProcessManager.openInEditor(path: fullPath) }.disabled(!file.status.existsOnDisk)
        Button("Reveal in Finder") { RepoActions.reveal(fullPath) }.disabled(!file.status.existsOnDisk)
        Divider()
        Button("Copy Diff") { RepoActions.copy(file.unifiedText) }
        Button("Copy Path") { RepoActions.copy(fullPath) }
        if revertable {
            Divider()
            Button("Revert File…") { confirming = true }
        }
    }

    @ViewBuilder private var diffBody: some View {
        if let patch = file.patch {
            let lines = GHDiffLine.parse(patch)
            let shown = showAll ? lines : Array(lines.prefix(Self.pageSize))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { line in GHDiffLineRow(line: line) }
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
            Text(placeholder)
                .font(NFont.small).foregroundStyle(N.text2)
                .frame(maxWidth: .infinity).padding(.vertical, 18)
        }
    }

    private var placeholder: String {
        if file.isBinary { return "Binary file changed." }
        if file.isTooLarge { return "Too large to show here. Open it in your editor to see the changes." }
        if file.status == .renamed { return "Renamed without changes." }
        if file.status == .untracked || file.status == .added { return "Empty file." }
        return "No line changes (mode or type only)."
    }

    private var isNew: Bool { file.status == .untracked || file.status == .added || file.status == .copied }

    private var confirmTitle: String { "Revert \(file.path)?" }
    private var confirmButton: String { isNew ? "Move to Trash" : "Revert File" }

    private var confirmMessage: String {
        var text: String
        switch file.status {
        case .untracked, .added, .copied:
            text = "\(file.path) is new since HEAD. It will be moved to the Trash."
        case .renamed:
            text = "\(file.path) goes back to \(file.oldPath ?? "its old name") as HEAD has it, and the renamed copy is moved to the Trash."
        case .deleted:
            text = "\(file.path) will be brought back as HEAD has it."
        default:
            text = "Uncommitted changes to \(file.path), staged or not, will be discarded and the file put back as HEAD has it. This can't be undone."
        }
        if session.process != nil && session.state == .working {
            text += "\n\n\(session.agent.name) is still working and may change this file again."
        }
        return text
    }
}
