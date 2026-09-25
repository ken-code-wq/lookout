import Foundation

/// One `type: "assistant"` transcript line that carries `message.usage`.
struct ClaudeUsageRecord: Sendable {
    var messageID: String?
    var requestID: String?
    var lineIndex: Int
    var timestamp: Date
    var model: String
    var sessionID: String
    var uncached: Int64
    var cached: Int64
    var cacheCreation: Int64
    var output: Int64
    var fast: Bool
    var reportedCost: Double?
    var isSidechain: Bool

    var totalTokens: Int64 { uncached + cached + cacheCreation + output }

    /// Claude Code writes one line per content block and repeats the parent message's full
    /// `usage` on each, so (message.id, requestId) identifies one billed request.
    var dedupeKey: String? {
        guard messageID != nil || requestID != nil else { return nil }
        return "\(messageID ?? "")|\(requestID ?? "")"
    }

    var usage: TokenUsage {
        TokenUsage(uncachedInputTokens: uncached, cachedInputTokens: cached, cacheCreationTokens: cacheCreation, outputTokens: output)
    }

    /// ccusage's rule: a main-thread copy beats a sidechain replay, then the larger usage wins
    /// (streamed partial lines can under-report output), then the one that recorded `speed`.
    func shouldReplace(_ existing: ClaudeUsageRecord) -> Bool {
        if isSidechain != existing.isSidechain { return existing.isSidechain }
        return totalTokens > existing.totalTokens
    }
}

enum ClaudeTail: Sendable {
    case none
    case assistantEndTurn
    case assistantToolUse
    case assistantStreaming
    case toolResult
    case userPrompt
    case error
}

struct ClaudeFileState: AgentLineScanState {
    var offset: UInt64 = 0
    var lineIndex = 0
    var records: [ClaudeUsageRecord] = []
    var sessionID = ""
    var cwd = ""
    var branch = ""
    var model = ""
    var sidechainModel = ""
    var customTitle = ""
    var aiTitle = ""
    var summaryTitle = ""
    var firstPrompt = ""
    var startedAt: Date?
    var updatedAt: Date?
    var tail = ClaudeTail.none
    var contextTokens: Int64?
    var sawMainThread = false
    var sawConversation = false

    mutating func consume(line: UnsafeRawBufferPointer, index: Int) {
        if AgentJSON.contains(line, "\"type\":\"assistant\"") {
            guard let object = AgentJSON.parseObject(line), AgentJSON.string(object, ["type"]) == "assistant" else { return }
            consumeAssistant(object, index: index)
        } else if AgentJSON.contains(line, "\"type\":\"user\"") {
            let isToolResult = AgentJSON.contains(line, "\"tool_result\"")
            let needsDetails = cwd.isEmpty || sessionID.isEmpty || (!isToolResult && firstPrompt.isEmpty)
            if needsDetails, let object = AgentJSON.parseObject(line), AgentJSON.string(object, ["type"]) == "user" {
                consumeUser(object, isToolResult: isToolResult)
            } else {
                sawConversation = true
                if !AgentJSON.contains(line, "\"isSidechain\":true") {
                    sawMainThread = true
                    tail = isToolResult ? .toolResult : .userPrompt
                }
            }
        } else if AgentJSON.contains(line, "\"custom-title\"") {
            if let object = AgentJSON.parseObject(line), let title = AgentJSON.string(object, ["customTitle", "title"]) {
                customTitle = ClaudeText.titled(title)
            }
        } else if AgentJSON.contains(line, "\"ai-title\"") {
            if let object = AgentJSON.parseObject(line), let title = AgentJSON.string(object, ["aiTitle", "title"]) {
                aiTitle = ClaudeText.titled(title)
            }
        } else if AgentJSON.contains(line, "\"type\":\"summary\"") {
            if let object = AgentJSON.parseObject(line), let title = AgentJSON.string(object, ["summary"]) {
                summaryTitle = ClaudeText.titled(title)
            }
        } else if AgentJSON.contains(line, "\"type\":\"system\""), AgentJSON.contains(line, "\"api_error\"") {
            if !AgentJSON.contains(line, "\"isSidechain\":true") { tail = .error }
        }
    }

    private mutating func noteCommon(_ object: [String: Any]) -> (timestamp: Date?, sidechain: Bool) {
        sawConversation = true
        if sessionID.isEmpty, let value = AgentJSON.string(object, ["sessionId"]) { sessionID = value }
        if let value = AgentJSON.string(object, ["cwd"]) { cwd = value }
        if let value = AgentJSON.string(object, ["gitBranch"]), value != "HEAD" || branch.isEmpty { branch = value }
        let timestamp = AgentJSON.date(object, ["timestamp"])
        if let timestamp {
            startedAt = min(startedAt ?? timestamp, timestamp)
            updatedAt = max(updatedAt ?? timestamp, timestamp)
        }
        let sidechain = AgentJSON.bool(object, ["isSidechain"]) == true
        if !sidechain { sawMainThread = true }
        return (timestamp, sidechain)
    }

