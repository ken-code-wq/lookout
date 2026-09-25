import Foundation

struct CodexUsageRecord: Sendable {
    var lineIndex: Int
    var timestamp: Date
    var model: String
    var uncached: Int64
    var cached: Int64
    var cacheWrite: Int64
    var output: Int64
    var reasoning: Int64

    var usage: TokenUsage {
        TokenUsage(
            uncachedInputTokens: uncached,
            cachedInputTokens: cached,
            cacheCreationTokens: cacheWrite,
            outputTokens: output,
            reasoningTokens: reasoning
        )
    }
}

struct CodexRateWindow: Sendable, Hashable {
    var slot: String
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
}

struct CodexRateSnapshot: Sendable {
    var observedAt: Date
    var limitID: String
    var planType: String
    var windows: [CodexRateWindow]
}

enum CodexTail: Sendable {
    case none
    case taskStarted
    case taskComplete
    case approvalRequested
}

struct CodexFileState: AgentLineScanState {
    var offset: UInt64 = 0
    var lineIndex = 0
    var sessionID = ""
    var cwd = ""
    var branch = ""
    var model = ""
    var title = ""
    var startedAt: Date?
    var updatedAt: Date?
    var records: [CodexUsageRecord] = []
    var rateLimits: [String: CodexRateSnapshot] = [:]
    var tail = CodexTail.none
    var contextTokens: Int64?
    var sawSessionMeta = false
    /// While true, leading usage events are re-stamped copies of the parent's history.
    var suppressingForkCopies = false
    var forkCopyAnchor = Date.distantPast
    var lastUsageSignature: [Int64]?

    /// A forked rollout opens with the parent's history copied in one burst (gaps of 0–40 ms);
    /// the child's own first turn lands seconds later. One second splits them (T3 Code, ccusage).
    static let forkCopyMaxGap: TimeInterval = 1

    mutating func consume(line: UnsafeRawBufferPointer, index: Int) {
        let interesting = AgentJSON.contains(line, "\"token_count\"") || AgentJSON.contains(line, "\"turn_context\"") ||
            AgentJSON.contains(line, "\"session_meta\"") || AgentJSON.contains(line, "\"task_") ||
            AgentJSON.contains(line, "approval_request") || AgentJSON.contains(line, "\"user_message\"") ||
            (tail == .approvalRequested && AgentJSON.contains(line, "_begin\"")) ||
            (title.isEmpty && AgentJSON.contains(line, "\"role\":\"user\""))
        guard interesting, let object = AgentJSON.parseObject(line) else { return }
        let timestamp = AgentJSON.date(object, ["timestamp"])
        if let timestamp {
            startedAt = min(startedAt ?? timestamp, timestamp)
            updatedAt = max(updatedAt ?? timestamp, timestamp)
        }
        let type = AgentJSON.string(object, ["type"])
        guard let payload = AgentJSON.object(object, ["payload"]) else { return }
        let payloadType = AgentJSON.string(payload, ["type"])

        switch (type, payloadType) {
        case ("session_meta", _):
            // Only the first meta describes this file; a fork repeats its ancestors' metas after it.
            guard !sawSessionMeta else { return }
            sawSessionMeta = true
            if let id = AgentJSON.string(payload, ["id", "session_id"]) { sessionID = id }
            if let value = AgentJSON.string(payload, ["cwd"]) { cwd = value }
            if let git = AgentJSON.object(payload, ["git"]), let value = AgentJSON.string(git, ["branch"]) { branch = value }
            if let timestamp, Self.isFork(payload) {
                suppressingForkCopies = true
                forkCopyAnchor = timestamp
            }
        case ("turn_context", _):
            if let value = AgentJSON.string(payload, ["model"]) { model = value }
            if cwd.isEmpty, let value = AgentJSON.string(payload, ["cwd"]) { cwd = value }
        case ("event_msg", "token_count"):
            consumeTokenCount(payload, timestamp: timestamp, index: index)
        case ("event_msg", "task_started"):
            tail = .taskStarted
        case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
            tail = .taskComplete
        case ("event_msg", "user_message"):
            if title.isEmpty, let text = AgentJSON.string(payload, ["message"]) { adoptTitle(text) }
        case ("response_item", "message"):
            guard title.isEmpty, AgentJSON.string(payload, ["role"]) == "user" else { return }
            for block in AgentJSON.array(payload["content"]) {
                guard let block = AgentJSON.object(block), let text = AgentJSON.string(block, ["text"]) else { continue }
                adoptTitle(text)
                if !title.isEmpty { break }
            }
        default:
            if payloadType?.contains("approval_request") == true {
                tail = .approvalRequested
            } else if tail == .approvalRequested, payloadType?.hasSuffix("_begin") == true {
                // The request was answered and the command started.
                tail = .taskStarted
            }
        }
    }

