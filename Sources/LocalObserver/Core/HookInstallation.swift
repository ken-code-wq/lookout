import Foundation
import LocalObserverHooks

/// Connects agents to `lookout-hook` by editing their own config files, with the merge logic from LocalObserverHooks.
enum HookInstallation {
    /// The helper ships next to the app's executable: Lookout.app/Contents/MacOS, or .build/<config>/ under `swift run`.
    static var helperPath: String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent(HookHelper.fileName).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// `LOCAL_OBSERVER_HOOKS_HOME` points the installer at another home folder, so connecting can be tried against a
    /// scratch copy instead of the real ~/.claude and ~/.codex.
    private static var home: String {
        ProcessInfo.processInfo.environment["LOCAL_OBSERVER_HOOKS_HOME"] ?? HookSocket.realHome
    }

    static func configURL(_ agent: HookAgent) -> URL {
        switch agent {
        case .claude: return URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
        case .codex: return URL(fileURLWithPath: home).appendingPathComponent(".codex/config.toml")
        }
    }

    static func status(_ agent: HookAgent) -> HookInstallStatus {
        let path = helperPath ?? "/Applications/Lookout.app/Contents/MacOS/\(HookHelper.fileName)"
        do {
            let text = try HookConfigFile.read(configURL(agent))
            switch agent {
            case .claude:
                return ClaudeHookConfig.status(try ClaudeHookConfig.parse(text), command: HookHelper.command(helperPath: path, agent: .claude))
            case .codex:
                return CodexNotifyConfig.status(text, helperPath: path)
            }
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Adds or refreshes Lookout's entries. Returns the backup of the previous file, if one was written.
    @discardableResult
    static func connect(_ agent: HookAgent) throws -> URL? {
        guard let path = helperPath else { throw Missing() }
        return try HookConfigFile.update(configURL(agent)) { text in
            switch agent {
            case .claude:
                let settings = ClaudeHookConfig.install(try ClaudeHookConfig.parse(text), command: HookHelper.command(helperPath: path, agent: .claude))
                return try ClaudeHookConfig.render(settings)
            case .codex:
                return try CodexNotifyConfig.install(text, helperPath: path)
            }
        }
    }

    @discardableResult
    static func disconnect(_ agent: HookAgent) throws -> URL? {
        try HookConfigFile.update(configURL(agent)) { text in
            switch agent {
            case .claude:
                let settings = try ClaudeHookConfig.parse(text)
                let cleaned = ClaudeHookConfig.uninstall(settings)
                // Untouched settings keep their original text; only a real removal rewrites the file.
                return NSDictionary(dictionary: cleaned).isEqual(to: settings) ? text : try ClaudeHookConfig.render(cleaned)
            case .codex:
                return CodexNotifyConfig.uninstall(text)
            }
        }
    }

    struct Missing: LocalizedError {
        var errorDescription: String? { "The lookout-hook helper isn't next to Lookout. Build the app with packaging/build-app.sh." }
    }
}
