import Foundation

/// What a file in a project is, from its name.
public enum EnvFileRole: Hashable, Sendable {
    /// `.env`
    case base
    /// `.env.local`
    case local
    /// `.env.development`, `.env.staging`…
    case mode(String)
    /// `.env.development.local`
    case modeLocal(String)
    /// `.env.example`, `.env.sample`, `.env.template`, `.env.dist`, `.env.production.example`: the list of keys a
    /// project expects, meant to be committed.
    case template
    /// Other real files that aren't loaded by mode: `.env.vault`, `.env.keys`, backups like `.env.bak`. They can
    /// still hold secrets, so they're listed and checked against git.
    case other

    static let templateNames: Set<String> = ["example", "sample", "template", "dist", "defaults", "tpl"]
    static let otherNames: Set<String> = ["vault", "keys", "me", "enc", "bak", "backup", "old", "orig", "save", "swp", "tmp", "copy"]

    /// Nil for anything that isn't an env file (`.envrc`, `.environment`).
    public static func classify(_ name: String) -> EnvFileRole? {
        if name == ".env" { return .base }
        guard name.hasPrefix(".env."), name.count > 5 else { return nil }
        let rest = String(name.dropFirst(5))
        let parts = rest.split(separator: ".").map(String.init)
        guard let last = parts.last?.lowercased() else { return nil }
        if templateNames.contains(last) { return .template }
        if parts.contains(where: { otherNames.contains($0.lowercased()) }) { return .other }
        if rest == "local" { return .local }
        if parts.count == 2, last == "local" { return .modeLocal(parts[0]) }
        if parts.count == 1 { return .mode(parts[0]) }
        return .other
    }

    public var isTemplate: Bool { self == .template }
}

/// The two common orders. They differ in one place: whether `.env.local` beats `.env.[mode]`.
public enum EnvConvention: String, CaseIterable, Sendable, Identifiable {
    /// Next.js, Create React App and dotenv-flow's Next-style setups:
    /// `.env.[mode].local` > `.env.local` > `.env.[mode]` > `.env`, and `.env.local` is skipped when mode is `test`.
    case nextjs = "Next.js"
    /// Vite (and dotenv-flow): `.env.[mode].local` > `.env.[mode]` > `.env.local` > `.env`.
    case vite = "Vite"

    public var id: String { rawValue }

    /// The files that load for `mode`, highest precedence first. Variables already in the process environment beat
    /// all of them; Lookout can't see those.
    public func order(mode: String) -> [EnvFileRole] {
        switch self {
        case .nextjs: return mode == "test" ? [.modeLocal(mode), .mode(mode), .base] : [.modeLocal(mode), .local, .mode(mode), .base]
        case .vite: return [.modeLocal(mode), .mode(mode), .local, .base]
        }
    }
}

/// One env file as read from disk.
public struct EnvFileInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var role: EnvFileRole
    public var parsed: DotenvFile
    /// Committed to git (`git ls-files`). Nil outside a repository.
    public var tracked: Bool?
    /// Covered by .gitignore (`git check-ignore`). Nil outside a repository.
    public var ignored: Bool?
    public var modified: Date?

    public var id: String { path }

    public init(name: String, path: String = "", parsed: DotenvFile, tracked: Bool? = nil, ignored: Bool? = nil, modified: Date? = nil) {
        self.name = name
        self.path = path.isEmpty ? name : path
        self.role = EnvFileRole.classify(name) ?? .other
        self.parsed = parsed
        self.tracked = tracked
        self.ignored = ignored
        self.modified = modified
    }

    /// The git problem with this file, if it's a real one: committed, or not ignored so it could be.
    public var gitWarning: EnvWarning.Kind? {
        guard !role.isTemplate else { return nil }
        if tracked == true { return .tracked }
        if tracked == false, ignored == false { return .notIgnored }
        return nil
    }
}

public struct EnvWarning: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case tracked, notIgnored, secretInTemplate, parse
    }
    public var kind: Kind
    public var file: String
    public var message: String
    public var id: String { "\(kind.rawValue)|\(file)|\(message)" }
}

