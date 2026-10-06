import AppKit
import LocalObserverCore
import LocalObserverHooks

/// Types a quick reply into the iTerm2 or Terminal tab a session runs in, by AppleScript. The secondary route: a
/// session with a reply waiter gets the reply through Claude Code's hook instead (`ApprovalCenter.sendReply`).
enum TerminalReply {
    enum Outcome: Equatable {
        case typed(String)
        /// The host has no tab on the session's TTY any more.
        case missing(String)
        case failed(String)
    }

    @MainActor
    static func send(_ text: String, to session: AgentSession) async -> Outcome {
        guard let process = session.process, let host = process.host else {
            return .failed("Lookout can't tell which app this session runs in.")
        }
        let bundleID = Bundle(path: host.bundlePath)?.bundleIdentifier
            ?? NSRunningApplication(processIdentifier: host.pid)?.bundleIdentifier
        let tty = "/dev/\(process.terminal)"
        guard !process.terminal.isEmpty, process.terminal != "??",
              let script = TerminalScript.reply(text, tty: tty, bundleID: bundleID) else {
            return .failed("\(host.name) can't take a typed reply.")
        }
        let result = await Task.detached(priority: .userInitiated) { () -> (String?, Int?) in
            var error: NSDictionary?
            let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
            return (output, error?[NSAppleScript.errorNumber] as? Int)
        }.value
        if result.0 == "ok" { return .typed(host.name) }
        // -1743: not allowed to control the terminal.
        if result.1 == -1743 {
            return .failed("Allow Lookout to control \(host.name) in System Settings › Privacy & Security › Automation.")
        }
        return .missing(host.name)
    }
}
