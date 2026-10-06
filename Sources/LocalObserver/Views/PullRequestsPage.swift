import SwiftUI
import LocalObserverRepos

/// Your open pull requests and the ones waiting on your review, with their checks.
struct PullRequestsPage: View {
    @ObservedObject var store: RepoStore
    @State private var width: CGFloat = 900

    var body: some View {
        let query = store.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let match: (PullRequest) -> Bool = { pr in
            query.isEmpty || [pr.title, pr.repo, pr.branch, "#\(pr.number)", pr.author].contains { $0.lowercased().contains(query) }
        }
        let reviews = store.reviewRequests.filter(match)
        let mine = store.myPulls.filter(match)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: SidebarItem.pullRequests.symbol, title: SidebarItem.pullRequests.title, subtitle: AnyView(summary))
                GitHubStatusBanner(store: store)
                if store.gitHub.login != nil || !store.pulls.isEmpty {
                    group("Waiting on your review", symbol: "eye", pulls: reviews,
                          empty: "No one is waiting on you.")
                    group("Your pull requests", symbol: "arrow.triangle.pull", pulls: mine,
                          empty: "You have no open pull requests.")
                } else if case .unknown = store.gitHub {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Asking GitHub…").font(NFont.small).foregroundStyle(N.text2)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 64)
                }
            }
            .padding(.horizontal, width > 1100 ? 64 : (width > 800 ? 44 : 24))
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            if let login = store.gitHub.login { Label(login, systemImage: "person.crop.circle") }
            Label("\(store.myPulls.count) open", systemImage: "arrow.triangle.pull")
            if !store.failingPulls.isEmpty {
                Label("\(store.failingPulls.count) failing", systemImage: "xmark.circle").foregroundStyle(TagColor.red.fg)
            }
            if !store.runningPulls.isEmpty {
                Label("\(store.runningPulls.count) running", systemImage: "circle.dotted.circle").foregroundStyle(TagColor.yellow.fg)
            }
            if !store.readyPulls.isEmpty {
                Label("\(store.readyPulls.count) ready to merge", systemImage: "checkmark.circle").foregroundStyle(TagColor.green.fg)
            }
            RelativeTimeText(date: store.lastGitHub)
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .labelStyle(TightLabelStyle())
    }

    private func group(_ title: String, symbol: String, pulls: [PullRequest], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11.5))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(pulls.count)").font(NFont.small).foregroundStyle(N.text3).monospacedDigit()
            }
            .foregroundStyle(N.text)
            .padding(.top, 22)
            .padding(.bottom, 6)
            Rectangle().fill(N.divider).frame(height: 1)
            if pulls.isEmpty {
                Text(empty).font(NFont.small).foregroundStyle(N.text3).padding(.vertical, 14).padding(.leading, 8)
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(pulls) { PullRow(store: store, pull: $0) }
                }
                .padding(.top, 2)
            }
        }
    }
}
