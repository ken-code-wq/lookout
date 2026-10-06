import Foundation

/// The groups on the Cleanup page.
public enum DiskCategory: String, CaseIterable, Identifiable, Sendable {
    case artifacts = "Build artifacts"
    case worktrees = "Worktrees"
    case caches = "Package caches"
    case xcode = "Xcode"
    case docker = "Docker"
    case agents = "Agent data"
    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .artifacts: return "hammer"
        case .worktrees: return "square.stack.3d.down.right"
        case .caches: return "shippingbox"
        case .xcode: return "swift"
        case .docker: return "cube.box"
        case .agents: return "sparkles"
        }
    }

    public var blurb: String {
        switch self {
        case .artifacts: return "Dependencies and build output inside your projects. Each comes back with one install or build."
        case .worktrees: return "Extra checkouts made by agents and `git worktree`. Only clean ones with nothing unpushed can be removed."
        case .caches: return "Download caches shared by package managers. They refill as you install."
        case .xcode: return "Build products, simulator caches and device symbols Xcode recreates when needed."
        case .docker: return "Images, containers and build cache Docker no longer uses."
        case .agents: return "Session transcripts. Lookout's usage history reads these, so they're shown here but never cleared."
        }
    }
}

public enum DiskKind: String, Sendable, Codable, CaseIterable {
    case nodeModules, swiftBuild, rustTarget, webBuild, pythonVenv, gradleBuild, pods
    case worktree, prunableWorktree
    case npmCache, pnpmStore, yarnCache, bunCache, homebrewCache, pipCache, goBuildCache, cargoRegistry, gradleCache, uvCache
    case derivedData, simulatorCaches, deviceSupport, xcodeArchives
    case dockerImages, dockerBuildCache, dockerContainers, dockerVolumes
    case agentData

    public var category: DiskCategory {
        switch self {
        case .nodeModules, .swiftBuild, .rustTarget, .webBuild, .pythonVenv, .gradleBuild, .pods: return .artifacts
        case .worktree, .prunableWorktree: return .worktrees
        case .npmCache, .pnpmStore, .yarnCache, .bunCache, .homebrewCache, .pipCache, .goBuildCache, .cargoRegistry, .gradleCache, .uvCache:
            return .caches
        case .derivedData, .simulatorCaches, .deviceSupport, .xcodeArchives: return .xcode
        case .dockerImages, .dockerBuildCache, .dockerContainers, .dockerVolumes: return .docker
        case .agentData: return .agents
        }
    }

    public var symbol: String {
        switch self {
        case .nodeModules: return "shippingbox"
        case .swiftBuild: return "swift"
        case .rustTarget: return "gearshape.2"
        case .webBuild: return "globe"
        case .pythonVenv: return "chevron.left.forwardslash.chevron.right"
        case .gradleBuild: return "cup.and.saucer"
        case .pods: return "cube"
        case .worktree, .prunableWorktree: return "square.stack.3d.down.right"
        case .npmCache, .pnpmStore, .yarnCache, .bunCache, .uvCache, .pipCache: return "archivebox"
        case .homebrewCache: return "mug"
        case .goBuildCache, .cargoRegistry, .gradleCache: return "archivebox"
        case .derivedData: return "hammer"
        case .simulatorCaches: return "iphone"
        case .deviceSupport: return "cable.connector"
        case .xcodeArchives: return "archivebox.fill"
        case .dockerImages: return "square.stack.3d.up"
        case .dockerBuildCache: return "hammer"
        case .dockerContainers: return "shippingbox"
        case .dockerVolumes: return "externaldrive"
        case .agentData: return "text.bubble"
        }
    }

    /// How it comes back, shown under the size.
    public var rebuildHint: String {
        switch self {
        case .nodeModules: return "npm / pnpm / yarn install brings it back"
        case .swiftBuild: return "swift build recreates it"
        case .rustTarget: return "cargo build recreates it"
        case .webBuild: return "Rebuilt on the next dev or build run"
        case .pythonVenv: return "Recreate with python -m venv and pip install"
        case .gradleBuild: return "gradle build recreates it"
        case .pods: return "pod install brings it back"
        case .worktree: return "git worktree remove; the branch stays"
        case .prunableWorktree: return "The folder is gone; this clears git's record of it"
        case .npmCache, .pnpmStore, .yarnCache, .bunCache, .uvCache, .pipCache, .goBuildCache, .cargoRegistry, .gradleCache, .homebrewCache:
            return "Refills as packages download again"
        case .derivedData: return "Xcode rebuilds it on the next build"
        case .simulatorCaches: return "Simulators recreate it"
        case .deviceSupport: return "Re-copied the next time that device connects"
        case .xcodeArchives: return "Archived app builds: keep the ones you ship or symbolicate from"
        case .dockerImages: return "docker image prune -a: unused images are pulled again when needed"
        case .dockerBuildCache: return "docker builder prune: the next build is slower once"
        case .dockerContainers: return "docker container prune: removes stopped containers"
        case .dockerVolumes: return "Volumes hold data; Lookout never clears them"
        case .agentData: return "Transcripts and history"
        }
    }
}

public enum DiskSafety: Int, Comparable, Sendable {
    /// Rebuilds or refills on its own.
    case safe
    /// Clearable, but worth a look first: a server or agent is using it, or it's not merged yet.
    case review
    /// Never cleared from here: unsaved work, or data that doesn't come back.
    case keep

    public static func < (a: DiskSafety, b: DiskSafety) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .keep: return "Keep"
        }
    }
}

