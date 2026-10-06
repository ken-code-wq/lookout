import Foundation

/// Agents that can report to Lookout through `lookout-hook`. Raw values match `AgentKind`'s.
public enum HookAgent: String, CaseIterable, Sendable {
    case claude
    case codex
}

/// What a hook event says about the session, independent of the agent that sent it.
public enum HookSignal: String, Sendable {
    case working
    case needsYou
    case yourTurn
    case ended
}

/// One event an agent's hook sent, parsed from the envelope `lookout-hook` forwards.
/// Claude Code's schema: https://code.claude.com/docs/en/hooks. Codex: the JSON its `notify` program receives.
public struct HookEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case sessionStart(source: String)
        case sessionEnd
        case promptSubmitted
        case permissionRequest
        case notification(type: String)
        case stop
        /// Codex's `agent-turn-complete`.
        case turnComplete
        case other(String)
    }

    public var agent: HookAgent
    public var kind: Kind
    public var sessionID: String
    public var cwd: String
    public var transcriptPath: String
    public var toolName: String
    public var preview: HookToolPreview?
    /// The notification text, or the agent's last message when a turn ends.
    public var message: String
    /// `permission_suggestions` as Claude Code sent them, echoed back for "Always allow".
    public var suggestions: Data?
    /// The helper's parent processes, nearest first: the shell the hook runs in, then the agent itself.
    public var pids: [Int32]
    public var receivedAt: Date

    public init(agent: HookAgent, kind: Kind, sessionID: String = "", cwd: String = "", transcriptPath: String = "",
                toolName: String = "", preview: HookToolPreview? = nil, message: String = "", suggestions: Data? = nil,
                pids: [Int32] = [], receivedAt: Date = Date()) {
        self.agent = agent
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.preview = preview
        self.message = message
        self.suggestions = suggestions
        self.pids = pids
        self.receivedAt = receivedAt
    }

    /// True when the agent is blocked on the helper until Lookout answers (or gives up).
    public var awaitsDecision: Bool { kind == .permissionRequest }

    /// How the event changes the session's state; nil when it says nothing about it.
    public var signal: HookSignal? {
        switch kind {
        case .sessionStart(let source): return source == "compact" ? nil : .yourTurn
        case .sessionEnd: return .ended
        case .promptSubmitted: return .working
        case .permissionRequest: return .needsYou
        case .notification(let type):
            switch type {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return .needsYou
            case "idle_prompt": return .yourTurn
            default: return nil
            }
        case .stop, .turnComplete: return .yourTurn
        case .other: return nil
        }
    }

    // MARK: Parsing

    /// Parses one envelope line: `{"v":1,"agent":"claude","pids":[…],"payload":{…}}`.
    public static func parse(envelope data: Data, now: Date = Date()) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agent = (object["agent"] as? String).flatMap(HookAgent.init(rawValue:)),
              let payload = object["payload"] as? [String: Any] else { return nil }
        let pids = (object["pids"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        return parse(agent: agent, payload: payload, pids: pids, now: now)
    }

    public static func parse(agent: HookAgent, payload: [String: Any], pids: [Int32] = [], now: Date = Date()) -> HookEvent? {
        switch agent {
        case .claude: return parseClaude(payload, pids: pids, now: now)
        case .codex: return parseCodex(payload, pids: pids, now: now)
        }
    }

    private static func parseClaude(_ p: [String: Any], pids: [Int32], now: Date) -> HookEvent? {
        guard let name = p["hook_event_name"] as? String else { return nil }
        let kind: Kind
        switch name {
        case "SessionStart": kind = .sessionStart(source: p["source"] as? String ?? "startup")
        case "SessionEnd": kind = .sessionEnd
        case "UserPromptSubmit": kind = .promptSubmitted
        case "PermissionRequest": kind = .permissionRequest
        case "Notification": kind = .notification(type: p["notification_type"] as? String ?? "")
        case "Stop": kind = .stop
        default: kind = .other(name)
        }
        let tool = p["tool_name"] as? String ?? ""
        let input = p["tool_input"] as? [String: Any] ?? [:]
        let suggestions = (p["permission_suggestions"] as? [Any]).flatMap { list in
            list.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: list)
        }
        return HookEvent(
            agent: .claude, kind: kind,
            sessionID: p["session_id"] as? String ?? "",
            cwd: p["cwd"] as? String ?? "",
            transcriptPath: p["transcript_path"] as? String ?? "",
            toolName: tool,
            preview: tool.isEmpty ? nil : HookToolPreview(tool: tool, input: input),
            message: p["message"] as? String ?? p["last_assistant_message"] as? String ?? "",
            suggestions: suggestions,
            pids: pids, receivedAt: now
        )
    }

    /// Codex's notify payload uses kebab-case keys: `type`, `thread-id`, `cwd`, `last-assistant-message`.
    private static func parseCodex(_ p: [String: Any], pids: [Int32], now: Date) -> HookEvent? {
        guard let type = p["type"] as? String else { return nil }
        return HookEvent(
            agent: .codex, kind: type == "agent-turn-complete" ? .turnComplete : .other(type),
            sessionID: p["thread-id"] as? String ?? p["thread_id"] as? String ?? "",
            cwd: p["cwd"] as? String ?? "",
            message: p["last-assistant-message"] as? String ?? "",
            pids: pids, receivedAt: now
        )
    }

    /// The line `lookout-hook` sends: the hook's own JSON wrapped with who sent it. One line, no trailing newline.
    public static func envelope(agent: HookAgent, payload: Any, pids: [Int32]) -> Data? {
        let object: [String: Any] = ["v": 1, "agent": agent.rawValue, "pids": pids.map(Int.init), "payload": payload]
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object)
    }
}

