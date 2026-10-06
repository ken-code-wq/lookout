import Foundation

/// What the `lookout` CLI and the read-only App Intents report: the widget snapshot, flattened into a stable
/// shape for scripts. Built from the file the app already writes, so nothing outside the app scans or asks
/// providers for anything.
public struct LookoutStatus: Codable, Sendable {
    /// The app rewrites the snapshot at least every 5 minutes while it runs (see WidgetPublisher).
    public static let staleAfter: TimeInterval = 10 * 60

    public var generatedAt: Date
    public var stale: Bool
    public var agents: [Agent]
    public var limits: [Limit]
    public var servers: [Server]
    public var today: Today

    public struct Agent: Codable, Sendable, Hashable {
        public var id: String
        public var agent: String
        public var agentName: String
        public var project: String
        public var title: String
        public var model: String
        public var state: String
        public var stateTitle: String
        public var needsAttention: Bool
        public var startedAt: Date
        public var tokens: Int64?
    }

    public struct Limit: Codable, Sendable, Hashable {
        public var agent: String
        public var agentName: String
        public var plan: String
        public var window: String
        public var usedPercent: Double
        public var remainingPercent: Double
        public var resetsAt: Date?
        /// The window shown for this provider in the notch and menu bar.
        public var headline: Bool
    }

    public struct Server: Codable, Sendable, Hashable {
        public var port: Int
        public var name: String
        public var url: String
        public var health: String
        public var status: String
        public var uptimeSeconds: Int
    }

    public struct Today: Codable, Sendable, Hashable {
        public var tokens: Int64
        public var cost: Double?
        public var costIsEstimated: Bool
        public var sessions: Int
    }

    public init(_ snapshot: WidgetSnapshot, now: Date = .now) {
        generatedAt = snapshot.generatedAt
        stale = now.timeIntervalSince(snapshot.generatedAt) > Self.staleAfter
        agents = snapshot.sessions.map { s in
            Agent(id: s.id, agent: s.agent.rawValue, agentName: s.agent.name, project: s.project, title: s.title, model: s.model,
                  state: s.state.rawValue, stateTitle: s.state.title, needsAttention: s.needsAttention, startedAt: s.startedAt, tokens: s.tokens)
        }
        limits = snapshot.providers.flatMap { provider in
            let headline = provider.headline?.id
            return provider.windows.map { w in
                Limit(agent: provider.agent.rawValue, agentName: provider.agent.name, plan: provider.plan, window: w.label,
                      usedPercent: w.usedPercent, remainingPercent: max(0, min(100, 100 - w.usedPercent)),
                      resetsAt: w.resetsAt, headline: w.id == headline)
            }
        }
        servers = snapshot.servers.map {
            Server(port: $0.port, name: $0.name, url: $0.url, health: $0.health.rawValue, status: $0.status, uptimeSeconds: Int($0.uptime))
        }
        today = Today(tokens: snapshot.today.processed, cost: snapshot.today.cost, costIsEstimated: snapshot.today.costIsEstimated,
                      sessions: snapshot.today.sessions)
    }

    public var needingAttention: [Agent] { agents.filter(\.needsAttention) }

    /// Percent left in a provider's headline window, or nil when Lookout has no limits for it.
    public func remainingPercent(for agent: AgentKind) -> Double? {
        let windows = limits.filter { $0.agent == agent.rawValue }
        return (windows.first(where: \.headline) ?? windows.min { $0.remainingPercent < $1.remainingPercent })?.remainingPercent
    }

    public static func load(now: Date = .now) -> LookoutStatus? {
        WidgetSnapshot.load().map { LookoutStatus($0, now: now) }
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    // MARK: Text

    public var agentsText: String {
        guard !agents.isEmpty else { return "No agents running." }
        return Self.table(agents.map { [$0.agentName, $0.stateTitle, $0.project, $0.title] })
    }

    public var limitsText: String {
        guard !limits.isEmpty else { return "No plan limits yet. Connect a provider in Lookout › Settings › Limits." }
        return Self.table(limits.map { l in
            [l.agentName, l.window, "\(Int(l.remainingPercent.rounded()))% left", l.resetsAt.map { "resets \(Self.relative($0))" } ?? ""]
        })
    }

    public var serversText: String {
        guard !servers.isEmpty else { return "No servers listening." }
        return Self.table(servers.map { [":\($0.port)", $0.name, $0.status, $0.url] })
    }

    /// Left-aligned columns, two spaces apart; the last column isn't padded.
    public static func table(_ rows: [[String]]) -> String {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { c in rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { c, cell in c == row.count - 1 ? cell : cell.padding(toLength: widths[c], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "now" }
        if seconds < 3600 { return "in \(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "in \(seconds / 3600)h \(seconds / 60 % 60)m" }
        return "in \(seconds / 86_400)d \(seconds / 3600 % 24)h"
    }
}

/// Where the "Install command-line tool" button puts the `lookout` symlink.
public enum CLIInstallLocation {
    /// `/usr/local/bin` when it exists and we can write to it (Homebrew on Intel, or set up by hand),
    /// otherwise `~/.local/bin`, which needs no admin rights and is created if missing.
    public static func directory(home: String, isWritableDirectory: (String) -> Bool) -> String {
        let system = "/usr/local/bin"
        if isWritableDirectory(system) { return system }
        return (home as NSString).appendingPathComponent(".local/bin")
    }
}
