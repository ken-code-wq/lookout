import Foundation
import LocalObserverCore

/// Fixture checks for transcript parsing, de-duplication, and pricing.
enum ParsingChecks {
    @MainActor
    static func run() {
        checkPricing()
        checkClaude()
        checkCodex()
        checkQoder()
        print("Lookout parsing checks passed")
    }

    private static func close(_ lhs: Double?, _ rhs: Double, _ message: String) {
        guard let lhs else { preconditionFailure("\(message): value was nil") }
        precondition(abs(lhs - rhs) < 1e-9, "\(message): expected \(rhs), got \(lhs)")
    }

    private static func checkPricing() {
        precondition(AgentPricing.price(model: "claude-opus-5-5[1m]")?.input == 4, "Variant suffix not stripped")
        precondition(AgentPricing.price(model: "anthropic/claude-haiku-4.5")?.input == 1, "Provider prefix / dotted version not normalized")
        precondition(AgentPricing.price(model: "claude-haiku-4-5-20251001")?.output == 5, "Date suffix not stripped")
        precondition(AgentPricing.price(model: "claude-4-sonnet-20250514")?.input == 3, "Legacy Claude naming not normalized")
        precondition(AgentPricing.price(model: "gpt-5.5-codex")?.input == 5, "Unknown variant did not fall back to its base model")
        precondition(AgentPricing.price(model: "claude-opus-9-1")?.input == 5, "Claude family fallback missing")
        precondition(AgentPricing.price(model: "<synthetic>") == nil, "Synthetic messages must be unpriced")
        precondition(AgentPricing.price(model: "mystery-model") == nil, "Unknown models must be unpriced")
        precondition(AgentPricing.price(model: "opencode/deepseek-v4-flash-free")?.input == 0, "Free models must price at zero")
        precondition(AgentPricing.price(model: "gpt-5.2")?.cacheWrite == 1.75, "Missing cache-write rate must fall back to input")

        let usage = TokenUsage(uncachedInputTokens: 10, cachedInputTokens: 1_000, cacheCreationTokens: 200, outputTokens: 50)
        // (10×4 + 1000×0.2 + 200×5 + 50×20) / 1M
        close(AgentPricing.cost(usage: usage, model: "claude-opus-5-5"), 0.00224, "Claude cost formula")
        close(AgentPricing.cost(usage: usage, model: "claude-opus-5-5", fast: true), 0.00448, "Fast-mode multiplier")
        close(AgentPricing.cacheSavings(usage: usage, model: "claude-opus-5-5"), 0.0038, "Cache savings formula")
        // Codex-style usage with inclusive input: uncached derives as 1000 − 400.
        let inclusive = TokenUsage(inputTokens: 1_000, cachedInputTokens: 400, outputTokens: 100)
        close(AgentPricing.cost(usage: inclusive, model: "gpt-5.5"), (600 * 5 + 400 * 0.5 + 100 * 30) / 1_000_000, "Inclusive input pricing")
        precondition(AgentPricing.cost(usage: usage, model: "mystery-model") == nil, "Unpriced cost must be nil")
    }

    private static func claudeLine(
        message: String,
        request: String,
        output: Int,
        model: String = "claude-opus-5-5",
        speed: String = "standard",
        stop: String = "tool_use",
        extra: String = "",
        sidechain: Bool = false,
        second: Int = 1
    ) -> String {
        """
        {"type":"assistant","sessionId":"s-1","cwd":"/tmp/fixture-project","gitBranch":"main","isSidechain":\(sidechain),"timestamp":"2026-09-20T10:00:0\(second).000Z","requestId":"\(request)"\(extra),"message":{"id":"\(message)","model":"\(model)","stop_reason":"\(stop)","content":[],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens":\(output),"speed":"\(speed)"}}}
        """
    }

