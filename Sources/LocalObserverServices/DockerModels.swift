import Foundation

/// Whether Lookout can talk to Docker right now, and if not, why. Shown as is, so "not installed" and "not running"
/// never look like "no containers".
public enum DockerAvailability: Hashable, Sendable {
    case unknown
    case notInstalled
    /// The CLI is there but the daemon (Docker Desktop, OrbStack, Colima…) isn't answering.
    case daemonDown(String)
    case failed(String)
    case ready

    public var isReady: Bool { self == .ready }

    /// Reads a failed `docker` call: a daemon that isn't running says so in a few different ways.
    public static func classify(status: Int32, stderr: String) -> DockerAvailability {
        guard status != 0 else { return .ready }
        let message = stderr.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let lower = stderr.lowercased()
        let downMarkers = ["cannot connect to the docker daemon", "is the docker daemon running", "error during connect",
                           "docker.sock: connect: no such file", "connection refused", "docker desktop is not running"]
        if downMarkers.contains(where: lower.contains) { return .daemonDown(message) }
        return .failed(message.isEmpty ? "docker exited with \(status)" : message)
    }
}

public enum DockerState: String, Sendable, Codable, CaseIterable {
    case running, paused, restarting, created, exited, dead, removing

    public var title: String {
        switch self {
        case .running: return "Running"
        case .paused: return "Paused"
        case .restarting: return "Restarting"
        case .created: return "Created"
        case .exited: return "Stopped"
        case .dead: return "Dead"
        case .removing: return "Removing"
        }
    }

    public var isUp: Bool { self == .running || self == .restarting || self == .paused }
}

/// One published (or merely exposed) container port.
public struct DockerPort: Hashable, Sendable, Codable {
    public var hostIP: String?
    /// Nil when the port is exposed but not published to the Mac.
    public var hostPort: Int?
    public var containerPort: Int
    public var proto: String

    public init(hostIP: String? = nil, hostPort: Int?, containerPort: Int, proto: String = "tcp") {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }

    public var label: String {
        guard let hostPort else { return "\(containerPort)/\(proto) (not published)" }
        return hostPort == containerPort ? ":\(hostPort)" : ":\(hostPort) → \(containerPort)"
    }
}

public struct DockerContainer: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var image: String
    public var state: DockerState
    /// Docker's own words: "Up 2 hours (healthy)", "Exited (0) 3 days ago".
    public var status: String
    public var ports: [DockerPort]
    public var labels: [String: String]
    public var createdAt: Date?
    /// How long it's been up, read from `status` (or from `docker inspect` when that's been read).
    public var uptime: TimeInterval?

    public init(id: String, name: String, image: String, state: DockerState, status: String, ports: [DockerPort] = [],
                labels: [String: String] = [:], createdAt: Date? = nil, uptime: TimeInterval? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
        self.labels = labels
        self.createdAt = createdAt
        self.uptime = uptime
    }

    public var composeProject: String? { labels["com.docker.compose.project"].flatMap { $0.isEmpty ? nil : $0 } }
    public var composeService: String? { labels["com.docker.compose.service"] }
    /// The folder `docker compose up` ran in, so a container leads back to its project.
    public var composeFolder: String? { labels["com.docker.compose.project.working_dir"].flatMap { $0.isEmpty ? nil : $0 } }

    public var kind: ServiceKind? { ServiceRecognizer.kind(image: image) }
    public var publishedPorts: [DockerPort] { ports.filter { $0.hostPort != nil } }
    public var shortID: String { String(id.prefix(12)) }

    /// "healthy", "unhealthy" or "health: starting", when the image has a health check.
    public var health: String? {
        for word in ["unhealthy", "healthy", "health: starting"] where status.contains("(\(word))") { return word }
        return nil
    }

    /// The exit code in "Exited (137) 2 minutes ago".
    public var exitCode: Int? {
        guard state == .exited || state == .dead,
              let open = status.firstIndex(of: "("), let close = status[open...].firstIndex(of: ")") else { return nil }
        return Int(status[status.index(after: open)..<close])
    }

    /// The host port clients use for this service: its default port's mapping, else the first published one.
    public var primaryHostPort: Int? {
        if let kind {
            for port in kind.defaultPorts {
                if let match = ports.first(where: { $0.containerPort == port && $0.hostPort != nil }) { return match.hostPort }
            }
        }
        return publishedPorts.first?.hostPort
    }
}

/// What `docker inspect` adds for one container: its environment (for connection details) and exact start time.
/// Values here can be secrets; they are kept in memory only and never logged.
public struct DockerInspect: Hashable, Sendable {
    public var id: String
    public var env: [String: String]
    public var command: [String]
    public var startedAt: Date?

    public init(id: String, env: [String: String], command: [String] = [], startedAt: Date? = nil) {
        self.id = id
        self.env = env
        self.command = command
        self.startedAt = startedAt
    }
}

/// Containers that belong together: one compose project, or the ones started on their own.
public struct DockerGroup: Identifiable, Hashable, Sendable {
    /// The compose project, or nil for standalone containers.
    public var project: String?
    public var folder: String?
    public var containers: [DockerContainer]

    public var id: String { project ?? "" }
    public var title: String { project ?? "Standalone" }
    public var running: Int { containers.filter { $0.state.isUp }.count }

    /// Compose projects first, alphabetically, standalone containers last; running containers before stopped ones.
    public static func group(_ containers: [DockerContainer]) -> [DockerGroup] {
        let byProject = Dictionary(grouping: containers) { $0.composeProject }
        return byProject.map { project, list in
            DockerGroup(project: project, folder: list.lazy.compactMap(\.composeFolder).first,
                        containers: list.sorted { a, b in
                            if a.state.isUp != b.state.isUp { return a.state.isUp }
                            return a.name.localizedStandardCompare(b.name) == .orderedAscending
                        })
        }
        .sorted { a, b in
            switch (a.project, b.project) {
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return x.localizedStandardCompare(y) == .orderedAscending
            }
        }
    }
}
