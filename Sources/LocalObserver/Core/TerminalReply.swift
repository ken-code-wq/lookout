import AppKit
import LocalObserverCore
import LocalObserverHooks

/// Sends a quick reply to the terminal a session runs in. iTerm2 and Terminal take it directly by AppleScript; any
/// other host gets it on the clipboard, brought to the front so ⌘V finishes the job.
enum TerminalReply {
    enum Outcome: Equatable {
        case typed(String)
        case copied(String)
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
        if !process.terminal.isEmpty, process.terminal != "??",
           let script = TerminalScript.reply(text, tty: tty, bundleID: bundleID) {
            let result = await Task.detached(priority: .userInitiated) { () -> (String?, Int?) in
                var error: NSDictionary?
                let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
                return (output, error?[NSAppleScript.errorNumber] as? Int)
            }.value
            if result.0 == "ok" { return .typed(host.name) }
            // -1743: not allowed to control the terminal. Fall through to the clipboard and say why.
            if result.1 == -1743 {
                copyAndFocus(text, session: session)
                return .failed("Allow Lookout to control \(host.name) in System Settings › Privacy & Security › Automation. Copied the reply instead.")
            }
        }
        copyAndFocus(text, session: session)
        return .copied(host.name)
    }

    @MainActor
    private static func copyAndFocus(_ text: String, session: AgentSession) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(TerminalScript.singleLine(text), forType: .string)
        AgentActions.jump(to: session)
    }
}
