import Foundation

// The contribution graph from your GitHub profile, a year at a time, and what a single day held.

public struct GHContributionDay: Identifiable, Hashable, Sendable {
    public var id: String { date }
    /// `yyyy-MM-dd`, as GitHub sends it (in your profile's time zone).
    public var date: String
    public var count: Int
    /// 0…4, GitHub's own quartile for the colour.
    public var level: Int
    public var weekday: Int

    public init(date: String, count: Int, level: Int, weekday: Int) {
        self.date = date
        self.count = count
        self.level = level
        self.weekday = weekday
    }

    public static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    public var day: Date? { Self.parser.date(from: date) }
}

public struct GHRepoContribution: Hashable, Sendable {
    public var repo: String
    public var count: Int
    public var color: String?

    public init(repo: String, count: Int, color: String? = nil) {
        self.repo = repo
        self.count = count
        self.color = color
    }
}

public struct GHContributionYear: Hashable, Sendable {
    public var year: Int?
    public var weeks: [[GHContributionDay]]
    public var total: Int
    public var commits: Int
    public var pulls: Int
    public var reviews: Int
    public var issues: Int
    /// Contributions to private repositories GitHub counts but won't itemise.
    public var restricted: Int
    public var topRepos: [GHRepoContribution]
    public var years: [Int]

    public init(year: Int?, weeks: [[GHContributionDay]], total: Int, commits: Int = 0, pulls: Int = 0, reviews: Int = 0, issues: Int = 0,
                restricted: Int = 0, topRepos: [GHRepoContribution] = [], years: [Int] = []) {
        self.year = year
        self.weeks = weeks
        self.total = total
        self.commits = commits
        self.pulls = pulls
        self.reviews = reviews
        self.issues = issues
        self.restricted = restricted
        self.topRepos = topRepos
        self.years = years
    }

    public var days: [GHContributionDay] { weeks.flatMap { $0 } }

    /// Streaks over the days in this graph: the longest run, and the current one (today may still be empty).
    public var streaks: (current: Int, longest: Int) {
        let days = self.days
        var longest = 0, run = 0
        for d in days { run = d.count > 0 ? run + 1 : 0; longest = max(longest, run) }
        var current = 0
        for (i, d) in days.reversed().enumerated() {
            if d.count > 0 { current += 1 } else if i == 0 { continue } else { break }
        }
        return (current, longest)
    }

    public var busiestDay: GHContributionDay? { days.max { $0.count < $1.count } }
    public var activeDays: Int { days.filter { $0.count > 0 }.count }

    /// Contributions per weekday, Sunday first: which days you actually work.
    public var byWeekday: [Int] {
        var totals = Array(repeating: 0, count: 7)
        for d in days { totals[max(0, min(6, d.weekday))] += d.count }
        return totals
    }
}

/// What one day held: commits per repository and the pull requests, reviews and issues you opened.
public struct GHContributionDetail: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var kind: String
        public var title: String
        public var repo: String
        public var number: Int
        public var url: String
    }
    public var commits: [GHRepoContribution]
    public var items: [Item]
    public var restricted: Int

    public init(commits: [GHRepoContribution], items: [Item], restricted: Int) {
        self.commits = commits
        self.items = items
        self.restricted = restricted
    }
}

extension GitHubAPI {
    static let calendarFields = """
    contributionYears totalCommitContributions totalPullRequestContributions totalPullRequestReviewContributions
    totalIssueContributions restrictedContributionsCount
    contributionCalendar { totalContributions weeks { contributionDays { date contributionCount contributionLevel weekday } } }
    commitContributionsByRepository(maxRepositories: 8) { repository { nameWithOwner primaryLanguage { color } } contributions { totalCount } }
    """

