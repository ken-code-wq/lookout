import Foundation
import LocalObserverCore

// Starting agent tasks from Lookout: which agent CLIs can be launched and how, which terminal runs them, and the
// pure rules for naming branches and worktrees, quoting the prompt, and writing the launch script. Everything here
// is a function of its inputs, so it's checked in LocalObserverVerification; the app does the launching.

/// A coding agent's command-line tool that Lookout can start interactively with a prompt.
public enum AgentCLI: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case openCode = "opencode"
    case cursor = "cursor-agent"
    case copilot
    case pi

    public var id: String { rawValue }

    /// The agent whose sessions this CLI produces, for icons and matching.
    public var agent: AgentKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .openCode: return .openCode
        case .cursor: return .cursor
        case .copilot: return .copilot
        case .pi: return .pi
        }
    }

    public var name: String {
        switch self {
        case .cursor: return "Cursor Agent"
        case .copilot: return "Copilot CLI"
        default: return agent.name
        }
    }

    public var executableNames: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        case .openCode: return ["opencode"]
        case .cursor: return ["cursor-agent"]
        case .copilot: return ["copilot"]
        case .pi: return ["pi"]
        }
    }

    /// Arguments that open the agent's interactive session with `prompt` already sent, so it starts working and
    /// stays open for follow-ups.
    public func arguments(prompt: String) -> [String] {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        switch self {
        case .claude, .codex, .cursor, .pi: return [text]
        case .openCode: return ["--prompt", text]
        case .copilot: return ["-i", text]
        }
    }
}

/// Where agent CLIs live. Apps opened from Finder get a bare PATH (`/usr/bin:/bin:…`), so the usual install
/// folders are searched as well: Homebrew, npm/bun/pnpm globals, nvm, and each agent's own installer.
public enum AgentCLILocator {
    public static func searchDirectories(home: String, path: String?, nodeVersions: [String] = []) -> [String] {
        let fixed = [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin",
            "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.opencode/bin", "\(home)/Library/pnpm",
            "\(home)/.asdf/shims", "\(home)/.local/share/mise/shims", "\(home)/.cargo/bin",
        ]
        // Newest Node first, so `env node` in an npm-installed CLI finds a recent one.
        let nvm = nodeVersions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(home)/.nvm/versions/node/\($0)/bin" }
        let inherited = (path ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (fixed + nvm + inherited).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The first executable for `cli` in `directories`.
    public static func locate(_ cli: AgentCLI, in directories: [String], isExecutable: (String) -> Bool) -> String? {
        for name in cli.executableNames {
            for dir in directories where isExecutable(dir + "/" + name) { return dir + "/" + name }
        }
        return nil
    }

    /// This Mac's search folders: the fixed list, installed nvm versions, and the app's own PATH.
    public static func currentDirectories() -> [String] {
        let home = NSHomeDirectory()
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node")) ?? []
        return searchDirectories(home: home, path: ProcessInfo.processInfo.environment["PATH"], nodeVersions: versions)
    }
}

/// The terminal a task opens in.
public enum TerminalApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal
    case iTerm = "iterm2"
    case ghostty
    case warp

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .terminal: return ["com.apple.Terminal"]
        case .iTerm: return ["com.googlecode.iterm2"]
        case .ghostty: return ["com.mitchellh.ghostty"]
        case .warp: return ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        }
    }
}

// MARK: - Quoting

public enum ShellQuote {
    private static let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@,+%")