    private static func checkClaude() {
        let now = AgentJSON_date("2026-09-20T10:30:00Z")
        let prompt = #"{"type":"user","sessionId":"s-1","cwd":"/tmp/fixture-project","gitBranch":"main","isSidechain":false,"timestamp":"2026-09-20T10:00:00.000Z","message":{"role":"user","content":"Fix the   login\nbug please"}}"#
        let meta = #"{"type":"user","isMeta":true,"sessionId":"s-1","timestamp":"2026-09-20T09:59:59.000Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#
        let main = [
            meta,
            prompt,
            // One API response split over three lines, each repeating usage; the first is a partial stream.
            claudeLine(message: "msg_1", request: "req_1", output: 5),
            claudeLine(message: "msg_1", request: "req_1", output: 50),
            claudeLine(message: "msg_1", request: "req_1", output: 50),
            #"{"type":"user","sessionId":"s-1","isSidechain":false,"timestamp":"2026-09-20T10:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
            claudeLine(message: "msg_2", request: "req_2", output: 100, speed: "fast", stop: "end_turn", second: 3),
            claudeLine(message: "msg_3", request: "req_3", output: 1, stop: "end_turn", extra: #","costUSD":0.5"#, second: 4),
            claudeLine(message: "msg_4", request: "req_4", output: 1, model: "<synthetic>", stop: "end_turn", second: 5),
            #"{"type":"custom-title","customTitle":"Login bug","sessionId":"s-1"}"#
        ].joined(separator: "\n")
        // A resumed session copies msg_1 forward into a new file; a subagent file shares the session id.
        let resumed = [claudeLine(message: "msg_1", request: "req_1", output: 50)].joined(separator: "\n")
        let subagent = claudeLine(message: "msg_9", request: "req_9", output: 7, model: "claude-haiku-4-5-20251001", stop: "end_turn", sidechain: true)

        let parsed = AgentParsingSeams.parseClaude([
            .init(path: "/tmp/p/s-1.jsonl", modifiedAt: now.addingTimeInterval(-600), contents: main),
            .init(path: "/tmp/p/s-2.jsonl", modifiedAt: now.addingTimeInterval(-300), contents: resumed),
            .init(path: "/tmp/p/s-1/subagents/agent-a.jsonl", modifiedAt: now.addingTimeInterval(-500), contents: subagent)
        ], now: now)

        let events = Dictionary(uniqueKeysWithValues: parsed.usageEvents.map { ($0.id, $0) })
        precondition(events.count == 4, "Duplicate Claude usage lines must count once (got \(events.count) events)")
        guard let first = events["claude|msg_1|req_1"] else { preconditionFailure("Stable Claude event id missing") }
        precondition(first.usage.processedTokens == 1_260, "Most complete duplicate must win (got \(first.usage.processedTokens ?? -1))")
        precondition(first.usage.inputTokens == nil && first.usage.derivedUncachedInputTokens == 10, "Claude input must map to uncached input")
        precondition(first.sourcePath == "/tmp/p/s-1.jsonl", "Original transcript must own a copied message")
        close(first.cost, 0.00224, "Estimated Claude cost")
        precondition(first.costIsEstimated, "Estimated cost must be flagged")
        close(first.cacheSavings, 0.0038, "Claude cache savings")
        close(events["claude|msg_2|req_2"]?.cost, (10 * 4 + 1_000 * 0.2 + 200 * 5 + 100 * 20) / 1_000_000 * 2, "Fast-mode Claude cost")
        close(events["claude|msg_3|req_3"]?.cost, 0.5, "Reported costUSD must be used")
        precondition(events["claude|msg_3|req_3"]?.costIsEstimated == false, "Reported cost must not be flagged as estimated")
        precondition(events["claude|msg_9|req_9"] != nil, "Sidechain usage must be counted")

        precondition(parsed.sessions.count == 2, "Sessions must fold by sessionId (got \(parsed.sessions.count))")
        guard let session = parsed.sessions.first(where: { $0.sourcePath == "/tmp/p/s-1.jsonl" }) else {
            preconditionFailure("Main Claude session missing")
        }
        precondition(session.title == "Login bug", "Custom title must win (got \(session.title))")
        precondition(session.model == "claude-opus-5-5", "Synthetic model must not replace the session model")
        precondition(session.branch == "main" && session.projectPath == "/tmp/fixture-project", "Branch/cwd not recorded")
        precondition(session.requests == 4, "Session must include its subagent's request (got \(session.requests ?? -1))")
        precondition(session.contextTokens == 1_210, "Context tokens must come from the last main-thread request")
        precondition(session.state == .idle, "end_turn tail must read as idle")

        let untitled = AgentParsingSeams.parseClaude([
            .init(path: "/tmp/q/x.jsonl", modifiedAt: now.addingTimeInterval(-60), contents: [meta, prompt, claudeLine(message: "m", request: "r", output: 1)].joined(separator: "\n"))
        ], now: now)
        precondition(untitled.sessions.first?.title == "Fix the login bug please", "First prompt title fallback failed (got \(untitled.sessions.first?.title ?? "nil"))")
        precondition(untitled.sessions.first?.state == .needsInput, "Pending tool_use on a quiet file must read as needs input")
    }

    private static func checkCodex() {
        let base = AgentJSON_date("2026-09-20T10:00:00Z")
        let now = base.addingTimeInterval(120)
        let weeklyReset = Int(base.timeIntervalSince1970) + 86_400
        let tokenCount = #"{"timestamp":"2026-09-20T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50,"reasoning_output_tokens":20,"total_tokens":1050}},"rate_limits":null}}"#
        let rollout = [
            #"{"timestamp":"2026-09-20T10:00:00.000Z","type":"session_meta","payload":{"id":"codex-1","cwd":"/tmp/codex-project","git":{"branch":"feature"}}}"#,
            #"{"timestamp":"2026-09-20T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":42.0,"window_minutes":300,"resets_in_seconds":3600},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":\#(weeklyReset)},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-09-20T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
            #"{"timestamp":"2026-09-20T10:00:02.500Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a settings page"}]}}"#,
            #"{"timestamp":"2026-09-20T10:00:03.000Z","type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/tmp/codex-project"}}"#,
            tokenCount,
            tokenCount,
            #"{"timestamp":"2026-09-20T10:00:09.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2000,"cached_input_tokens":1500,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":2010}}}}"#,
            #"{"timestamp":"2026-09-20T10:00:10.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#
        ].joined(separator: "\n")
        let fork = [
            #"{"timestamp":"2026-09-20T10:01:00.000Z","type":"session_meta","payload":{"id":"codex-2","forked_from_id":"codex-1","cwd":"/tmp/codex-project"}}"#,
            #"{"timestamp":"2026-09-20T10:01:00.010Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-09-20T10:01:00.020Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50,"total_tokens":1050}}}}"#,
            #"{"timestamp":"2026-09-20T10:01:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":0,"output_tokens":30,"total_tokens":330}}}}"#
        ].joined(separator: "\n")

        let parsed = AgentParsingSeams.parseCodex([
            .init(path: "/tmp/codex/rollout-1.jsonl", modifiedAt: base.addingTimeInterval(10), contents: rollout),
            .init(path: "/tmp/codex/rollout-2.jsonl", modifiedAt: base.addingTimeInterval(70), contents: fork)
        ], now: now)

        let own = parsed.usageEvents.filter { $0.sessionID == "codex-1" }.sorted { $0.observedAt < $1.observedAt }
        precondition(own.count == 2, "Repeated token_count must be skipped (got \(own.count))")
        precondition(own[0].usage.derivedUncachedInputTokens == 600, "Codex cached input must be subtracted from input")
        precondition(own[0].usage.processedTokens == 1_050, "Codex processed tokens (got \(own[0].usage.processedTokens ?? -1))")
        precondition(own[0].usage.reasoningTokens == 20, "Codex reasoning tokens")
        precondition(own[0].id == "codex|codex-1|5", "Codex event id must be session + line")
        close(own[0].cost, (600 * 5 + 400 * 0.5 + 50 * 30) / 1_000_000, "Codex estimated cost")
        let forked = parsed.usageEvents.filter { $0.sessionID == "codex-2" }
        precondition(forked.count == 1 && forked[0].usage.processedTokens == 330, "Forked rollout's copied history must be dropped")

        let session = parsed.sessions.first { $0.sessionID == "codex-1" }
        precondition(session?.title == "Add a settings page", "Codex title must skip injected context (got \(session?.title ?? "nil"))")
        precondition(session?.branch == "feature" && session?.model == "gpt-5.5", "Codex branch/model")
        precondition(session?.state == .idle, "task_complete must read as idle")

        let windows = Dictionary(uniqueKeysWithValues: parsed.quotaWindows.map { ($0.kind, $0) })
        precondition(parsed.quotaWindows.count == 2, "Codex rate_limits must yield two windows (got \(parsed.quotaWindows.count))")
        guard let session5h = windows[.session], let weekly = windows[.weekly] else { preconditionFailure("Codex window kinds") }
        precondition(session5h.usedPercent == 42 && session5h.windowDuration == 18_000, "Codex primary window")
        precondition(session5h.resetsAt == base.addingTimeInterval(3_601), "resets_in_seconds must be relative to the event")
        precondition(weekly.usedPercent == 10 && weekly.resetsAt == Date(timeIntervalSince1970: TimeInterval(weeklyReset)), "Codex secondary window")
        precondition(session5h.source == "Codex session log", "Codex window source")
    }

    /// Qoder zeroes its usage fields; tokens come from content. A response split across lines is one request,
    /// its input is the system prompt plus the conversation before it, and subagent files fold into the parent.
    static func checkQoder() {
        let now = AgentJSON_date("2026-09-30T12:00:00Z")
        let zero = #""usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}"#
        let prompt = String(repeating: "a", count: 3_200)
        let main = [
            #"{"type":"user","sessionId":"s1","cwd":"/p/app","timestamp":"2026-09-30T11:00:00Z","message":{"role":"user","content":"\#(prompt)"}}"#,
            #"{"type":"assistant","sessionId":"s1","timestamp":"2026-09-30T11:00:01Z","message":{"id":"m1","model":"qfmodel","content":[{"type":"text","text":"\#(String(repeating: "b", count: 320))"}],\#(zero)}}"#,
            #"{"type":"assistant","sessionId":"s1","timestamp":"2026-09-30T11:00:02Z","message":{"id":"m1","model":"qfmodel","stop_reason":"end_turn","content":[{"type":"text","text":"\#(String(repeating: "c", count: 320))"}],\#(zero)}}"#,
        ].joined(separator: "\n")
        let sub = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-09-30T11:00:03Z","message":{"id":"m2","model":"qfmodel","content":"hi",\#(zero)}}"#
        let parsed = AgentParsingSeams.parseQoder([
            .init(path: "/q/p/s1.jsonl", modifiedAt: now, contents: main),
            .init(path: "/q/p/s1/subagents/agent-x.jsonl", modifiedAt: now, contents: sub),
        ], now: now)
        precondition(parsed.sessions.count == 1, "Qoder subagents fold into their session (got \(parsed.sessions.count))")
        precondition(parsed.usageEvents.count == 2, "Qoder: one event per response id")
        guard let first = parsed.usageEvents.first(where: { $0.id.hasSuffix("|m1") }) else { preconditionFailure("Qoder m1 event") }
        // Prompt text 3,200 bytes plus the "text"/"type" keys of nothing (plain string) → 1,000 tokens + 20k system prompt.
        precondition(first.usage.inputTokens == 21_000, "Qoder input estimate (got \(first.usage.inputTokens ?? -1))")
        // Two lines of 320 content bytes plus keys ("type","text" and the value "text") → 2 × (320 + 12) / 3.2.
        precondition(first.usage.outputTokens == 208, "Qoder output estimate (got \(first.usage.outputTokens ?? -1))")
        precondition(first.model == "Qwen3.8-Flash", "Qoder model display name")
        precondition(first.cost == nil, "Qoder bills in credits, not dollars")
        precondition((parsed.sessions[0].usage?.processedTokens ?? 0) > 21_000, "Qoder session totals")
    }

    private static func AgentJSON_date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: string) else { preconditionFailure("Bad fixture date \(string)") }
        return date
    }
}
