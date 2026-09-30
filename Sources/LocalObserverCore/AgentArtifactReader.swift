import Foundation

struct AgentArtifactResult: Sendable {
    var sessions: [AgentSession] = []
    var usageEvents: [AgentUsageEvent] = []
    var quotaWindows: [AgentQuotaWindow] = []
    var warnings: [String] = []
}

/// Reads each agent's on-disk history. Every reader is local and read-only; results for
/// unchanged files come from a process-lifetime cache, so a 30s refresh only parses new lines.
enum AgentArtifactReader {
    static func read(agent: AgentKind, historyDays: Int) async -> AgentArtifactResult {
        await AgentDiscovery.background {
            let now = Date()
            switch agent {
            case .claude: return AgentClaudeReader.read(historyDays: historyDays, now: now)
            case .codex: return AgentCodexReader.read(historyDays: historyDays, now: now)
            case .copilot: return AgentCopilotReader.read(historyDays: historyDays, now: now)
            case .pi: return AgentPiReader.read(historyDays: historyDays, now: now)
            case .qoder: return AgentQoderReader.read(historyDays: historyDays, now: now)
            case .antigravity: return AgentAntigravityReader.read(historyDays: historyDays, now: now)
            // Read by AgentProviderClients.readOpenCode, which owns the OpenCode source.
            case .openCode: return AgentArtifactResult()
            case .cursor:
                return AgentArtifactResult(warnings: ["Cursor keeps usage in its account dashboard, not in local files"])
            }
        }
    }

    static func scanWarnings<State>(agent: AgentKind, outcome: AgentFileScanner.Outcome<State>) -> [String] {
        var warnings: [String] = []
        if outcome.deferredFiles > 0 {
            warnings.append("\(agent.name) history is still indexing (\(outcome.deferredFiles) files left)")
        }
        if outcome.oversizedFiles > 0 {
            warnings.append("\(agent.name) skipped \(outcome.oversizedFiles) transcript files over 512 MB")
        }
        if outcome.unreadableFiles > 0 {
            warnings.append("\(agent.name) could not read \(outcome.unreadableFiles) transcript files")
        }
        return warnings
    }
}

enum AgentUsageFactory {
    /// Builds a usage event, preferring the agent's reported cost and otherwise estimating it.
    static func event(
        id: String,
        agent: AgentKind,
        sessionID: String,
        projectPath: String,
        projectName: String,
        model: String,
        observedAt: Date,
        usage: TokenUsage,
        reportedCost: Double?,
        fast: Bool = false,
        requests: Int = 1,
        sourcePath: String
    ) -> AgentUsageEvent {
        let reported = reportedCost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let cost = reported ?? AgentPricing.cost(usage: usage, model: model, fast: fast)
        return AgentUsageEvent(
            id: id,
            agent: agent,
            sessionID: sessionID,
            projectPath: projectPath,
            projectName: projectName,
            model: model,
            observedAt: observedAt,
            usage: usage,
            cost: cost,
            requests: requests,
            sourcePath: sourcePath,
            sourceKind: .transcript,
            costIsEstimated: reported == nil && cost != nil,
            cacheSavings: AgentPricing.cacheSavings(usage: usage, model: model, fast: fast)
        )
    }

    /// Totals a session's events onto it.
    static func apply(_ events: [AgentUsageEvent], to session: inout AgentSession) {
        guard !events.isEmpty else { return }
        session.usage = events.reduce(TokenUsage()) { $0.adding($1.usage) }
        let costs = events.compactMap(\.cost)
        session.cost = costs.isEmpty ? nil : costs.reduce(0, +)
        session.costIsEstimated = events.contains { $0.costIsEstimated }
        session.requests = events.compactMap(\.requests).reduce(0, +)
    }
}
