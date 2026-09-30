import SwiftUI
import UniformTypeIdentifiers
import LocalObserverCore
import LocalObserverShelf

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var agentStore: AgentStore
    @State private var dropTargeted = false
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var windowWidth: CGFloat = 1200
    @State private var autoCollapsed = false
    @AppStorage("LocalObserver.inspectorWidth") private var inspectorWidth: Double = 340

    private var searchBinding: Binding<String> {
        isAgentHub ? $agentStore.searchText : $state.searchText
    }

    private var isAgentHub: Bool { state.sidebar.isAgentPage }
    private var inspectingServer: ServerEntry? {
        state.sidebar == .launchers || state.sidebar == .home || isAgentHub ? nil : state.selected
    }
    private var inspectingAgent: AgentSession? { state.sidebar == .agentActivity ? agentStore.selectedSession : nil }
    private var isInspecting: Bool { inspectingServer != nil || inspectingAgent != nil }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(state: state, agentStore: agentStore)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            HStack(spacing: 0) {
                page
                if let session = inspectingAgent {
                    InspectorPanel(width: $inspectorWidth) {
                        AgentInspectorView(store: agentStore, session: session)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if let server = inspectingServer {
                    InspectorPanel(width: $inspectorWidth) {
                        InspectorView(state: state, server: server)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.28), value: isInspecting)
        }
        .searchable(text: searchBinding, placement: .toolbar, prompt: isAgentHub ? "Search agent, project, model" : "Search port, project, folder…")
        .toolbar { toolbar }
        .navigationTitle(state.sidebar.title)
        .sheet(item: $state.draft) { draft in
            LauncherSheet(state: state, draft: draft)
        }
        .frame(minWidth: 760, minHeight: 540)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { windowWidth = $0 }
        .onChange(of: isInspecting) { _, open in
            // Sidebar + page + inspector don't fit in a narrow window: tuck the sidebar away while inspecting.
            if open, windowWidth < 220 + 600 + inspectorWidth, columns != .detailOnly {
                withAnimation(.snappy(duration: 0.28)) { columns = .detailOnly }
                autoCollapsed = true
            } else if !open, autoCollapsed {
                withAnimation(.snappy(duration: 0.28)) { columns = .all }
                autoCollapsed = false
            }
        }
    }

    private var page: some View {
        Group {
            if state.sidebar == .home {
                HomePage(state: state, agentStore: agentStore, shelf: ShelfStore.shared)
            } else if state.sidebar == .launchers {
                LaunchersPage(state: state)
            } else if state.sidebar == .agentActivity {
                AgentActivityPage(store: agentStore)
            } else if state.sidebar == .agentUsage {
                AgentUsagePage(store: agentStore)
            } else if state.sidebar == .agentLimits {
                AgentLimitsPage(store: agentStore)
            } else {
                ServersPage(state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(N.bg)
        .overlay { if !isAgentHub && dropTargeted { DropOverlay() } }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                ToastView(toast: toast,
                          onAction: { toast.action?(); state.dismissToast() },
                          onClose: { state.dismissToast() })
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !isAgentHub else { return false }
            guard let folder = urls.first(where: \.hasDirectoryPath) ?? urls.first.map({ $0.deletingLastPathComponent() }) else { return false }
            state.draftLauncher(folder: folder.path)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { dropTargeted = targeted }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                isAgentHub ? agentStore.refresh(forceLimits: state.sidebar == .agentLimits) : state.refresh()
            } label: {
                if isAgentHub ? agentStore.isScanning : state.isScanning {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .help("Refresh now (⌘R)")

            if isAgentHub {
                SettingsLink {
                    Label("Agent settings", systemImage: "gearshape")
                }
                .help("Choose which agents to watch (⌘,)")
            } else {
                Button {
                    state.draft = LauncherDraft()
                } label: {
                    Label("New server", systemImage: "plus")
                }
                .help("Start a new server (⌘N)")
            }
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            N.blue.opacity(0.06)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(N.blue.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(12)
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.plus").font(.system(size: 28)).foregroundStyle(N.blue)
                Text("Drop a project folder to start it").font(.system(size: 15, weight: .semibold)).foregroundStyle(N.text)
                Text("We’ll read package.json, manage.py, go.mod… and suggest a command.")
                    .font(NFont.small).foregroundStyle(N.text2)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var agentStore: AgentStore

    var body: some View {
        List(selection: sidebarBinding) {
            Section {
                row(.home)
                row(.all)
                row(.favorites)
                row(.launchers)
            }
            Section("Agents") {
                row(.agentActivity)
                row(.agentUsage)
                row(.agentLimits)
            }
            Section("Stack") {
                ForEach(TypeGroup.allCases) { row(.group($0)) }
            }
            if !state.managed.isEmpty {
                Section("Launchers") {
                    ForEach(state.managed) { launcher in
                        LauncherSidebarRow(state: state, launcher: launcher)
                    }
                    .onMove { state.moveLaunchers(from: $0, to: $1) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var sidebarBinding: Binding<SidebarItem?> {
        Binding(get: { state.sidebar }, set: { if let v = $0 { state.sidebar = v } })
    }

    private func row(_ item: SidebarItem) -> some View {
        Label {
            HStack {
                Text(item.title)
                Spacer()
                let n = count(for: item)
                let urgent = attention(for: item)
                if urgent > 0 {
                    Text("\(urgent)")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(TagColor.orange.fg)
                        .padding(.horizontal, 5).frame(height: 16)
                        .background(TagColor.orange.bg, in: Capsule())
                        .help("\(urgent) need\(urgent == 1 ? "s" : "") you")
                } else if n > 0 {
                    Text("\(n)").font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
        } icon: {
            Image(systemName: item.symbol)
        }
        .tag(item)
    }

    private func count(for item: SidebarItem) -> Int {
        item == .agentActivity ? agentStore.runningSessions.count : state.count(for: item)
    }

    /// Orange count of sessions waiting on the user; shown instead of the running count when non-zero.
    private func attention(for item: SidebarItem) -> Int {
        item == .agentActivity ? agentStore.attentionSessions.count : 0
    }

    private var footer: some View {
        Group {
            if state.sidebar.isAgentPage {
                HStack(spacing: 8) {
                    Circle()
                        .fill(agentStore.settings.autoRefresh ? N.green : N.text3)
                        .frame(width: 7, height: 7)
                    RelativeTimeText(date: agentStore.lastRefresh)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Live", isOn: Binding(
                        get: { agentStore.settings.autoRefresh },
                        set: { enabled in
                            var settings = agentStore.settings
                            settings.autoRefresh = enabled
                            agentStore.saveSettings(settings)
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Refresh agents every 15 seconds")
                }
            } else {
                HStack(spacing: 8) {
                    Circle()
                        .fill(state.autoRefresh ? N.green : N.text3)
                        .frame(width: 7, height: 7)
                    RelativeTimeText(date: state.lastScan)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Live", isOn: $state.autoRefresh)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help("Refresh every 4 seconds")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct LauncherSidebarRow: View {
    @ObservedObject var state: AppState
    var launcher: ManagedServer

    var body: some View {
        let running = state.server(for: launcher) != nil
        HStack(spacing: 8) {
            FolderIconView(folder: launcher.workingDirectory, name: launcher.name, size: 16)
            Text(launcher.name).lineLimit(1)
            Spacer()
            Circle().fill(running ? N.green : Color.clear).frame(width: 6, height: 6)
        }
        .contextMenu { LauncherMenu(state: state, launcher: launcher) }
        .onTapGesture(count: 2) { running ? state.stop(launcher) : state.start(launcher) }
        .help(running ? "Running — double-click to stop" : "Double-click to start")
    }
}

struct LauncherMenu: View {
    @ObservedObject var state: AppState
    var launcher: ManagedServer

    var body: some View {
        if state.isRunning(launcher) {
            if let s = state.server(for: launcher) { Button("Open in Browser") { state.open(s) } }
            Button("Restart") { state.restart(launcher) }
            Button("Stop") { state.stop(launcher) }
        } else {
            Button("Start") { state.start(launcher) }
        }
        Divider()
        Button("Edit…") { state.edit(launcher) }
        Button("Show Log") { NSWorkspace.shared.open(URL(fileURLWithPath: launcher.logPath)) }
        Button("Reveal in Finder") { ProcessManager.reveal(path: launcher.workingDirectory) }
        Divider()
        Button("Remove", role: .destructive) { state.remove(launcher) }
    }
}

/// Right-hand panel with a draggable leading edge.
private struct InspectorPanel<Content: View>: View {
    @Binding var width: Double
    @ViewBuilder var content: Content
    @State private var dragStart: Double? = nil
    @State private var hoverHandle = false

    var body: some View {
        content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(N.bg)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(hoverHandle || dragStart != nil ? N.blue.opacity(0.5) : N.divider)
                    .frame(width: hoverHandle || dragStart != nil ? 2 : 1)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .offset(x: -4)
                    .onHover { h in
                        hoverHandle = h
                        if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                let start = dragStart ?? width
                                dragStart = start
                                width = min(max(start - v.translation.width, 300), 520)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .animation(.easeOut(duration: 0.12), value: hoverHandle)
            }
    }
}
