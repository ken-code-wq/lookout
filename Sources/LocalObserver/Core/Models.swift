import Foundation
import LocalObserverCore

enum ProjectType: String, Codable, CaseIterable {
    case node = "Node"
    case python = "Python"
    case ruby = "Ruby"
    case go = "Go"
    case rust = "Rust"
    case docker = "Docker"
    /// Databases, caches, queues and other backing services (see LocalObserverServices).
    case database = "Database"
    case staticSite = "Static"
    case xcode = "Apple"
    case app = "App"
    case other = "Other"
    case system = "System"

    var symbol: String {
        switch self {
        case .node: return "hexagon"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .ruby: return "diamond"
        case .go: return "hare"
        case .rust: return "gearshape"
        case .docker: return "shippingbox"
        case .database: return "cylinder.split.1x2"
        case .staticSite: return "doc.richtext"
        case .xcode: return "hammer"
        case .app: return "app"
        case .other: return "app.dashed"
        case .system: return "cpu"
        }
    }

    var group: TypeGroup {
        switch self {
        case .node: return .node
        case .python: return .python
        case .docker: return .docker
        case .database: return .databases
        case .app: return .apps
        default: return .other
        }
    }
}

/// Coarse buckets used by the sidebar.
enum TypeGroup: String, CaseIterable, Identifiable, Hashable {
    case node = "Node"
    case python = "Python"
    case docker = "Docker"
    case databases = "Databases"
    case apps = "Apps"
    case other = "Other"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .node: return "hexagon"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .docker: return "shippingbox"
        case .databases: return "cylinder.split.1x2"
        case .apps: return "app"
        case .other: return "square.stack.3d.up"
        }
    }
}

enum HttpState: String, Codable {
    case unknown
    case online
    case offline
    case authRequired
    case error
}

struct ServerEntry: Identifiable, Hashable {
    var id: String { "\(pid)-\(port)-\(bindAddress)" }
    var pid: Int32
    var pgid: Int32 = 0
    var processName: String
    var command: String
    var port: Int
    var bindAddress: String
    var workingDirectory: String
    /// Folder where a project marker (package.json, go.mod…) was found. Falls back to cwd.
    var projectRoot: String
    var projectName: String
    var projectType: ProjectType
    var httpState: HttpState = .unknown
    var statusCode: Int = 0
    var latencyMs: Int = 0
    var pageTitle: String = ""
    /// `<link rel="icon" href>` from the served HTML, if any.
    var iconHref: String = ""
    var cpu: Double = 0
    var rssKB: Int = 0
    var uptime: TimeInterval = 0
    var managedID: UUID? = nil
    /// Branch and worktree of the folder it was started from, when that's a git checkout.
    var git: GitCheckout? = nil

    var isManaged: Bool { managedID != nil }
    var isInWorktree: Bool { git?.isLinkedWorktree ?? false }

    var urlString: String {
        let host: String
        switch bindAddress {
        case "*", "0.0.0.0", "::", "::1", "127.0.0.1": host = "localhost"
        default: host = bindAddress.contains(":") ? "[\(bindAddress)]" : bindAddress
        }
        return "http://\(host):\(port)"
    }

    /// `/Applications/Foo.app` when the process lives inside an app bundle.
    var appBundlePath: String? {
        guard let r = command.range(of: ".app/") else { return nil }
        let path = String(command[..<r.lowerBound]) + ".app"
        return path.hasPrefix("/") ? path : nil
    }

    /// Stable key for icon caching.
    var iconKey: String {
        if !projectRoot.isEmpty { return projectRoot }
        return appBundlePath ?? "port:\(port):\(processName)"
    }

    var displayPath: String {
        guard !workingDirectory.isEmpty, workingDirectory != "/" else { return "" }
        return workingDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// `command`, but with the noisy bits (nvm/homebrew interpreter paths, $HOME) collapsed —
    /// what you'd want to read in a tooltip, not what the shell actually saw.
    var friendlyCommand: String {
        var tokens = command.split(separator: " ").map(String.init)
        for i in tokens.indices {
            var t = tokens[i]
            guard t.contains("/") else { continue }
            // Interpreter/tool paths (nvm, homebrew, volta, asdf…) → just the binary name.
            if let range = t.range(of: "/bin/") {
                let bin = String(t[range.upperBound...])
                if !bin.isEmpty, !bin.contains("/") { t = bin }
            } else if let range = t.range(of: "node_modules/") {
                // Long installed-package paths → just the bit that matters, e.g. "openclaw/dist/index.js".
                t = String(t[range.upperBound...])
            } else {
                t = t.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            }
            tokens[i] = t
        }
        let joined = tokens.joined(separator: " ")
        return joined.count > 140 ? String(joined.prefix(140)) + "…" : joined
    }

    var isResponding: Bool { httpState == .online || httpState == .authRequired }

    var isSystemProcess: Bool {
        let lower = (processName + " " + command).lowercased()
        let markers = ["rapportd", "controlcenter", "sharingd", "accountsd", "identityservicesd",
                       "remoted", "airplay", "/system/library/", "/usr/libexec/"]
        return processName == "launchd" || markers.contains { lower.contains($0) }
    }

    var memoryText: String {
        guard rssKB > 0 else { return "—" }
        let mb = Double(rssKB) / 1024
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    var uptimeText: String { Self.formatDuration(uptime) }

    static func formatDuration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "—" }
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86_400)d \(s % 86_400 / 3600)h"
    }
}

