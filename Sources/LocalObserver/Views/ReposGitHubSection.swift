import SwiftUI
import LocalObserverRepos

/// Under the local repositories: the ones on your GitHub account that aren't cloned on this Mac, so Repositories is
/// the one list of everything you work on. Each row clones in one click into your first code folder; clicking the
/// rest of the row opens it on the GitHub page.
struct ReposGitHubSection: View {
    @ObservedObject var store: RepoStore
    @ObservedObject var github: GitHubStore
    var openOnGitHub: (String) -> Void
    @State private var showAll = false

    /// Rows shown before "Show N more".
    private static let preview = 5

    private var remote: [GHRepository] {
        let q = store.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return github.repositories
            .filter { !$0.isArchived && store.localRepo(slug: $0.slug) == nil }
            .filter { q.isEmpty || $0.slug.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false) }
            .sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
    }

    var body: some View {
        let remote = self.remote
        if !remote.isEmpty {
            let searching = !store.searchText.isEmpty
            let shown = showAll || searching ? remote : Array(remote.prefix(Self.preview))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "cloud").font(.system(size: 11)).foregroundStyle(N.text2)
                    Text("On GitHub only").font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                    Text("\(remote.count)").font(NFont.small).monospacedDigit().foregroundStyle(N.text3)
                    Text("Not cloned on this Mac").font(NFont.small).foregroundStyle(N.text2)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
                .overlay(alignment: .bottom) { Rectangle().fill(N.divider).frame(height: 1) }
                LazyVStack(spacing: 1) {
                    ForEach(shown) { repo in
                        RemoteRepoRow(repo: repo, viewer: store.gitHub.login,
                                      cloning: github.working.contains(GitHubStore.cloneKey(repo.slug)),
                                      clone: { clone(repo) }, open: { openOnGitHub(repo.slug) })
                    }
                }
                .padding(.top, 2)
                if !searching, remote.count > Self.preview {
                    Button(showAll ? "Show fewer" : "Show \(remote.count - Self.preview) more") {
                        withAnimation(.snappy(duration: 0.2)) { showAll.toggle() }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .font(NFont.small)
                    .padding(.top, 4)
                }
            }
            .padding(.top, 28)
        }
    }

    private var cloneParent: String? { store.settings.effectiveRoots.first }

    private func clone(_ repo: GHRepository) {
        guard let parent = cloneParent else { return }
        github.clone(repo.slug, into: parent) { store.refresh(rediscover: true) }
    }
}

private struct RemoteRepoRow: View {
    var repo: GHRepository
    var viewer: String?
    var cloning: Bool
    var clone: () -> Void
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: repo.isFork ? "tuningfork" : "book.closed")
                .font(.system(size: 12)).foregroundStyle(N.text2).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(repo.name).font(NFont.small.weight(.medium)).foregroundStyle(N.text).lineLimit(1)
                    if let viewer, repo.owner.caseInsensitiveCompare(viewer) != .orderedSame {
                        Text(repo.owner).font(NFont.caption).foregroundStyle(N.text3).lineLimit(1)
                    }
                    if repo.isPrivate { Tag(text: "Private", color: .gray) }
                }
                if let description = repo.description, !description.isEmpty {
                    Text(description).font(NFont.caption).foregroundStyle(N.text2).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 12)
            if let language = repo.language { GHLanguageDot(language: language).font(NFont.caption).foregroundStyle(N.text2) }
            Text(RepoFormat.ago(repo.pushedAt)).font(NFont.caption).foregroundStyle(N.text3)
                .frame(width: 76, alignment: .trailing)
            Button(action: clone) {
                if cloning {
                    HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Cloning") }
                } else {
                    Label("Clone", systemImage: "arrow.down.to.line").labelStyle(TightLabelStyle())
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(cloning)
            .help("gh repo clone \(repo.slug) into your first code folder")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Open in Lookout", action: open)
            Button("Open on GitHub") { ProcessManager.openURL(repo.url) }
            Button("Copy Clone Command") { RepoActions.copy("gh repo clone \(repo.slug)") }
        }
    }
}
