import SwiftUI
import UserNotifications
import LocalObserverCore

/// Settings window (⌘,). Changes apply immediately, like System Settings.
struct AgentSettingsView: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        TabView {
            AgentsPane(store: store)
                .tabItem { Label("Agents", systemImage: "sparkles") }
            LimitsPane(store: store)
                .tabItem { Label("Limits", systemImage: "gauge.with.dots.needle.33percent") }
            GeneralPane(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 560)
    }
}

// MARK: - Panes

private struct AgentsPane: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        SettingsPage(title: "Agents", message: "Local Observer watches the agents you turn on here. It reads their session files and running processes on this Mac, and never changes them.") {
            SettingsGroup {
                ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { index, agent in
                    AgentToggleRow(store: store, agent: agent)
                    if index < AgentKind.allCases.count - 1 { SettingsDivider() }
                }
            }
        }
    }
}

private struct AgentToggleRow: View {
    @ObservedObject var store: AgentStore
    var agent: AgentKind

    var body: some View {
        let integration = store.integration(for: agent)
        HStack(spacing: 12) {
            AgentIconView(agent: agent, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                Text(detection(integration))
                    .font(NFont.caption)
                    .foregroundStyle(N.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if agent.capabilities.sessions { Tag(text: "Sessions", color: .gray) }
                    if agent.capabilities.tokens { Tag(text: "Tokens", color: .gray) }
                    if AgentLimitClients.supportsAccountLimits(agent) { Tag(text: "Plan limits", color: .gray) }
                }
                .padding(.top, 2)
            }
            Spacer()
            Toggle(agent.name, isOn: Binding(
                get: { store.settings.enabledAgents.contains(agent) },
                set: { on in
                    var updated = store.settings
                    if on { updated.enabledAgents.insert(agent) } else { updated.enabledAgents.remove(agent) }
                    store.saveSettings(updated)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func detection(_ integration: AgentIntegration?) -> String {
        guard let integration, store.lastRefresh != nil else { return "Checking this Mac" }
        if integration.runningProcessCount > 0 { return "Running now" }
        if integration.isInstalled {
            return integration.installedPath.isEmpty
                ? "Installed"
                : "Installed at \((integration.installedPath as NSString).abbreviatingWithTildeInPath)"
        }
        return "Not found on this Mac"
    }
}

private struct LimitsPane: View {
    @ObservedObject var store: AgentStore

    private var agents: [AgentKind] { AgentKind.allCases.filter(AgentLimitClients.supportsAccountLimits) }

    var body: some View {
        SettingsPage(title: "Plan limits", message: "Connecting an agent lets Local Observer ask the provider for your current 5-hour, weekly, and monthly usage, using the sign-in that agent already has on this Mac. Tokens are read when needed and never stored.") {
            SettingsGroup {
                ForEach(Array(agents.enumerated()), id: \.element) { index, agent in
                    HStack(alignment: .top, spacing: 12) {
                        AgentIconView(agent: agent, size: 22).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                            Text(AgentLimitClients.connectDescription(agent))
                                .font(NFont.caption)
                                .foregroundStyle(N.text2)
                                .fixedSize(horizontal: false, vertical: true)
                            if let report = store.accountReports[agent], report.status == .error {
                                Text(report.message).font(NFont.caption).foregroundStyle(TagColor.orange.fg)
                            }
                        }
                        Spacer(minLength: 12)
                        Toggle("Connect \(agent.name)", isOn: Binding(
                            get: { store.settings.accountLimitAgents.contains(agent) },
                            set: { store.setAccountLimits(agent, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!store.settings.enabledAgents.contains(agent))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    if index < agents.count - 1 { SettingsDivider() }
                }
            }
            Text("Without a connection, Codex and Claude Code limits still appear when their own session logs include them.")
                .font(NFont.caption)
                .foregroundStyle(N.text3)
                .padding(.top, 10)
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var store: AgentStore
    @State private var notificationsDenied = false

    var body: some View {
        SettingsPage(title: "General", message: nil) {
            SettingsGroup {
                SettingsRow(title: "Refresh automatically", detail: "Check processes and session files every 15 seconds") {
                    Toggle("Refresh automatically", isOn: binding(\.autoRefresh)).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Keep history for", detail: "Older sessions are skipped when reading files") {
                    Picker("Keep history for", selection: binding(\.historyDays)) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Text("Notifications").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 8)
            SettingsGroup {
                SettingsRow(title: "When an agent needs you", detail: "A session is waiting for permission or an answer") {
                    Toggle("When an agent needs you", isOn: Binding(
                        get: { store.settings.notifyNeedsInput },
                        set: { on in
                            update { $0.notifyNeedsInput = on }
                            if on { requestPermission() }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "When a limit runs high", detail: "Once per window, when usage crosses the threshold") {
                    Picker("When a limit runs high", selection: Binding(
                        get: { store.settings.limitAlertPercent ?? 0 },
                        set: { value in
                            update { $0.limitAlertPercent = value == 0 ? nil : value }
                            if value > 0 { requestPermission() }
                        }
                    )) {
                        Text("Off").tag(0)
                        Text("At 75%").tag(75)
                        Text("At 90%").tag(90)
                        Text("At 100%").tag(100)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if notificationsDenied {
                Text("Notifications are turned off for Local Observer in System Settings.")
                    .font(NFont.caption).foregroundStyle(TagColor.orange.fg).padding(.top, 8)
            } else if !AgentNotifier.isAvailable {
                Text("Notifications need the packaged app. Build it with packaging/build-app.sh.")
                    .font(NFont.caption).foregroundStyle(N.text3).padding(.top, 8)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func update(_ change: (inout AgentSettings) -> Void) {
        var updated = store.settings
        change(&updated)
        store.saveSettings(updated)
    }

    private func requestPermission() {
        AgentNotifier.requestAuthorization { granted in notificationsDenied = !granted }
    }
}

// MARK: - First run

/// Inline first-run setup on the Activity page: detected agents are pre-selected; limits stay off until chosen.
struct AgentSetupPanel: View {
    @ObservedObject var store: AgentStore
    @State private var chosen: Set<AgentKind> = []
    @State private var limits: Set<AgentKind> = []
    @State private var seeded = false

    private var detected: [AgentKind] {
        AgentKind.allCases.filter { store.integration(for: $0)?.isInstalled == true || store.integration(for: $0)?.runningProcessCount ?? 0 > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose the agents to watch")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(N.text)
            Text(store.lastRefresh == nil
                 ? "Looking for coding agents on this Mac…"
                 : "Found \(detected.count) on this Mac. Watching reads their local session files; nothing leaves your Mac unless you connect plan limits.")
                .font(NFont.small)
                .foregroundStyle(N.text2)
                .padding(.top, 3)

            let grid = [GridItem(.adaptive(minimum: 200), spacing: 8, alignment: .leading)]
            LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                ForEach(AgentKind.allCases) { agent in
                    SetupAgentTile(
                        agent: agent,
                        found: detected.contains(agent),
                        selected: chosen.contains(agent)
                    ) {
                        if chosen.contains(agent) { chosen.remove(agent); limits.remove(agent) } else { chosen.insert(agent) }
                    }
                }
            }
            .padding(.top, 16)

            let limitAgents = AgentKind.allCases.filter { chosen.contains($0) && AgentLimitClients.supportsAccountLimits($0) }
            if !limitAgents.isEmpty {
                Text("Also show plan limits for")
                    .font(NFont.small.weight(.medium))
                    .foregroundStyle(N.text)
                    .padding(.top, 18)
                HStack(spacing: 14) {
                    ForEach(limitAgents) { agent in
                        Toggle(isOn: Binding(
                            get: { limits.contains(agent) },
                            set: { on in if on { limits.insert(agent) } else { limits.remove(agent) } }
                        )) {
                            Text(agent.shortName).font(NFont.small)
                        }
                        .toggleStyle(.checkbox)
                        .help(AgentLimitClients.connectDescription(agent))
                    }
                }
                .padding(.top, 6)
                Text("Uses each agent's existing sign-in to ask the provider for your usage. macOS may ask to allow Keychain access.")
                    .font(NFont.caption)
                    .foregroundStyle(N.text3)
                    .padding(.top, 4)
            }

            HStack(spacing: 8) {
                Button("Start watching") { store.completeSetup(enabled: chosen, accountLimits: limits) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(chosen.isEmpty)
                    .keyboardShortcut(.defaultAction)
                Text(chosen.isEmpty ? "Select at least one agent" : "\(chosen.count) selected. Change this any time in Settings.")
                    .font(NFont.caption)
                    .foregroundStyle(N.text3)
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(N.divider))
        .onChange(of: store.lastRefresh) { _, _ in seed() }
        .onAppear(perform: seed)
    }

    private func seed() {
        guard !seeded, store.lastRefresh != nil else { return }
        seeded = true
        chosen = Set(detected)
    }
}

private struct SetupAgentTile: View {
    var agent: AgentKind
    var found: Bool
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AgentIconView(agent: agent, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).font(NFont.body).foregroundStyle(N.text).lineLimit(1)
                    Text(found ? "Found on this Mac" : "Not found").font(NFont.caption)
                        .foregroundStyle(found ? N.text2 : N.text3)
                }
                Spacer(minLength: 6)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? N.blue : N.text3)
            }
            .padding(.horizontal, 12)
            .frame(height: 50)
            .background(selected ? N.bgRaised : (hover ? N.hover : .clear),
                        in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: N.radius, style: .continuous)
                .strokeBorder(selected ? N.blue.opacity(0.55) : N.divider, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(found ? "Found on this Mac" : "Not found on this Mac")
    }
}

// MARK: - Settings layout pieces

private struct SettingsPage<Content: View>: View {
    var title: String
    var message: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(NFont.title).foregroundStyle(N.text)
                if let message {
                    Text(message)
                        .font(NFont.small)
                        .foregroundStyle(N.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                content.padding(.top, 18)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(N.bg)
    }
}

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(N.divider))
    }
}

private struct SettingsDivider: View {
    var body: some View { Rectangle().fill(N.divider).frame(height: 1).padding(.leading, 14) }
}

private struct SettingsRow<Control: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NFont.body).foregroundStyle(N.text)
                Text(detail).font(NFont.caption).foregroundStyle(N.text2)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