    private mutating func adoptTitle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("# AGENTS.md") else { return }
        title = ClaudeText.titled(trimmed)
    }

    private static func isFork(_ payload: [String: Any]) -> Bool {
        if AgentJSON.string(payload, ["forked_from_id"]) != nil { return true }
        return AgentJSON.path(payload, ["source", "subagent", "thread_spawn", "parent_thread_id"]) is String
    }

    private mutating func consumeTokenCount(_ payload: [String: Any], timestamp: Date?, index: Int) {
        guard let timestamp else { return }
        if let limits = AgentJSON.object(payload, ["rate_limits"]) {
            consumeRateLimits(limits, observedAt: timestamp)
        }
        guard let last = AgentJSON.path(payload, ["info", "last_token_usage"]) as? [String: Any] else { return }
        // A token_count before any turn_context has no model; skipping it must not consume the
        // signature, or its re-emitted copy would be dropped as a duplicate.
        guard !model.isEmpty else { return }
        let input = max(0, AgentJSON.int64(last, ["input_tokens"]) ?? 0)
        let cached = max(0, AgentJSON.int64(last, ["cached_input_tokens"]) ?? 0)
        let cacheWrite = max(0, AgentJSON.int64(last, ["cache_write_input_tokens"]) ?? 0)
        let output = max(0, AgentJSON.int64(last, ["output_tokens"]) ?? 0)
        let reasoning = max(0, AgentJSON.int64(last, ["reasoning_output_tokens"]) ?? 0)
        let total = AgentJSON.int64(last, ["total_tokens"]) ?? 0
        // Codex re-emits an unchanged token_count on some stream boundaries.
        let signature = [input, cached, cacheWrite, output, reasoning, total]
        guard signature != lastUsageSignature else { return }
        lastUsageSignature = signature
        if suppressingForkCopies {
            if timestamp.timeIntervalSince(forkCopyAnchor) < Self.forkCopyMaxGap {
                forkCopyAnchor = timestamp
                return
            }
            suppressingForkCopies = false
        }
        // Codex reports input_tokens inclusive of the cached portion.
        let record = CodexUsageRecord(
            lineIndex: index,
            timestamp: timestamp,
            model: model,
            uncached: max(0, input - cached - cacheWrite),
            cached: cached,
            cacheWrite: cacheWrite,
            output: output,
            reasoning: min(output, reasoning)
        )
        guard record.uncached + cached + cacheWrite + output > 0 else { return }
        contextTokens = input
        records.append(record)
    }

    private mutating func consumeRateLimits(_ limits: [String: Any], observedAt: Date) {
        var windows: [CodexRateWindow] = []
        for slot in ["primary", "secondary"] {
            guard let window = AgentJSON.object(limits, [slot]),
                  let used = AgentJSON.double(window, ["used_percent", "usedPercent"]) else { continue }
            var resetsAt: Date?
            if let absolute = AgentJSON.double(window, ["resets_at", "resetsAt"]) {
                resetsAt = Date(timeIntervalSince1970: absolute > 10_000_000_000 ? absolute / 1000 : absolute)
            } else if let relative = AgentJSON.double(window, ["resets_in_seconds", "resetsInSeconds"]) {
                resetsAt = observedAt.addingTimeInterval(relative)
            }
            windows.append(CodexRateWindow(
                slot: slot,
                usedPercent: min(max(used, 0), 100),
                windowMinutes: AgentJSON.int(window, ["window_minutes", "windowDurationMins"]),
                resetsAt: resetsAt
            ))
        }
        guard !windows.isEmpty else { return }
        let limitID = AgentJSON.string(limits, ["limit_id"]) ?? "codex"
        rateLimits[limitID] = CodexRateSnapshot(
            observedAt: observedAt,
            limitID: limitID,
            planType: AgentJSON.string(limits, ["plan_type"]) ?? "",
            windows: windows
        )
    }
}

enum AgentCodexReader {
    static let cache = AgentFileCache<CodexFileState>()

    static func read(historyDays: Int, now: Date = Date()) -> AgentArtifactResult {
        let cutoff = now.addingTimeInterval(-Double(historyDays) * 86_400)
        let files = AgentFileScanner.files(in: AgentDiscovery.dataURLs(for: .codex), since: cutoff) {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
        }
        guard !files.isEmpty else { return AgentArtifactResult() }
        let outcome = AgentFileScanner.scan(files: files, cache: cache) { _ in CodexFileState() }
        var result = aggregate(outcome.states.map { ($0.file.url.path, $0.file.stamp.modifiedAt, $0.state) }, cutoff: cutoff, now: now)
        result.warnings.append(contentsOf: AgentArtifactReader.scanWarnings(agent: .codex, outcome: outcome))
        return result
    }

