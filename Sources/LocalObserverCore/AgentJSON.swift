import Foundation

enum AgentJSON {
    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func object(_ dictionary: [String: Any], _ keys: [String]) -> [String: Any]? {
        guard let value = value(dictionary, keys) else { return nil }
        return AgentJSON.object(value)
    }

    static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    static func value(_ object: [String: Any], _ keys: [String]) -> Any? {
        for key in keys {
            if let value = object[key], !(value is NSNull) { return value }
        }
        return nil
    }

    static func string(_ object: [String: Any], _ keys: [String]) -> String? {
        guard let value = value(object, keys) else { return nil }
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func int64(_ object: [String: Any], _ keys: [String]) -> Int64? {
        guard let value = value(object, keys) else { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func int(_ object: [String: Any], _ keys: [String]) -> Int? {
        int64(object, keys).map(Int.init)
    }

    static func double(_ object: [String: Any], _ keys: [String]) -> Double? {
        guard let value = value(object, keys) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func bool(_ object: [String: Any], _ keys: [String]) -> Bool? {
        guard let value = value(object, keys) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return nil
    }

    static func date(_ object: [String: Any], _ keys: [String]) -> Date? {
        guard let value = value(object, keys) else { return nil }
        return date(value)
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            if raw > 10_000_000_000 { return Date(timeIntervalSince1970: raw / 1000) }
            return Date(timeIntervalSince1970: raw)
        }
        guard let string = value as? String else { return nil }
        if let date = fastISODate(string) { return date }
        if let seconds = TimeInterval(string) { return Date(timeIntervalSince1970: seconds) }
        if let date = fractionalFormatter.date(from: string) { return date }
        return plainFormatter.date(from: string)
    }

    // ISO8601DateFormatter is thread-safe for parsing; building one per call dominated scan time.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fff…](Z|±HH:MM)` without a formatter. Nil for anything else.
    static func fastISODate(_ string: String) -> Date? {
        let utf8 = Array(string.utf8)
        guard utf8.count >= 20 else { return nil }
        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for index in start..<(start + count) {
                let byte = utf8[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard utf8[4] == 45, utf8[7] == 45, utf8[10] == 84 || utf8[10] == 32, utf8[13] == 58, utf8[16] == 58,
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var index = 19
        var fraction = 0.0
        if index < utf8.count, utf8[index] == 46 {
            index += 1
            var scale = 0.1
            while index < utf8.count, utf8[index] >= 48, utf8[index] <= 57 {
                fraction += Double(utf8[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offset = 0
        if index < utf8.count, utf8[index] == 90 {
            index += 1
        } else if index + 6 <= utf8.count, utf8[index] == 43 || utf8[index] == 45, utf8[index + 3] == 58,
                  let hours = digits(index + 1, 2), let minutes = digits(index + 4, 2) {
            offset = (hours * 3600 + minutes * 60) * (utf8[index] == 45 ? -1 : 1)
            index += 6
        } else {
            return nil
        }
        guard index == utf8.count else { return nil }
        // Days from civil (Howard Hinnant), valid for the proleptic Gregorian calendar.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Walks a nested path of dictionary keys.
    static func path(_ object: [String: Any], _ keys: [String]) -> Any? {
        var value: Any? = object
        for key in keys {
            guard let dictionary = value as? [String: Any], let next = dictionary[key], !(next is NSNull) else { return nil }
            value = next
        }
        return value
    }

    static func parseObject(_ bytes: UnsafeRawBufferPointer) -> [String: Any]? {
        guard !bytes.isEmpty, let base = bytes.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func parseObject(_ string: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
    }

    /// Byte-level substring test, used to skip lines before paying for `JSONSerialization`.
    static func contains(_ bytes: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = bytes.baseAddress, bytes.count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base, bytes.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    static func tokenUsage(_ value: Any?) -> TokenUsage? {
        guard let object = AgentJSON.object(value) else { return nil }
        let total = int64(object, ["total_tokens", "totalTokens", "total"])
        let output = int64(object, ["output_tokens", "outputTokens", "output", "completion_tokens"])
        let reasoning = int64(object, ["reasoning_output_tokens", "reasoningTokens", "reasoning_output"])
        let cacheObject = AgentJSON.object(object, ["cache"])
        let cached = int64(object, [
            "cache_read_input_tokens", "cacheReadInputTokens", "cache_read_tokens", "cacheRead", "cached_input_tokens", "cachedInputTokens"
        ]) ?? cacheObject.flatMap { int64($0, ["read"]) }
        let cacheCreation = int64(object, [
            "cache_creation_input_tokens", "cacheCreationInputTokens", "cache_creation_tokens", "cacheWrite", "cache_write_tokens"
        ]) ?? cacheObject.flatMap { int64($0, ["write"]) }
        let explicitUncached = int64(object, ["uncached_input_tokens", "uncachedInputTokens"])
        let inputField = int64(object, ["input_tokens", "inputTokens"])
        let genericInput = int64(object, ["input"])
        let hasCache = cached != nil || cacheCreation != nil
        var input = inputField
        var uncached = explicitUncached
        if input == nil {
            if let genericInput {
                if hasCache {
                    uncached = uncached ?? genericInput
                } else {
                    input = genericInput
                }
            }
        }
        let usage = TokenUsage(
            inputTokens: input,
            uncachedInputTokens: uncached,
            cachedInputTokens: cached,
            cacheCreationTokens: cacheCreation,
            outputTokens: output,
            reasoningTokens: reasoning,
            reportedTotalTokens: total
        )
        return usage.isEmpty ? nil : usage.normalized()
    }

    static func firstTokenUsage(_ object: [String: Any]) -> TokenUsage? {
        let paths: [[String]] = [
            ["payload", "info", "last_token_usage"],
            ["info", "last_token_usage"],
            ["payload", "usage"],
            ["message", "usage"],
            ["message", "tokens"],
            ["response", "usage"],
            ["assistant", "usage"],
            ["data", "usage"],
            ["usage"],
            ["tokens"],
            ["token_usage"]
        ]
        for path in paths {
            var value: Any? = object
            for key in path {
                guard let dictionary = AgentJSON.object(value), let next = dictionary[key] else {
                    value = nil
                    break
                }
                value = next
            }
            if let usage = tokenUsage(value) { return usage }
        }
        return tokenUsage(object)
    }

    static func cost(_ object: [String: Any]) -> Double? {
        if let value = double(object, ["costUSD", "cost_usd", "total_cost_usd", "totalCostUsd", "total_cost"]) { return value }
        if let number = object["cost"] as? NSNumber { return number.doubleValue }
        if let dictionary = AgentJSON.object(object, ["cost"]) {
            if let value = double(dictionary, ["total", "total_cost_usd", "totalCostUsd", "usd"]) { return value }
        }
        if let payload = AgentJSON.object(object, ["payload"]) {
            return cost(payload)
        }
        return nil
    }

    static func model(_ object: [String: Any]) -> String? {
        if let value = string(object, ["model", "model_name", "modelName"]) { return value }
        if let dictionary = AgentJSON.object(object, ["model"]) {
            if let value = string(dictionary, ["display_name", "displayName", "id", "modelID", "model_id"]) { return value }
        }
        if let value = string(object, ["modelID", "model_id"]) { return value }
        if let payload = AgentJSON.object(object, ["payload"]) { return model(payload) }
        return nil
    }

    static func sessionID(_ object: [String: Any], fallback: String) -> String {
        if let value = string(object, ["sessionId", "session_id", "conversation_id", "conversationId", "thread_id", "threadId"]) {
            return value
        }
        return fallback
    }

    static func projectPath(_ object: [String: Any]) -> String? {
        if let value = string(object, ["cwd", "projectPath", "project_path", "workingDirectory", "working_directory", "directory"]) {
            return value
        }
        if let workspace = AgentJSON.object(object, ["workspace"]) {
            if let value = string(workspace, ["project_dir", "projectDir", "current_dir", "currentDir"]) { return value }
        }
        if let payload = AgentJSON.object(object, ["payload"]) { return projectPath(payload) }
        return nil
    }

    static func title(_ object: [String: Any]) -> String? {
        if let value = string(object, ["session_name", "sessionName", "title", "name", "conversation_name", "conversationName"]) {
            return value
        }
        if let payload = AgentJSON.object(object, ["payload"]) { return title(payload) }
        return nil
    }

    static func branch(_ object: [String: Any]) -> String? {
        if let value = string(object, ["branch", "git_branch", "gitBranch"]) { return value }
        if let vcs = AgentJSON.object(object, ["vcs"]) { return string(vcs, ["branch"]) }
        if let payload = AgentJSON.object(object, ["payload"]) { return branch(payload) }
        return nil
    }

    static func account(_ object: [String: Any]) -> String? {
        string(object, ["account", "account_id", "accountId", "plan_tier", "planType"])
    }

    static func activityState(_ object: [String: Any]) -> AgentActivityState? {
        if let value = string(object, ["agent_state", "agentState", "status", "state"]) {
            switch value.lowercased() {
            case "working", "busy", "running", "tool_use": return value.lowercased() == "tool_use" ? .toolUse : .working
            case "thinking", "reasoning": return .thinking
            case "needs_input", "permission", "approval", "question", "confirmation": return .needsInput
            case "waiting", "blocked": return .waiting
            case "idle", "completed", "complete": return .idle
            case "failed", "error", "aborted": return .failed
            default: break
            }
        }
        if bool(object, ["tool_confirmation_pending", "toolConfirmationPending"]) == true { return .needsInput }
        let descriptor = [string(object, ["type"]), string(object, ["event"]), string(object, ["event_type"])]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if descriptor.contains("permission") || descriptor.contains("approval") || descriptor.contains("question") { return .needsInput }
        if descriptor.contains("error") || descriptor.contains("failed") { return .failed }
        if descriptor.contains("completed") || descriptor.contains("finish") { return .idle }
        return nil
    }
}
