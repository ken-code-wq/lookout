import Foundation
import LocalObserverCore
import LocalObserverRepos

/// Which week the report sheet shows, the reports for it (cached per ledger revision), and the GitHub numbers that
/// come from the network. Shared, so the Usage page, ⌘K and the digest can all open the same sheet.
@MainActor
final class WeeklyReportModel: ObservableObject {
    static let shared = WeeklyReportModel()

    enum PullState: Equatable {
        case loading
        case loaded(WeeklyPulls)
        case unavailable(String)
    }

    @Published var isPresented = false
    /// Start of the week on show.
    @Published var weekStart = WeeklyReport.week(containing: Date()).start
    @Published private(set) var pulls: [Date: PullState] = [:]

    private var isDemo = false
    private var cache: [String: (current: WeeklyReport, previous: WeeklyReport)] = [:]

    func open(weekOf date: Date = Date()) {
        weekStart = WeeklyReport.week(containing: date).start
        isPresented = true
    }

    var isCurrentWeek: Bool { weekStart >= WeeklyReport.week(containing: Date()).start }

    func step(_ offset: Int) {
        let target = WeeklyReport.week(offset: offset, from: weekStart).start
        guard target <= WeeklyReport.week(containing: Date()).start else { return }
        weekStart = target
    }

    /// The week on show and the one before it (cut to the same stretch while the week is under way).
    func reports(store: AgentStore, github: GitHubStore, weekOf date: Date? = nil, now: Date = Date()) -> (current: WeeklyReport, previous: WeeklyReport) {
        let start = WeeklyReport.week(containing: date ?? weekStart).start
        let previousStart = WeeklyReport.week(offset: -1, from: start).start
        let graph = contributions(github)
        let pullsNow = loadedPulls(start), pullsBefore = loadedPulls(previousStart)
        // A week under way moves with the clock; a finished one only when the ledger or GitHub numbers change.
        let minute = start == WeeklyReport.week(containing: now).start ? Int(now.timeIntervalSince1970 / 60) : 0
        let key = "\(start.timeIntervalSince1970)|\(store.ledgerRevision)|\(graph.count)|\(String(describing: pullsNow))|\(String(describing: pullsBefore))|\(minute)"
        if let hit = cache[key] { return hit }
        let current = WeeklyReport.build(events: store.ledgerEvents, weekOf: start, now: now, contributions: graph.isEmpty ? nil : graph, pulls: pullsNow)
        let previous = WeeklyReport.previous(to: current, events: store.ledgerEvents, contributions: graph.isEmpty ? nil : graph,
                                             pulls: current.isPartial ? nil : pullsBefore)
        if cache.count > 24 { cache.removeAll() }
        cache[key] = (current, previous)
        return (current, previous)
    }

    /// Asks GitHub for the pull requests you opened and merged in a week, once per week per launch.
    func loadPulls(for week: DateInterval) {
        guard !isDemo, pulls[week.start] == nil else { return }
        guard RepoGitHub.cliPath != nil else {
            pulls[week.start] = .unavailable("Install the GitHub CLI to include pull requests")
            return
        }
        pulls[week.start] = .loading
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { GitHubAPI.pullCounts(from: week.start, to: week.end) }.value
            switch result {
            case .success(let counts): self?.pulls[week.start] = .loaded(WeeklyPulls(opened: counts.opened, merged: counts.merged))
            case .failure(let failure): self?.pulls[week.start] = .unavailable(failure.message)
            }
        }
    }

    private func loadedPulls(_ start: Date) -> WeeklyPulls? {
        if case .loaded(let value) = pulls[start] { return value }
        return nil
    }

    /// Every loaded contribution graph, keyed by day.
    private func contributions(_ github: GitHubStore) -> [String: Int] {
        var days: [String: Int] = [:]
        for year in github.contributions.values {
            for day in year.days { days[day.date] = day.count }
        }
        return days
    }

    /// Debug/demo: pull request counts per week start, so the snapshot never calls GitHub.
    func loadDemo(pulls demo: [Date: WeeklyPulls]) {
        isDemo = true
        pulls = demo.mapValues { .loaded($0) }
    }
}
