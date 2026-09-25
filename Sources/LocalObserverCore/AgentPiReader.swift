import Foundation

/// Pi coding agent sessions: `~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<id>.jsonl`.
/// A `type: "session"` header carries id and cwd; `type: "message"` entries wrap pi-ai
/// messages whose assistant `usage` is `{input, output, cacheRead, cacheWrite, cost.total}`,
/// with `input` already excluding cache.
struct PiUsageRecord: Sendable {
    var entryID: String
    var timestamp: Date
    var model: String
    var usage: TokenUsage
    var reportedCost: Double?
}

enum PiTail: Sendable {
    case none
    case user
    case assistantDone
    case assistantTool
    case error
}

struct PiFileState: AgentLineScanState {
    var offset: UInt64 = 0
    var lineIndex = 0
    var sessionID = ""
    var cwd = ""
    var model = ""
    var name = ""
    var firstPrompt = ""
    var startedAt: Date?
    var updatedAt: Date?
    var records: [PiUsageRecord] = []
    var tail = PiTail.none
    var contextTokens: Int64?

    mutating func consume(line: UnsafeRawBufferPointer, index: Int) {
        let needsParse = AgentJSON.contains(line, "\"usage\"") || AgentJSON.contains(line, "\"type\":\"session") ||
            AgentJSON.contains(line, "\"model_change\"") || AgentJSON.contains(line, "\"role\":\"user\"") ||
            AgentJSON.contains(line, "\"role\":\"assistant\"")
        guard needsParse, let object = AgentJSON.parseObject(line), let type = AgentJSON.string(object, ["type"]) else { return }
        let timestamp = AgentJSON.date(object, ["timestamp"])
        if let timestamp {
            startedAt = min(startedAt ?? timestamp, timestamp)
            updatedAt = max(updatedAt ?? timestamp, timestamp)
        }
        switch type {
        case "session":
            if let value = AgentJSON.string(object, ["id"]) { sessionID = value }
            if let value = AgentJSON.string(object, ["cwd"]) { cwd = value }
        case "session_info":
            if let value = AgentJSON.string(object, ["name", "title"]) { name = ClaudeText.titled(value) }
        case "model_change":
            if let value = AgentJSON.string(object, ["modelId", "model"]) { model = value }
        case "message":
            guard let message = AgentJSON.object(object, ["message"]) else { return }
            switch AgentJSON.string(message, ["role"]) {
            case "user":
                tail = .user
                if firstPrompt.isEmpty, let text = Self.text(message["content"]) { firstPrompt = ClaudeText.titled(text) }
            case "assistant":
                consumeAssistant(message, entryID: AgentJSON.string(object, ["id"]) ?? "line\(index)", timestamp: timestamp)
            default:
                break
            }
        default:
            break
        }
    }

    private mutating func consumeAssistant(_ message: [String: Any], entryID: String, timestamp: Date?) {
        if let value = AgentJSON.string(message, ["model"]) { model = value }
        switch AgentJSON.string(message, ["stopReason"]) {
        case "toolUse": tail = .assistantTool
        case "error", "aborted": tail = .error
        default: tail = .assistantDone
        }
        guard let usage = AgentJSON.object(message, ["usage"]),
              let timestamp = timestamp ?? AgentJSON.date(message, ["timestamp"]) else { return }
        let input = max(0, AgentJSON.int64(usage, ["input"]) ?? 0)
        let cached = max(0, AgentJSON.int64(usage, ["cacheRead"]) ?? 0)
        let cacheWrite = max(0, AgentJSON.int64(usage, ["cacheWrite"]) ?? 0)
        let output = max(0, AgentJSON.int64(usage, ["output"]) ?? 0)
        guard input + cached + cacheWrite + output > 0 else { return }
        let cost = AgentJSON.object(usage, ["cost"]).flatMap { AgentJSON.double($0, ["total"]) }
        records.append(PiUsageRecord(
            entryID: entryID,
            timestamp: timestamp,
            model: model,
            usage: TokenUsage(uncachedInputTokens: input, cachedInputTokens: cached, cacheCreationTokens: cacheWrite, outputTokens: output),
            // Pi writes 0 for models it has no price for; let the shared table estimate those.
            reportedCost: cost.flatMap { $0 > 0 ? $0 : nil }
        ))
        contextTokens = input + cached + cacheWrite
    }

    private static func text(_ content: Any?) -> String? {
        if let string = content as? String { return string.isEmpty ? nil : string }
        for block in AgentJSON.array(content) {
            if let object = AgentJSON.object(block), AgentJSON.string(object, ["type"]) == "text",
               let text = AgentJSON.string(object, ["text"]) {
                return text
            }
        }
        return nil
    }
}

enum AgentPiReader {
    static let cache = AgentFileCache<PiFileState>()

    static func read(historyDays: Int, now: Date = Date()) -> AgentArtifactResult {
        let cutoff = now.addingTimeInterval(-Double(historyDays) * 86_400)
        let files = AgentFileScanner.files(in: AgentDiscovery.dataURLs(for: .pi), since: cutoff) { $0.pathExtension == "jsonl" }
        guard !files.isEmpty else { return AgentArtifactResult() }
        let outcome = AgentFileScanner.scan(files: files, cache: cache) { _ in PiFileState() }
        let names = AgentProjectNames()
        var result = AgentArtifactResult()
        for (file, state) in outcome.states {
            let sessionID = state.sessionID.isEmpty ? file.url.deletingPathExtension().lastPathComponent : state.sessionID
            let projectName = names.name(for: state.cwd)
            let events = state.records.filter { $0.timestamp >= cutoff }.map { record in
                AgentUsageFactory.event(
                    id: "pi|\(sessionID)|\(record.entryID)",
                    agent: .pi,
                    sessionID: sessionID,
                    projectPath: state.cwd,
                    projectName: projectName,
                    model: record.model,
                    observedAt: record.timestamp,
                    usage: record.usage,
                    reportedCost: record.reportedCost,
                    sourcePath: file.url.path
                )
            }
            result.usageEvents.append(contentsOf: events)
            let age = now.timeIntervalSince(file.stamp.modifiedAt)
            let activity: AgentActivityState
            switch state.tail {
            case .assistantDone, .none: activity = age < 10 && state.tail == .none ? .working : .idle
            case .error: activity = age < 30 * 60 ? .failed : .idle
            case .assistantTool: activity = age < 10 ? .toolUse : (age < 120 ? .working : .idle)
            case .user: activity = age < 10 ? .working : (age < 120 ? .thinking : .idle)
            }
            var session = AgentSession(
                id: "pi|session|\(sessionID)",
                agent: .pi,
                sessionID: sessionID,
                title: [state.name, state.firstPrompt].first { !$0.isEmpty } ?? projectName,
                process: nil,
                projectPath: state.cwd,
                projectName: projectName,
                model: state.model,
                account: "",
                branch: "",
                state: activity,
                startedAt: state.startedAt ?? file.stamp.modifiedAt,
                updatedAt: max(state.updatedAt ?? file.stamp.modifiedAt, file.stamp.modifiedAt),
                sourcePath: file.url.path,
                sourceKind: .transcript,
                usage: nil,
                cost: nil,
                requests: nil,
                contextTokens: state.contextTokens
            )
            AgentUsageFactory.apply(events, to: &session)
            result.sessions.append(session)
        }
        result.warnings.append(contentsOf: AgentArtifactReader.scanWarnings(agent: .pi, outcome: outcome))
        return result
    }
}
