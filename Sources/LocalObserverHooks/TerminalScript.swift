import Foundation

/// AppleScript that types a reply into the terminal tab a session runs in, found by its TTY.
public enum TerminalScript {
    public static let iTermBundleID = "com.googlecode.iterm2"
    public static let terminalBundleID = "com.apple.Terminal"

    /// The script for a host app, or nil when it has no scripting for this (Ghostty, Warp, editors…).
    /// Each returns "ok" when it found the tab, so a missing tab isn't mistaken for success.
    public static func reply(_ text: String, tty: String, bundleID: String?) -> String? {
        let line = singleLine(text)
        switch bundleID {
        case iTermBundleID:
            // `write text` types the line and presses Return.
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \(quoted(tty)) then
                                tell s to write text \(quoted(line))
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        case terminalBundleID:
            // `do script … in` a busy tab types into whatever is running there, then Return.
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(quoted(tty)) then
                            do script \(quoted(line)) in t
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        default:
            return nil
        }
    }

    /// An AppleScript string literal.
    public static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A reply is one line: a newline in the middle would submit half of it.
    public static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
