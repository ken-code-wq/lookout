import Foundation

/// Token totals Copilot CLI writes per model in each `session.shutdown` event. Each shutdown
/// covers the segment since the session started or was last resumed, so segments add up.
struct CopilotUsageRecord: Sendable {
    var eventID: String
    var lineIndex: Int
    var timestamp: Date
    var model: String
    var uncached: Int64
    var cached: Int64
    var cacheWrite: Int64
    var output: Int64
    var reasoning: Int64
    var requests: Int

    var usage: TokenUsage {
        TokenUsage(uncachedInputTokens: uncached, cachedInputTokens: cached, cacheCreationTokens: cacheWrite, outputTokens: output, reasoningTokens: reasoning)
    }
}

enum CopilotTail: Sendable {
    case none
    case turnStarted
    case turnEnded
    case shutdown
}

struct CopilotFileState: AgentLineScanState {
    var offset: UInt64 = 0
    var lineIndex = 0
    var sessionID = ""
    var cwd = ""
    var branch = ""
    var model = ""
    var title = ""
    var startedAt: Date?
    var updatedAt: Date?
    var records: [CopilotUsageRecord] = []
    var tail = CopilotTail.none

    mutating func consume(line: UnsafeRawBufferPointer, index: Int) {
        let interesting = AgentJSON.contains(line, "\"type\":\"session.") || AgentJSON.contains(line, "\"type\":\"assistant.turn_") ||
            AgentJSON.contains(line, "\"type\":\"abort\"") || (title.isEmpty && AgentJSON.contains(line, "\"type\":\"user.message\""))
        guard interesting, let object = AgentJSON.parseObject(line), let type = AgentJSON.string(object, ["type"]) else { return }
        let data = AgentJSON.object(object, ["data"]) ?? [:]
        let timestamp = AgentJSON.date(object, ["timestamp"])
        if let timestamp {
            startedAt = min(startedAt ?? timestamp, timestamp)
            updatedAt = max(updatedAt ?? timestamp, timestamp)
        }
        switch type {
        case "session.start", "session.resume":
            if let value = AgentJSON.string(data, ["sessionId"]) { sessionID = value }
            if let value = AgentJSON.string(data, ["selectedModel"]) { model = value }
            if let context = AgentJSON.object(data, ["context"]) {
                if let value = AgentJSON.string(context, ["cwd"]) { cwd = value }
                if let value = AgentJSON.string(context, ["branch"]) { branch = value }
            }
            tail = .turnEnded
        case "session.model_change":
            if let value = AgentJSON.string(data, ["newModel", "model"]) { model = value }
        case "session.shutdown":
            tail = .shutdown
            if let value = AgentJSON.string(data, ["currentModel"]) { model = value }
            guard let timestamp, let metrics = AgentJSON.object(data, ["modelMetrics"]) else { return }
            let eventID = AgentJSON.string(object, ["id"]) ?? "line\(index)"
            for (modelName, value) in metrics.sorted(by: { $0.key < $1.key }) {
                guard let metric = AgentJSON.object(value), let usage = AgentJSON.object(metric, ["usage"]) else { continue }
                // inputTokens includes cache reads and writes.
                let input = max(0, AgentJSON.int64(usage, ["inputTokens"]) ?? 0)
                let cached = max(0, AgentJSON.int64(usage, ["cacheReadTokens"]) ?? 0)
                let cacheWrite = max(0, AgentJSON.int64(usage, ["cacheWriteTokens"]) ?? 0)
                let output = max(0, AgentJSON.int64(usage, ["outputTokens"]) ?? 0)
                let record = CopilotUsageRecord(
                    eventID: eventID,
                    lineIndex: index,
                    timestamp: timestamp,
                    model: modelName,
                    uncached: max(0, input - cached - cacheWrite),
                    cached: cached,
                    cacheWrite: cacheWrite,
                    output: output,
                    reasoning: min(output, max(0, AgentJSON.int64(usage, ["reasoningTokens"]) ?? 0)),
                    requests: AgentJSON.path(metric, ["requests", "count"]).flatMap { ($0 as? NSNumber)?.intValue } ?? 1
                )
                if record.uncached + cached + cacheWrite + output > 0 { records.append(record) }
            }
        case "assistant.turn_start":
            tail = .turnStarted
        case "assistant.turn_end", "abort", "session.task_complete":
            tail = .turnEnded
        case "user.message":
            guard title.isEmpty, let text = AgentJSON.string(data, ["content"]) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("<") { title = ClaudeText.titled(trimmed) }
        default:
            break
        }
    }
}