    static func aggregate(_ files: [(path: String, modifiedAt: Date, state: CodexFileState)], cutoff: Date, now: Date) -> AgentArtifactResult {
        let names = AgentProjectNames()
        var result = AgentArtifactResult()
        var newestLimits: [String: CodexRateSnapshot] = [:]
        for file in files {
            let state = file.state
            let sessionID = state.sessionID.isEmpty ? URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent : state.sessionID
            let projectName = names.name(for: state.cwd)
            let events = state.records.filter { $0.timestamp >= cutoff }.map { record in
                AgentUsageFactory.event(
                    id: "codex|\(sessionID)|\(record.lineIndex)",
                    agent: .codex,
                    sessionID: sessionID,
                    projectPath: state.cwd,
                    projectName: projectName,
                    model: record.model,
                    observedAt: record.timestamp,
                    usage: record.usage,
                    reportedCost: nil,
                    sourcePath: file.path
                )
            }
            result.usageEvents.append(contentsOf: events)
            for (limitID, snapshot) in state.rateLimits where snapshot.observedAt > (newestLimits[limitID]?.observedAt ?? .distantPast) {
                newestLimits[limitID] = snapshot
            }
            var session = AgentSession(
                id: "codex|session|\(sessionID)",
                agent: .codex,
                sessionID: sessionID,
                title: state.title.isEmpty ? projectName : state.title,
                process: nil,
                projectPath: state.cwd,
                projectName: projectName,
                model: state.model,
                account: "",
                branch: state.branch,
                state: activityState(tail: state.tail, modifiedAt: file.modifiedAt, now: now),
                startedAt: state.startedAt ?? file.modifiedAt,
                updatedAt: max(state.updatedAt ?? file.modifiedAt, file.modifiedAt),
                sourcePath: file.path,
                sourceKind: .transcript,
                usage: nil,
                cost: nil,
                requests: nil,
                contextTokens: state.contextTokens
            )
            AgentUsageFactory.apply(events, to: &session)
            result.sessions.append(session)
        }
        result.quotaWindows = newestLimits.values.flatMap { quotaWindows($0, now: now) }
        return result
    }

    static func quotaWindows(_ snapshot: CodexRateSnapshot, now: Date) -> [AgentQuotaWindow] {
        snapshot.windows.map { window in
            let kind = limitKind(minutes: window.windowMinutes, slot: window.slot)
            var label: String
            switch kind {
            case .session: label = window.windowMinutes.map { $0 % 60 == 0 ? "\($0 / 60)-hour" : "\($0)-minute" } ?? "Session"
            case .weekly: label = "Weekly"
            case .monthly: label = "Monthly"
            case .daily: label = "Daily"
            default: label = window.windowMinutes.map { "\($0)-minute" } ?? window.slot.capitalized
            }
            if snapshot.limitID != "codex" { label = "\(snapshot.limitID.capitalized) \(label.lowercased())" }
            var used = window.usedPercent
            var resetsAt = window.resetsAt
            var detail = snapshot.planType.isEmpty ? "" : "\(snapshot.planType.capitalized) plan"
            // The log predates a reset: the new window's usage is unknown but starts from zero.
            if let reset = resetsAt, reset <= now {
                used = 0
                resetsAt = nil
                detail = "Reset since the last Codex session"
            }
            return AgentQuotaWindow(
                id: "codex|log|\(snapshot.limitID)|\(window.slot)",
                agent: .codex,
                label: label,
                kind: kind,
                usedPercent: used,
                resetsAt: resetsAt,
                windowDuration: window.windowMinutes.map { TimeInterval($0 * 60) },
                detail: detail,
                observedAt: snapshot.observedAt,
                source: "Codex session log",
                account: ""
            )
        }
    }

    static func limitKind(minutes: Int?, slot: String) -> AgentLimitKind {
        guard let minutes else { return slot == "primary" ? .session : .weekly }
        switch minutes {
        case ..<(12 * 60): return .session
        case ..<(3 * 24 * 60): return .daily
        case ..<(14 * 24 * 60): return .weekly
        default: return .monthly
        }
    }

    static func activityState(tail: CodexTail, modifiedAt: Date, now: Date) -> AgentActivityState {
        let age = now.timeIntervalSince(modifiedAt)
        switch tail {
        case .taskComplete: return .idle
        case .approvalRequested: return age < 30 * 60 ? .needsInput : .idle
        case .taskStarted:
            if age < 10 { return .working }
            return age < 120 ? .thinking : .idle
        case .none: return age < 10 ? .working : .idle
        }
    }
}
