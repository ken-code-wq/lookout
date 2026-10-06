import Foundation

/// Whether an agent's config sends its events to Lookout.
public enum HookInstallStatus: Equatable, Sendable {
    case notConnected
    case connected
    /// Lookout's entries are there but point at another copy of the helper, or some events are missing.
    case outdated
    /// The setting Lookout needs is already used by another program (Codex has a single `notify`).
    case conflict(String)
    case unreadable(String)
}

public enum HookInstallError: LocalizedError, Equatable {
    case notJSONObject
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .notJSONObject: return "The settings file isn't a JSON object, so Lookout left it alone."
        case .conflict(let program): return "Codex's notify already runs \(program). Lookout won't replace it."
        }
    }
}

/// Everything Lookout writes is recognised by the helper's file name, so its own entries can be found, updated and
/// removed without touching anyone else's.
public enum HookHelper {
    public static let fileName = "lookout-hook"

    public static func isOurs(_ command: String) -> Bool { command.contains(fileName) }

    /// `'/Applications/Lookout.app/Contents/MacOS/lookout-hook' claude`, quoted for the shell Claude Code runs hooks in.
    public static func command(helperPath: String, agent: HookAgent) -> String {
        "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "' " + agent.rawValue
    }
}

// MARK: - Claude Code

/// Merges Lookout's hooks into Claude Code's `settings.json` (`hooks.<Event>[].hooks[]`), leaving every other key,
/// matcher group and hook exactly as it was.
public enum ClaudeHookConfig {
    /// Event, matcher, timeout in seconds. PermissionRequest blocks the agent while Lookout waits for an answer, so
    /// its timeout is Claude Code's maximum; Lookout gives up well before that (Settings › Agents).
    ///
    /// The second Stop entry is the reply waiter (`HookReply`): `asyncRewake` runs it in the background and wakes
    /// Claude when it exits 2. Its timeout is a ceiling; the app releases it sooner (Settings › Agents).
    public static let events: [(name: String, matcher: String?, timeout: Int, awaitsReply: Bool)] = [
        ("PermissionRequest", "*", 600, false),
        ("Notification", nil, 10, false),
        ("UserPromptSubmit", nil, 10, false),
        ("Stop", nil, 10, false),
        ("Stop", nil, replyWaitCeiling, true),
        ("SessionStart", nil, 10, false),
        ("SessionEnd", nil, 10, false),
    ]

    /// The longest a reply waiter may live, in seconds; the helper enforces the same ceiling itself.
    public static let replyWaitCeiling = 8 * 3600

    /// The command an entry runs: the helper, plus `--await-reply` for the waiter.
    public static func command(_ base: String, awaitsReply: Bool) -> String {
        awaitsReply ? base + " " + HookReply.awaitFlag : base
    }

    /// Connected when every event has exactly Lookout's current entries. An install from before the reply waiter
    /// (one Stop entry) reads as outdated, so Settings offers to update it.
    public static func status(_ settings: [String: Any], command: String) -> HookInstallStatus {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let names = Set(events.map(\.name))
        var found = 0, exact = 0
        for name in names {
            let commands = ourCommands(in: hooks[name])
            found += commands.count
            let expected = events.filter { $0.name == name }.map { Self.command(command, awaitsReply: $0.awaitsReply) }
            if commands.sorted() == expected.sorted() { exact += 1 }
        }
        if found == 0 { return .notConnected }
        return exact == names.count ? .connected : .outdated
    }

