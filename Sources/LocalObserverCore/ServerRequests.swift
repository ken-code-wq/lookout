import Foundation

// MARK: - Request log

/// A request a dev server printed: Next.js, Vite/Express (morgan), Django, uvicorn/FastAPI, Rails, Go's and Flask's
/// access logs all write a method, a path and a status on one line.
public struct ServerRequest: Identifiable, Hashable, Sendable {
    public var id: Int
    public var method: String
    public var path: String
    public var status: Int
    public var milliseconds: Double?

    public var isError: Bool { status >= 500 }
    public var isClientError: Bool { status >= 400 && status < 500 }

    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(pattern:
        #"\b(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+"?(/[^\s"]*)"?(?:\s+HTTP/[\d.]+"?)?(?:\s+-)?\s+(?:status[= ])?([1-5]\d\d)\b(?:.*?(\d+(?:\.\d+)?)\s?ms)?"#)
    nonisolated(unsafe) private static let railsStart = try! NSRegularExpression(pattern: #"Started (GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) "([^"]+)""#)
    nonisolated(unsafe) private static let railsDone = try! NSRegularExpression(pattern: #"Completed ([1-5]\d\d) .*? in (\d+(?:\.\d+)?)ms"#)

    /// Requests in the order they were logged.
    public static func parse(_ text: String) -> [ServerRequest] {
        var requests: [ServerRequest] = []
        var pending: (String, String)?
        for line in text.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            if let m = pattern.firstMatch(in: s, range: range) {
                func group(_ i: Int) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
                requests.append(ServerRequest(id: requests.count, method: group(1) ?? "GET", path: group(2) ?? "/",
                                              status: Int(group(3) ?? "") ?? 0, milliseconds: group(4).flatMap(Double.init)))
            } else if let m = railsStart.firstMatch(in: s, range: range) {
                pending = (Range(m.range(at: 1), in: s).map { String(s[$0]) } ?? "GET", Range(m.range(at: 2), in: s).map { String(s[$0]) } ?? "/")
            } else if let m = railsDone.firstMatch(in: s, range: range), let (method, path) = pending {
                requests.append(ServerRequest(id: requests.count, method: method, path: path,
                                              status: Range(m.range(at: 1), in: s).flatMap { Int(s[$0]) } ?? 0,
                                              milliseconds: Range(m.range(at: 2), in: s).flatMap { Double(s[$0]) }))
                pending = nil
            }
        }
        return requests
    }

    /// Lines that look like a crash or a stack trace, for the error count.
    public static func errorLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter {
            $0.range(of: #"(?i)^\s*(error|uncaught|unhandled|traceback|exception|panic:)|\b[A-Z]\w*(Error|Exception)\b:"#,
                     options: .regularExpression) != nil
        }
    }
}

