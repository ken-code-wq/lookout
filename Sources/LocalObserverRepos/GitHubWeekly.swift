import Foundation

// Pull requests you opened and merged in a date range, for the weekly report. Two search counts in one query.

extension GitHubAPI {
    /// Your pull requests created in `[from, to)` and merged in it, across every repository GitHub lets you search.
    public static func pullCounts(from: Date, to: Date) -> Result<(opened: Int, merged: Int), Failure> {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        // Search ranges are inclusive; stop a second short of the next week.
        let range = "\(formatter.string(from: from))..\(formatter.string(from: to.addingTimeInterval(-1)))"
        let query = """
        query($opened: String!, $merged: String!) {
          opened: search(query: $opened, type: ISSUE, first: 1) { issueCount }
          merged: search(query: $merged, type: ISSUE, first: 1) { issueCount }
        }
        """
        return graphQL(query, ["opened": "is:pr author:@me created:\(range)", "merged": "is:pr author:@me is:merged merged:\(range)"])
            .map { data in
                (opened: dict(data["opened"])?["issueCount"] as? Int ?? 0, merged: dict(data["merged"])?["issueCount"] as? Int ?? 0)
            }
    }
}
