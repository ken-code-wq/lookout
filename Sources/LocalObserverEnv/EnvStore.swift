import Foundation
import Combine
import LocalObserverRepos

/// Reads a project folder's env files and asks git about them. Read-only: never writes, never runs anything but
/// `git ls-files` and `git check-ignore`. Blocks; call off the main thread.
public enum EnvScanner {
    /// Files bigger than this aren't env files anyone wrote by hand; they're skipped.
    static let maxBytes = 512 * 1024

    public static func scan(folder: String, fileManager fm: FileManager = .default) -> [EnvFileInfo] {
        guard !folder.isEmpty, let names = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        var files: [EnvFileInfo] = []
        for name in names where EnvFileRole.classify(name) != nil {
            let path = (folder as NSString).appendingPathComponent(name)
            // `.env` is also a common virtualenv folder name; only regular files (or links to them) count.
            guard let attributes = try? fm.attributesOfItem(atPath: (path as NSString).resolvingSymlinksInPath),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? Int ?? 0) <= maxBytes,
                  let data = fm.contents(atPath: path) else { continue }
            files.append(EnvFileInfo(name: name, path: path, parsed: Dotenv.parse(String(decoding: data, as: UTF8.self)),
                                     modified: attributes[.modificationDate] as? Date))
        }
        guard !files.isEmpty else { return [] }
        let (tracked, ignored) = gitStatus(folder: folder, names: files.map(\.name))
        if let tracked, let ignored {
            for i in files.indices {
                files[i].tracked = tracked.contains(files[i].name)
                files[i].ignored = ignored.contains(files[i].name)
            }
        }
        return files
    }

    /// Which of `names` git tracks and which it ignores, or nils when the folder isn't in a repository.
    static func gitStatus(folder: String, names: [String]) -> (Set<String>?, Set<String>?) {
        let git = RepoGit.gitPath
        let inside = RepoGit.run(git, ["-C", folder, "rev-parse", "--is-inside-work-tree"], timeout: 5)
        guard inside.ok, inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return (nil, nil) }
        let tracked = RepoGit.run(git, ["-C", folder, "--no-optional-locks", "ls-files", "-z", "--"] + names, timeout: 5)
        // check-ignore exits 1 when nothing is ignored; that's an answer, not a failure.
        let ignored = RepoGit.run(git, ["-C", folder, "check-ignore", "--"] + names, timeout: 5)
        guard tracked.ok, ignored.status == 0 || ignored.status == 1 else { return (nil, nil) }
        return (split(tracked.stdout), Set(ignored.stdout.split(separator: "\n").map { ($0 as NSString).lastPathComponent }))
    }

    /// NUL-separated paths, relative to the folder.
    static func split(_ text: String) -> Set<String> {
        Set(text.split(separator: "\0").map { ($0 as NSString).lastPathComponent })
    }
}

/// Env files per project folder, cached and re-read when asked (inspectors ask on appear). Holds parsed values in
/// memory only; nothing is written or logged.
@MainActor
public final class EnvStore: ObservableObject {
    public static let shared = EnvStore()

    @Published public private(set) var files: [String: [EnvFileInfo]] = [:]
    @Published public private(set) var loading: Set<String> = []
    /// Which mode's files to resolve against, and which framework's order.
    @Published public var mode = "development"
    @Published public var convention: EnvConvention {
        didSet { defaults.set(convention.rawValue, forKey: Self.conventionKey) }
    }

    private var readAt: [String: Date] = [:]
    private let defaults: UserDefaults
    private static let conventionKey = "LocalObserver.envConvention"
    private var isDemo = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        convention = EnvConvention(rawValue: defaults.string(forKey: Self.conventionKey) ?? "") ?? .nextjs
    }

    /// Reads the folder unless it was read in the last `age` seconds.
    public func load(_ folder: String, age: TimeInterval = 10) {
        guard !isDemo, !folder.isEmpty, !loading.contains(folder) else { return }
        if let at = readAt[folder], Date().timeIntervalSince(at) < age { return }
        loading.insert(folder)
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { EnvScanner.scan(folder: folder) }.value
            guard let self else { return }
            self.readAt[folder] = Date()
            if self.files[folder] != found { self.files[folder] = found }
            self.loading.remove(folder)
        }
    }

    public func report(_ folder: String) -> EnvReport? {
        guard let list = files[folder] else { return nil }
        let modes = EnvResolver.modes(in: list)
        return EnvResolver.resolve(folder: folder, files: list, mode: modes.contains(mode) ? mode : "development", convention: convention)
    }

    /// Template keys with no value in any real file: what the badge counts. Mode-independent on purpose.
    public func missingCount(_ folder: String) -> Int {
        report(folder)?.missing.count ?? 0
    }

    public func loadDemo(_ folders: [String: [EnvFileInfo]]) {
        isDemo = true
        files = folders
    }
}
