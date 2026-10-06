import Foundation
import LocalObserverCore
import LocalObserverRepos

/// Joins the Agents and Repos pillars without either knowing the other: which repository and branch a session works
/// on, the pull request for that branch, and every session that has worked on a pull request's branch.
@MainActor
enum AgentLinks {
    /// The repository and branch a session works on: its live checkout while running, else where the transcript says it was.
    static func target(of session: AgentSession, in repos: RepoStore) -> (repo: Repo, branch: String)? {
        if let git = session.checkout, let branch = git.branch,
           let repo = repos.repos.first(where: { $0.root == git.mainRoot }) {
            return (repo, branch)
        }
        let path = session.projectPath
        guard !path.isEmpty else { return nil }
        // Worktrees first: they often live outside the repository's own folder.
        for repo in repos.repos {
            if let wt = repo.worktrees.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }),
               let branch = wt.branch ?? (session.branch.isEmpty ? nil : session.branch) {
                return (repo, branch)
            }
        }
        for repo in repos.repos where path == repo.root || path.hasPrefix(repo.root + "/") {
            if let branch = session.branch.isEmpty ? repo.branch : session.branch { return (repo, branch) }
        }
        return nil
    }

    /// Your open pull request for the branch a session works on.
    static func pull(for session: AgentSession, in repos: RepoStore) -> PullRequest? {
        guard let (repo, branch) = target(of: session, in: repos), branch != repo.defaultBranch else { return nil }
        return repos.pull(for: repo, branch: branch)
    }

    /// Every session, running or finished, that worked on `branch` of the repository `slug`; newest first.
    static func sessions(slug: String, branch: String, agents: AgentStore, repos: RepoStore) -> [AgentSession] {
        let running = agents.snapshot.processes
        let seen = Set(running.map(\.sessionID))
        let all = running + agents.snapshot.sessions.filter { !seen.contains($0.sessionID) }
        return all.filter { session in
            guard let (repo, b) = target(of: session, in: repos) else { return false }
            return b == branch && repo.github?.caseInsensitiveCompare(slug) == .orderedSame
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Tokens and cost summed over sessions: what a feature has cost so far.
    static func totals(_ sessions: [AgentSession]) -> (tokens: Int64, cost: Double?, estimated: Bool) {
        let tokens = sessions.reduce(Int64(0)) { $0 + ($1.usage?.processedTokens ?? 0) }
        let costs = sessions.compactMap(\.cost)
        return (tokens, costs.isEmpty ? nil : costs.reduce(0, +), sessions.contains { $0.costIsEstimated })
    }
}
