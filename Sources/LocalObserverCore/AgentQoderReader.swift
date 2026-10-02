import Foundation

/// Qoder sessions: `~/.qoder/projects/<encoded-cwd>/<session-id>.jsonl`, a Claude-Code-shaped transcript, with
/// subagent transcripts under `<session-id>/subagents/`.
///
/// Qoder writes zero into every `message.usage` token field (and its own logs), so tokens are estimated from the
/// transcript itself: each model request's input is the conversation so far plus the system prompt, and its output
/// is what the assistant wrote. See `QoderTokenEstimate`. Qoder bills in plan credits rather than dollars, so no cost.
struct QoderRequestRecord: Sendable {
    var lineIndex: Int
    var messageID: String?
    var timestamp: Date
    var model: String
    var inputTokens: Int64
    var outputBytes: Int
}

/// Calibrated against the `preTokens` Qoder records when it compacts a conversation: context bytes (string content,
/// not JSON syntax) divided by `bytesPerToken`, plus `systemPromptTokens`, lands within ~4% of Qoder's own count.
enum QoderTokenEstimate {
    static let bytesPerToken = 3.2
    static let systemPromptTokens: Int64 = 20_000
    /// Qoder's models take at most this much input (`max_input_tokens` in its logs). Long sessions get pruned
    /// without a compaction marker, so the running estimate is capped here.
    static let maxInputTokens: Int64 = 180_000
    /// A vision input costs roughly this many tokens regardless of its base64 length.
    static let imageBytes = 5_600

    static func tokens(bytes: Int) -> Int64 { Int64((Double(bytes) / bytesPerToken).rounded()) }

    /// Byte size of the text a message carries: string leaves and keys, images at a flat rate, signatures skipped.
    static func bytes(_ value: Any?) -> Int {
        switch value {
        case let string as String:
            return string.utf8.count
        case let array as [Any]:
            return array.reduce(0) { $0 + bytes($1) }
        case let object as [String: Any]:
            if object["type"] as? String == "image" { return imageBytes }
            return object.reduce(0) { total, entry in
                entry.key == "signature" || entry.key == "cache_control" ? total : total + entry.key.utf8.count + bytes(entry.value)
            }
        case is NSNumber:
            return 2
        default:
            return 0
        }
    }

    /// Qoder's internal model keys, as its model picker names them.
    static func displayName(_ model: String) -> String {
        switch model {
        case "qfmodel": return "Qwen3.8-Flash"
        case "qmodel_38max": return "Qwen3.8-Max"
        case "auto": return "Qoder Auto"
        default: return model
        }
    }
}

struct QoderFileState: AgentLineScanState {
    var offset: UInt64 = 0
    var lineIndex = 0
    var sessionID = ""
    var cwd = ""
    var branch = ""
    var model = ""
    var firstPrompt = ""
    var startedAt: Date?
    var updatedAt: Date?
    var records: [QoderRequestRecord] = []
    var tail = ClaudeTail.none
    var sawConversation = false
    /// Bytes of conversation the next request will send, since the last compaction.
    var contextBytes = 0
    var lastContextTokens: Int64?

    mutating func consume(line: UnsafeRawBufferPointer, index: Int) {
        if AgentJSON.contains(line, "\"type\":\"assistant\"") {
            if let object = AgentJSON.parseObject(line), AgentJSON.string(object, ["type"]) == "assistant" {
                consumeAssistant(object, index: index)
            }
        } else if AgentJSON.contains(line, "\"type\":\"user\"") {
            if let object = AgentJSON.parseObject(line), AgentJSON.string(object, ["type"]) == "user" {
                consumeUser(object, isToolResult: AgentJSON.contains(line, "\"tool_result\""))
            }
        } else if AgentJSON.contains(line, "\"type\":\"runtime-config\"") {
            if let object = AgentJSON.parseObject(line), let value = AgentJSON.string(object, ["model"]), !value.isEmpty {
                model = value
            }
        } else if AgentJSON.contains(line, "\"type\":\"workspace-directories\"") {
            // The first user line carries `cwd` too; this covers sessions with no conversation yet.
            if cwd.isEmpty, let object = AgentJSON.parseObject(line),
               let first = AgentJSON.array(object["directories"]).first as? String, !first.isEmpty {
                cwd = first
            }
        } else if AgentJSON.contains(line, "\"compact_boundary\"") {
            // After compaction the next request carries only the summary Qoder measured.
            if let object = AgentJSON.parseObject(line), let metadata = AgentJSON.object(object, ["compactMetadata"]),
               let post = AgentJSON.int64(metadata, ["postTokens"]) {
                contextBytes = Int(Double(post) * QoderTokenEstimate.bytesPerToken)
            }
        } else if AgentJSON.contains(line, "\"type\":\"system\""), AgentJSON.contains(line, "\"api_error\"") {
            tail = .error
        }
    }

    private mutating func noteCommon(_ object: [String: Any]) -> Date? {
        sawConversation = true
        if sessionID.isEmpty, let value = AgentJSON.string(object, ["sessionId"]) { sessionID = value }
        if let value = AgentJSON.string(object, ["cwd"]) { cwd = value }
        if let value = AgentJSON.string(object, ["gitBranch"]), value != "HEAD" || branch.isEmpty { branch = value }
        let timestamp = AgentJSON.date(object, ["timestamp"])
        if let timestamp {
            startedAt = min(startedAt ?? timestamp, timestamp)
            updatedAt = max(updatedAt ?? timestamp, timestamp)
        }
        return timestamp
    }