    /// Idempotent: any earlier Lookout entries are replaced, so installing twice leaves one set.
    public static func install(_ settings: [String: Any], command: String) -> [String: Any] {
        var result = uninstall(settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event.name] as? [Any] ?? []
            var hook: [String: Any] = ["type": "command", "command": Self.command(command, awaitsReply: event.awaitsReply), "timeout": event.timeout]
            if event.awaitsReply { hook["asyncRewake"] = true }
            var group: [String: Any] = ["hooks": [hook]]
            if let matcher = event.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[event.name] = groups
        }
        result["hooks"] = hooks
        return result
    }

    /// Removes only hooks whose command runs the helper, then any group or event list that leaves empty.
    public static func uninstall(_ settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        var changed = false
        for (name, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            var kept: [Any] = []
            var touched = false
            for item in groups {
                guard var group = item as? [String: Any], let list = group["hooks"] as? [Any] else { kept.append(item); continue }
                let remaining = list.filter { !isOurs($0) }
                if remaining.count == list.count { kept.append(item); continue }
                touched = true
                if remaining.isEmpty { continue }
                group["hooks"] = remaining
                kept.append(group)
            }
            guard touched else { continue }
            changed = true
            hooks[name] = kept.isEmpty ? nil : kept
        }
        guard changed else { return settings }
        var result = settings
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    private static func isOurs(_ hook: Any) -> Bool {
        guard let hook = hook as? [String: Any], let command = hook["command"] as? String else { return false }
        return HookHelper.isOurs(command)
    }

    private static func ourCommands(in value: Any?) -> [String] {
        (value as? [Any] ?? []).flatMap { group -> [String] in
            ((group as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { hook in
                guard let command = (hook as? [String: Any])?["command"] as? String, HookHelper.isOurs(command) else { return nil }
                return command
            }
        }
    }

    // MARK: Text

    public static func parse(_ text: String?) throws -> [String: Any] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw HookInstallError.notJSONObject
        }
        return object
    }

    public static func render(_ settings: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

// MARK: - Codex

/// Codex runs one `notify` program after each turn, configured as a top-level array in `~/.codex/config.toml`:
/// `notify = ["/path/to/lookout-hook", "codex"]`. Codex has no approval hook, so this only reports finished turns.
public enum CodexNotifyConfig {
    public static let marker = "# Lookout: tells Lookout when a Codex turn finishes (Settings › Agents)."

    public static func value(helperPath: String) -> String {
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "[\(quote(helperPath)), \(quote(HookAgent.codex.rawValue))]"
    }

    public static func status(_ text: String?, helperPath: String) -> HookInstallStatus {
        guard let text, let found = findNotify(text) else { return .notConnected }
        guard HookHelper.isOurs(found.value) else { return .conflict(program(found.value)) }
        return found.value == value(helperPath: helperPath) ? .connected : .outdated
    }

    public static func install(_ text: String, helperPath: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let line = "notify = \(value(helperPath: helperPath))"
        if let found = findNotify(text) {
            guard HookHelper.isOurs(found.value) else { throw HookInstallError.conflict(program(found.value)) }
            lines.replaceSubrange(found.lines, with: [line])
            return lines.joined(separator: "\n")
        }
        // Top-level keys must come before the first [table], so the top of the file is always valid.
        let body = text.isEmpty ? "" : "\n" + text
        return marker + "\n" + line + "\n" + body
    }

    public static func uninstall(_ text: String) -> String {
        guard let found = findNotify(text), HookHelper.isOurs(found.value) else { return text }
        var lines = text.components(separatedBy: "\n")
        var range = found.lines
        if range.lowerBound > 0, lines[range.lowerBound - 1] == marker { range = (range.lowerBound - 1)..<range.upperBound }
        // The blank line install put after the entry goes too, so connect + disconnect leaves the file as it was.
        if range.upperBound < lines.count, lines[range.upperBound].isEmpty, range.lowerBound == 0 { range = range.lowerBound..<(range.upperBound + 1) }
        lines.removeSubrange(range)
        return lines.joined(separator: "\n")
    }

    /// The top-level `notify = …` entry: its line range (multi-line arrays included) and its value text.
    public static func findNotify(_ text: String) -> (lines: Range<Int>, value: String)? {
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil } // first table: the top level is over
            if trimmed.hasPrefix("notify"), let eq = trimmed.firstIndex(of: "="),
               trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<eq].allSatisfy(\.isWhitespace) {
                var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                var end = index + 1
                while depth(value) > 0, end < lines.count {
                    value += "\n" + lines[end]
                    end += 1
                }
                return (index..<end, value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            index += 1
        }
        return nil
    }

    /// Open brackets minus closed ones, ignoring any inside strings or comments.
    private static func depth(_ value: String) -> Int {
        var depth = 0, inString: Character? = nil, escaped = false, inComment = false
        for ch in value {
            if inComment {
                if ch == "\n" { inComment = false }
                continue
            }
            if let quote = inString {
                if escaped { escaped = false } else if ch == "\\" && quote == "\"" { escaped = true } else if ch == quote { inString = nil }
                continue
            }
            switch ch {
            case "\"", "'": inString = ch
            case "[": depth += 1
            case "]": depth -= 1
            case "#": inComment = true
            default: break
            }
        }
        return depth
    }

    /// The program name from a notify value, for the "already used by" message.
    static func program(_ value: String) -> String {
        guard let start = value.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return value }
        let quote = value[start]
        let rest = value[value.index(after: start)...]
        guard let end = rest.firstIndex(of: quote) else { return value }
        return (String(rest[..<end]) as NSString).lastPathComponent
    }
}

// MARK: - Files

/// Reads, transforms, backs up and writes an agent's config file. A missing file reads as empty.
public enum HookConfigFile {
    public static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Applies `transform`; when the text changes, copies the old file to `<name>.lookout-backup-<time>` and writes
    /// the new one atomically. Returns the backup's URL, or nil when nothing needed changing.
    @discardableResult
    public static func update(_ url: URL, now: Date = Date(), transform: (String) throws -> String) throws -> URL? {
        let old = try read(url)
        let new = try transform(old ?? "")
        guard new != (old ?? "") else { return nil }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if old != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let target = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).lookout-backup-\(formatter.string(from: now))")
            try? manager.removeItem(at: target)
            try manager.copyItem(at: url, to: target)
            backup = target
        }
        try new.write(to: url, atomically: true, encoding: .utf8)
        return backup
    }
}
