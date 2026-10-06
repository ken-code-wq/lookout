import Foundation

/// One step in what an agent did: something said, a command run, a file read or changed.
public struct ReplayEvent: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case prompt(String)
        case message(String)
        /// Shell command with its output and whether it failed.
        case command(String, output: String, failed: Bool)
        /// A file edited or created; `diff` is unified-diff hunks (or every line added for a new file).
        case edit(path: String, diff: String, created: Bool)
        case delete(path: String)
        case read(path: String)
        case search(String)
        /// Any other tool: name and a one-line summary of its input.
        case tool(String, String)
        case compaction
    }

    public var id: Int
    public var date: Date?
    public var kind: Kind

    public init(id: Int, date: Date?, kind: Kind) {
        self.id = id
        self.date = date
        self.kind = kind
    }

    public var isChange: Bool {
        switch kind {
        case .edit, .delete: return true
        default: return false
        }
    }

    /// Lines added and removed, for edits.
    public var lineCounts: (added: Int, removed: Int) {
        guard case .edit(_, let diff, _) = kind else { return (0, 0) }
        return ReplayDiff.counts(diff)
    }

    public var path: String? {
        switch kind {
        case .edit(let path, _, _), .delete(let path), .read(let path): return path
        default: return nil
        }
    }
}

/// Everything a session did, in order, with per-file totals.
public struct SessionReplay: Sendable {
    public var events: [ReplayEvent]
    public var start: Date?
    public var end: Date?

    public init(events: [ReplayEvent]) {
        self.events = events
        start = events.compactMap(\.date).min()
        end = events.compactMap(\.date).max()
    }

    public struct FileSummary: Identifiable, Hashable, Sendable {
        public var id: String { path }
        public var path: String
        public var added: Int
        public var removed: Int
        public var edits: Int
        public var created: Bool
        public var deleted: Bool
    }

    /// Files changed, most-changed first.
    public var files: [FileSummary] {
        var byPath: [String: FileSummary] = [:]
        for event in events {
            switch event.kind {
            case .edit(let path, let diff, let created):
                let (a, r) = ReplayDiff.counts(diff)
                var f = byPath[path] ?? FileSummary(path: path, added: 0, removed: 0, edits: 0, created: false, deleted: false)
                f.added += a; f.removed += r; f.edits += 1; f.created = f.created || created
                byPath[path] = f
            case .delete(let path):
                var f = byPath[path] ?? FileSummary(path: path, added: 0, removed: 0, edits: 0, created: false, deleted: false)
                f.deleted = true
                byPath[path] = f
            default: break
            }
        }
        return byPath.values.sorted { ($0.added + $0.removed, $1.path) > ($1.added + $1.removed, $0.path) }
    }

    public var commandCount: Int { events.filter { if case .command = $0.kind { return true }; return false }.count }
    public var failedCommands: Int { events.filter { if case .command(_, _, true) = $0.kind { return true }; return false }.count }
    public var totals: (added: Int, removed: Int) {
        files.reduce((0, 0)) { ($0.0 + $1.added, $0.1 + $1.removed) }
    }
}

public enum ReplayDiff {
    public static func counts(_ diff: String) -> (added: Int, removed: Int) {
        var a = 0, r = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { a += 1 } else if line.hasPrefix("-") { r += 1 }
        }
        return (a, r)
    }

    /// A replace of `old` with `new` as one hunk: every old line removed, every new line added. Agents' edit tools
    /// record the strings, not line numbers, so there's nothing better to number them by.
    public static func replace(_ old: String, _ new: String) -> String {
        let o = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false)
        let n = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false)
        // Trim lines the two share at the start and end so the hunk shows only what changed, with a little context.
        var head = 0
        while head < o.count, head < n.count, o[head] == n[head] { head += 1 }
        var tail = 0
        while tail < o.count - head, tail < n.count - head, o[o.count - 1 - tail] == n[n.count - 1 - tail] { tail += 1 }
        let ctxBefore = o[max(0, head - 2)..<head]
        let ctxAfter = o[(o.count - tail)..<min(o.count, o.count - tail + 2)]
        // No line numbers to give: the header just marks the hunk, and the view leaves the number columns blank.
        var lines = [replacedHeader]
        lines += ctxBefore.map { " " + $0 }
        lines += o[head..<(o.count - tail)].map { "-" + $0 }
        lines += n[head..<(n.count - tail)].map { "+" + $0 }
        lines += ctxAfter.map { " " + $0 }
        return lines.joined(separator: "\n")
    }

    public static let replacedHeader = "@@ replaced @@"

    public static func created(_ content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return (["@@ -0,0 +1,\(lines.count) @@"] + lines.map { "+" + $0 }).joined(separator: "\n")
    }
}

