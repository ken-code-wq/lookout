import Foundation

/// Everything the desktop widgets show, written by the app and read by the sandboxed widget extension.
/// The widgets never scan processes or read agent logs themselves; they only render the last snapshot.
public struct WidgetSnapshot: Codable, Sendable {
    /// Bumped when the shape changes incompatibly, so an old widget never misreads a newer file.
    public static let currentVersion = 1

    public var version = WidgetSnapshot.currentVersion
    public var generatedAt: Date
    public var sessions: [Session]
    public var providers: [Provider]
    /// Providers chosen for the notch and menu bar. Empty means "the tightest window overall".
    public var glanceProviders: [AgentKind]
    public var today: Usage
    public var servers: [Server]

    public init(generatedAt: Date, sessions: [Session], providers: [Provider], glanceProviders: [AgentKind],
                today: Usage, servers: [Server]) {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.providers = providers
        self.glanceProviders = glanceProviders
        self.today = today
        self.servers = servers
    }

    // Lossy: an entry this build can't read (say, an agent added in a newer app) is dropped rather than
    // failing the whole file, which would blank every widget.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        sessions = c.lossy([Session].self, .sessions)
        providers = c.lossy([Provider].self, .providers)
        glanceProviders = c.lossy([AgentKind].self, .glanceProviders)
        today = (try? c.decode(Usage.self, forKey: .today)) ?? .empty
        servers = c.lossy([Server].self, .servers)
    }

    public struct Session: Codable, Sendable, Identifiable, Hashable {
        public var id: String
        public var agent: AgentKind
        public var project: String
        public var title: String
        public var model: String
        public var state: AgentActivityState
        public var startedAt: Date
        public var tokens: Int64?

        public init(id: String, agent: AgentKind, project: String, title: String, model: String,
                    state: AgentActivityState, startedAt: Date, tokens: Int64?) {
            self.id = id
            self.agent = agent
            self.project = project
            self.title = title
            self.model = model
            self.state = state
            self.startedAt = startedAt
            self.tokens = tokens
        }

        public var needsAttention: Bool { state == .needsInput || state == .failed }
    }

    public struct Provider: Codable, Sendable, Identifiable, Hashable {
        public var id: AgentKind { agent }
        public var agent: AgentKind
        public var plan: String
        public var windows: [Window]
        /// The window the user picked as this provider's headline (Settings › Menu Bar & Notch).
        public var headlineID: String?

        public init(agent: AgentKind, plan: String, windows: [Window], headlineID: String?) {
            self.agent = agent
            self.plan = plan
            self.windows = windows
            self.headlineID = headlineID
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agent = try c.decode(AgentKind.self, forKey: .agent)
            plan = (try? c.decode(String.self, forKey: .plan)) ?? ""
            windows = c.lossy([Window].self, .windows)
            headlineID = try? c.decode(String.self, forKey: .headlineID)
        }

        public var headline: Window? {
            windows.first { $0.id == headlineID } ?? windows.max { $0.usedPercent < $1.usedPercent }
        }
    }

    public struct Window: Codable, Sendable, Identifiable, Hashable {
        public var id: String
        public var agent: AgentKind
        public var label: String
        public var kind: AgentLimitKind
        public var usedPercent: Double
        public var resetsAt: Date?
        public var windowDuration: TimeInterval?
        public var observedAt: Date

        public init(_ window: AgentQuotaWindow) {
            id = window.id
            agent = window.agent
            label = window.label
            kind = window.kind
            usedPercent = window.usedPercent
            resetsAt = window.resetsAt
            windowDuration = window.windowDuration
            observedAt = window.observedAt
        }

        /// Back to the core type, so pace and formatting share one implementation with the app.
        public var quotaWindow: AgentQuotaWindow {
            AgentQuotaWindow(id: id, agent: agent, label: label, kind: kind, usedPercent: usedPercent,
                             resetsAt: resetsAt, windowDuration: windowDuration, observedAt: observedAt,
                             source: "widget", account: "")
        }
    }

    public struct Usage: Codable, Sendable, Hashable {
        public var processed: Int64
        public var cost: Double?
        public var costIsEstimated: Bool
        public var sessions: Int
        public var cacheHitRate: Double?
        /// Last 24 hours, one bucket per (hour, agent), oldest first. Token counts.
        public var hourly: [Bucket]
        /// Today's models by tokens, most first.
        public var models: [Model]

        public init(processed: Int64, cost: Double?, costIsEstimated: Bool, sessions: Int, cacheHitRate: Double?,
                    hourly: [Bucket], models: [Model]) {
            self.processed = processed
            self.cost = cost
            self.costIsEstimated = costIsEstimated
            self.sessions = sessions
            self.cacheHitRate = cacheHitRate
            self.hourly = hourly
            self.models = models
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            processed = (try? c.decode(Int64.self, forKey: .processed)) ?? 0
            cost = try? c.decode(Double.self, forKey: .cost)
            costIsEstimated = (try? c.decode(Bool.self, forKey: .costIsEstimated)) ?? false
            sessions = (try? c.decode(Int.self, forKey: .sessions)) ?? 0
            cacheHitRate = try? c.decode(Double.self, forKey: .cacheHitRate)
            hourly = c.lossy([Bucket].self, .hourly)
            models = c.lossy([Model].self, .models)
        }

        public static let empty = Usage(processed: 0, cost: nil, costIsEstimated: false, sessions: 0,
                                        cacheHitRate: nil, hourly: [], models: [])
    }

    public struct Bucket: Codable, Sendable, Hashable {
        public var date: Date
        public var agent: AgentKind
        public var value: Double

        public init(date: Date, agent: AgentKind, value: Double) {
            self.date = date
            self.agent = agent
            self.value = value
        }
    }

    public struct Model: Codable, Sendable, Hashable, Identifiable {
        public var id: String { title }
        public var title: String
        public var agent: AgentKind?
        public var tokens: Int64
        public var cost: Double?
        public var share: Double

        public init(title: String, agent: AgentKind?, tokens: Int64, cost: Double?, share: Double) {
            self.title = title
            self.agent = agent
            self.tokens = tokens
            self.cost = cost
            self.share = share
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            agent = try? c.decode(AgentKind.self, forKey: .agent)
            tokens = (try? c.decode(Int64.self, forKey: .tokens)) ?? 0
            cost = try? c.decode(Double.self, forKey: .cost)
            share = (try? c.decode(Double.self, forKey: .share)) ?? 0
        }
    }

    public struct Server: Codable, Sendable, Hashable, Identifiable {
        public enum Health: String, Codable, Sendable { case live, warning, failing, quiet }

        public var id: String { "\(port)-\(name)" }
        public var port: Int
        public var name: String
        public var url: String
        /// SF Symbol for the project type, matching the Servers page.
        public var symbol: String
        public var health: Health
        /// "Live · 12ms", "404", "TCP only": the same words as the Servers page.
        public var status: String
        public var uptime: TimeInterval
        /// PNG in `WidgetSnapshot.iconsDirectory`: the favicon or app icon the Servers page shows. Nil until resolved.
        public var icon: String?

        public init(port: Int, name: String, url: String, symbol: String, health: Health, status: String, uptime: TimeInterval,
                    icon: String? = nil) {
            self.port = port
            self.name = name
            self.url = url
            self.symbol = symbol
            self.health = health
            self.status = status
            self.uptime = uptime
            self.icon = icon
        }
    }
}

// MARK: - Lossy decoding

/// Decodes whatever elements it can and skips the rest.
private struct LossyElement<Element: Decodable>: Decodable {
    var value: Element?
    init(from decoder: Decoder) throws { value = try? Element(from: decoder) }
}

extension KeyedDecodingContainer {
    func lossy<Element: Decodable>(_ type: [Element].Type, _ key: Key) -> [Element] {
        ((try? decode([LossyElement<Element>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

// MARK: - Storage

extension WidgetSnapshot {
    /// `~/Library/Application Support/LocalObserver/Widgets/`. The widget's sandbox has a read-only exception
    /// for exactly this folder (packaging/Widgets.entitlements), so both sides must resolve the real home,
    /// not the sandbox container `NSHomeDirectory()` returns inside the extension.
    public static var directory: URL {
        URL(fileURLWithPath: realHome)
            .appendingPathComponent("Library/Application Support/LocalObserver/Widgets", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("snapshot.json") }
    public static var iconsDirectory: URL { directory.appendingPathComponent("icons", isDirectory: true) }

    private static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }

    public func write() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }
}