public struct DiskItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: DiskKind
    /// The folder, or empty for Docker totals.
    public var path: String
    public var name: String
    /// Project or repository it belongs to.
    public var project: String?
    /// For worktrees, the main checkout `git worktree remove` runs from.
    public var ownerRoot: String?
    /// Nil until measured.
    public var bytes: Int64?
    public var lastUsed: Date?
    public var safety: DiskSafety
    /// Why it's flagged, e.g. "A server is running here" or "Merged into main".
    public var note: String

    public init(id: String? = nil, kind: DiskKind, path: String, name: String, project: String? = nil, ownerRoot: String? = nil,
                bytes: Int64? = nil, lastUsed: Date? = nil, safety: DiskSafety = .safe, note: String = "") {
        self.id = id ?? path
        self.kind = kind
        self.path = path
        self.name = name
        self.project = project
        self.ownerRoot = ownerRoot
        self.bytes = bytes
        self.lastUsed = lastUsed
        self.safety = safety
        self.note = note
    }

    public var displayPath: String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    public var canClear: Bool { safety != .keep && kind != .dockerVolumes && kind != .agentData && kind != .xcodeArchives }

    public func isStale(days: Int, now: Date = Date()) -> Bool {
        guard let lastUsed else { return true }
        return now.timeIntervalSince(lastUsed) > Double(days) * 86_400
    }
}

/// A folder to look inside for build artifacts, with what the app knows about it.
public struct DiskProject: Hashable, Sendable {
    public var root: String
    public var name: String
    public var lastTouched: Date?
    /// A server or agent is running in it right now.
    public var inUse: String?

    public init(root: String, name: String, lastTouched: Date? = nil, inUse: String? = nil) {
        self.root = root
        self.name = name
        self.lastTouched = lastTouched
        self.inUse = inUse
    }
}

/// A linked worktree and what decides whether it's safe to remove.
public struct DiskWorktree: Hashable, Sendable {
    public var path: String
    public var mainRoot: String
    public var repoName: String
    public var branch: String?
    public var owner: String?
    public var uncommitted: Int
    public var unpushed: Int
    public var merged: Bool
    /// Open pull request number for its branch, if any.
    public var openPull: Int?
    public var prunable: Bool
    public var lastTouched: Date?
    public var inUse: String?

    public init(path: String, mainRoot: String, repoName: String, branch: String?, owner: String? = nil, uncommitted: Int = 0,
                unpushed: Int = 0, merged: Bool = false, openPull: Int? = nil, prunable: Bool = false, lastTouched: Date? = nil,
                inUse: String? = nil) {
        self.path = path
        self.mainRoot = mainRoot
        self.repoName = repoName
        self.branch = branch
        self.owner = owner
        self.uncommitted = uncommitted
        self.unpushed = unpushed
        self.merged = merged
        self.openPull = openPull
        self.prunable = prunable
        self.lastTouched = lastTouched
        self.inUse = inUse
    }

    /// The safety rules, in order: unsaved work keeps it; something running or an open pull request means look first;
    /// merged is safe; otherwise every commit is on a remote, so it's removable after a look.
    public var verdict: (DiskSafety, String) {
        if prunable { return (.safe, "Folder already gone") }
        if uncommitted > 0 || unpushed > 0 {
            let parts = [uncommitted > 0 ? "\(uncommitted) uncommitted" : nil, unpushed > 0 ? "\(unpushed) unpushed" : nil].compactMap { $0 }
            return (.keep, parts.joined(separator: ", "))
        }
        if let inUse { return (.keep, inUse) }
        if let openPull { return (.review, "Pull request #\(openPull) is open") }
        if merged { return (.safe, "Merged, nothing unsaved") }
        return (.review, "Not merged, but every commit is on the remote")
    }
}

public struct DiskVolume: Hashable, Sendable {
    public var name: String
    public var total: Int64
    /// What macOS would free up for an important write, purgeable space included.
    public var available: Int64

    public init(name: String, total: Int64, available: Int64) {
        self.name = name
        self.total = total
        self.available = available
    }

    public var used: Int64 { max(0, total - available) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public struct DiskSettings: Codable, Equatable, Sendable {
    /// Warn when free space drops below this many gigabytes.
    public var lowSpaceGB = 20
    public var notifyLowSpace = true
    /// Untouched this long counts as stale and gets preselected.
    public var staleDays = 14
    /// Extra folders to look in for projects, beyond repositories and launchers.
    public var extraRoots: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DiskSettings()
        lowSpaceGB = try c.decodeIfPresent(Int.self, forKey: .lowSpaceGB) ?? d.lowSpaceGB
        notifyLowSpace = try c.decodeIfPresent(Bool.self, forKey: .notifyLowSpace) ?? d.notifyLowSpace
        staleDays = try c.decodeIfPresent(Int.self, forKey: .staleDays) ?? d.staleDays
        extraRoots = try c.decodeIfPresent([String].self, forKey: .extraRoots) ?? d.extraRoots
    }
}

public enum DiskFormat {
    public static func bytes(_ value: Int64?) -> String {
        guard let value else { return "…" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Docker's "2.31GB", "512.4MB", "0B" sizes.
    public static func parseDockerSize(_ text: String) -> Int64 {
        let s = text.split(separator: " ").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where s.hasSuffix(unit) {
            return Int64((Double(s.dropLast(unit.count)) ?? 0) * factor)
        }
        return 0
    }
}