/// Where a key is set, and the value it ends up with.
public struct EnvKey: Hashable, Sendable, Identifiable {
    public struct Source: Hashable, Sendable {
        public var file: String
        public var entry: DotenvEntry
    }

    public enum Status: String, Sendable {
        /// Set, with a value.
        case set
        /// Set, but to an empty string.
        case empty
        /// In the template, not set in any real file.
        case missing
        /// Only set for another mode (`.env.production` while looking at development).
        case otherModeOnly
    }

    public var key: String
    /// The assignment that wins for the chosen mode and convention.
    public var effective: Source?
    /// Every active file that sets it, highest precedence first. All but the first are overridden.
    public var sources: [Source]
    /// Real files that set it but don't load in this mode.
    public var inactiveFiles: [String]
    public var inTemplate: Bool
    /// Set in real files but not listed in the template (only meaningful when there is a template).
    public var isExtra: Bool
    /// The other convention would pick a different file's value.
    public var dependsOnConvention: Bool
    public var status: Status

    public var id: String { key }
}

public struct EnvReport: Hashable, Sendable {
    public var folder: String
    public var mode: String
    public var convention: EnvConvention
    public var files: [EnvFileInfo]
    public var keys: [EnvKey]
    public var warnings: [EnvWarning]

    public var hasTemplate: Bool { files.contains { $0.role.isTemplate } }
    public var hasRealFiles: Bool { files.contains { !$0.role.isTemplate } }
    public var missing: [EnvKey] { keys.filter { $0.status == .missing } }
    public var extra: [EnvKey] { keys.filter(\.isExtra) }
    public var isEmpty: Bool { files.isEmpty }
}

public enum EnvResolver {
    /// Modes with a file in the project, `development` first, for the mode picker.
    public static func modes(in files: [EnvFileInfo]) -> [String] {
        var modes: Set<String> = ["development"]
        for file in files {
            switch file.role {
            case .mode(let m), .modeLocal(let m): modes.insert(m)
            default: break
            }
        }
        let preferred = ["development", "production", "test"]
        return preferred.filter(modes.contains) + modes.subtracting(preferred).sorted()
    }

    public static func resolve(folder: String, files: [EnvFileInfo], mode: String = "development",
                               convention: EnvConvention = .nextjs) -> EnvReport {
        let sorted = files.sorted { a, b in
            if a.role.isTemplate != b.role.isTemplate { return !a.role.isTemplate }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        func active(_ c: EnvConvention) -> [EnvFileInfo] {
            c.order(mode: mode).compactMap { role in files.first { $0.role == role } }
        }
        let loaded = active(convention)
        let alternate = active(convention == .nextjs ? .vite : .nextjs)
        let real = files.filter { !$0.role.isTemplate && $0.role != .other }
        let templates = files.filter(\.role.isTemplate)
        let templateKeys = Set(templates.flatMap(\.parsed.keys))
        let hasTemplate = !templates.isEmpty

        // Keys in a stable order: the template's order first (it's usually grouped by meaning), then the rest.
        var order: [String] = []
        var seen = Set<String>()
        for file in templates + real { for key in file.parsed.keys where seen.insert(key).inserted { order.append(key) } }

        let keys = order.map { key -> EnvKey in
            let sources = loaded.compactMap { file in file.parsed.effective[key].map { EnvKey.Source(file: file.name, entry: $0) } }
            let other = alternate.first { $0.parsed.effective[key] != nil }?.name
            let inactive = real.filter { file in !loaded.contains(file) && file.parsed.effective[key] != nil }.map(\.name)
            let inReal = real.contains { $0.parsed.effective[key] != nil }
            let status: EnvKey.Status
            if let winner = sources.first {
                status = winner.entry.value.isEmpty ? .empty : .set
            } else if inReal {
                status = .otherModeOnly
            } else {
                status = .missing
            }
            return EnvKey(key: key, effective: sources.first, sources: sources, inactiveFiles: inactive,
                          inTemplate: templateKeys.contains(key), isExtra: hasTemplate && inReal && !templateKeys.contains(key),
                          dependsOnConvention: sources.first != nil && other != nil && other != sources.first?.file,
                          status: status)
        }

        var warnings: [EnvWarning] = []
        for file in sorted {
            switch file.gitWarning {
            case .tracked?:
                warnings.append(EnvWarning(kind: .tracked, file: file.name,
                                           message: "\(file.name) is committed to git. Anyone with the repository has these values."))
            case .notIgnored?:
                warnings.append(EnvWarning(kind: .notIgnored, file: file.name,
                                           message: "\(file.name) isn't in .gitignore, so the next git add . would commit it."))
            default: break
            }
            if file.role.isTemplate {
                let leaky = file.parsed.entries.filter { EnvMask.looksLikeSecret($0.value) }.map(\.key)
                if !leaky.isEmpty {
                    warnings.append(EnvWarning(kind: .secretInTemplate, file: file.name,
                                               message: "\(file.name) has what looks like a real key in \(leaky.prefix(3).joined(separator: ", ")). Templates are meant to be committed."))
                }
            }
            for issue in file.parsed.issues.prefix(3) {
                warnings.append(EnvWarning(kind: .parse, file: file.name, message: "\(file.name) line \(issue.line): \(issue.message)"))
            }
        }
        // Templates have no secrets to protect, so there are no git warnings for them; real files are listed first.
        return EnvReport(folder: folder, mode: mode, convention: convention, files: sorted, keys: keys, warnings: warnings)
    }
}

/// Masking. Values are hidden by default; revealing shows only their shape, never the value itself.
public enum EnvMask {
    public static let hidden = "••••••••"

