import Foundation

/// Pages a link, the CLI or a Shortcut can open. Slugs are what people type, so each has a few aliases.
public enum LookoutPage: String, CaseIterable, Sendable {
    case dashboard, sessions, usage, limits, repos, github, ci, inbox, pulls, servers, favorites, launchers, containers, cleanup, shelf, clipboard

    public init?(slug: String) {
        let key = slug.lowercased().trimmingCharacters(in: .whitespaces)
        if let page = LookoutPage(rawValue: key) { self = page; return }
        switch key {
        case "home": self = .dashboard
        case "activity", "agents": self = .sessions
        case "repositories": self = .repos
        case "deploys": self = .ci
        case "pull-requests", "prs": self = .pulls
        case "all": self = .servers
        case "disk": self = .cleanup
        case "docker", "databases": self = .containers
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .sessions: return "Sessions"
        case .usage: return "Usage"
        case .limits: return "Plan limits"
        case .repos: return "Repositories"
        case .github: return "GitHub"
        case .ci: return "CI & Deploys"
        case .inbox: return "Inbox"
        case .pulls: return "Pull requests"
        case .servers: return "All servers"
        case .favorites: return "Favorites"
        case .launchers: return "Launchers"
        case .containers: return "Containers"
        case .cleanup: return "Cleanup"
        case .shelf: return "Shelf"
        case .clipboard: return "Clipboard"
        }
    }
}

/// Everything `lookout://` (and the widgets' older `localobserver://`) can ask the app to do.
/// The URL scheme, the CLI and the App Intents all go through this, so they can't drift apart.
public enum LookoutRoute: Equatable, Sendable {
    public enum LauncherAction: String, Sendable { case start, stop, toggle }
    public enum Switch: String, Sendable { case on, off, toggle }

    case open(LookoutPage)
    case session(id: String)
    case launcher(name: String, action: LauncherAction)
    case palette
    /// The "New agent task" sheet.
    case newTask
    case weeklyReport
    case peek
    case keepAwake(Switch)
    /// Minutes for a new focus timer; nil stops the running one.
    case timer(minutes: Int?)
    case refresh
    case checkForUpdates

    public static let scheme = "lookout"
    /// Kept so links from existing widgets keep working.
    public static let legacyScheme = "localobserver"
    public static let defaultTimerMinutes = 25

    /// `lookout://open/usage`, `lookout://launcher/web/start`, `lookout://palette`, `localobserver://limits`…
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == Self.scheme || scheme == Self.legacyScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Split the encoded path so a launcher named "api/v2" survives as one segment.
        let path = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let host = (components.host ?? "").lowercased()

        switch host {
        case "open", "page":
            guard let slug = path.first ?? query["page"], let page = LookoutPage(slug: slug) else { return nil }
            self = .open(page)
        case "session":
            guard let id = query["id"] ?? path.first, !id.isEmpty else { return nil }
            self = .session(id: id)
        case "launcher", "launchers":
            guard path.count >= 2, !path[0].isEmpty, let action = LauncherAction(rawValue: path[1].lowercased()) else {
                if path.isEmpty { self = .open(.launchers); return }
                return nil
            }
            self = .launcher(name: path[0], action: action)
        case "palette", "search": self = .palette
        case "new-task", "task": self = .newTask
        case "weekly-report", "weekly", "report": self = .weeklyReport
        case "peek": self = .peek
        case "keep-awake", "keepawake", "awake":
            guard let value = Switch(rawValue: (path.first ?? "toggle").lowercased()) else { return nil }
            self = .keepAwake(value)
        case "timer", "focus":
            let first = path.first?.lowercased()
            if first == "stop" { self = .timer(minutes: nil); return }
            let raw = query["minutes"] ?? (first == "start" ? path.dropFirst().first : first)
            guard let minutes = raw.map({ Int($0) }) ?? Self.defaultTimerMinutes, (1...24 * 60).contains(minutes) else { return nil }
            self = .timer(minutes: minutes)
        case "refresh": self = .refresh
        case "update", "updates", "check-for-updates": self = .checkForUpdates
        default:
            // `lookout://usage` as a shorthand for `lookout://open/usage`, which is also how the widgets link.
            guard let page = LookoutPage(slug: host) else { return nil }
            self = .open(page)
        }
    }

    /// Index of the launcher a typed name means: an exact (case-insensitive) name first, then the only name
    /// starting with it. Nil when nothing matches or the prefix is ambiguous.
    public static func matchLauncher(_ query: String, names: [String]) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        if let exact = names.firstIndex(where: { $0.lowercased() == q }) { return exact }
        let prefixed = names.indices.filter { names[$0].lowercased().hasPrefix(q) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        func segment(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s
        }
        switch self {
        case .open(let page): components.host = "open"; components.percentEncodedPath = "/" + page.rawValue
        case .session(let id): components.host = "session"; components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .launcher(let name, let action):
            components.host = "launcher"
            components.percentEncodedPath = "/" + segment(name) + "/" + action.rawValue
        case .palette: components.host = "palette"
        case .newTask: components.host = "new-task"
        case .weeklyReport: components.host = "weekly-report"
        case .peek: components.host = "peek"
        case .keepAwake(let value): components.host = "keep-awake"; components.percentEncodedPath = "/" + value.rawValue
        case .timer(let minutes):
            components.host = "timer"
            components.percentEncodedPath = minutes.map { "/start/\($0)" } ?? "/stop"
        case .refresh: components.host = "refresh"
        case .checkForUpdates: components.host = "update"
        }
        return components.url ?? URL(string: "\(Self.scheme)://open/sessions")!
    }
}
