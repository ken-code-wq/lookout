import AppIntents
import LocalObserverCore

// Shortcuts and Spotlight actions. They only show up in Shortcuts when the app bundle carries the
// Metadata.appintents that Xcode's appintentsmetadataprocessor generates; packaging/build-app.sh runs it when
// Xcode is installed. Without it these are inert. Every action goes through LookoutRoute, like the URL scheme.

struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource
}

enum PageOption: String, AppEnum {
    case dashboard, sessions, usage, limits, repos, github, ci, inbox, pulls, servers, launchers, containers, cleanup, shelf

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Lookout Page"
    static let caseDisplayRepresentations: [PageOption: DisplayRepresentation] = [
        .dashboard: "Dashboard",
        .sessions: "Sessions",
        .usage: "Usage",
        .limits: "Plan limits",
        .repos: "Repositories",
        .github: "GitHub",
        .ci: "CI & Deploys",
        .inbox: "Inbox",
        .pulls: "Pull requests",
        .servers: "Servers",
        .launchers: "Launchers",
        .containers: "Containers",
        .cleanup: "Cleanup",
        .shelf: "Shelf"
    ]
}

enum ProviderOption: String, AppEnum {
    case claude, codex, copilot, cursor, antigravity

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let caseDisplayRepresentations: [ProviderOption: DisplayRepresentation] = [
        .claude: "Claude Code",
        .codex: "Codex",
        .copilot: "GitHub Copilot",
        .cursor: "Cursor",
        .antigravity: "Antigravity"
    ]

    var agent: AgentKind { AgentKind(rawValue: rawValue) ?? .claude }
}

enum LauncherActionOption: String, AppEnum {
    case start, stop

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Launcher Action"
    static let caseDisplayRepresentations: [LauncherActionOption: DisplayRepresentation] = [.start: "Start", .stop: "Stop"]
}

enum SwitchOption: String, AppEnum {
    case toggle, on, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Switch"
    static let caseDisplayRepresentations: [SwitchOption: DisplayRepresentation] = [.toggle: "Toggle", .on: "On", .off: "Off"]
}

struct AgentsNeedingAttentionIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Agents Needing Attention"
    static let description = IntentDescription("Lists the coding agent sessions waiting on you for a permission, an answer, or after a failure.")

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        guard let status = LookoutStatus.load() else { throw IntentFailure(localizedStringResource: "Lookout hasn't published any status yet.") }
        let lines = status.needingAttention.map { "\($0.agentName): \($0.title) (\($0.project))" }
        let dialog: IntentDialog = lines.isEmpty ? "No agents need you." : "\(lines.count) waiting: \(lines.joined(separator: "; "))"
        return .result(value: lines, dialog: dialog)
    }
}

struct PlanLimitRemainingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Plan Limit Remaining"
    static let description = IntentDescription("Percent left in a provider's headline plan-limit window, the one the notch shows.")

    @Parameter(title: "Provider", default: .claude)
    var provider: ProviderOption

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let left = LookoutStatus.load()?.remainingPercent(for: provider.agent) else {
            throw IntentFailure(localizedStringResource: "No plan limits for \(provider.agent.name). Connect it in Lookout › Settings › Limits.")
        }
        let percent = Int(left.rounded())
        return .result(value: percent, dialog: "\(provider.agent.name) has \(percent)% left.")
    }
}

struct LauncherIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or Stop a Launcher"
    static let description = IntentDescription("Starts or stops a saved dev server launcher by name.")

    @Parameter(title: "Launcher name")
    var name: String

    @Parameter(title: "Action", default: .start)
    var action: LauncherActionOption

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSurfaces.shared.perform(.launcher(name: name, action: action == .start ? .start : .stop))
        return .result()
    }
}

struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Lookout Page"
    static let openAppWhenRun = true

    @Parameter(title: "Page", default: .dashboard)
    var page: PageOption

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSurfaces.shared.perform(.open(LookoutPage(rawValue: page.rawValue) ?? .dashboard))
        return .result()
    }
}

struct KeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Mac Awake"
    static let description = IntentDescription("Turns Lookout's keep-awake on, off, or flips it. Returns whether it's on.")

    @Parameter(title: "Keep awake", default: .toggle)
    var mode: SwitchOption

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        LiveSurfaces.shared.perform(.keepAwake(LookoutRoute.Switch(rawValue: mode.rawValue) ?? .toggle))
        return .result(value: Preferences.shared.keepAwake != .off)
    }
}

struct FocusTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus Timer"
    static let description = IntentDescription("Starts the countdown beside the notch.")

    @Parameter(title: "Minutes", default: 25, inclusiveRange: (1, 1440))
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveSurfaces.shared.perform(.timer(minutes: minutes))
        return .result()
    }
}

struct LookoutShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AgentsNeedingAttentionIntent(), phrases: ["Which agents need me in \(.applicationName)"],
                    shortTitle: "Agents Needing You", systemImageName: "exclamationmark.bubble")
        AppShortcut(intent: PlanLimitRemainingIntent(), phrases: ["How much \(.applicationName) limit is left"],
                    shortTitle: "Plan Limit Left", systemImageName: "gauge.with.dots.needle.33percent")
        AppShortcut(intent: FocusTimerIntent(), phrases: ["Start a \(.applicationName) focus timer"],
                    shortTitle: "Focus Timer", systemImageName: "timer")
    }
}
