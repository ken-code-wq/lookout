import Foundation

/// Where a session's state came from: read off its transcript, or reported by the agent itself through a hook.
public enum AgentStateSource: String, Codable, Sendable {
    case inferred
    case hook
}

/// A state an agent reported through a hook (see LocalObserverHooks), laid over the running session it belongs to.
public struct AgentHookState: Hashable, Sendable {
    public var state: AgentActivityState
    public var at: Date
    /// Held regardless of the transcript, for a permission request that's still waiting on an answer.
    public var pinned: Bool

    public init(state: AgentActivityState, at: Date, pinned: Bool = false) {
        self.state = state
        self.at = at
        self.pinned = pinned
    }
}

public enum AgentHookOverlay {
    /// Transcripts are written a moment before the hook fires for the same moment; this much slack keeps the hook's word.
    static let slack: TimeInterval = 3

    /// Sessions with hook states applied, keyed by `AgentSession.id`. A hook state wins unless the transcript has
    /// moved on since (the user answered in the terminal, say), in which case inference is the fresher source.
    public static func apply(_ states: [String: AgentHookState], to sessions: [AgentSession]) -> [AgentSession] {
        guard !states.isEmpty else { return sessions }
        return sessions.map { session in
            guard let hook = states[session.id], hook.pinned || hook.at >= session.updatedAt.addingTimeInterval(-slack) else {
                return session
            }
            var updated = session
            updated.state = hook.state
            updated.stateSource = .hook
            if hook.at > updated.updatedAt { updated.updatedAt = hook.at }
            return updated
        }
    }

    /// The running session a hook event came from. The helper's parent processes name it exactly; failing that,
    /// the agent's own session id, then the newest session of that agent in the same folder.
    public static func match(agent: AgentKind, pids: [Int32], sessionID: String, cwd: String,
                             in sessions: [AgentSession]) -> AgentSession? {
        let own = sessions.filter { $0.agent == agent && $0.process != nil }
        if let byPID = own.first(where: { pids.contains($0.process!.pid) }) { return byPID }
        if !sessionID.isEmpty, let bySession = own.first(where: { $0.sessionID == sessionID }) { return bySession }
        guard !cwd.isEmpty else { return nil }
        return own.filter { $0.projectPath == cwd }.max { $0.updatedAt < $1.updatedAt }
    }
}