    private mutating func consumeUser(_ object: [String: Any], isToolResult: Bool) {
        let (_, sidechain) = noteCommon(object)
        guard !sidechain else { return }
        tail = isToolResult ? .toolResult : .userPrompt
        guard !isToolResult, firstPrompt.isEmpty, AgentJSON.bool(object, ["isMeta"]) != true,
              let message = AgentJSON.object(object, ["message"]) else { return }
        if let text = ClaudeText.promptText(message["content"]) { firstPrompt = text }
    }

    private mutating func consumeAssistant(_ object: [String: Any], index: Int) {
        let (timestamp, sidechain) = noteCommon(object)
        guard let message = AgentJSON.object(object, ["message"]) else { return }
        let model = AgentJSON.string(message, ["model"]) ?? ""
        let synthetic = model == "<synthetic>"
        if !model.isEmpty, !synthetic {
            if sidechain { sidechainModel = model } else { self.model = model }
        }
        if !sidechain {
            if AgentJSON.bool(object, ["isApiErrorMessage"]) == true {
                tail = .error
            } else {
                switch AgentJSON.string(message, ["stop_reason"]) {
                case "end_turn", "stop_sequence", "max_tokens", "refusal": tail = .assistantEndTurn
                case "tool_use": tail = .assistantToolUse
                case "pause_turn": tail = .assistantStreaming
                default: tail = .assistantStreaming
                }
            }
        }
        guard !synthetic, !model.isEmpty, let usage = AgentJSON.object(message, ["usage"]), let timestamp else { return }
        let record = ClaudeUsageRecord(
            messageID: AgentJSON.string(message, ["id"]),
            requestID: AgentJSON.string(object, ["requestId"]),
            lineIndex: index,
            timestamp: timestamp,
            model: model,
            sessionID: AgentJSON.string(object, ["sessionId"]) ?? sessionID,
            uncached: max(0, AgentJSON.int64(usage, ["input_tokens"]) ?? 0),
            cached: max(0, AgentJSON.int64(usage, ["cache_read_input_tokens"]) ?? 0),
            cacheCreation: max(0, AgentJSON.int64(usage, ["cache_creation_input_tokens"]) ?? 0),
            output: max(0, AgentJSON.int64(usage, ["output_tokens"]) ?? 0),
            fast: AgentJSON.string(usage, ["speed"]) == "fast",
            reportedCost: AgentJSON.double(object, ["costUSD"]),
            isSidechain: sidechain
        )
        guard record.totalTokens > 0 else { return }
        if !sidechain { contextTokens = record.uncached + record.cached + record.cacheCreation }
        // Consecutive lines of one message: keep the most complete in place rather than growing the array.
        if let key = record.dedupeKey, let last = records.last, last.dedupeKey == key {
            if record.shouldReplace(last) || record.totalTokens == last.totalTokens && record.fast && !last.fast {
                records[records.count - 1] = record
            }
            return
        }
        records.append(record)
    }
}

enum ClaudeText {
    private static let skippedPrefixes = [
        "<command-", "<local-command", "<system-reminder", "<bash-", "<user-prompt-submit-hook",
        "caveat:", "[request interrupted", "<task-notification", "<ide_", "<session-start-hook"
    ]

    static func promptText(_ content: Any?) -> String? {
        var text: String?
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [Any] {
            for block in blocks {
                guard let object = block as? [String: Any] else { continue }
                if AgentJSON.string(object, ["type"]) == "tool_result" { return nil }
                if AgentJSON.string(object, ["type"]) == "text", let value = AgentJSON.string(object, ["text"]) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !isSkipped(trimmed) {
                        text = trimmed
                        break
                    }
                }
            }
        }
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSkipped(trimmed) else { return nil }
        return titled(trimmed)
    }

    private static func isSkipped(_ text: String) -> Bool {
        let lower = text.prefix(40).lowercased()
        return skippedPrefixes.contains { lower.hasPrefix($0) }
    }

    /// Single line, at most ~80 characters.
    static func titled(_ text: String, limit: Int = 80) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

enum AgentClaudeReader {
    static let cache = AgentFileCache<ClaudeFileState>()

    static func read(historyDays: Int, now: Date = Date()) -> AgentArtifactResult {
        let cutoff = now.addingTimeInterval(-Double(historyDays) * 86_400)
        let roots = AgentDiscovery.dataURLs(for: .claude)
        let files = AgentFileScanner.files(in: roots, since: cutoff) { $0.pathExtension == "jsonl" }
        guard !files.isEmpty else { return AgentArtifactResult() }
        let outcome = AgentFileScanner.scan(files: files, cache: cache) { _ in ClaudeFileState() }
        var result = aggregate(outcome.states.map { ($0.file.url.path, $0.file.stamp.modifiedAt, $0.state) }, cutoff: cutoff, now: now)
        result.warnings.append(contentsOf: AgentArtifactReader.scanWarnings(agent: .claude, outcome: outcome))
        return result
    }