    /// The last twelve months when `year` is nil, else that calendar year.
    public static func contributions(year: Int?) -> Result<GHContributionYear, Failure> {
        let range: String
        if let year {
            range = "(from: \"\(year)-01-01T00:00:00Z\", to: \"\(year)-12-31T23:59:59Z\")"
        } else {
            range = ""
        }
        let query = "query { viewer { contributionsCollection\(range) { \(calendarFields) } } }"
        return graphQL(query, timeout: 45).flatMap { data in
            guard let c = dict(dict(data["viewer"])?["contributionsCollection"]) else { return .failure(Failure("No contributions")) }
            let calendar = dict(c["contributionCalendar"])
            let weeks = ((calendar?["weeks"] as? [[String: Any]]) ?? []).map { week in
                ((week["contributionDays"] as? [[String: Any]]) ?? []).compactMap { d -> GHContributionDay? in
                    guard let date = d["date"] as? String else { return nil }
                    let level: Int = switch d["contributionLevel"] as? String {
                    case "FIRST_QUARTILE": 1
                    case "SECOND_QUARTILE": 2
                    case "THIRD_QUARTILE": 3
                    case "FOURTH_QUARTILE": 4
                    default: 0
                    }
                    return GHContributionDay(date: date, count: d["contributionCount"] as? Int ?? 0, level: level, weekday: d["weekday"] as? Int ?? 0)
                }
            }
            let repos = ((c["commitContributionsByRepository"] as? [[String: Any]]) ?? []).compactMap { r -> GHRepoContribution? in
                guard let repo = dict(r["repository"]), let name = repo["nameWithOwner"] as? String else { return nil }
                return GHRepoContribution(repo: name, count: count(r["contributions"]), color: dict(repo["primaryLanguage"])?["color"] as? String)
            }
            return .success(GHContributionYear(
                year: year, weeks: weeks, total: calendar?["totalContributions"] as? Int ?? 0,
                commits: c["totalCommitContributions"] as? Int ?? 0, pulls: c["totalPullRequestContributions"] as? Int ?? 0,
                reviews: c["totalPullRequestReviewContributions"] as? Int ?? 0, issues: c["totalIssueContributions"] as? Int ?? 0,
                restricted: c["restrictedContributionsCount"] as? Int ?? 0, topRepos: repos,
                years: (c["contributionYears"] as? [Int]) ?? []))
        }
    }

    public static func contributionDetail(date: String) -> Result<GHContributionDetail, Failure> {
        let query = """
        query($from: DateTime!, $to: DateTime!) { viewer { contributionsCollection(from: $from, to: $to) {
          restrictedContributionsCount
          commitContributionsByRepository(maxRepositories: 25) { repository { nameWithOwner primaryLanguage { color } } contributions { totalCount } }
          pullRequestContributions(first: 20) { nodes { pullRequest { title number url repository { nameWithOwner } } } }
          pullRequestReviewContributions(first: 20) { nodes { pullRequest { title number url repository { nameWithOwner } } } }
          issueContributions(first: 20) { nodes { issue { title number url repository { nameWithOwner } } } }
        } } }
        """
        return graphQL(query, ["from": "\(date)T00:00:00Z", "to": "\(date)T23:59:59Z"]).flatMap { data in
            guard let c = dict(dict(data["viewer"])?["contributionsCollection"]) else { return .failure(Failure("No contributions")) }
            let commits = ((c["commitContributionsByRepository"] as? [[String: Any]]) ?? []).compactMap { r -> GHRepoContribution? in
                guard let repo = dict(r["repository"]), let name = repo["nameWithOwner"] as? String else { return nil }
                return GHRepoContribution(repo: name, count: count(r["contributions"]), color: dict(repo["primaryLanguage"])?["color"] as? String)
            }
            func items(_ key: String, _ field: String, _ kind: String) -> [GHContributionDetail.Item] {
                nodes(c[key]).compactMap { n in
                    guard let x = dict(n[field]) else { return nil }
                    return GHContributionDetail.Item(kind: kind, title: x["title"] as? String ?? "",
                                                     repo: dict(x["repository"])?["nameWithOwner"] as? String ?? "",
                                                     number: x["number"] as? Int ?? 0, url: x["url"] as? String ?? "")
                }
            }
            return .success(GHContributionDetail(
                commits: commits,
                items: items("pullRequestContributions", "pullRequest", "Opened") + items("pullRequestReviewContributions", "pullRequest", "Reviewed")
                    + items("issueContributions", "issue", "Issue"),
                restricted: c["restrictedContributionsCount"] as? Int ?? 0))
        }
    }
}
