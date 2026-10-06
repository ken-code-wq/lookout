import SwiftUI
import Carbon.HIToolbox
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
            RepoSettingsPane()
                .tabItem { Label("Repos", systemImage: "square.stack.3d.up") }
            DiskSettingsPane()
                .tabItem { Label("Disk", systemImage: "internaldrive") }
            MenuBarDockPane()
                .tabItem { Label("Menu Bar & Notch", systemImage: "menubar.dock.rectangle") }
            ShelfSettingsPane()
                .tabItem { Label("Shelf", systemImage: "tray.full") }
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
        SettingsPage(title: "Agents", message: "Lookout watches the agents you turn on here. It reads their session files and running processes on this Mac, and never changes them.") {
            SettingsGroup {
                ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { index, agent in
                    AgentToggleRow(store: store, agent: agent)
                    if index < AgentKind.allCases.count - 1 { SettingsDivider() }
                }
            }
            AgentHooksSettings()
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
                    if agent.capabilities.tokens { Tag(text: agent.capabilities.estimatedTokens ? "Tokens (estimated)" : "Tokens", color: .gray) }
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
        SettingsPage(title: "Plan limits", message: "Connecting an agent lets Lookout ask the provider for your current 5-hour, weekly, and monthly usage, using the sign-in that agent already has on this Mac. Tokens are read when needed and never stored.") {
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

private struct MenuBarDockPane: View {
    @ObservedObject var prefs = Preferences.shared

    private var notchDetail: String {
        if NSScreen.screens.contains(where: { $0.safeAreaInsets.top > 0 }) { return "Agents, usage, and limits around the camera notch" }
        return "No display with a notch is connected right now"
    }

    var body: some View {
        SettingsPage(title: "Menu Bar, Dock & Notch", message: "Choose what Lookout shows outside its window. Changes apply immediately.") {
            Text("Menu bar title").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.bottom, 8)
            SettingsGroup {
                ForEach(Array(MenuBarItem.allCases.enumerated()), id: \.element) { index, item in
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol).frame(width: 18).foregroundStyle(N.text2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(NFont.body).foregroundStyle(N.text)
                            Text(item.detail).font(NFont.caption).foregroundStyle(N.text2)
                        }
                        Spacer(minLength: 12)
                        Toggle(item.title, isOn: Binding(
                            get: { prefs.menuBarItems.contains(item) },
                            set: { prefs.toggle(item, on: $0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    if index < MenuBarItem.allCases.count - 1 { SettingsDivider() }
                }
            }

            Text("Menu bar panel").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 8)
            SettingsGroup {
                ForEach(Array(prefs.menuSections.enumerated()), id: \.element) { index, section in
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol).frame(width: 18).foregroundStyle(N.text2)
                        Text(section.title).font(NFont.body).foregroundStyle(prefs.isVisible(section) ? N.text : N.text3)
                        Spacer(minLength: 12)
                        IconButton(symbol: "chevron.up", help: "Move up") { withAnimation(.snappy) { prefs.move(section, by: -1) } }
                            .disabled(index == 0)
                        IconButton(symbol: "chevron.down", help: "Move down") { withAnimation(.snappy) { prefs.move(section, by: 1) } }
                            .disabled(index == prefs.menuSections.count - 1)
                        Toggle(section.title, isOn: Binding(
                            get: { prefs.isVisible(section) },
                            set: { prefs.setVisible(section, $0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    if index < prefs.menuSections.count - 1 { SettingsDivider() }
                }
            }

            Text("Dock").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 8)
            SettingsGroup {
                SettingsRow(title: "Show in Dock", detail: "Off keeps Lookout in the menu bar only") {
                    Toggle("Show in Dock", isOn: $prefs.showDockIcon).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Dock icon", detail: "Agent Peek draws a limit ring and a running-agent pill on the icon") {
                    Picker("Dock icon", selection: $prefs.dockIconStyle) {
                        ForEach(DockIconStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsDivider()
                SettingsRow(title: "Badge", detail: "Red number on the Dock icon") {
                    Picker("Badge", selection: $prefs.dockBadge) {
                        ForEach(DockBadge.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Text("Right-click the Dock icon to jump to a running agent, open a server, or toggle Agent Peek.")
                .font(NFont.caption).foregroundStyle(N.text3).padding(.top, 6)

            Text("Keyboard shortcuts").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 8)
            SettingsGroup {
                ShortcutRow(action: .menuBar, title: "Open menu bar panel", detail: "Drops down the Lookout panel from any app")
                SettingsDivider()
                ShortcutRow(action: .notch, title: "Open the notch", detail: "Drops the notch dashboard down from any app")
                SettingsDivider()
                ShortcutRow(action: .peek, title: "Toggle Agent Peek", detail: "Shows or hides the floating panel from any app")
                SettingsDivider()
                ShortcutRow(action: .shelf, title: "Open clipboard history", detail: "Opens the Shelf in the notch, ready to search")
                SettingsDivider()
                ShortcutRow(action: .approvals, title: "Answer agent requests", detail: "Opens the oldest permission request: ⏎ allows, ⎋ denies")
            }
            Text("These work everywhere, even when another app is in front. Press one again to close.")
                .font(NFont.caption).foregroundStyle(N.text3).padding(.top, 6)

            Text("Notch").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 8)
            SettingsGroup {
                SettingsRow(title: "Show in the notch", detail: notchDetail) {
                    Toggle("Show in the notch", isOn: $prefs.notchEnabled).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Displays without a notch", detail: "Draw a notch-shaped pill at the top of the main display") {
                    Toggle("Displays without a notch", isOn: $prefs.notchOnPlainDisplays).toggleStyle(.switch).labelsHidden()
                }
                .disabled(!prefs.notchEnabled)
                SettingsDivider()
                SettingsRow(title: "Width", detail: "Closed wings, the open panel, and the virtual notch") {
                    HStack(spacing: 8) {
                        Slider(value: $prefs.notchWidth, in: 0.8...1.3, step: 0.05)
                            .frame(width: 150)
                        Text("\(Int((prefs.notchWidth * 100).rounded()))%")
                            .font(NFont.small).monospacedDigit().foregroundStyle(N.text2)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                .disabled(!prefs.notchEnabled)
                SettingsDivider()
                SettingsRow(title: "Left of the notch", detail: "Shown while the notch is closed") {
                    Picker("Left of the notch", selection: $prefs.notchLeft) {
                        ForEach(NotchWing.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .disabled(!prefs.notchEnabled)
                SettingsDivider()
                SettingsRow(title: "Right of the notch", detail: "Shown while the notch is closed") {
                    Picker("Right of the notch", selection: $prefs.notchRight) {
                        ForEach(NotchWing.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .disabled(!prefs.notchEnabled)
                SettingsDivider()
                SettingsRow(title: "Open on hover", detail: "Off opens it with a click instead") {
                    Toggle("Open on hover", isOn: $prefs.notchHoverToOpen).toggleStyle(.switch).labelsHidden()
                }
                .disabled(!prefs.notchEnabled)
                SettingsDivider()
                SettingsRow(title: "Drop down when an agent needs you", detail: "Shows the project and what it's waiting on for a few seconds") {
                    Toggle("Drop down when an agent needs you", isOn: $prefs.notchAlerts).toggleStyle(.switch).labelsHidden()
                }
                .disabled(!prefs.notchEnabled)
                SettingsDivider()
                SettingsRow(title: "…and when an agent finishes", detail: "A working session hands the turn back to you") {
                    Toggle("…and when an agent finishes", isOn: $prefs.notchFinishedAlerts).toggleStyle(.switch).labelsHidden()
                }
                .disabled(!prefs.notchEnabled || !prefs.notchAlerts)
                SettingsDivider()
                SettingsRow(title: "Volume and brightness", detail: "Key presses show a level bar in the notch") {
                    Toggle("Volume and brightness", isOn: $prefs.notchHUD).toggleStyle(.switch).labelsHidden()
                }
                .disabled(!prefs.notchEnabled)
                SettingsDivider()
                SettingsRow(title: "Haptic feedback", detail: "A light tap on Force Touch trackpads when the notch reacts") {
                    Toggle("Haptic feedback", isOn: $prefs.notchHaptics).toggleStyle(.switch).labelsHidden()
                }
                .disabled(!prefs.notchEnabled)
            }
            Text("Music controls work with Spotify and Apple Music. macOS asks once before Lookout can control each player.")
                .font(NFont.caption).foregroundStyle(N.text3).padding(.top, 6)

            Text("Plan limits at a glance").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 8)
            SettingsGroup {
                ForEach(Array(AgentKind.allCases.filter(AgentLimitClients.supportsAccountLimits).enumerated()), id: \.element) { index, agent in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: 12) {
                        AgentIconView(agent: agent, size: 18)
                        Text(agent.name).font(NFont.body).foregroundStyle(N.text)
                        Spacer(minLength: 12)
                        if let position = prefs.limitProviders.firstIndex(of: agent), prefs.limitProviders.count > 1 {
                            Text("Arc \(position + 1)").font(NFont.caption).foregroundStyle(N.text3)
                        }
                        Toggle(agent.name, isOn: Binding(
                            get: { prefs.limitProviders.contains(agent) },
                            set: { _ in prefs.toggleLimitProvider(agent) }
                        ))
                        .toggleStyle(.switch).labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                SettingsDivider()
                SettingsRow(title: "Window per provider", detail: prefs.limitWindowChoice.detail) {
                    Picker("Window per provider", selection: $prefs.limitWindowChoice) {
                        ForEach(LimitWindowChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Text(prefs.limitProviders.isEmpty
                 ? "None chosen: the notch, menu bar, and Dock show whichever limit is closest to running out."
                 : "With two or more, the closed notch shows a ring split into one arc per provider, each filled to its usage.")
                .font(NFont.caption).foregroundStyle(N.text3).padding(.top, 6)

            Text("Agent Peek").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 8)
            SettingsGroup {
                SettingsRow(title: "Floating panel", detail: "Always-on-top glance at running agents") {
                    Toggle("Floating panel", isOn: Binding(
                        get: { prefs.peekVisible },
                        set: { $0 ? LiveSurfaces.shared.showPeek() : LiveSurfaces.shared.hidePeek() }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Show on every Space", detail: "Follows you across desktops and full-screen apps") {
                    Toggle("Show on every Space", isOn: $prefs.peekOnAllSpaces).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Size", detail: "Or drag either side edge of Peek to any width; double-click an edge to snap back. Small keeps one line per agent and limit.") {
                    Picker("Size", selection: $prefs.peekSize) {
                        ForEach(PeekSize.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingsDivider()
                SettingsRow(title: "Small shows", detail: prefs.peekSmallProviders.isEmpty
                            ? "The 5-hour window of every provider that has one"
                            : "The 5-hour window of the providers you tick") {
                    HStack(spacing: 10) {
                        ForEach(AgentKind.allCases.filter(AgentLimitClients.supportsAccountLimits)) { agent in
                            Toggle(isOn: Binding(get: { prefs.peekSmallProviders.contains(agent) },
                                                 set: { _ in prefs.toggleSmallPeekProvider(agent) })) {
                                Text(agent.shortName).font(NFont.small)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Show agents", detail: "The running agents list. Off leaves just the limits") {
                    Toggle("Show agents", isOn: $prefs.peekShowsAgents).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Include limits", detail: "The three plan windows closest to running out") {
                    Toggle("Include limits", isOn: $prefs.peekShowsLimits).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Limit style", detail: "Pie shows a ring with the percentage inside; Line shows a slim bar") {
                    Picker("Limit style", selection: $prefs.peekLimitStyle) {
                        ForEach(PeekLimitStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingsDivider()
                SettingsRow(title: "Glass", detail: "Clear shows more of what's behind; frosted is easier to read on busy backgrounds") {
                    Picker("Glass", selection: $prefs.peekClearGlass) {
                        Text("Clear").tag(true)
                        Text("Frosted").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            if !prefs.peekHiddenAgents.isEmpty {
                HStack(spacing: 6) {
                    Text("Hidden in Peek: \(prefs.peekHiddenAgents.sorted { $0.name < $1.name }.map(\.name).joined(separator: ", "))")
                    Button("Show all") { prefs.peekHiddenAgents = [] }.buttonStyle(.link)
                }
                .font(NFont.caption).foregroundStyle(N.text3).padding(.top, 6)
            }
        }
    }
}

/// Records a system-wide shortcut and suggests combinations nothing else on this Mac uses.
private struct ShortcutRow: View {
    var action: HotKeyAction
    var title: String
    var detail: String
    @ObservedObject var prefs = Preferences.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var conflict: HotKeyConflict?
    @State private var showFinder = false
    @State private var suggestions: [HotKey] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: title, detail: detail) {
                HStack(spacing: 6) {
                    Button(action: toggleRecording) {
                        Text(recording ? "Type a shortcut…" : (current?.display ?? "None"))
                            .font(.system(size: 12.5, weight: .medium, design: recording ? .default : .rounded))
                            .foregroundStyle(recording ? N.blue : (current == nil ? N.text3 : N.text))
                            .frame(minWidth: 96)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(N.bg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(recording ? N.blue : N.pressed, lineWidth: recording ? 1.5 : 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(recording ? "Press Esc to cancel, Delete to clear" : "Click, then press the new shortcut")
                    if current != nil && !recording {
                        IconButton(symbol: "xmark.circle.fill", help: "Remove shortcut", tint: N.text3) {
                            setKey(nil)
                            conflict = nil
                        }
                    }
                    Button {
                        suggestions = GlobalHotKeys.shared.suggestions(for: action)
                        showFinder = true
                    } label: {
                        Label("Find", systemImage: "sparkle.magnifyingglass")
                    }
                    .controlSize(.small)
                    .help("Check this Mac for free shortcuts")
                    .popover(isPresented: $showFinder, arrowEdge: .bottom) { finder }
                }
            }
            if let conflict {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TagColor.orange.fg)
                    Text(conflict.message).foregroundStyle(N.text2)
                }
                .font(NFont.caption)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .onAppear { conflict = current.flatMap { GlobalHotKeys.shared.conflict(for: $0, action: action) } }
        .onDisappear { stopRecording() }
    }

    private var finder: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Free shortcuts").font(NFont.bodyMedium).foregroundStyle(N.text)
                Text("Checked against macOS shortcuts, your App Shortcuts, and global shortcuts other running apps have claimed.")
                    .font(NFont.caption).foregroundStyle(N.text2).fixedSize(horizontal: false, vertical: true)
            }
            if suggestions.isEmpty {
                Text("Nothing free found. Record your own instead.").font(NFont.caption).foregroundStyle(N.text3)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(suggestions) { key in
                        let isCurrent = key == current
                        Button {
                            setKey(key)
                            conflict = nil
                            showFinder = false
                        } label: {
                            Text(key.display)
                                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                .foregroundStyle(isCurrent ? .white : N.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(isCurrent ? N.blue : N.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isCurrent ? "Current shortcut" : "Use \(key.display)")
                    }
                }
            }
            Text("Apps that only handle a shortcut while they're in front aren't visible to this check. Pick one with ⌃ or several modifiers to stay clear of them.")
                .font(NFont.caption).foregroundStyle(N.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var current: HotKey? { prefs.hotKey(for: action) }
    private func setKey(_ key: HotKey?) { prefs.setHotKey(key, for: action) }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        conflict = nil
        GlobalHotKeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(HotKey.relevant)
            if flags.isEmpty && Int(event.keyCode) == kVK_Escape { stopRecording(); return nil }
            if flags.isEmpty && (Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete) {
                setKey(nil)
                stopRecording()
                return nil
            }
            let key = HotKey(keyCode: UInt32(event.keyCode), modifiers: flags)
            guard key.isUsable else { NSSound.beep(); return nil }
            setKey(key)
            stopRecording()
            conflict = GlobalHotKeys.shared.conflict(for: key, action: action)
            return nil
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        GlobalHotKeys.shared.resume()
    }
}

private struct GeneralPane: View {
    @ObservedObject var store: AgentStore
    @ObservedObject private var prefs = Preferences.shared
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
            Text("Power").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 8)
            SettingsGroup {
                SettingsRow(title: "Keep this Mac awake", detail: "Stops idle sleep so long agent runs aren't interrupted. The display can still sleep.") {
                    Picker("Keep this Mac awake", selection: $prefs.keepAwake) {
                        ForEach(KeepAwakeMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
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
                SettingsDivider()
                SettingsRow(title: "When a limit will run out early", detail: "At your current rate, a window empties before it resets") {
                    Toggle("When a limit will run out early", isOn: Binding(
                        get: { prefs.notifyPace },
                        set: { prefs.notifyPace = $0; if $0 { requestPermission() } }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "When a used-up limit resets", detail: "Also drops down from the notch, so you know you can start again") {
                    Toggle("When a used-up limit resets", isOn: Binding(
                        get: { prefs.notifyReset },
                        set: { prefs.notifyReset = $0; if $0 { requestPermission() } }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "When an agent finishes", detail: "A working session hands the turn back to you") {
                    Toggle("When an agent finishes", isOn: Binding(
                        get: { prefs.notifyFinished },
                        set: { prefs.notifyFinished = $0; if $0 { requestPermission() } }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                }
            }
            if notificationsDenied {
                Text("Notifications are turned off for Lookout in System Settings.")
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

struct SettingsPage<Content: View>: View {
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

struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(N.divider))
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(N.divider).frame(height: 1).padding(.leading, 14) }
}

struct SettingsRow<Control: View>: View {
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
