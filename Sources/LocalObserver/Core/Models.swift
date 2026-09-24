import Foundation

enum ProjectType: String, Codable, CaseIterable {
    case node = "Node"
    case python = "Python"
    case ruby = "Ruby"
    case go = "Go"
    case rust = "Rust"
    case docker = "Docker"
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
    case apps = "Apps"
    case other = "Other"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .node: return "hexagon"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .docker: return "shippingbox"
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

    var isManaged: Bool { managedID != nil }

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