/// A readable summary of what a tool call is about to do.
public struct HookToolPreview: Hashable, Sendable {
    public enum Body: Hashable, Sendable {
        case command(String)
        /// Replace `old` with `new` in `path` (Edit, and the first change of a MultiEdit).
        case edit(path: String, old: String, new: String)
        case write(path: String, content: String)
        case text(String)
    }

    /// "Run a command", "Edit file", …
    public var title: String
    /// A one-line subject: the command, the file name, the URL.
    public var subject: String
    /// Claude Code's own one-line description of the call, when it sent one.
    public var detail: String
    public var body: Body

    public init(title: String, subject: String, detail: String = "", body: Body) {
        self.title = title
        self.subject = subject
        self.detail = detail
        self.body = body
    }

    public init(tool: String, input: [String: Any]) {
        func string(_ key: String) -> String { input[key] as? String ?? "" }
        let path = string("file_path").isEmpty ? string("notebook_path") : string("file_path")
        let file = (path as NSString).lastPathComponent
        switch tool {
        case "Bash":
            let command = string("command")
            self.init(title: "Run a command", subject: Self.firstLine(command), detail: string("description"), body: .command(command))
        case "Edit":
            self.init(title: "Edit \(file)", subject: path, body: .edit(path: path, old: string("old_string"), new: string("new_string")))
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            let first = edits.first ?? [:]
            self.init(title: "Edit \(file)", subject: path, detail: edits.count > 1 ? "\(edits.count) changes" : "",
                      body: .edit(path: path, old: first["old_string"] as? String ?? "", new: first["new_string"] as? String ?? ""))
        case "Write":
            self.init(title: "Write \(file)", subject: path, body: .write(path: path, content: string("content")))
        case "NotebookEdit":
            self.init(title: "Edit \(file)", subject: path, body: .write(path: path, content: string("new_source")))
        case "WebFetch":
            self.init(title: "Fetch a web page", subject: string("url"), body: .text(string("prompt")))
        case "WebSearch":
            self.init(title: "Search the web", subject: string("query"), body: .text(string("query")))
        case "Read":
            self.init(title: "Read \(file)", subject: path, body: .text(path))
        case "Glob", "Grep":
            let pattern = string("pattern")
            self.init(title: tool == "Glob" ? "Find files" : "Search files", subject: pattern,
                      body: .text([pattern, string("path")].filter { !$0.isEmpty }.joined(separator: " in ")))
        case "Task", "Agent":
            self.init(title: "Start a subagent", subject: string("description"), body: .text(string("prompt")))
        default:
            // MCP tools and anything newer: the tool name and its arguments, compactly.
            let pairs = input.keys.sorted().prefix(6).map { key -> String in
                let value = input[key].map { "\($0)" } ?? ""
                return "\(key): \(value.count > 120 ? String(value.prefix(120)) + "…" : value)"
            }
            self.init(title: "Use \(Self.toolTitle(tool))", subject: pairs.first ?? "", body: .text(pairs.joined(separator: "\n")))
        }
    }

    /// `mcp__github__create_issue` reads as "github: create issue".
    static func toolTitle(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return tool }
        return "\(parts[1]): \(parts[2...].joined(separator: " ").replacingOccurrences(of: "_", with: " "))"
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return text.contains("\n") ? line + " …" : line
    }
}