    /// One shell word that sh, bash and zsh all read back as exactly `text`: left bare when it's only safe
    /// characters, otherwise single-quoted, with each `'` written as `'\''`. NUL can't appear in an argument, so
    /// it's dropped.
    public static func quote(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\0", with: "")
        if !clean.isEmpty, clean.allSatisfy(plain.contains) { return clean }
        return "'" + clean.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `argv` as one command line.
    public static func command(_ argv: [String]) -> String { argv.map(quote).joined(separator: " ") }

    /// Text inside an AppleScript string literal.
    public static func appleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// A YAML double-quoted scalar.
    public static func yaml(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

// MARK: - Naming

public enum AgentTaskNaming {
    public static let branchPrefix = "agent/"

    /// "Fix the flaky login test (again!)" → "fix-the-flaky-login-test-again": lowercase ASCII words joined by
    /// dashes, cut at a word boundary to fit `maxLength`. "task" when nothing usable is left.
    public static func slug(_ text: String, maxLength: Int = 40) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let words = folded.split { !(($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9")) }.map(String.init)
        var result = ""
        for word in words {
            let next = result.isEmpty ? word : result + "-" + word
            if next.count > maxLength {
                if result.isEmpty { result = String(word.prefix(maxLength)) }
                break
            }
            result = next
        }
        return result.isEmpty ? "task" : result
    }

    /// `agent/<slug>`, with `-2`, `-3`… added until no existing branch has the name. Git refs are case-sensitive
    /// but macOS file systems aren't, so the comparison ignores case.
    public static func branchName(for prompt: String, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        return unique(branchPrefix + slug(prompt)) { lowered.contains($0.lowercased()) }
    }

    /// `base`, or `base-2`, `base-3`… whichever `exists` says is free first.
    public static func unique(_ base: String, exists: (String) -> Bool) -> String {
        guard exists(base) else { return base }
        var n = 2
        while exists("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Worktrees for a repository go next to it: `~/code/app` → `~/code/app-worktrees`. Beside the repository so
    /// they're easy to find, but outside it so they never show up in its `git status`.
    public static func worktreeContainer(repoRoot: String) -> String {
        let root = (repoRoot as NSString).standardizingPath
        let parent = (root as NSString).deletingLastPathComponent
        return (parent as NSString).appendingPathComponent((root as NSString).lastPathComponent + "-worktrees")
    }

    /// The worktree folder for a branch: its name without the `agent/` prefix, made unique.
    public static func worktreePath(repoRoot: String, branch: String, exists: (String) -> Bool) -> String {
        let name = branch.hasPrefix(branchPrefix) ? String(branch.dropFirst(branchPrefix.count)) : branch
        let folder = name.replacingOccurrences(of: "/", with: "-")
        return unique((worktreeContainer(repoRoot: repoRoot) as NSString).appendingPathComponent(folder), exists: exists)
    }
}

// MARK: - Launch script

public enum AgentTaskScript {
    /// The script a terminal runs: name the tab, `cd` into the checkout, run the agent with the prompt, then hand
    /// over to the user's own shell in the same folder once the agent exits. `searchPath` goes in front of PATH so
    /// npm-installed CLIs (`#!/usr/bin/env node`) find Node even when the terminal didn't load the shell's setup.
    public static func script(directory: String, executable: String, arguments: [String], title: String, searchPath: [String]) -> String {
        var lines = ["#!/bin/zsh -l", "# Started from Lookout. Safe to delete."]
        if !searchPath.isEmpty {
            lines.append("export PATH=\(ShellQuote.quote(searchPath.joined(separator: ":"))):\"$PATH\"")
        }
        lines.append("printf '\\033]0;%s\\007' \(ShellQuote.quote(title))")
        lines.append("cd \(ShellQuote.quote(directory)) || exit 1")
        lines.append(ShellQuote.command([executable] + arguments))
        lines.append("exec \"${SHELL:-/bin/zsh}\" -l")
        return lines.joined(separator: "\n") + "\n"
    }

    /// What the user would type, for the sheet's preview: the agent's command name rather than its full path.
    public static func preview(_ cli: AgentCLI, prompt: String) -> String {
        ShellQuote.command([cli.executableNames[0]] + cli.arguments(prompt: prompt))
    }

    /// A Warp launch configuration that opens one tab in `directory` running `scriptPath`.
    public static func warpLaunchConfiguration(name: String, title: String, directory: String, scriptPath: String) -> String {
        """
        ---
        name: \(ShellQuote.yaml(name))
        windows:
          - tabs:
              - title: \(ShellQuote.yaml(title))
                layout:
                  cwd: \(ShellQuote.yaml(directory))
                  commands:
                    - exec: \(ShellQuote.yaml(ShellQuote.quote(scriptPath)))

        """
    }

    /// iTerm2: a new window whose session runs the script.
    public static func iTermAppleScript(scriptPath: String) -> String {
        let command = ShellQuote.appleScript("/bin/zsh -l " + ShellQuote.quote(scriptPath))
        return """
        tell application id "com.googlecode.iterm2"
            activate
            create window with default profile command "\(command)"
        end tell
        """
    }
}
