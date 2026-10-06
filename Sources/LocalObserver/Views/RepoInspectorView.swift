import SwiftUI
import AppKit
import LocalObserverRepos

/// Notion-style peek for the selected repository.
struct RepoInspectorView: View {
    @ObservedObject var store: RepoStore
    var repo: Repo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                actions.padding(.top, 14)
                Rectangle().fill(N.divider).frame(height: 1).padding(.vertical, 16)
                properties
                if !store.pulls(for: repo).isEmpty {
                    section("Pull requests") {
                        VStack(spacing: 1) {
                            ForEach(store.pulls(for: repo)) { PullRow(store: store, pull: $0, showRepo: false, compact: true) }
                        }
                    }
                }
                if !repo.worktrees.isEmpty { worktrees }
                cleanup
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(N.bg)
        .id(repo.root)
        .transition(.opacity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            FolderIconView(folder: repo.root, name: repo.name, size: 52)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            Text(repo.name).font(NFont.title).foregroundStyle(N.text).textSelection(.enabled).padding(.top, 6)
            BranchTag(branch: repo.refLabel, detached: repo.branch == nil, maxWidth: 300)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { RepoActions.openEditor(repo.root) } label: {
                Label("Open", systemImage: "chevron.left.forwardslash.chevron.right").labelStyle(TightLabelStyle())
            }
            .buttonStyle(PrimaryButtonStyle())
            Button { store.pull(repo) } label: {
                Label("Pull", systemImage: "arrow.down").labelStyle(TightLabelStyle())
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(repo.status.upstream == nil || store.busy.contains(repo.root))
            .help(repo.status.upstream == nil ? "This branch doesn't track a remote branch" : "git pull --ff-only: never merges or rebases")
            Spacer(minLength: 0)
            if store.busy.contains(repo.root) { ProgressView().controlSize(.small) }
            IconButton(symbol: "arrow.triangle.2.circlepath", help: "Fetch") { store.fetch(repo) }
                .disabled(repo.isLocalOnly || store.busy.contains(repo.root))
            IconButton(symbol: "terminal", help: "Open in Terminal") { RepoActions.openTerminal(repo.root) }
            IconButton(symbol: "folder", help: "Reveal in Finder") { RepoActions.reveal(repo.root) }
            if let url = repo.githubURL {
                IconButton(symbol: "arrow.up.right.square", help: "Open on GitHub") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 2) {
            PropertyRow(symbol: "pencil", label: "Changes") {
                Text(repo.changes.summary).foregroundStyle(repo.isDirty ? N.text : N.text2)
            }
            PropertyRow(symbol: "arrow.up.arrow.down", label: "Remote") {
                Text(syncText).foregroundStyle(repo.hasUnpushed || repo.isBehind ? N.text : N.text2)
            }
            if let upstream = repo.status.upstream {
                PropertyRow(symbol: "link", label: "Tracks") { Text(upstream).font(NFont.monoSmall) }
            }
            if repo.stashes > 0 {
                PropertyRow(symbol: "tray.full", label: "Stashes") { Text("\(repo.stashes)") }
            }
            PropertyRow(symbol: "text.bubble", label: "Last commit") {
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.lastCommitSubject.isEmpty ? "No commits yet" : repo.lastCommitSubject).lineLimit(2)
                    if let date = repo.lastCommitAt {
                        Text("\(repo.lastCommitAuthor), \(RepoFormat.ago(date))").font(NFont.caption).foregroundStyle(N.text2)
                    }
                }
            }
            PropertyRow(symbol: "clock", label: "Touched") { Text(RepoFormat.ago(repo.lastTouched)) }
            PropertyRow(symbol: "arrow.triangle.branch", label: "Branches") {
                Text("\(repo.branchCount) local" + (repo.defaultBranch.map { ", default \($0)" } ?? ""))
            }
            if let github = repo.github {
                PropertyRow(symbol: "globe", label: "GitHub") {
                    Link(github, destination: repo.githubURL ?? URL(fileURLWithPath: "/")).foregroundStyle(N.text).underline(color: N.text3)
                }
            } else if !repo.remoteURL.isEmpty {
                PropertyRow(symbol: "globe", label: "Remote") { Text(repo.remoteURL).lineLimit(1).truncationMode(.middle) }
            }
            PropertyRow(symbol: "folder", label: "Folder") {
                Button { RepoActions.reveal(repo.root) } label: {
                    Text(repo.displayPath).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var syncText: String {
        if repo.isLocalOnly { return "No remote. This work exists only on this Mac." }
        var parts: [String] = []
        if repo.unpushedCount > 0 { parts.append("\(repo.unpushedCount) to push") }
        if repo.status.behind > 0 { parts.append("\(repo.status.behind) to pull") }
        return parts.isEmpty ? "Up to date" : parts.joined(separator: ", ")
    }

    private var worktrees: some View {
        section("Worktrees") {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(repo.worktrees) { worktree in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            BranchTag(branch: worktree.refLabel, worktree: true, detached: worktree.branch == nil, maxWidth: 220)
                            Text((worktree.owner.map { "\($0) · " } ?? "") + worktree.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(NFont.caption).foregroundStyle(N.text2).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 6)
                        RepoStateChips(changes: worktree.changes, unpushed: worktree.ahead, behind: worktree.behind)
                        IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor", size: 22) {
                            RepoActions.openEditor(worktree.path)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder private var cleanup: some View {
        let prunable = repo.worktrees.filter(\.isPrunable).count
        if !repo.mergedBranches.isEmpty || prunable > 0 {
            section("Tidy up") {
                VStack(alignment: .leading, spacing: 10) {
                    if !repo.mergedBranches.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(repo.mergedBranches.count) local branch\(repo.mergedBranches.count == 1 ? " is" : "es are") already in \(repo.defaultBranch ?? "the default branch"):")
                                .font(NFont.small).foregroundStyle(N.text2)
                            Text(repo.mergedBranches.prefix(8).joined(separator: ", ") + (repo.mergedBranches.count > 8 ? "…" : ""))
                                .font(NFont.monoSmall).foregroundStyle(N.text).lineLimit(3)
                            ArmedButton(title: "Delete merged branches", armedTitle: "Delete \(repo.mergedBranches.count)?") {
                                store.deleteMergedBranches(repo)
                            }
                            .help("git branch -d: refuses anything not fully merged, so no work can be lost")
                        }
                    }
                    if prunable > 0 {
                        HStack {
                            Text("\(prunable) worktree\(prunable == 1 ? "'s folder is" : "s' folders are") gone.").font(NFont.small).foregroundStyle(N.text2)
                            Button("Prune") { store.pruneWorktrees(repo) }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
            content()
        }
        .padding(.top, 20)
    }
}

/// Two-step button for actions that remove something: first click arms, second confirms.
struct ArmedButton: View {
    var title: String
    var armedTitle: String
    var action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed { armed = false; action() } else {
                withAnimation(.snappy(duration: 0.2)) { armed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation(.snappy(duration: 0.2)) { armed = false } }
            }
        } label: {
            Text(armed ? armedTitle : title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(armed ? Color.white : N.red)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(armed ? N.red : N.red.opacity(0.08), in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