    /// `sk-proj-…(164)`, `postgresql://…(58)`, `…(32)`, `empty`, `…(1650, 28 lines)`. Enough to tell a test key
    /// from a live one, or a stale value from a fresh one, without showing it.
    public static func shape(_ value: String) -> String {
        guard !value.isEmpty else { return "empty" }
        let count = value.count
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).count
        let size = lines > 1 ? "(\(count), \(lines) lines)" : "(\(count))"
        return (prefix(value).map { $0 + "…" } ?? "…") + size
    }

    /// A non-secret head: a URL scheme, or one or two short alphabetic segments ending in `-` or `_` (`sk-`,
    /// `sk_live_`, `ghp_`, `xoxb-`). Only offered when it leaves most of the value hidden.
    static func prefix(_ value: String) -> String? {
        if let scheme = value.range(of: "://"), value.distance(from: value.startIndex, to: scheme.lowerBound) <= 16 {
            let head = String(value[..<scheme.upperBound])
            if head.dropLast(3).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }) { return head }
        }
        guard value.count >= 12 else { return nil }
        var head = ""
        var rest = Substring(value)
        for _ in 0..<2 {
            let word = rest.prefix { $0.isASCII && $0.isLetter }
            guard (1...8).contains(word.count), let sep = rest.dropFirst(word.count).first, sep == "-" || sep == "_" else { break }
            head += word + String(sep)
            rest = rest.dropFirst(word.count + 1)
        }
        return head.isEmpty || head.count * 3 > value.count ? nil : head
    }

    /// Token formats that are never placeholders: provider prefixes followed by a long random tail.
    public static func looksLikeSecret(_ value: String) -> Bool {
        let prefixes = ["sk-", "sk_live_", "rk_live_", "pk_live_", "ghp_", "gho_", "ghs_", "github_pat_", "glpat-", "xoxb-", "xoxp-",
                        "AKIA", "AIza", "SG.", "sk-ant-", "sk-proj-"]
        guard value.count >= 24, !value.contains(" "), let p = prefixes.first(where: value.hasPrefix) else { return false }
        let tail = value.dropFirst(p.count)
        let lower = tail.lowercased()
        // `sk-your-key-here`, `sk-xxxxxxxx…` are placeholders.
        if ["your", "xxxx", "change", "replace", "example", "placeholder", "dummy"].contains(where: lower.contains) { return false }
        return tail.contains { $0.isNumber } && tail.contains { $0.isLetter }
    }
}
