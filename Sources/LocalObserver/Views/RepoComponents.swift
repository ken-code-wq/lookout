import SwiftUI
import AppKit
import LocalObserverRepos
import LocalObserverCore

// MARK: - Checks and reviews

extension CheckState {
    var color: TagColor {
        switch self {
        case .success: return .green
        case .failure: return .red
        case .pending: return .yellow
        case .none: return .gray
        }
    }
    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .pending: return "circle.dotted.circle"
        case .none: return "circle.dashed"
        }
    }
}

extension ReviewState {
    var color: TagColor {
        switch self {
        case .approved: return .green
        case .changesRequested: return .red
        case .required: return .orange
        case .none: return .gray
        }
    }
}

/// CI result as a tinted glyph; pulses while checks run.
struct CheckGlyph: View {
    var state: CheckState
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(state.color.fg)
            .symbolEffect(.pulse, options: .repeating, isActive: state == .pending)
            .help(state.title)
    }
}

/// "#42 ✓" pill linking to a pull request.
struct PullChip: View {
    var pull: PullRequest

    var body: some View {
        Button { GitHubNav.open(pull: pull.repo, number: pull.number) } label: {
            HStack(spacing: 4) {
                CheckGlyph(state: pull.checks, size: 10)
                Text(verbatim: "#\(pull.number)").font(NFont.monoSmall)
                if pull.review == .approved {
                    Image(systemName: "hand.thumbsup.fill").font(.system(size: 9)).foregroundStyle(TagColor.green.fg)
                }
            }
            .foregroundStyle(N.text2)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(TagColor.gray.bg, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(pull.title)\n\(pull.checks.title) · \(pull.review.title)")
    }
}

/// The pull request for the branch a session works on, if you have one open.
struct SessionPullChip: View {
    var session: AgentSession
    @ObservedObject private var repos = RepoStore.shared

    var body: some View {
        if let pull = AgentLinks.pull(for: session, in: repos) { PullChip(pull: pull) }
    }
}

/// "✓ #214 Add rate limiting · Approved", for the agent inspector.
struct AgentPullValue: View {
    var pull: PullRequest

    var body: some View {
        Button { GitHubNav.open(pull: pull.repo, number: pull.number) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    CheckGlyph(state: pull.checks, size: 11)
                    Text(verbatim: "#\(pull.number)").font(NFont.monoSmall).foregroundStyle(N.text2)
                    Text(pull.title).lineLimit(1).underline(color: N.text3)
                }
                Text([pull.checks.title, pull.isReadyToMerge ? "Ready to merge" : pull.review.title].joined(separator: " · "))
                    .font(NFont.caption).foregroundStyle(N.text2)
            }
        }
        .buttonStyle(.plain)
        .help("Open #\(pull.number) in Lookout")
    }
}

// MARK: - Repository state

/// Compact counters for a checkout: uncommitted files, unpushed and behind commits, stashes.
struct RepoStateChips: View {
    var changes: RepoChanges?
    var unpushed: Int
    var behind: Int
    var stashes: Int = 0
    var localOnly = false

    var body: some View {
        HStack(spacing: 5) {
            if let changes, changes.conflicted > 0 {
                chip("exclamationmark.triangle.fill", "\(changes.conflicted)", .red, "\(changes.conflicted) conflicted")
            }
            if let changes, !changes.isClean {
                chip("pencil", "\(changes.total)", .orange, changes.summary)
            }
            if unpushed > 0 { chip("arrow.up", "\(unpushed)", .blue, "\(unpushed) commit\(unpushed == 1 ? "" : "s") no remote has") }
            if behind > 0 { chip("arrow.down", "\(behind)", .purple, "\(behind) commit\(behind == 1 ? "" : "s") behind upstream") }
            if stashes > 0 { chip("tray.full", "\(stashes)", .gray, "\(stashes) stash\(stashes == 1 ? "" : "es")") }
            if localOnly { chip("externaldrive", "Local", .gray, "No remote: this repository exists only on this Mac") }
            if (changes?.isClean ?? true) && unpushed == 0 && behind == 0 && stashes == 0 && !localOnly {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 9.5, weight: .semibold))
                    Text("Clean").font(.system(size: 12))
                }
                .foregroundStyle(N.text3)
            }
        }
    }

    private func chip(_ symbol: String, _ text: String, _ color: TagColor, _ help: String) -> some View {
        Tag(text: text, color: color, symbol: symbol).help(help)
    }
}

/// Opens Lookout's GitHub page at a repository or pull request, with the trail back to the list in place.
@MainActor
enum GitHubNav {
    static func open(repo slug: String, tab: GHRepoTab = .code) {
        GitHubStore.shared.path = [.repo(slug, tab)]
        LiveSurfaces.shared.openMain(.github)
    }

    static func open(pull slug: String, number: Int) {
        GitHubStore.shared.path = [.repo(slug, .pulls), .pull(slug, number)]
        LiveSurfaces.shared.openMain(.github)
    }
}

