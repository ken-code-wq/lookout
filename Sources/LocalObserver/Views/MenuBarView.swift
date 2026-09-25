import SwiftUI
import AppKit
import LocalObserverCore

/// Menu bar popover: glance at what's running, open or stop it, start a saved launcher.
struct MenuBarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var agentStore: AgentStore
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat = 0

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
        Array(agentStore.limitReports.flatMap(\.windows)
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
                    if !agents.isEmpty {
                        SectionLabel("Agents")
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
                        Divider().padding(.horizontal, 10)
                    }

                    if !limitWindows.isEmpty {
                        SectionLabel("Limits")
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
                        Divider().padding(.horizontal, 10)
                    }

                    if servers.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "moon.zzz").font(.system(size: 18, weight: .light)).foregroundStyle(.tertiary)
                            Text("Nothing running").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            if !projects.isEmpty {
                                if !apps.isEmpty { SectionLabel("Projects").padding(.leading, -8) }
                                ForEach(projects) { MenuServerRow(state: state, server: $0) }
                            }
                            if !apps.isEmpty {
                                if !projects.isEmpty { SectionLabel("Apps").padding(.leading, -8) }
                                ForEach(apps) { MenuServerRow(state: state, server: $0) }
                            }
                        }
                        .padding(6)
                    }

                    if !idleLaunchers.isEmpty {
                        Divider().padding(.horizontal, 10)
                        SectionLabel("Launchers")
                        VStack(spacing: 1) {
                            ForEach(idleLaunchers.prefix(6)) { l in
                                MenuLauncherRow(state: state, launcher: l)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
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
                MenuItem(title: "Open Local Observer", symbol: "macwindow", shortcut: "o") { showWindow() }
                MenuItem(title: "Agent activity", symbol: "waveform.path.ecg", shortcut: nil) {
                    showWindow()
                    state.sidebar = .agentActivity
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

private struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
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
                AgentStateTag(state: agent.state)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(agent.process?.host.map { "Jump to \($0.name)" } ?? "Show in Local Observer")
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
                    .frame(width: 34, alignment: .trailing)
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
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 18).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut { Text("⌘" + String(shortcut).uppercased()).font(.system(size: 12)).foregroundStyle(.tertiary) }
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