struct ManagedServer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var workingDirectory: String
    var command: String
    var port: Int? = nil
    var createdAt = Date()
    /// Process group of the last launch, so we can stop the whole tree (npm → node).
    var lastPGID: Int32? = nil

    var logPath: String { ProcessManager.logURL(for: self).path }
}

// MARK: - Server filters

enum ServerStatusFilter: String, CaseIterable, Identifiable, Hashable {
    case online = "Online"
    case authRequired = "Auth required"
    case httpError = "HTTP error"
    case tcpOnly = "TCP only"
    var id: String { rawValue }

    init(_ server: ServerEntry) {
        switch server.httpState {
        case .online: self = .online
        case .authRequired: self = .authRequired
        case .error: self = .httpError
        case .offline, .unknown: self = .tcpOnly
        }
    }
}

enum ServerOrigin: String, CaseIterable, Identifiable, Hashable {
    case any = "Any origin"
    case launcher = "From launchers"
    case external = "Started elsewhere"
    var id: String { rawValue }
}

enum ServerExposure: String, CaseIterable, Identifiable, Hashable {
    case any = "Any address"
    case loopback = "This Mac only"
    case network = "Reachable on network"
    var id: String { rawValue }

    static func isLoopback(_ address: String) -> Bool {
        ["127.0.0.1", "::1", "localhost"].contains(address) || address.hasPrefix("127.")
    }
}

enum ServerMemoryFilter: Int, CaseIterable, Identifiable, Hashable {
    case any = 0
    case over100MB = 102_400
    case over500MB = 512_000
    case over1GB = 1_048_576
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .any: return "Any memory"
        case .over100MB: return "Over 100 MB"
        case .over500MB: return "Over 500 MB"
        case .over1GB: return "Over 1 GB"
        }
    }
}

enum ServerUptimeFilter: String, CaseIterable, Identifiable, Hashable {
    case any = "Any uptime"
    case underHour = "Started < 1 hour ago"
    case overHour = "Up > 1 hour"
    case overDay = "Up > 1 day"
    var id: String { rawValue }

    func matches(_ uptime: TimeInterval) -> Bool {
        switch self {
        case .any: return true
        case .underHour: return uptime < 3600
        case .overHour: return uptime >= 3600
        case .overDay: return uptime >= 86_400
        }
    }
}

enum PortRangeFilter: String, CaseIterable, Identifiable, Hashable {
    case any = "Any port"
    case wellKnown = "Below 1024"
    case dev = "1024 – 9999"
    case high = "10000 and up"
    var id: String { rawValue }

    func matches(_ port: Int) -> Bool {
        switch self {
        case .any: return true
        case .wellKnown: return port < 1024
        case .dev: return (1024..<10_000).contains(port)
        case .high: return port >= 10_000
        }
    }
}

enum ServerCheckoutFilter: String, CaseIterable, Identifiable, Hashable {
    case any = "Any checkout"
    case main = "Main checkout"
    case worktree = "Worktrees"
    case none = "Not in git"
    var id: String { rawValue }

    func matches(_ s: ServerEntry) -> Bool {
        switch self {
        case .any: return true
        case .main: return s.git != nil && !s.isInWorktree
        case .worktree: return s.isInWorktree
        case .none: return s.git == nil
        }
    }
}

/// Filters on the servers table, layered on top of the sidebar group and search. Empty sets mean "everything".
struct ServerFilter: Hashable {
    var statuses: Set<ServerStatusFilter> = []
    var types: Set<ProjectType> = []
    var origin: ServerOrigin = .any
    var exposure: ServerExposure = .any
    var memory: ServerMemoryFilter = .any
    var uptime: ServerUptimeFilter = .any
    var ports: PortRangeFilter = .any
    var checkout: ServerCheckoutFilter = .any

    var isNarrowed: Bool { self != ServerFilter() }

    func matches(_ s: ServerEntry) -> Bool {
        if !statuses.isEmpty, !statuses.contains(ServerStatusFilter(s)) { return false }
        if !types.isEmpty, !types.contains(s.projectType) { return false }
        switch origin {
        case .any: break
        case .launcher: if !s.isManaged { return false }
        case .external: if s.isManaged { return false }
        }
        switch exposure {
        case .any: break
        case .loopback: if !ServerExposure.isLoopback(s.bindAddress) { return false }
        case .network: if ServerExposure.isLoopback(s.bindAddress) { return false }
        }
        if memory != .any, s.rssKB < memory.rawValue { return false }
        return uptime.matches(s.uptime) && ports.matches(s.port) && checkout.matches(s)
    }
}