/// Opening a repository or worktree folder in the usual places.
enum RepoActions {
    static func openEditor(_ path: String) { ProcessManager.openInEditor(path: path) }
    static func openTerminal(_ path: String) { ProcessManager.openInTerminal(path: path) }
    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct RepoMenu: View {
    @ObservedObject var store: RepoStore
    var repo: Repo

    var body: some View {
        Button("Open in Editor") { RepoActions.openEditor(repo.root) }
        Button("Open in Terminal") { RepoActions.openTerminal(repo.root) }
        Button("Reveal in Finder") { RepoActions.reveal(repo.root) }
        if let slug = repo.github {
            Button("Show GitHub Page") { GitHubNav.open(repo: slug) }
        }
        if let url = repo.githubURL {
            Button("Open on GitHub") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Fetch") { store.fetch(repo) }.disabled(repo.isLocalOnly || store.busy.contains(repo.root))
        Button("Pull (fast-forward only)") { store.pull(repo) }
            .disabled(repo.status.upstream == nil || store.busy.contains(repo.root))
        if !repo.mergedBranches.isEmpty {
            Button("Delete \(repo.mergedBranches.count) Merged Branch\(repo.mergedBranches.count == 1 ? "" : "es")") { store.deleteMergedBranches(repo) }
        }
        if repo.worktrees.contains(where: \.isPrunable) {
            Button("Prune Missing Worktrees") { store.pruneWorktrees(repo) }
        }
        Divider()
        Button("Copy Path") { RepoActions.copy(repo.root) }
        Button("Copy Branch Name") { RepoActions.copy(repo.refLabel) }
        Divider()
        Button("Hide Repository") { store.setHidden(repo, true) }
    }
}

// MARK: - Pull request row

struct PullRow: View {
    @ObservedObject var store: RepoStore
    var pull: PullRequest
    var showRepo = true
    /// Narrow layout for the inspector: review state and age move into the second line.
    var compact = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            CheckGlyph(state: pull.checks, size: 14)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pull.title).font(compact ? NFont.small.weight(.medium) : NFont.bodyMedium).foregroundStyle(N.text).lineLimit(1)
                    if !compact {
                        if pull.isDraft { Tag(text: "Draft", color: .gray) }
                        if pull.isReadyToMerge { Tag(text: "Ready to merge", color: .green, symbol: "checkmark") }
                        if pull.mergeable == false { Tag(text: "Conflicts", color: .red, symbol: "exclamationmark.triangle") }
                    }
                }
                if compact {
                    Text("#\(pull.number) · \(pull.isReadyToMerge ? "Ready to merge" : pull.review.title) · \(RepoFormat.ago(pull.updatedAt))")
                        .font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
                } else {
                HStack(spacing: 5) {
                    if showRepo { Text(pull.repo).lineLimit(1) ; Text("·") }
                    Text(verbatim: "#\(pull.number)")
                    Text("·")
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                    Text(pull.branch).lineLimit(1).truncationMode(.middle)
                    if pull.role == .reviewRequested { Text("·"); Text("by \(pull.author)") }
                }
                .font(NFont.caption)
                .foregroundStyle(N.text2)
                }
            }
            Spacer(minLength: 8)
            if !compact {
                if pull.review != .none {
                    Tag(text: pull.review.title, color: pull.review.color)
                }
                Text(RepoFormat.ago(pull.updatedAt))
                    .font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { GitHubNav.open(pull: pull.repo, number: pull.number) }
        .contextMenu {
            Button("Open in Lookout") { GitHubNav.open(pull: pull.repo, number: pull.number) }
            Button("Open on GitHub") { ProcessManager.openURL(pull.url) }
            Button("Open Checks") { ProcessManager.openURL(pull.url + "/checks") }
            Button("Copy URL") { RepoActions.copy(pull.url) }
            Button("Copy Branch Name") { RepoActions.copy(pull.branch) }
            if let repo = store.localRepo(for: pull) {
                Divider()
                Button("Open \(repo.name) in Editor") { RepoActions.openEditor(repo.root) }
                Button("Show \(repo.name) in Lookout") { store.selection = repo.root; LiveSurfaces.shared.openMain(.repos) }
            }
        }
        .help("Open #\(pull.number) in Lookout")
    }
}

/// Explains why pull requests aren't showing, with the one step that fixes it.
struct GitHubStatusBanner: View {
    @ObservedObject var store: RepoStore

    var body: some View {
        switch store.gitHub {
        case .missingCLI:
            banner("GitHub CLI not found", "Pull requests and checks come from the GitHub CLI's sign-in. Install it with `brew install gh`, then run `gh auth login`.",
                   symbol: "terminal")
        case .signedOut:
            banner("Sign in to GitHub", "Run `gh auth login` in a terminal. Lookout uses that sign-in and never stores your token.",
                   symbol: "person.crop.circle.badge.questionmark")
        case .error(let message):
            banner("Couldn't reach GitHub", message, symbol: "exclamationmark.triangle")
        case .off:
            banner("GitHub is off", "Turn it on in Settings › Repos to see your pull requests and their checks.", symbol: "powersleep")
        case .ok, .unknown:
            EmptyView()
        }
    }

