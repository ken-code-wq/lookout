import Foundation
import LocalObserverCore

/// Session replay: tool calls pair with their results, edits become diffs, refused edits and plumbing are dropped.
enum ReplayChecks {
    static func run() {
        if let path = ProcessInfo.processInfo.environment["REPLAY_PROBE"] { probe(path) }
        checkClaude()
        checkDiff()
    }

    /// `REPLAY_PROBE=/path/to/transcript.jsonl`: what a replay of a real session contains.
    private static func probe(_ path: String) {
        let agent: AgentKind = path.contains("/.codex/") ? .codex : .claude
        let start = Date()
        guard let replay = SessionReplayReader.read(agent: agent, path: path) else { print("unreadable"); return }
        print("\(replay.events.count) events in \(Int(Date().timeIntervalSince(start) * 1000)) ms, \(replay.files.count) files, \(replay.commandCount) commands (\(replay.failedCommands) failed), +\(replay.totals.added) −\(replay.totals.removed)")
        for f in replay.files.prefix(5) { print("  \(f.path) +\(f.added) −\(f.removed) ×\(f.edits)") }
    }

    private static func checkClaude() {
        let lines = [
            #"{"type":"user","timestamp":"2026-10-06T10:00:00.000Z","message":{"role":"user","content":"Fix the header"}}"#,
            #"{"type":"user","timestamp":"2026-10-06T10:00:00.100Z","message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-06T10:00:02.000Z","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","timestamp":"2026-10-06T10:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt","is_error":false}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-06T10:00:04.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/p/a.swift","old_string":"a\nb\nc","new_string":"a\nB\nc"}}]}}"#,
            #"{"type":"user","timestamp":"2026-10-06T10:00:05.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-06T10:00:06.000Z","message":{"content":[{"type":"tool_use","id":"t3","name":"Edit","input":{"file_path":"/p/b.swift","old_string":"x","new_string":"y"}}]}}"#,
            #"{"type":"user","timestamp":"2026-10-06T10:00:07.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"String not found","is_error":true}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-06T10:00:08.000Z","message":{"content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"swift build"}}]}}"#,
            #"{"type":"user","timestamp":"2026-10-06T10:00:09.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t4","content":[{"type":"text","text":"error: boom"}],"is_error":true}]}}"#,
        ]
        let path = NSTemporaryDirectory() + "replay-check-\(UUID().uuidString).jsonl"
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let replay = SessionReplayReader.read(agent: .claude, path: path) else { preconditionFailure("Replay read") }
        let kinds = replay.events.map { e -> String in
            switch e.kind {
            case .prompt: return "prompt"
            case .message: return "message"
            case .command(_, _, let failed): return failed ? "command!" : "command"
            case .edit: return "edit"
            case .tool: return "tool"
            default: return "other"
            }
        }
        precondition(kinds == ["prompt", "message", "command", "edit", "tool", "command!"], "Replay kinds: \(kinds)")
        if case .command(_, let out, _) = replay.events[2].kind { precondition(out == "a.txt", "Command output paired") }
        if case .command(_, let out, true) = replay.events[5].kind { precondition(out == "error: boom", "Failed output") }
        precondition(replay.files.map(\.path) == ["/p/a.swift"], "Refused edits don't count as changes")
        precondition(replay.files.first?.added == 1 && replay.files.first?.removed == 1, "Edit trimmed to what changed")
        precondition(replay.end!.timeIntervalSince(replay.start!) == 8, "Duration from the first to the last step")
        precondition(SessionReplayReader.supports(.codex) && !SessionReplayReader.supports(.antigravity), "Supported agents")
    }

    private static func checkDiff() {
        let d = ReplayDiff.replace("one\ntwo\nthree\nfour", "one\nTWO\nthree\nfour")
        precondition(ReplayDiff.counts(d) == (1, 1), "Shared lines trimmed: \(d)")
        precondition(d.contains(" one") && d.contains(" three"), "Context kept around the change")
        precondition(ReplayDiff.counts(ReplayDiff.created("a\nb")) == (2, 0), "New file is all additions")
    }
}