/// Reads a session's transcript into a replay. Claude Code and Codex record tool calls in full; other agents
/// only their messages, or nothing Lookout can read.
public enum SessionReplayReader {
    public static func supports(_ agent: AgentKind) -> Bool { agent == .claude || agent == .codex }

    public static func read(agent: AgentKind, path: String) -> SessionReplay? {
        guard !path.isEmpty, let data = FileManager.default.contents(atPath: path) else { return nil }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        switch agent {
        case .claude: return claude(lines)
        case .codex: return codex(lines)
        default: return nil
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    static func json(_ line: Data.SubSequence) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }

    /// User text that is really harness plumbing (reminders, command echoes) rather than something typed.
    static func isPlumbing(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("<") || t.hasPrefix("Caveat:") || t.hasPrefix("[Request interrupted")
    }

    static func clip(_ s: String, _ n: Int = 4000) -> String { s.count > n ? String(s.prefix(n)) + "\n…" : s }

    // MARK: Claude Code

    static func claude(_ lines: [Data.SubSequence]) -> SessionReplay {
        var events: [ReplayEvent] = []
        // Commands wait for their tool_result to learn the output and exit status.
        var pending: [String: Int] = [:]
        func add(_ date: Date?, _ kind: ReplayEvent.Kind) -> Int {
            events.append(ReplayEvent(id: events.count, date: date, kind: kind))
            return events.count - 1
        }
        for line in lines {
            guard let o = json(line), let type = o["type"] as? String, type == "user" || type == "assistant",
                  let message = o["message"] as? [String: Any] else { continue }
            if o["isSidechain"] as? Bool == true { continue }
            let date = date(o["timestamp"])
            if let text = message["content"] as? String {
                if type == "user", !isPlumbing(text) { _ = add(date, .prompt(clip(text))) }
                continue
            }
            for item in message["content"] as? [[String: Any]] ?? [] {
                switch item["type"] as? String {
                case "text":
                    let text = item["text"] as? String ?? ""
                    if type == "assistant" { if !text.isEmpty { _ = add(date, .message(clip(text))) } }
                    else if !isPlumbing(text) { _ = add(date, .prompt(clip(text))) }
                case "tool_use":
                    let id = item["id"] as? String ?? ""
                    let input = item["input"] as? [String: Any] ?? [:]
                    let name = item["name"] as? String ?? "Tool"
                    let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? ""
                    switch name {
                    case "Bash":
                        pending[id] = add(date, .command(input["command"] as? String ?? "", output: "", failed: false))
                    case "Edit":
                        pending[id] = add(date, .edit(path: path, diff: ReplayDiff.replace(input["old_string"] as? String ?? "",
                                                                                           input["new_string"] as? String ?? ""), created: false))
                    case "MultiEdit":
                        let diff = (input["edits"] as? [[String: Any]] ?? []).map {
                            ReplayDiff.replace($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "")
                        }.joined(separator: "\n")
                        pending[id] = add(date, .edit(path: path, diff: diff, created: false))
                    case "Write":
                        pending[id] = add(date, .edit(path: path, diff: ReplayDiff.created(clip(input["content"] as? String ?? "", 60_000)), created: true))
                    case "Read", "NotebookRead":
                        _ = add(date, .read(path: path))
                    case "Grep", "Glob":
                        _ = add(date, .search(input["pattern"] as? String ?? ""))
                    default:
                        let summary = (input["description"] ?? input["url"] ?? input["query"] ?? input["prompt"]).map { "\($0)" } ?? ""
                        _ = add(date, .tool(name, String(summary.prefix(200))))
                    }
                case "tool_result":
                    guard let index = pending.removeValue(forKey: item["tool_use_id"] as? String ?? "") else { continue }
                    let failed = item["is_error"] as? Bool ?? false
                    let output: String
                    if let s = item["content"] as? String { output = s }
                    else { output = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
                    switch events[index].kind {
                    case .command(let cmd, _, _): events[index].kind = .command(cmd, output: clip(output), failed: failed)
                    // An edit the tool refused didn't happen.
                    case .edit where failed: events[index].kind = .tool("Edit (failed)", String(output.prefix(200)))
                    default: break
                    }
                default: break
                }
            }
        }
        return SessionReplay(events: events)
    }

    // MARK: Codex

    static func codex(_ lines: [Data.SubSequence]) -> SessionReplay {
        var events: [ReplayEvent] = []
        func add(_ date: Date?, _ kind: ReplayEvent.Kind) { events.append(ReplayEvent(id: events.count, date: date, kind: kind)) }
        for line in lines {
            guard let o = json(line), let payload = o["payload"] as? [String: Any],
                  payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any] else { continue }
            let date = date(o["timestamp"])
            func text(_ key: String = "content") -> String {
                (item[key] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            switch item["type"] as? String {
            case "UserMessage":
                let t = text()
                if !isPlumbing(t) { add(date, .prompt(clip(t))) }
            case "AgentMessage":
                let t = text()
                if !t.isEmpty { add(date, .message(clip(t))) }
            case "CommandExecution":
                let parts = item["command"] as? [String] ?? []
                // ["/bin/zsh", "-lc", "the command"]: show what was asked for, not the shell wrapper.
                let cmd = parts.count >= 3 && parts[1].hasPrefix("-") ? parts[2] : parts.joined(separator: " ")
                let parsed = (item["parsed_cmd"] as? [[String: Any]])?.first
                if parsed?["type"] as? String == "read", let path = parsed?["path"] as? String {
                    add(date, .read(path: path)); continue
                }
                if parsed?["type"] as? String == "search" { add(date, .search(parsed?["query"] as? String ?? cmd)); continue }
                let exit = item["exit_code"] as? Int ?? 0
                let output = [item["stdout"] as? String, item["stderr"] as? String, item["aggregated_output"] as? String]
                    .compactMap { $0 }.first { !$0.isEmpty } ?? ""
                add(date, .command(cmd, output: clip(output), failed: exit != 0 || item["status"] as? String == "failed"))
            case "FileChange":
                for (path, value) in (item["changes"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    let change = value as? [String: Any] ?? [:]
                    switch change["type"] as? String {
                    case "add": add(date, .edit(path: path, diff: ReplayDiff.created(clip(change["content"] as? String ?? "", 60_000)), created: true))
                    case "delete": add(date, .delete(path: path))
                    default: add(date, .edit(path: (change["move_path"] as? String) ?? path, diff: change["unified_diff"] as? String ?? "", created: false))
                    }
                }
            case "McpToolCall":
                let server = item["server"] as? String ?? "", tool = item["tool"] as? String ?? ""
                let args = (item["arguments"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .map { String(decoding: $0, as: UTF8.self) } ?? ""
                add(date, .tool("\(server).\(tool)", String(args.prefix(200))))
            case "WebSearch":
                add(date, .search(item["query"] as? String ?? ""))
            case "ContextCompaction":
                add(date, .compaction)
            default: break
            }
        }
        return SessionReplay(events: events)
    }
}
