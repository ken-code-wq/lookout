import AppKit
import SwiftUI
import Combine
import LocalObserverCore
import LocalObserverWidgetUI
import LocalObserverRepos

/// Everything that lives outside the main window: Dock badge, live Dock icon, Dock menu, and the floating Peek panel.
@MainActor
final class LiveSurfaces: NSObject, NSWindowDelegate {
    static let shared = LiveSurfaces()

    private weak var state: AppState?
    private weak var agentStore: AgentStore?
    private var openWindow: ((SidebarItem) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private var panel: NSPanel?
    private var dockTile: NSHostingView<DockTileView>?
    private var lastDockState: String?
    /// Edges the panel keeps while its content grows or shrinks: always the top (AppKit would otherwise pin the
    /// bottom), and whichever side is nearer its screen's edge, so a Peek parked top-right stays there as it narrows.
    private var panelAnchor: (top: CGFloat, left: CGFloat, right: CGFloat)?
    /// While a side edge of Peek is dragged, the opposite edge stays put.
    private var resizePin: HorizontalEdge?
    private let prefs = Preferences.shared
    /// A widget link that arrived before the menu bar label attached the stores (cold launch from a widget).
    private var pendingURLs: [URL] = []

    func attach(state: AppState, agentStore: AgentStore, openMain: @escaping (SidebarItem) -> Void) {
        openWindow = openMain
        guard self.state == nil else { return }
        self.state = state
        self.agentStore = agentStore

        // Dock/widget surfaces don't need to track every store write: throttle (not debounce, which constant
        // churn would starve) so they refresh at most every few seconds.
        Publishers.Merge(
            state.objectWillChange.map { _ in () },
            agentStore.objectWillChange.map { _ in () }
        )
        .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] in self?.update() }
        .store(in: &cancellables)
        // Settings changes should show up promptly.
        prefs.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &cancellables)

        prefs.$showDockIcon
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { show in
                NSApp.setActivationPolicy(show ? .regular : .accessory)
                if !show { NSApp.activate(ignoringOtherApps: true) }
            }
            .store(in: &cancellables)
        prefs.$peekOnAllSpaces
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyPanelBehavior() }
            .store(in: &cancellables)
        prefs.$peekHotKey
            .removeDuplicates()
            .sink { GlobalHotKeys.shared.register(.peek, $0) }
            .store(in: &cancellables)
        prefs.$menuBarHotKey
            .removeDuplicates()
            .sink { GlobalHotKeys.shared.register(.menuBar, $0) }
            .store(in: &cancellables)
        prefs.$notchHotKey
            .removeDuplicates()
            .sink { GlobalHotKeys.shared.register(.notch, $0) }
            .store(in: &cancellables)
        prefs.$shelfHotKey
            .removeDuplicates()
            .sink { GlobalHotKeys.shared.register(.shelf, $0) }
            .store(in: &cancellables)

        // Repo actions (fetch, pull, cleanup) report back as toasts in the main window.
        RepoStore.shared.onActionResult = { [weak state] message, ok in
            state?.show(Toast(message: message, symbol: ok ? "checkmark.circle" : "exclamationmark.triangle", tone: ok ? .success : .danger))
        }
        DiskCoordinator.shared.attach(state: state, agentStore: agentStore)
        BudgetNotifier.shared.attach(to: agentStore)
        LimitRouteNotifier.shared.attach(to: agentStore)
        CICoordinator.shared.attach(state: state)
        GitHubStore.shared.onActionResult = { [weak state] message, ok in
            state?.show(Toast(message: message, symbol: ok ? "checkmark.circle" : "exclamationmark.triangle", tone: ok ? .success : .danger))
        }
        RepoStore.shared.objectWillChange
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.update() }
            .store(in: &cancellables)

        if prefs.peekVisible { showPeek() }
        NotchController.shared.attach(state: state, agentStore: agentStore)
        AppAudio.shared.start()
        update()
        pendingURLs.forEach(handle)
        pendingURLs = []
    }

    // MARK: Widget links

    /// `localobserver://activity|usage|limits|servers|shelf`, and `localobserver://session?id=…` to jump to a session.
    func handle(_ url: URL) {
        guard url.scheme == WidgetLink.scheme else { return }
        guard let agentStore else {
            pendingURLs.append(url)
            return
        }
        switch url.host {
        case "usage": openMain(.agentUsage)
        case "limits": openMain(.agentLimits)
        case "servers": openMain(.all)
        case "repos": openMain(.repos)
        case "pulls": openMain(.pullRequests)
        case "github": openMain(.github)
        case "cleanup": openMain(.cleanup)
        case "ci": openMain(.ci)
        // The shelf lives in the notch; without one, the menu bar panel has it.
        case "shelf": if !NotchController.shared.openShelf(.shelf) { toggleMenuBarPanel() }
        case "session":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            let session = agentStore.runningSessions.first { $0.id == id }
            // Straight to the terminal it runs in when we can; otherwise select it on the Activity page.
            if let session, AgentActions.jump(to: session) { return }
            agentStore.selectedSessionID = session?.id
            openMain(.agentActivity)
        default: openMain(.agentActivity)
        }
    }

    // MARK: Main window

    func toast(_ message: String, ok: Bool = true) {
        state?.show(Toast(message: message, symbol: ok ? "checkmark.circle" : "exclamationmark.triangle", tone: ok ? .success : .danger))
    }

    /// Opens the main window with a session's replay on top.
    func replay(_ session: AgentSession) {
        openMain(state?.sidebar ?? .agentActivity)
        state?.replaySession = session
    }

    func openMain(_ page: SidebarItem) {
        state?.sidebar = page
        openWindow?(page)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Dock

    private var running: [AgentSession] {
        (agentStore?.runningSessions ?? []).filter { !($0.process.map { AgentDiscovery.isDesktopApp($0.processName) } ?? false) }
    }

    private func update() {
        guard let agentStore, let state else { return }
        WidgetPublisher.shared.schedule(state: state, agentStore: agentStore)
        let attention = agentStore.attentionSessions.count
        let agents = running.count
        let limit = glanceWindow(agentStore)?.usedPercent
        let badge: String?
        switch prefs.dockBadge {
        case .none: badge = nil
        case .attention: badge = attention > 0 ? "\(attention)" : nil
        case .agents: badge = agents > 0 ? "\(agents)" : nil
        case .servers: badge = state.visibleServers.isEmpty ? nil : "\(state.visibleServers.count)"
        case .limit: badge = limit.map { "\(Int($0.rounded()))%" }
        case .pullRequests:
            let count = RepoStore.shared.pullsNeedingYou.count
            badge = count > 0 ? "\(count)" : nil
        }
        let peek = prefs.dockIconStyle == .peek
        // Store changes fire this constantly; only touch the Dock tile when its content actually moved.
        let key = "\(badge ?? "")|\(peek ? "\(agents):\(attention):\(limit.map { Int($0.rounded()) } ?? -1)" : "-")"
        guard key != lastDockState else { return }
        lastDockState = key

        let tile = NSApp.dockTile
        tile.badgeLabel = badge
        if peek, let icon = NSApp.applicationIconImage {
            let view = dockTile ?? {
                let v = NSHostingView(rootView: DockTileView(icon: icon, agents: agents, attention: attention, limitPercent: limit))
                v.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
                dockTile = v
                return v
            }()
            view.rootView = DockTileView(icon: icon, agents: agents, attention: attention, limitPercent: limit)
            tile.contentView = view
        } else if tile.contentView != nil {
            tile.contentView = nil
            dockTile = nil
        }
        tile.display()
    }

    private func glanceWindow(_ store: AgentStore) -> AgentQuotaWindow? {
        prefs.glanceWindows(from: store.limitReports.flatMap(\.windows)).max { $0.usedPercent < $1.usedPercent }
    }

    /// Right-click menu on the Dock icon: running agents to jump to, servers to open, and quick actions.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        let sessions = running.sorted { ($0.needsAttention ? 0 : 1) < ($1.needsAttention ? 0 : 1) }
        if !sessions.isEmpty {
            menu.addItem(header("Agents"))
            for session in sessions.prefix(10) {
                let title = "\(session.needsAttention ? "✋ " : "")\(session.agent.shortName): \(session.title)"
                let item = ActionItem(title: title) { [weak self] in
                    if !AgentActions.jump(to: session) {
                        self?.agentStore?.selectedSessionID = session.id
                        self?.openMain(.agentActivity)
                    }
                }
                item.toolTip = "\(session.state.title), \(session.projectName)"
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let servers = (state?.visibleServers ?? []).filter { $0.projectType != .app }.sorted { $0.port < $1.port }
        if !servers.isEmpty {
            menu.addItem(header("Servers"))
            for server in servers.prefix(10) {
                menu.addItem(ActionItem(title: ":\(server.port)  \(server.projectName)") { ProcessManager.openURL(server.urlString) })
            }
            menu.addItem(.separator())
        }
        if let today = agentStore?.todayTotals, today.processed > 0 {
            let cost = today.hasCost ? ", \(AgentFormat.cost(today.cost, estimated: today.costIsEstimated))" : ""
            let item = ActionItem(title: "Today: \(AgentFormat.compact(Double(today.processed))) tokens\(cost)") { [weak self] in
                self?.openMain(.agentUsage)
            }
            menu.addItem(item)
        }
        let peek = ActionItem(title: prefs.peekVisible ? "Hide Agent Peek" : "Show Agent Peek") { [weak self] in self?.togglePeek() }
        if let key = prefs.peekHotKey { peek.toolTip = key.display }
        menu.addItem(peek)
        menu.addItem(ActionItem(title: "Refresh") { [weak self] in
            self?.state?.refresh()
            self?.agentStore?.refresh(forceLimits: true)
        })
        return menu
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Menu bar panel

    /// Clicks Local Observer's status item, which opens (or closes) the menu bar panel just like a mouse click.
    func toggleMenuBarPanel() {
        // No activate() first: activating races the click and brings the main window forward too.
        statusItemButton()?.performClick(nil)
    }

    /// SwiftUI's MenuBarExtra doesn't expose its NSStatusItem, so find the button in the status bar window it owns.
    private func statusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = Self.findButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let found = findButton(in: sub) { return found } }
        return nil
    }

    // MARK: Peek panel

    func togglePeek() {
        if panel?.isVisible == true { hidePeek() } else { showPeek() }
    }

    func showPeek() {
        guard let state, let agentStore else { return }
        if panel == nil {
            // Borderless and clear: the SwiftUI view draws the whole Liquid Glass slab, the window only casts its shadow.
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 336, height: 200),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.setFrameAutosaveName("LocalObserver.AgentPeek")
            panel.delegate = self
            let host = NSHostingView(rootView: AgentPeekView(agentStore: agentStore, state: state) { [weak self] page in
                self?.openMain(page)
            })
            host.sizingOptions = [.preferredContentSize]
            host.wantsLayer = true
            host.layer?.backgroundColor = .clear
            panel.contentView = host
            if !panel.setFrameUsingName("LocalObserver.AgentPeek"), let screen = NSScreen.main?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 352, y: screen.maxY - 12))
            }
            self.panel = panel
        }
        applyPanelBehavior()
        recordAnchor()
        panel?.orderFrontRegardless()
        prefs.peekVisible = true
    }

    func hidePeek() {
        panel?.orderOut(nil)
        prefs.peekVisible = false
    }

    private func applyPanelBehavior() {
        panel?.collectionBehavior = prefs.peekOnAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
    }

    func beginPeekResize(pinning edge: HorizontalEdge) {
        recordAnchor()
        resizePin = edge
    }

    func endPeekResize() {
        resizePin = nil
        recordAnchor()
    }

    private func recordAnchor() {
        guard let frame = panel?.frame else { return }
        panelAnchor = (frame.maxY, frame.minX, frame.maxX)
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in self.recordAnchor() }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        Task { @MainActor in
            guard let panel = self.panel else { return }
            // The shadow follows the glass shape; recompute it when the content changes size.
            panel.invalidateShadow()
            guard let anchor = self.panelAnchor, !panel.inLiveResize else { return }
            let screen = (panel.screen ?? NSScreen.main)?.visibleFrame
            let pinRight = self.resizePin.map { $0 == .trailing }
                ?? screen.map { (anchor.left + anchor.right) / 2 > $0.midX } ?? false
            let x = pinRight ? anchor.right - panel.frame.width : anchor.left
            guard abs(panel.frame.maxY - anchor.top) > 0.5 || abs(panel.frame.minX - x) > 0.5 else { return }
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.top))
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in Preferences.shared.peekVisible = false }
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