    /// Globally de-duplicates usage across files, then folds files into sessions by `sessionId`
    /// (subagent transcripts share their parent's id).
    static func aggregate(_ files: [(path: String, modifiedAt: Date, state: ClaudeFileState)], cutoff: Date, now: Date) -> AgentArtifactResult {
        // Oldest first, so an original transcript wins ties against resumed/forked copies.
        let ordered = files.sorted { $0.modifiedAt < $1.modifiedAt }
        var winners: [String: (file: Int, record: Int)] = [:]
        var keyless: [(file: Int, record: Int)] = []
        for (fileIndex, file) in ordered.enumerated() {
            for (recordIndex, record) in file.state.records.enumerated() {
                guard let key = record.dedupeKey else {
                    keyless.append((fileIndex, recordIndex))
                    continue
                }
                if let existing = winners[key] {
                    let current = ordered[existing.file].state.records[existing.record]
                    if record.shouldReplace(current) { winners[key] = (fileIndex, recordIndex) }
                } else {
                    winners[key] = (fileIndex, recordIndex)
                }
            }
        }

        let names = AgentProjectNames()
        var result = AgentArtifactResult()
        var perFile: [Int: [AgentUsageEvent]] = [:]
        func emit(_ location: (file: Int, record: Int), id: String) {
            let file = ordered[location.file]
            let record = file.state.records[location.record]
            guard record.timestamp >= cutoff else { return }
            let projectPath = file.state.cwd
            let event = AgentUsageFactory.event(
                id: id,
                agent: .claude,
                sessionID: record.sessionID.isEmpty ? Self.sessionID(for: file) : record.sessionID,
                projectPath: projectPath,
                projectName: names.name(for: projectPath),
                model: record.model,
                observedAt: record.timestamp,
                usage: record.usage,
                reportedCost: record.reportedCost,
                fast: record.fast,
                sourcePath: file.path
            )
            perFile[location.file, default: []].append(event)
            result.usageEvents.append(event)
        }
        for (key, location) in winners { emit(location, id: "claude|\(key)") }
        for location in keyless {
            let file = ordered[location.file]
            emit(location, id: "claude|\(file.path)|\(file.state.records[location.record].lineIndex)")
        }

        let groups = Dictionary(grouping: ordered.indices.filter { ordered[$0].state.sawConversation }) { sessionID(for: ordered[$0]) }
        for (sessionID, indices) in groups {
            // The main transcript describes the session; subagent files only add usage.
            let primaryIndex = indices.filter { ordered[$0].state.sawMainThread }.max { ordered[$0].modifiedAt < ordered[$1].modifiedAt }
                ?? indices.max { ordered[$0].modifiedAt < ordered[$1].modifiedAt }!
            let primary = ordered[primaryIndex]
            let events = indices.flatMap { perFile[$0] ?? [] }
            let lastActivity = indices.map { ordered[$0].modifiedAt }.max() ?? primary.modifiedAt
            guard lastActivity >= cutoff else { continue }
            let state = primary.state
            let projectPath = state.cwd
            let projectName = names.name(for: projectPath)
            let title = [state.customTitle, state.aiTitle, state.summaryTitle, state.firstPrompt].first { !$0.isEmpty } ?? projectName
            var session = AgentSession(
                id: "claude|session|\(sessionID)",
                agent: .claude,
                sessionID: sessionID,
                title: title,
                process: nil,
                projectPath: projectPath,
                projectName: projectName,
                model: state.model.isEmpty ? state.sidechainModel : state.model,
                account: "",
                branch: state.branch,
                state: activityState(tail: state.tail, modifiedAt: primary.modifiedAt, now: now),
                startedAt: indices.compactMap { ordered[$0].state.startedAt }.min() ?? primary.modifiedAt,
                updatedAt: max(state.updatedAt ?? primary.modifiedAt, lastActivity),
                sourcePath: primary.path,
                sourceKind: .transcript,
                usage: nil,
                cost: nil,
                requests: nil,
                contextTokens: state.contextTokens
            )
            AgentUsageFactory.apply(events, to: &session)
            result.sessions.append(session)
        }
        return result
    }

    private static func sessionID(for file: (path: String, modifiedAt: Date, state: ClaudeFileState)) -> String {
        file.state.sessionID.isEmpty ? URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent : file.state.sessionID
    }

    /// Recent-activity heuristic from the transcript tail. Old sessions are idle regardless of how they ended.
    static func activityState(tail: ClaudeTail, modifiedAt: Date, now: Date) -> AgentActivityState {
        let age = now.timeIntervalSince(modifiedAt)
        let recent: TimeInterval = 30 * 60
        switch tail {
        case .assistantEndTurn:
            return .idle
        case .error:
            return age < recent ? .failed : .idle
        case .assistantToolUse:
            if age < 8 { return .toolUse }
            return age < recent ? .needsInput : .idle
        case .assistantStreaming, .toolResult, .userPrompt:
            if age < 10 { return .working }
            return age < 120 ? .thinking : .idle
        case .none:
            return age < 10 ? .working : .idle
        }
    }
}
