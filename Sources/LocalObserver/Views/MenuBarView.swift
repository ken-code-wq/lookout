import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverShelf

/// Menu bar popover: glance at what's running, open or stop it, start a saved launcher.
struct MenuBarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var agentStore: AgentStore
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat = 0
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject var shelf: ShelfStore = .shared
    @State private var shelfDropTargeted = false

    private var servers: [ServerEntry] {
        state.visibleServers.sorted {
            let fa = state.favorites.contains($0.port), fb = state.favorites.contains($1.port)
            return fa != fb ? fa : $0.port < $1.port
        }
    }
    private var projects: [ServerEntry] { servers.filter { $0.projectType != .app } }
    private var apps: [ServerEntry] { servers.filter { $0.projectType == .app } }
    private var idleLaunchers: [ManagedServer] { state.managed.filter { !state.isRunning($0) } }
    private var agents: [AgentSession] {
        let sessions = agentStore.runningSessions.filter { !($0.process.map { AgentDiscovery.isDesktopApp($0.processName) } ?? false) }
        // Sessions waiting on the user float to the top.
        return Array(sessions.sorted { ($0.needsAttention ? 0 : 1, $1.updatedAt) < ($1.needsAttention ? 0 : 1, $0.updatedAt) }.prefix(6))
    }
    private var limitWindows: [AgentQuotaWindow] {
        // Limited to the providers chosen in Settings › Menu Bar & Notch, when any are.
        Array(agentStore.limitReports.flatMap(\.windows)
            .filter { prefs.limitProviders.isEmpty || prefs.limitProviders.contains($0.agent) }
            .filter { $0.kind == .session || $0.kind == .weekly || $0.kind == .monthly }
            .sorted { $0.usedPercent > $1.usedPercent }
            .prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 10)

            // Everything between the header and the footer scrolls as one list, bounded to the screen's
            // height, so a full agents+limits+servers popover never gets clipped off the bottom of the display.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shownSections.enumerated()), id: \.element) { index, section in
                        if index > 0 { Divider().padding(.horizontal, 10) }
                        sectionView(section)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.top)
            .scrollDisabled(contentHeight <= maxScrollHeight)
            .frame(height: min(contentHeight, maxScrollHeight))

            Divider().padding(.horizontal, 10)
            VStack(spacing: 1) {
                MenuItem(title: "Open Lookout", symbol: "macwindow", shortcut: "o") { showWindow() }
                MenuItem(title: "Agent activity", symbol: "waveform.path.ecg", shortcut: nil) {
                    showWindow()
                    state.sidebar = .agentActivity
                }
                MenuItem(title: prefs.peekVisible ? "Hide Agent Peek" : "Show Agent Peek", symbol: "eye", shortcut: nil,
                         hint: prefs.peekHotKey?.display) {
                    LiveSurfaces.shared.togglePeek()
                }
                MenuItem(title: "New server…", symbol: "plus", shortcut: nil) {
                    showWindow()
                    state.draft = LauncherDraft()
                }
                MenuItem(title: "Quit", symbol: "power", shortcut: "q") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 360)
        // Dropping anything on the panel puts it on the Shelf.
        .onDrop(of: ShelfDrop.types, isTargeted: $shelfDropTargeted) { providers in
            if prefs.isCollapsed(menu: "shelf") { prefs.toggleCollapsed(menu: "shelf") }
            return shelf.add(providers: providers)
        }
        .overlay {
            if shelfDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(N.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(N.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottom) {
                        Label("Drop to keep on the Shelf", systemImage: "tray.and.arrow.down.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(N.blue, in: Capsule())
                            .padding(.bottom, 14)
                    }
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }


    /// Sections in the user's order, skipping hidden ones and ones with nothing to show.
    private var shownSections: [MenuSection] {
        prefs.menuSections.filter { section in
            guard prefs.isVisible(section) else { return false }
            switch section {
            case .today: return agentStore.todayTotals.processed > 0
            case .usage: return agentStore.hasUsageHistory
            case .sound: return true
            case .agents: return !agents.isEmpty
            case .limits: return !limitWindows.isEmpty
            case .servers: return true
            case .launchers: return !idleLaunchers.isEmpty
            // Always shown, like Servers: its empty state says what the section is for.
            case .shelf: return true
            }
        }
    }

    @ViewBuilder private func sectionView(_ section: MenuSection) -> some View {
        switch section {
        case .today:
            SectionLabel("Today", key: "today", summary: AgentFormat.compact(Double(agentStore.todayTotals.processed)) + " tokens")
            if !prefs.isCollapsed(menu: "today") {
                MenuTodayCard(totals: agentStore.todayTotals) {
                    showWindow()
                    agentStore.filter.setPreset(.today)
                    state.sidebar = .agentUsage
                }
            }
        case .usage:
            SectionLabel("Usage", key: "usage", summary: usageSummary)
            if !prefs.isCollapsed(menu: "usage") {
                GlanceUsageChart(store: agentStore) {
                    showWindow()
                    agentStore.filter = agentStore.glanceFilter
                    state.sidebar = .agentUsage
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
        case .sound:
            SectionLabel("Sound", key: "sound", summary: soundSummary)
            if !prefs.isCollapsed(menu: "sound") {
                SoundMixerView(maxRows: 5)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }
        case .agents:
            SectionLabel("Agents", key: "agents", summary: agentsSummary)
            if !prefs.isCollapsed(menu: "agents") {
                VStack(spacing: 1) {
                    ForEach(agents) { agent in
                        MenuAgentRow(agent: agent) {
                            if !AgentActions.jump(to: agent) {
                                showWindow()
                                state.sidebar = .agentActivity
                                agentStore.selectedSessionID = agent.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        case .limits:
            SectionLabel("Limits", key: "limits", summary: limitWindows.first.map { "\(Int($0.usedPercent.rounded()))% \($0.agent.shortName)" })
            if !prefs.isCollapsed(menu: "limits") {
                VStack(spacing: 7) {
                    ForEach(limitWindows) { MenuLimitRow(window: $0) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
                .onTapGesture {
                    showWindow()
                    state.sidebar = .agentLimits
                }
            }
        case .servers:
            if servers.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz").font(.system(size: 18, weight: .light)).foregroundStyle(.tertiary)
                    Text("Nothing running").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                serverGroup("Projects", key: "projects", projects)
                serverGroup("Apps", key: "apps", apps)
            }
        case .launchers:
            SectionLabel("Launchers", key: "launchers", summary: "\(idleLaunchers.count)")
            if !prefs.isCollapsed(menu: "launchers") {
                VStack(spacing: 1) {
                    ForEach(idleLaunchers.prefix(6)) { l in
                        MenuLauncherRow(state: state, launcher: l)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        case .shelf:
            shelfSection
        }
    }

    @ViewBuilder private var shelfSection: some View {
        SectionLabel("Shelf", key: "shelf", summary: shelf.shelf.isEmpty ? "empty" : "\(shelf.shelf.count)")
        if !prefs.isCollapsed(menu: "shelf") {
            ShelfMenuContent(store: shelf) { LiveSurfaces.shared.toggleMenuBarPanel() }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
    }

    @ViewBuilder private func serverGroup(_ title: String, key: String, _ entries: [ServerEntry]) -> some View {
        if !entries.isEmpty {
            SectionLabel(title, key: key, summary: "\(entries.count)")
            if !prefs.isCollapsed(menu: key) {
                VStack(spacing: 1) {
                    ForEach(entries) { MenuServerRow(state: state, server: $0) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
    }

    private var soundSummary: String {
        let playing = AppAudio.shared.apps.filter(\.isPlaying).count
        return playing == 0 ? "quiet" : "\(playing) playing"
    }

    private var usageSummary: String {
        let report = agentStore.glanceUsage
        return "\(AgentFormat.metric(report.totals.value(for: agentStore.glanceMetric), agentStore.glanceMetric)) · \(agentStore.glanceRange.longTitle.lowercased())"
    }

    /// Shown beside a folded Agents header so waiting sessions aren't missed.
    private var agentsSummary: String {
        let waiting = agents.filter(\.needsAttention).count
        return waiting > 0 ? "\(agents.count), \(waiting) need\(waiting == 1 ? "s" : "") you" : "\(agents.count)"
    }

    /// Leaves room for the header, divider, and footer so the popover fits under the menu bar on any display.
    private var maxScrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(screen - 260, 260)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Local activity").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Circle().fill(state.respondingCount > 0 || !agents.isEmpty ? N.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(headerSummary)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            Button {
                state.refresh()
                agentStore.refresh(quiet: true)
            } label: {
                Group {
                    if state.isScanning || agentStore.isScanning { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuHoverStyle())
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var headerSummary: String {
        var parts = ["\(servers.count) server\(servers.count == 1 ? "" : "s")", "\(agents.count) agent\(agents.count == 1 ? "" : "s")"]
        let urgent = agentStore.attentionSessions.count
        if urgent > 0 { parts.append("\(urgent) need\(urgent == 1 ? "s" : "") you") }
        return parts.joined(separator: ", ")
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Section title that folds its rows away when clicked. While folded it shows a one-line summary.
private struct SectionLabel: View {
    var text: String
    var key: String
    var summary: String?
    @ObservedObject private var prefs = Preferences.shared
    @State private var hover = false

    init(_ text: String, key: String, summary: String? = nil) {
        self.text = text
        self.key = key
        self.summary = summary
    }

    var body: some View {
        let collapsed = prefs.isCollapsed(menu: key)
        Button { withAnimation(.snappy(duration: 0.2)) { prefs.toggleCollapsed(menu: key) } } label: {
            HStack(spacing: 5) {
                Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if collapsed, let summary {
                    Text(summary).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .opacity(hover || collapsed ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, collapsed ? 8 : 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(collapsed ? "Expand \(text)" : "Collapse \(text)")
    }
}

private struct MenuServerRow: View {
    @ObservedObject var state: AppState
    var server: ServerEntry
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            FaviconView(server: server, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(server.projectName).font(.system(size: 13)).lineLimit(1)
                Text(server.isResponding ? "\(server.latencyMs)ms · \(server.uptimeText)" : "TCP · \(server.processName)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
            Spacer(minLength: 6)
            if hover {
                HStack(spacing: 0) {
                    Button { state.copy(server.urlString, label: server.urlString) } label: {
                        Image(systemName: "doc.on.doc").frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(MenuHoverStyle()).help("Copy URL")
                    Button { state.stop(server) } label: {
                        Image(systemName: "stop.fill").foregroundStyle(N.red).frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(MenuHoverStyle()).help("Stop")
                }
                .font(.system(size: 11))
                .transition(.opacity)
            }
            Text(verbatim: ":\(server.port)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(server.isResponding ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Circle()
                .fill(server.isResponding ? N.green : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
        .onTapGesture { state.open(server) }
        .contextMenu { ServerMenu(state: state, server: server) }
        .help("Open \(server.urlString)")
    }
}

private struct MenuAgentRow: View {
    var agent: AgentSession
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AgentIconView(agent: agent.agent, size: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(agent.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(agent.projectName + (agent.process?.host.map { ", \($0.name)" } ?? ""))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                HostAppIcon(session: agent, size: 16)
                AgentStateTag(state: agent.state)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(agent.process?.host.map { "Jump to \($0.name)" } ?? "Show in Lookout")
    }
}

private struct MenuLimitRow: View {
    var window: AgentQuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AgentIconView(agent: window.agent, size: 12)
                Text("\(window.agent.shortName) \(window.label.lowercased())")
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(AgentFormat.resetText(window.resetsAt))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            LimitMeter(window: window, height: 4)
        }
    }
}

private struct MenuLauncherRow: View {
    @ObservedObject var state: AppState
    var launcher: ManagedServer
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            FolderIconView(folder: launcher.workingDirectory, name: launcher.name, size: 18)
            Text(launcher.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            Image(systemName: "play.fill")
                .font(.system(size: 10))
                .foregroundStyle(hover ? AnyShapeStyle(N.blue) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { state.start(launcher) }
        .help("Start \(launcher.command)")
    }
}

private struct MenuItem: View {
    var title: String
    var symbol: String
    var shortcut: Character?
    var hint: String? = nil
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 18).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut { Text("⌘" + String(shortcut).uppercased()).font(.system(size: 12)).foregroundStyle(.tertiary) }
                else if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CommandShortcut(key: shortcut))
        .onHover { hover = $0 }
    }
}

private struct MenuHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuHoverBody(configuration: configuration)
    }
    private struct MenuHoverBody: View {
        var configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(configuration.isPressed ? Color.primary.opacity(0.12) : (hover ? Color.primary.opacity(0.07) : .clear),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .onHover { hover = $0 }
        }
    }
}

private struct CommandShortcut: ViewModifier {
    var key: Character?
    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(KeyEquivalent(key), modifiers: .command) } else { content }
    }
}

/// Today at a glance: tokens, cost, requests, and cache hit rate since midnight.
private struct MenuTodayCard: View {
    var totals: AgentUsageTotals
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                stat("Tokens", AgentFormat.compact(Double(totals.processed)))
                stat(totals.costIsEstimated ? "Est. cost" : "Cost", totals.hasCost ? AgentFormat.cost(totals.cost) : "–")
                stat("Requests", totals.requests.formatted())
                stat("Cache hits", totals.cacheHitRate.map { AgentFormat.percent($0, digits: 0) } ?? "–")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open today's usage")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
