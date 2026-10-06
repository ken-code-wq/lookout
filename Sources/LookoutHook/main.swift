import Foundation
import Darwin
import LocalObserverHooks

// lookout-hook: the program an agent's hook runs. It forwards the event to Lookout over a local socket and, for a
// Claude Code permission request, waits for the answer and prints it. Whenever Lookout isn't running, hangs up, or
// doesn't answer in time, it exits quietly with no output, so the agent falls back to asking in its own terminal.
//
//   Claude Code (settings.json hooks):   lookout-hook claude          event JSON on stdin
//   Codex (config.toml notify):          lookout-hook codex '<json>'  event JSON as the last argument
//   Claude Code reply waiter (Stop, asyncRewake):  lookout-hook claude --await-reply
//
// The reply waiter runs in the background after a turn ends and waits for a reply sent from Lookout. With one it
// prints the message to stderr and exits 2, which wakes Claude in that session; otherwise (released, Lookout quit,
// the ceiling passed) it exits 0 and Claude Code does nothing. See HookReply.
//
// LOOKOUT_HOOK_SOCKET points it at another socket, for testing against a stand-in server.

/// Never outlive the longest the app could hold a request (5 minutes) plus a margin, whatever happens.
let maxWait: TimeInterval = 330

var arguments = CommandLine.arguments
let awaitsReply = arguments.contains(HookReply.awaitFlag)
arguments.removeAll { $0 == HookReply.awaitFlag }
let agent = arguments.count > 1 ? HookAgent(rawValue: arguments[1]) ?? .claude : .claude
/// The waiter's ceiling is hours, matching its hook entry's timeout; the app releases it well before.
let replyWait = TimeInterval(ClaudeHookConfig.replyWaitCeiling)
alarm(UInt32((awaitsReply ? replyWait : maxWait) + 10))
let socketPath = ProcessInfo.processInfo.environment["LOOKOUT_HOOK_SOCKET"] ?? HookSocket.defaultPath()

func readPayload() -> Data? {
    switch agent {
    case .codex:
        return arguments.count > 2 ? arguments.last.map { Data($0.utf8) } : nil
    case .claude:
        // A terminal on stdin means someone ran this by hand; don't sit waiting for input.
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return FileHandle.standardInput.readDataToEndOfFile()
    }
}

/// Parent processes, nearest first: the shell running the hook, then the agent. Lets Lookout find the exact session.
func ancestry(depth: Int = 4) -> [Int32] {
    var pids: [Int32] = []
    var pid = getppid()
    while pid > 1, pids.count < depth {
        pids.append(pid)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        pid = info.kp_eproc.e_ppid
    }
    return pids
}

guard let data = readPayload(), !data.isEmpty,
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let line = HookEvent.envelope(agent: agent, payload: payload, pids: ancestry(), awaitingReply: awaitsReply && agent == .claude)
else { exit(0) }

if awaitsReply {
    guard agent == .claude else { exit(0) }
    let outcome = HookReply.outcome(of: HookClient.send(line, to: socketPath, wait: replyWait))
    if let message = outcome.stderr { FileHandle.standardError.write(Data(message.utf8)) }
    exit(outcome.exitCode)
}

let waits = agent == .claude && payload["hook_event_name"] as? String == "PermissionRequest"
if let reply = HookClient.send(line, to: socketPath, wait: waits ? maxWait : 0) {
    FileHandle.standardOutput.write(reply)
}
exit(0)
