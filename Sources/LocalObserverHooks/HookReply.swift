import Foundation

/// Replies from Lookout delivered through Claude Code itself, whatever app hosts the session (a terminal, VS Code's
/// extension, an SDK-driven app like T3 Code).
///
/// When a turn ends, an `asyncRewake` Stop hook runs `lookout-hook claude --await-reply` in the background. It tells
/// the app "this session is awaiting a reply" and waits on the socket without blocking anything. Claude Code's docs:
/// "If `true`, runs in the background and wakes Claude on exit code 2. The hook's stderr, or stdout if stderr is empty,
/// is shown to Claude as a system reminder" and "When Claude is idle and an `asyncRewake` hook exits 2, Claude Code
/// treats the stderr as a reason to wake Claude … as if you had typed it. When the hook exits 0, Claude Code does
/// nothing; the session stays idle." (https://code.claude.com/docs/en/hooks#run-hooks-in-the-background)
///
/// So the app answers the waiter with `{"reply":"…"}` and the helper prints the message to stderr and exits 2; or the
/// app hangs up (the user typed in their own UI, the session ended, the wait ran out, the app quit) and the helper
/// exits 0 without a word.
public enum HookReply {
    /// The flag the waiter's hook entry passes to the helper.
    public static let awaitFlag = "--await-reply"
    /// The helper's exit code that wakes Claude.
    public static let wakeExitCode: Int32 = 2

    /// The line the app sends the waiter.
    public static func answer(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["reply": trimmed], options: [.sortedKeys])
    }

    /// What the helper does with what the app sent: the text for Claude and exit 2, or nothing and exit 0.
    public static func outcome(of line: Data?) -> (stderr: String?, exitCode: Int32) {
        guard let line, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let text = (object["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return (nil, 0)
        }
        return (message(text), wakeExitCode)
    }

    /// Worded so Claude treats it as the user's next prompt, not as feedback from a hook to argue with.
    public static func message(_ text: String) -> String {
        "The user sent you this message from Lookout (a reply to your last turn). Treat it as their next prompt and act on it:\n\n" + text
    }
}

/// The reply waiters the app is holding, keyed by Claude Code's `session_id`. Pure bookkeeping: whoever owns it
/// answers or hangs up on the handles it gives back.
public struct ReplyWaiters<Handle> {
    public struct Waiter {
        public let id: String
        public var sessionID: String
        public var since: Date
        public var handle: Handle
    }

    public private(set) var waiters: [String: Waiter] = [:]

    public init() {}

    public func has(_ sessionID: String) -> Bool { waiters[sessionID] != nil }

    /// A new waiter for a session replaces the one before it, which comes back to be released.
    public mutating func register(id: String, sessionID: String, handle: Handle, at: Date) -> Handle? {
        guard !sessionID.isEmpty else { return handle }
        let old = waiters[sessionID]?.handle
        waiters[sessionID] = Waiter(id: id, sessionID: sessionID, since: at, handle: handle)
        return old
    }

    /// The waiter to answer with a reply, removed: one reply per wait.
    public mutating func take(_ sessionID: String) -> Handle? {
        waiters.removeValue(forKey: sessionID)?.handle
    }

    /// Waiters an event makes pointless: the user typed in their own UI, or the session ended.
    public mutating func release(for event: HookEvent) -> [Handle] {
        switch event.kind {
        case .promptSubmitted, .sessionEnd: return take(event.sessionID).map { [$0] } ?? []
        default: return []
        }
    }

    /// Waiters older than `cap`.
    public mutating func expire(now: Date, cap: TimeInterval) -> [Handle] {
        let old = waiters.values.filter { now.timeIntervalSince($0.since) >= cap }
        old.forEach { waiters[$0.sessionID] = nil }
        return old.map(\.handle)
    }

    /// The helper went away on its own (Claude Code killed it, or the session was interrupted). Only that waiter,
    /// not a newer one for the same session.
    public mutating func remove(id: String) {
        guard let entry = waiters.first(where: { $0.value.id == id }) else { return }
        waiters[entry.key] = nil
    }
}

/// How a quick reply reaches a session, or why it can't.
public enum ReplyRoute: Equatable, Sendable {
    /// Through the session's reply waiter: works in any host.
    case hook
    /// Typed into its iTerm2 or Terminal tab by AppleScript.
    case terminal
    case unavailable(String)

    public var canSend: Bool {
        if case .unavailable = self { return false }
        return true
    }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    public static func choose(hasWaiter: Bool, isClaude: Bool, hookStatus: HookInstallStatus, hostBundleID: String?, tty: String) -> ReplyRoute {
        if hasWaiter { return .hook }
        let typable = !tty.isEmpty && tty != "??" && (hostBundleID == TerminalScript.iTermBundleID || hostBundleID == TerminalScript.terminalBundleID)
        if typable { return .terminal }
        guard isClaude else { return .unavailable("Replies need Claude Code hooks") }
        switch hookStatus {
        case .connected: return .unavailable("Replies open when Claude next finishes a turn here")
        case .outdated: return .unavailable("Reconnect hooks to reply to this session")
        default: return .unavailable("Replies need Claude Code hooks")
        }
    }
}
