import Foundation

/// Public entry points into the transcript parsers, for the verification target (which
/// imports LocalObserverCore without `@testable`) and for diagnostics.
public enum AgentParsingSeams {
    public struct Transcript: Sendable {
        public var path: String
        public var modifiedAt: Date
        public var contents: String

        public init(path: String, modifiedAt: Date, contents: String) {
            self.path = path
            self.modifiedAt = modifiedAt
            self.contents = contents
        }
    }

    public struct Parsed: Sendable {
        public var sessions: [AgentSession]
        public var usageEvents: [AgentUsageEvent]
        public var quotaWindows: [AgentQuotaWindow]
        public var warnings: [String]
    }

    /// Parses in-memory Claude Code transcripts, with the same global de-duplication as a scan.
    public static func parseClaude(_ transcripts: [Transcript], now: Date, historyDays: Int = 90) -> Parsed {
        let states = transcripts.map { ($0.path, $0.modifiedAt, feed($0.contents, into: ClaudeFileState())) }
        return parsed(AgentClaudeReader.aggregate(states, cutoff: now.addingTimeInterval(-Double(historyDays) * 86_400), now: now))
    }

    /// Parses in-memory Codex rollouts.
    public static func parseCodex(_ transcripts: [Transcript], now: Date, historyDays: Int = 90) -> Parsed {
        let states = transcripts.map { ($0.path, $0.modifiedAt, feed($0.contents, into: CodexFileState())) }
        return parsed(AgentCodexReader.aggregate(states, cutoff: now.addingTimeInterval(-Double(historyDays) * 86_400), now: now))
    }

    /// Runs the real local reader for one agent (no process discovery, no network).
    public static func readLocal(agent: AgentKind, historyDays: Int) async -> Parsed {
        if agent == .openCode {
            let result = await AgentProviderClients.readOpenCode(enabledAgents: [.openCode], historyDays: historyDays) ?? AgentArtifactResult()
            return parsed(result)
        }
        return parsed(await AgentArtifactReader.read(agent: agent, historyDays: historyDays))
    }

    private static func parsed(_ result: AgentArtifactResult) -> Parsed {
        Parsed(sessions: result.sessions, usageEvents: result.usageEvents, quotaWindows: result.quotaWindows, warnings: result.warnings)
    }

    private static func feed<State: AgentLineScanState>(_ contents: String, into state: State) -> State {
        var state = state
        var data = Data(contents.utf8)
        if data.last != 0x0A { data.append(0x0A) }
        data.withUnsafeBytes { raw in
            var start = 0
            for index in 0..<raw.count where raw[index] == 0x0A {
                if index > start {
                    state.consume(line: UnsafeRawBufferPointer(rebasing: raw[start..<index]), index: state.lineIndex)
                }
                state.lineIndex += 1
                start = index + 1
            }
        }
        state.offset = UInt64(data.count)
        return state
    }
}