enum AgentCopilotReader {
    static let cache = AgentFileCache<CopilotFileState>()

    static func read(historyDays: Int, now: Date = Date()) -> AgentArtifactResult {
        let cutoff = now.addingTimeInterval(-Double(historyDays) * 86_400)
        let roots = AgentDiscovery.dataURLs(for: .copilot)
        // `<id>/events.jsonl` for current sessions, `<id>.jsonl` for older ones.
        let rootPaths = Set(roots.map { $0.standardizedFileURL.path })
        let files = AgentFileScanner.files(in: roots, since: cutoff) { url in
            url.lastPathComponent == "events.jsonl" ||
                (url.pathExtension == "jsonl" && rootPaths.contains(url.deletingLastPathComponent().standardizedFileURL.path))
        }
        guard !files.isEmpty else { return AgentArtifactResult() }
        let outcome = AgentFileScanner.scan(files: files, cache: cache) { _ in CopilotFileState() }
        let names = AgentProjectNames()
        var result = AgentArtifactResult()
        for (file, state) in outcome.states {
            let directory = file.url.deletingLastPathComponent()
            let workspace = file.url.lastPathComponent == "events.jsonl" ? readWorkspace(directory.appendingPathComponent("workspace.yaml")) : [:]
            let sessionID = state.sessionID.isEmpty
                ? (workspace["id"] ?? (file.url.lastPathComponent == "events.jsonl" ? directory.lastPathComponent : file.url.deletingPathExtension().lastPathComponent))
                : state.sessionID
            let projectPath = state.cwd.isEmpty ? (workspace["cwd"] ?? workspace["git_root"] ?? "") : state.cwd
            let projectName = names.name(for: projectPath)
            let events = state.records.filter { $0.timestamp >= cutoff }.map { record in
                AgentUsageFactory.event(
                    id: "copilot|\(sessionID)|\(record.eventID)|\(record.model)",
                    agent: .copilot,
                    sessionID: sessionID,
                    projectPath: projectPath,
                    projectName: projectName,
                    model: record.model,
                    observedAt: record.timestamp,
                    usage: record.usage,
                    reportedCost: nil,
                    requests: record.requests,
                    sourcePath: file.url.path
                )
            }
            result.usageEvents.append(contentsOf: events)
            let title = [workspace["name"] ?? "", workspace["summary"] ?? "", state.title].first { !$0.isEmpty }.map { ClaudeText.titled($0) }
            var session = AgentSession(
                id: "copilot|session|\(sessionID)",
                agent: .copilot,
                sessionID: sessionID,
                title: title ?? projectName,
                process: nil,
                projectPath: projectPath,
                projectName: projectName,
                model: state.model,
                account: "",
                branch: state.branch.isEmpty ? (workspace["branch"] ?? "") : state.branch,
                state: activityState(tail: state.tail, modifiedAt: file.stamp.modifiedAt, now: now),
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
        result.warnings.append(contentsOf: AgentArtifactReader.scanWarnings(agent: .copilot, outcome: outcome))
        return result
    }

    /// Top-level `key: value` pairs; block scalars (`key: |`) take their first line.
    static func readWorkspace(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        var pendingBlockKey: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let key = pendingBlockKey {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { values[key] = trimmed }
                pendingBlockKey = nil
                continue
            }
            guard let first = line.first, first != " ", first != "#", let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value == "|" || value == ">" || value.hasPrefix("|-") || value.hasPrefix(">-") {
                pendingBlockKey = key
                continue
            }
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { values[key] = value }
        }
        return values
    }

    static func activityState(tail: CopilotTail, modifiedAt: Date, now: Date) -> AgentActivityState {
        let age = now.timeIntervalSince(modifiedAt)
        switch tail {
        case .shutdown, .turnEnded: return .idle
        case .turnStarted:
            if age < 10 { return .working }
            return age < 120 ? .thinking : .idle
        case .none: return age < 10 ? .working : .idle
        }
    }
}
