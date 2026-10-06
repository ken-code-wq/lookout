import Foundation
import Darwin
import LocalObserverHooks

// lookout-hook: the program an agent's hook runs. It forwards the event to Lookout over a local socket and, for a
// Claude Code permission request, waits for the answer and prints it. Whenever Lookout isn't running, hangs up, or
// doesn't answer in time, it exits quietly with no output, so the agent falls back to asking in its own terminal.
//
//   Claude Code (settings.json hooks):   lookout-hook claude          event JSON on stdin
//   Codex (config.toml notify):          lookout-hook codex '<json>'  event JSON as the last argument

/// Never outlive the longest the app could hold a request (5 minutes) plus a margin, whatever happens.
let maxWait: TimeInterval = 330
alarm(UInt32(maxWait + 10))

let arguments = CommandLine.arguments
let agent = arguments.count > 1 ? HookAgent(rawValue: arguments[1]) ?? .claude : .claude

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
      let line = HookEvent.envelope(agent: agent, payload: payload, pids: ancestry()) else { exit(0) }

let waits = agent == .claude && payload["hook_event_name"] as? String == "PermissionRequest"
if let reply = HookClient.send(line, wait: waits ? maxWait : 0) {
    FileHandle.standardOutput.write(reply)
}
exit(0)
