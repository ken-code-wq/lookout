import Foundation

/// Qoder sessions: `~/.qoder/projects/<encoded-cwd>/<session-id>.jsonl`, a Claude-Code-shaped transcript.
///
/// Qoder writes zero into every `message.usage` token field, and bills in subscription credits that
/// reset per billing cycle rather than mapping onto dollars, so neither tokens nor cost are recoverable
/// locally. Each `usage` object still marks exactly one model request, which is what this reader reports.
struct QoderRequestRecord: Sendable {
    var lineIndex: Int
    var messageID: String?
    var timestamp: Date
    var model: String
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
        } else if AgentJSON.contains(line, "\"type\":\"system\""), AgentJSON.contains(line, "\"api_error\"") {
            tail = .error
        }
    }

    private mutating func noteCommon(_ object: [String: Any]) -> Date? {
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
        guard !isToolResult, firstPrompt.isEmpty, AgentJSON.bool(object, ["isMeta"]) != true,
              let message = AgentJSON.object(object, ["message"]) else { return }
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
        guard AgentJSON.object(message, ["usage"]) != nil, let timestamp else { return }
        records.append(QoderRequestRecord(
            lineIndex: index,
            messageID: AgentJSON.string(message, ["id"]),
            timestamp: timestamp,
            model: model
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
        let names = AgentProjectNames()
        var result = AgentArtifactResult()
        for (file, state) in outcome.states {
            let sessionID = state.sessionID.isEmpty ? file.url.deletingPathExtension().lastPathComponent : state.sessionID
            let projectName = names.name(for: state.cwd)
            let events = state.records.filter { $0.timestamp >= cutoff }.map { record in
                AgentUsageFactory.event(
                    id: "qoder|\(sessionID)|\(record.messageID ?? "line\(record.lineIndex)")",
                    agent: .qoder,
                    sessionID: sessionID,
                    projectPath: state.cwd,
                    projectName: projectName,
                    model: record.model,
                    observedAt: record.timestamp,
                    usage: TokenUsage(),
                    reportedCost: nil,
                    sourcePath: file.url.path
                )
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
                model: state.model,
                account: "",
                branch: state.branch,
                state: AgentClaudeReader.activityState(tail: state.tail, modifiedAt: file.stamp.modifiedAt, now: now),
                startedAt: state.startedAt ?? file.stamp.modifiedAt,
                updatedAt: max(state.updatedAt ?? file.stamp.modifiedAt, file.stamp.modifiedAt),
                sourcePath: file.url.path,
                sourceKind: .transcript,
                usage: nil,
                cost: nil,
                requests: nil
            )
            AgentUsageFactory.apply(events, to: &session)
            result.sessions.append(session)
        }
        result.warnings.append(contentsOf: AgentArtifactReader.scanWarnings(agent: .qoder, outcome: outcome))
        return result
    }
}
