import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverHooks

/// Settings › Agents › Live hooks: connect agents so they report their state as it happens and ask for permission
/// in the notch.
struct AgentHooksSettings: View {
    @ObservedObject var center = ApprovalCenter.shared
    @State private var statuses: [HookAgent: HookInstallStatus] = [:]
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Live hooks").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 4)
            Text("With hooks, an agent tells Lookout what it's doing as it happens instead of Lookout reading it from transcripts, and Claude Code asks for permission in the notch. Lookout adds its own entries to the agent's config, keeps a backup next to it, and leaves everything else as it was.")
                .font(NFont.caption).foregroundStyle(N.text2).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            SettingsGroup {
                ForEach(Array(HookAgent.allCases.enumerated()), id: \.element) { index, agent in
                    if index > 0 { SettingsDivider() }
                    row(agent)
                }
            }
            if let note {
                Text(note).font(NFont.caption).foregroundStyle(N.text2).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            }

            Text("Permission requests").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 8)
            SettingsGroup {
                SettingsRow(title: "Ask in Lookout", detail: "The notch opens on the request, and Peek and the menu bar list it. Off leaves every prompt in the terminal") {
                    Toggle("Ask in Lookout", isOn: $center.enabled).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Wait for an answer", detail: "Then the agent stops waiting and asks in its own terminal") {
                    Picker("Wait for an answer", selection: $center.waitSeconds) {
                        ForEach(ApprovalCenter.waitChoices, id: \.self) { Text(waitTitle($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .disabled(!center.enabled)
                SettingsDivider()
                SettingsRow(title: "Not while its terminal is in front", detail: "If you're already looking at the agent, it asks right there") {
                    Toggle("Not while its terminal is in front", isOn: $center.passWhenTerminalFront).toggleStyle(.switch).labelsHidden()
                }
                .disabled(!center.enabled)
            }
            Text(listenerText)
                .font(NFont.caption).foregroundStyle(N.text3).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private func row(_ agent: HookAgent) -> some View {
        let status = statuses[agent] ?? .notConnected
        let kind = AgentKind(rawValue: agent.rawValue) ?? .claude
        return HStack(alignment: .top, spacing: 12) {
            AgentIconView(agent: kind, size: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                    statusTag(status)
                }
                Text(description(agent, status))
                    .font(NFont.caption).foregroundStyle(N.text2).fixedSize(horizontal: false, vertical: true)
                Text((HookInstallation.configURL(agent).path as NSString).abbreviatingWithTildeInPath)
                    .font(NFont.monoSmall).foregroundStyle(N.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            // Connecting needs the helper next to the app; disconnecting never does.
            let canConnect = HookInstallation.helperPath != nil
            HStack(spacing: 6) {
                switch status {
                case .connected:
                    Button("Disconnect") { run(agent, connect: false) }
                case .outdated:
                    Button("Disconnect") { run(agent, connect: false) }
                    Button("Update") { run(agent, connect: true) }.buttonStyle(.borderedProminent).disabled(!canConnect)
                case .notConnected:
                    Button("Connect hooks") { run(agent, connect: true) }.buttonStyle(.borderedProminent).disabled(!canConnect)
                case .conflict, .unreadable:
                    Button("Connect hooks") {}.disabled(true)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder private func statusTag(_ status: HookInstallStatus) -> some View {
        switch status {
        case .connected: Tag(text: "Connected", color: .green, symbol: "checkmark")
        case .outdated: Tag(text: "Outdated", color: .orange, symbol: "arrow.triangle.2.circlepath")
        case .notConnected: Tag(text: "Not connected", color: .gray)
        case .conflict: Tag(text: "In use", color: .orange, symbol: "exclamationmark.triangle")
        case .unreadable: Tag(text: "Can't read", color: .red, symbol: "exclamationmark.triangle")
        }
    }

    private func description(_ agent: HookAgent, _ status: HookInstallStatus) -> String {
        switch status {
        case .conflict(let program):
            return "Codex runs one notify program and it's already \(program). Remove that from config.toml to connect Lookout."
        case .unreadable(let reason):
            return reason
        case .outdated:
            return "Lookout's hooks point at another copy of the helper, or some are missing. Update them to use this copy."
        default:
            break
        }
        let last = AgentKind(rawValue: agent.rawValue).flatMap { center.lastEventAt[$0] }
        let heard = last.map { " Last event \(AgentFormat.relative($0))." } ?? ""
        switch agent {
        case .claude:
            return "Sessions, prompts, finished turns and permission requests. Answer Allow, Deny or Always allow from the notch." + heard
        case .codex:
            return "Finished turns only: Codex has no hook for approvals, so it still asks in its terminal." + heard
        }
    }

    private var listenerText: String {
        if let error = center.listenerError { return "Not listening for hooks: \(error)" }
        if HookInstallation.helperPath == nil {
            return "The lookout-hook helper wasn't found next to Lookout, so hooks can't be connected from this build. Build the app with packaging/build-app.sh."
        }
        return center.isListening ? "Listening for hooks. If Lookout isn't running, agents simply ask in their terminal as usual." : "Starting…"
    }

    private func waitTitle(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) minutes"
    }

    private func run(_ agent: HookAgent, connect: Bool) {
        do {
            let backup = connect ? try HookInstallation.connect(agent) : try HookInstallation.disconnect(agent)
            let name = AgentKind(rawValue: agent.rawValue)?.name ?? agent.rawValue
            let verb = connect ? "Connected \(name)." : "Disconnected \(name)."
            let restart = agent == .claude && connect ? " Sessions already running pick it up when restarted." : ""
            note = verb + restart + (backup.map { " Previous file backed up as \($0.lastPathComponent)." } ?? "")
        } catch {
            note = error.localizedDescription
        }
        reload()
    }

    private func reload() {
        var updated: [HookAgent: HookInstallStatus] = [:]
        for agent in HookAgent.allCases { updated[agent] = HookInstallation.status(agent) }
        statuses = updated
    }
}