    private func banner(_ title: String, _ message: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(TagColor.orange.fg).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(NFont.bodyMedium).foregroundStyle(N.text)
                Text(LocalizedStringKey(message)).font(NFont.small).foregroundStyle(N.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Try again") { store.refreshGitHub() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(12)
        .background(TagColor.orange.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, 10)
    }
}

// MARK: - Hand-off

/// What to do with an agent's work once it stops: review it, push it, open a pull request, or clear the worktree.
/// Reads the checkout's live state (uncommitted, unpushed, pull request) from the Repos store.
struct AgentHandoffPanel: View {
    var session: AgentSession
    @ObservedObject private var repos = RepoStore.shared

    var body: some View {
        if let (repo, branch) = AgentLinks.target(of: session, in: repos) {
            let path = session.checkout?.root ?? repo.root
            let worktree = repo.worktrees.first { $0.path == path }
            let changes = worktree?.changes ?? (worktree == nil ? repo.changes : nil)
            let uncommitted = changes?.total ?? 0
            let unpushed = worktree?.ahead ?? repo.unpushedCount
            let pull = repos.pull(for: repo, branch: branch)
            let isDefault = branch == repo.defaultBranch
            let busy = repos.busy.contains(path)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    BranchTag(branch: branch, worktree: worktree != nil, maxWidth: 220)
                    RepoStateChips(changes: changes, unpushed: unpushed, behind: 0)
                    if busy { ProgressView().controlSize(.small) }
                }
                Text(advice(uncommitted: uncommitted, unpushed: unpushed, pull: pull, isDefault: isDefault))
                    .font(NFont.caption).foregroundStyle(N.text2).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    if SessionReplayReader.supports(session.agent), !session.sourcePath.isEmpty {
                        Button { LiveSurfaces.shared.replay(session) } label: { Label("Review changes", systemImage: "play.rectangle") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    Button { RepoActions.openEditor(path) } label: { Label("Open in editor", systemImage: "chevron.left.forwardslash.chevron.right") }
                        .buttonStyle(SecondaryButtonStyle())
                    if !repo.isLocalOnly, unpushed > 0, pull != nil || isDefault {
                        Button { repos.push(repo, path: path, branch: branch) } label: { Label("Push \(unpushed)", systemImage: "arrow.up") }
                            .buttonStyle(SecondaryButtonStyle()).disabled(busy)
                    }
                    if let pull {
                        Button { GitHubNav.open(pull: pull.repo, number: pull.number) } label: {
                            Label("View #\(pull.number)", systemImage: "arrow.triangle.pull")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    } else if !isDefault, repo.github != nil {
                        Button {
                            repos.createPull(repo, path: path, branch: branch) { number in
                                if let number, let slug = repo.github { GitHubNav.open(pull: slug, number: number) }
                            }
                        } label: {
                            Label(unpushed > 0 ? "Push and open PR" : "Open pull request", systemImage: "arrow.triangle.pull")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(busy || session.process != nil && session.state == .working)
                        .help("Pushes \(branch) and runs gh pr create --fill: title and description from its commits")
                    }
                    if let worktree, uncommitted == 0, unpushed == 0, session.process == nil {
                        HandoffRemoveButton { repos.removeWorktree(repo, path: worktree.path) }
                            .disabled(busy)
                    }
                }
            }
        }
    }

    private func advice(uncommitted: Int, unpushed: Int, pull: PullRequest?, isDefault: Bool) -> String {
        if uncommitted > 0 {
            return "\(uncommitted) file\(uncommitted == 1 ? " isn't" : "s aren't") committed yet. Review them, then ask the agent to commit (or commit yourself) before pushing."
        }
        if let pull { return unpushed > 0 ? "\(unpushed) new commit\(unpushed == 1 ? "" : "s") to push to #\(pull.number)." : "Everything is pushed to #\(pull.number): \(pull.checks.title.lowercased())." }
        if isDefault { return unpushed > 0 ? "\(unpushed) commit\(unpushed == 1 ? "" : "s") on the default branch aren't pushed." : "Nothing left to push." }
        return unpushed > 0 ? "\(unpushed) commit\(unpushed == 1 ? "" : "s") ready. Open a pull request to push and share them." : "Committed and pushed, with no pull request yet."
    }
}

/// "Remove worktree" that asks once more first.
private struct HandoffRemoveButton: View {
    var action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed { armed = false; action() } else {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
            }
        } label: {
            Label(armed ? "Remove it?" : "Remove worktree", systemImage: "trash")
        }
        .buttonStyle(SecondaryButtonStyle(tint: N.red))
        .help("git worktree remove: the folder goes, the branch stays")
    }
}