    private mutating func consumeUser(_ object: [String: Any], isToolResult: Bool) {
        _ = noteCommon(object)
        tail = isToolResult ? .toolResult : .userPrompt
        guard let message = AgentJSON.object(object, ["message"]) else { return }
        // The compaction summary is already counted by the boundary's postTokens.
        if AgentJSON.bool(object, ["isCompactSummary"]) != true {
            contextBytes += QoderTokenEstimate.bytes(message["content"])
        }
        guard !isToolResult, firstPrompt.isEmpty, AgentJSON.bool(object, ["isMeta"]) != true else { return }
        if let text = ClaudeText.promptText(message["content"]) { firstPrompt = text }
    }

    private mutating func consumeAssistant(_ object: [String: Any], index: Int) {
        let timestamp = noteCommon(object)
        guard let message = AgentJSON.object(object, ["message"]) else { return }
        if let value = AgentJSON.string(message, ["model"]), !value.isEmpty, value != "<synthetic>" { model = value }
        switch AgentJSON.string(message, ["stop_reason"]) {
        case "end_turn", "stop_sequence", "max_tokens", "refusal": tail = .assistantEndTurn
        case "tool_use": tail = .assistantToolUse
        default: tail = .assistantStreaming
        }
        let written = QoderTokenEstimate.bytes(message["content"])
        defer { contextBytes += written }
        guard AgentJSON.object(message, ["usage"]) != nil, let timestamp else { return }
        let messageID = AgentJSON.string(message, ["id"])
        // One response is split across several lines (thinking, text, each tool call) sharing an id.
        if let messageID, let last = records.indices.last, records[last].messageID == messageID {
            records[last].outputBytes += written
            return
        }
        let input = min(QoderTokenEstimate.systemPromptTokens + QoderTokenEstimate.tokens(bytes: contextBytes),
                        QoderTokenEstimate.maxInputTokens)
        lastContextTokens = input
        records.append(QoderRequestRecord(
            lineIndex: index,
            messageID: messageID,
            timestamp: timestamp,
            model: model,
            inputTokens: input,
            outputBytes: written
        ))
    }
}

enum AgentQoderReader {
    static let cache = AgentFileCache<QoderFileState>()

    static func read(historyDays: Int, now: Date = Date()) -> AgentArtifactResult {
        let cutoff = now.addingTimeInterval(-Double(historyDays) * 86_400)
        let files = AgentFileScanner.files(in: AgentDiscovery.dataURLs(for: .qoder), since: cutoff) { $0.pathExtension == "jsonl" }
        guard !files.isEmpty else { return AgentArtifactResult() }
        let outcome = AgentFileScanner.scan(files: files, cache: cache) { _ in QoderFileState() }
        var result = aggregate(outcome.states.map { ($0.file.url.path, $0.file.stamp.modifiedAt, $0.state) }, cutoff: cutoff, now: now)
        result.warnings.append(contentsOf: AgentArtifactReader.scanWarnings(agent: .qoder, outcome: outcome))
        return result
    }

    /// Folds subagent transcripts, which carry their parent's session id, into one session per conversation.
    static func aggregate(_ files: [(path: String, modifiedAt: Date, state: QoderFileState)], cutoff: Date, now: Date) -> AgentArtifactResult {
        let names = AgentProjectNames()
        var result = AgentArtifactResult()
        let conversations = files.filter { $0.state.sawConversation }
        let groups = Dictionary(grouping: conversations) { entry in
            entry.state.sessionID.isEmpty ? URL(fileURLWithPath: entry.path).deletingPathExtension().lastPathComponent : entry.state.sessionID
        }
        for (sessionID, entries) in groups {
            let primary = entries.first { !$0.path.contains("/subagents/") } ?? entries.max { $0.modifiedAt < $1.modifiedAt }!
            let lastActivity = entries.map(\.modifiedAt).max() ?? primary.modifiedAt
            guard lastActivity >= cutoff else { continue }
            let state = primary.state
            let projectName = names.name(for: state.cwd)
            var events: [AgentUsageEvent] = []
            for entry in entries {
                for record in entry.state.records where record.timestamp >= cutoff {
                    let usage = TokenUsage(inputTokens: record.inputTokens,
                                           outputTokens: QoderTokenEstimate.tokens(bytes: record.outputBytes))
                    let key = record.messageID ?? "\(URL(fileURLWithPath: entry.path).lastPathComponent)#\(record.lineIndex)"
                    events.append(AgentUsageFactory.event(
                        id: "qoder|\(sessionID)|\(key)",
                        agent: .qoder,
                        sessionID: sessionID,
                        projectPath: state.cwd,
                        projectName: projectName,
                        model: QoderTokenEstimate.displayName(record.model),
                        observedAt: record.timestamp,
                        usage: usage,
                        reportedCost: nil,
                        sourcePath: entry.path
                    ))
                }
            }
            result.usageEvents.append(contentsOf: events)
            var session = AgentSession(
                id: "qoder|session|\(sessionID)",
                agent: .qoder,
                sessionID: sessionID,
                title: state.firstPrompt.isEmpty ? projectName : state.firstPrompt,
                process: nil,
                projectPath: state.cwd,
                projectName: projectName,
                model: QoderTokenEstimate.displayName(state.model),
                account: "",
                branch: state.branch,
                state: AgentClaudeReader.activityState(tail: state.tail, modifiedAt: primary.modifiedAt, now: now),
                startedAt: entries.compactMap(\.state.startedAt).min() ?? primary.modifiedAt,
                updatedAt: max(state.updatedAt ?? primary.modifiedAt, lastActivity),
                sourcePath: primary.path,
                sourceKind: .transcript,
                usage: nil,
                cost: nil,
                requests: nil,
                contextTokens: state.lastContextTokens
            )
            AgentUsageFactory.apply(events, to: &session)
            result.sessions.append(session)
        }
        return result
    }
}
