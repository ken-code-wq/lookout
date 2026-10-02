import AppKit
import SwiftUI
import Combine
import LocalObserverCore

/// Transient drop-down from the notch, e.g. "Claude Code needs you".
struct NotchAlert: Equatable, Identifiable {
    enum Kind { case needsYou, failed, finished, limit, reset }
    var id: String
    var kind: Kind
    var agent: AgentKind?
    var title: String
    var detail: String
    var badge: String
    var sessionID: String?
}

/// Borderless panel that leaves keyboard focus with the app you're working in. While open it may take it, but only
/// for a text field (the Shelf's search), and gives it back when it closes.
final class NotchPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Owns the notch overlay: finds the notch (or draws a virtual one), tracks the mouse, and raises alerts.
@MainActor
final class NotchController: ObservableObject {
    static let shared = NotchController()

    enum Mode: Equatable { case compact, alert, hud(SystemControls.HUDKind), expanded }

    @Published private(set) var mode: Mode = .compact
    @Published private(set) var alert: NotchAlert?
    /// The camera housing (or virtual pill) in points.
    @Published private(set) var notchSize = CGSize(width: 185, height: 32)
    @Published private(set) var isPhysicalNotch = false
    /// Mouse is over the closed notch: it swells slightly as a hint.
    @Published private(set) var isHovering = false

    /// Pointer is resting on the closed notch's limit ring: show its detail card instead of opening.
    @Published private(set) var isHoveringLimit = false
    /// The limit ring's frame in the panel's content coordinates (top-left origin), reported by the view.
    var limitRingFrame: CGRect = .zero

    /// Size of the black shape as drawn, reported by the view so hit-testing matches what's on screen.
    var shapeSize: CGSize = .zero

    /// Fixed canvas big enough for the widest open notch (640pt at 130% width) plus its shadow.
    static let panelSize = CGSize(width: 880, height: 540)

    private weak var state: AppState?
    private weak var agentStore: AgentStore?
    private var panel: NotchPanel?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var hoverSince: Date?
    private var outsideSince: Date?
    private var menuOpen = false
    /// Closing on mouse-exit only applies once the pointer has been inside, so a shortcut-opened notch stays put.
    private var pointerEntered = false
    private var clickMonitor: Any?
    private var alertTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var lastBuckets: [String: AgentActivityBucket] = [:]
    private var primed = false
    private let prefs = Preferences.shared
    /// The system drag pasteboard's count while no button is down. A new count with the button held is a drag.
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragBaseline = 0

    func attach(state: AppState, agentStore: AgentStore) {
        guard self.state == nil else { return }
        self.state = state
        self.agentStore = agentStore

        Publishers.Merge3(prefs.$notchEnabled.map { _ in () }, prefs.$notchOnPlainDisplays.map { _ in () },
                          prefs.$notchWidth.removeDuplicates().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        // Menus opened from the notch take the mouse outside it; don't close underneath them.
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.menuOpen = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in self?.menuOpen = false; self?.outsideSince = nil }
            .store(in: &cancellables)
        agentStore.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkSessions() }
            .store(in: &cancellables)
        // No pointer to watch while the display sleeps or the session is switched away.
        let workspace = NSWorkspace.shared.notificationCenter
        Publishers.Merge(workspace.publisher(for: NSWorkspace.screensDidSleepNotification),
                         workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification))
            .sink { [weak self] _ in self?.pausePolling() }
            .store(in: &cancellables)
        Publishers.Merge(workspace.publisher(for: NSWorkspace.screensDidWakeNotification),
                         workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification))
            .sink { [weak self] _ in self?.resumePolling() }
            .store(in: &cancellables)
        SystemControls.shared.start()
        SystemControls.shared.externalChange
            .sink { [weak self] kind in self?.showHUD(kind) }
            .store(in: &cancellables)
        MediaController.shared.start()
        KeepAwake.shared.attach(to: agentStore)
        rebuild()
    }

    // MARK: Placement

    /// The screen with a camera notch, or the menu bar screen with a virtual notch when allowed.
    static func locate(allowPlain: Bool, widthScale: Double = 1) -> (screen: NSScreen, rect: CGRect, physical: Bool)? {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = max(screen.frame.width - left - right, 120)
            let height = screen.safeAreaInsets.top
            return (screen, CGRect(x: screen.frame.minX + left, y: screen.frame.maxY - height, width: width, height: height), true)
        }
        guard allowPlain, let screen = NSScreen.screens.first else { return nil }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let height = min(max(menuBar, 24), 32)
        let width = 185 * CGFloat(widthScale)
        return (screen, CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), false)
    }

    private func rebuild() {
        guard prefs.notchEnabled, let spot = Self.locate(allowPlain: prefs.notchOnPlainDisplays, widthScale: prefs.notchWidth) else {
            teardown()
            return
        }
        notchSize = spot.rect.size
        isPhysicalNotch = spot.physical
        let panel = self.panel ?? makePanel()
        let size = Self.panelSize
        panel.setFrame(NSRect(x: spot.rect.midX - size.width / 2, y: spot.screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        if timer == nil && !pollingPaused { installTimer(fast: false) }
        installMoveMonitors()
    }

    /// How often `tick()` samples the pointer: brisk only while it's near the notch or the panel is open,
    /// lazy otherwise — 20Hz around the clock was a constant wake-up on an idle desktop.
    private var pollFast = false
    private var pollingPaused = false
    private var moveMonitors: [Any] = []

    private func installTimer(fast: Bool) {
        pollFast = fast
        timer?.invalidate()
        let interval = fast ? 1.0 / 20 : 1.0 / 2
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = fast ? interval / 2 : 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pausePolling() {
        pollingPaused = true
        timer?.invalidate()
        timer = nil
    }

    private func resumePolling() {
        pollingPaused = false
        guard panel != nil, timer == nil else { return }
        installTimer(fast: false)
    }

    /// Pointer motion is what promotes the lazy timer to the brisk one, so the idle rate can stay low
    /// without making the notch feel slow to react. Nothing fires while the mouse is still.
    private func installMoveMonitors() {
        guard moveMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { moveMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { moveMonitors.append(local) }
    }

    private func pointerMoved() {
        guard panel != nil, !pollingPaused, !pollFast, isNearNotch(NSEvent.mouseLocation) else { return }
        installTimer(fast: true)
        tick()
    }

    /// The notch's own footprint plus a margin, rather than the whole top strip of the screen.
    private func isNearNotch(_ mouse: CGPoint) -> Bool {
        shapeRect.insetBy(dx: -48, dy: -48).contains(mouse)
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        // Clicking a button doesn't take focus from your app; clicking the search field does.
        panel.becomesKeyOnlyIfNeeded = true
        if let state, let agentStore {
            let host = NSHostingView(rootView: NotchRootView(controller: self, state: state, agentStore: agentStore))
            host.frame = NSRect(origin: .zero, size: Self.panelSize)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
        }
        self.panel = panel
        return panel
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        moveMonitors.forEach(NSEvent.removeMonitor)
        moveMonitors = []
        panel?.orderOut(nil)
        panel = nil
        mode = .compact
    }

    // MARK: Mouse

    private var shapeRect: CGRect {
        guard let panel else { return .zero }
        let size = shapeSize == .zero ? notchSize : shapeSize
        return CGRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func tick() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if !buttonDown { dragBaseline = dragPasteboard.changeCount }
        let near = mode == .expanded || isNearNotch(mouse)
        if near != pollFast { installTimer(fast: near) }
        guard near else { return }
        let now = Date()
        switch mode {
        case .compact, .alert, .hud:
            // A few points of slack below the shape so the menu bar edge is easy to hit.
            let inside = shapeRect.insetBy(dx: -6, dy: -6).contains(mouse)
            panel.ignoresMouseEvents = !inside
            // Something dragged up to the notch: open straight to the Shelf, ready for the drop.
            if inside && buttonDown && dragPasteboard.changeCount != dragBaseline {
                ShelfPresentation.shared.section = .shelf
                expand(tab: .shelf)
                return
            }
            let ring = CGRect(x: panel.frame.minX + limitRingFrame.minX, y: panel.frame.maxY - limitRingFrame.maxY,
                              width: limitRingFrame.width, height: limitRingFrame.height)
            let onRing = mode == .compact && limitRingFrame != .zero && ring.insetBy(dx: -5, dy: -5).contains(mouse)
            if isHoveringLimit != onRing {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isHoveringLimit = onRing }
            }
            if isHovering != inside {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovering = inside }
                if inside { haptic() }
            }
            if inside && prefs.notchHoverToOpen && !onRing {
                if let since = hoverSince {
                    if now.timeIntervalSince(since) > 0.25 { expand() }
                } else {
                    hoverSince = now
                }
            } else {
                hoverSince = nil
            }
        case .expanded:
            panel.ignoresMouseEvents = false
            let inside = shapeRect.insetBy(dx: -12, dy: -12).contains(mouse)
            if inside { pointerEntered = true }
            // A held button is usually an item being dragged out of the Shelf; closing under it would drop it.
            if inside || menuOpen || !pointerEntered || buttonDown {
                outsideSince = nil
            } else if let since = outsideSince {
                if now.timeIntervalSince(since) > 0.35 { collapse() }
            } else {
                outsideSince = now
            }
        }
    }

    func toggle() {
        mode == .expanded ? collapse() : expand()
    }

    func expand(tab: NotchTab? = nil) {
        guard panel != nil else { return }
        if !pollFast && !pollingPaused { installTimer(fast: true) }
        isHoveringLimit = false
        if let tab { prefs.notchTab = tab }
        alertTask?.cancel()
        hoverSince = nil
        outsideSince = nil
        guard mode != .expanded else { return }
        pointerEntered = shapeRect.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
        // Clicking anywhere else closes it, like a menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.menuOpen,
                      !self.shapeRect.contains(NSEvent.mouseLocation) else { return }
                self.collapse()
            }
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            mode = .expanded
            isHovering = false
        }
        panel?.ignoresMouseEvents = false
        panel?.allowsKey = true
    }

    /// Opens the notch on the Shelf tab. False when there's no notch to open (turned off, or no display for it).
    @discardableResult
    func openShelf(_ section: ShelfPresentation.Section, focusSearch: Bool = false) -> Bool {
        guard let panel else { return false }
        ShelfPresentation.shared.section = section
        expand(tab: .shelf)
        if focusSearch {
            // Take the keyboard now so typing goes straight into the search, without activating Lookout.
            panel.makeKey()
            ShelfPresentation.shared.focusSearch()
        }
        return true
    }

    /// The clipboard-history shortcut: opens it ready to search, or closes it if it's already showing.
    func toggleClipboardHistory() {
        if mode == .expanded && prefs.notchTab == .shelf && ShelfPresentation.shared.section == .clipboard {
            collapse()
            return
        }
        if !openShelf(.clipboard, focusSearch: true) { LiveSurfaces.shared.toggleMenuBarPanel() }
    }

    var isAvailable: Bool { panel != nil }

    func collapse() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        releaseKeyboard()
        guard mode != .compact else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 1)) {
            mode = .compact
            alert = nil
        }
        outsideSince = nil
        panel?.ignoresMouseEvents = true
    }

    /// Hands keyboard focus back to the app underneath. Ordering the panel out and straight back in drops key status
    /// without a visible flicker; the notch itself never leaves the screen.
    private func releaseKeyboard() {
        guard let panel else { return }
        panel.allowsKey = false
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func haptic() {
        guard prefs.notchHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: Alerts

    private func checkSessions() {
        guard let agentStore else { return }
        let sessions = agentStore.runningSessions.filter { !($0.process.map { AgentDiscovery.isDesktopApp($0.processName) } ?? false) }
        var buckets: [String: AgentActivityBucket] = [:]
        var next: NotchAlert?
        for session in sessions {
            let bucket = AgentActivityBucket(session)
            buckets[session.id] = bucket
            let previous = lastBuckets[session.id]
            guard primed, previous != bucket else { continue }
            if bucket == .needsYou {
                let failed = session.state == .failed
                next = NotchAlert(
                    id: "\(session.id)-\(bucket.rawValue)",
                    kind: failed ? .failed : .needsYou,
                    agent: session.agent,
                    title: session.projectName.isEmpty ? session.title : session.projectName,
                    detail: failed ? "\(session.agent.shortName) stopped with an error: \(session.title)"
                                   : "\(session.agent.shortName) is waiting for you: \(session.title)",
                    badge: failed ? "Failed" : "Needs approval",
                    sessionID: session.id
                )
            } else if bucket == .yourTurn, previous == .working, next == nil, prefs.notchFinishedAlerts {
                next = NotchAlert(
                    id: "\(session.id)-done-\(session.updatedAt.timeIntervalSince1970)",
                    kind: .finished,
                    agent: session.agent,
                    title: session.projectName.isEmpty ? session.title : session.projectName,
                    detail: "\(session.agent.shortName) finished: \(session.title)",
                    badge: "Your turn",
                    sessionID: session.id
                )
            }
        }
        lastBuckets = buckets
        primed = true
        if let next, prefs.notchAlerts { show(next) }
    }

    /// Drops the alert for a few seconds unless the notch is already open.
    func show(_ alert: NotchAlert, seconds: Double = 5) {
        guard panel != nil, mode != .expanded else { return }
        haptic()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            self.alert = alert
            mode = .alert
        }
        alertTask?.cancel()
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.mode == .alert else { return }
            // Keep it up while the pointer is on it.
            if self.shapeRect.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) { return }
            self.collapse()
        }
    }

    /// Volume/brightness drop-down, like the system HUD but in the notch. Refreshed while the keys are held.
    func showHUD(_ kind: SystemControls.HUDKind) {
        guard panel != nil, prefs.notchHUD, mode != .expanded, mode != .alert else { return }
        if mode != .hud(kind) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { mode = .hud(kind) }
        }
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self, self.mode == .hud(kind) else { return }
            self.collapse()
        }
    }

    /// Opens the session an alert or row refers to: its terminal if we can find it, otherwise Local Observer.
    func open(sessionID: String?) {
        guard let agentStore else { return }
        if let id = sessionID, let session = agentStore.runningSessions.first(where: { $0.id == id }),
           AgentActions.jump(to: session) {
            collapse()
            return
        }
        agentStore.selectedSessionID = sessionID
        LiveSurfaces.shared.openMain(.agentActivity)
        collapse()
    }

    #if DEBUG
    /// Snapshot harness only: pin a mode without a panel or mouse.
    func debugShow(_ mode: Mode, alert: NotchAlert? = nil, notch: CGSize = CGSize(width: 185, height: 32), limitHover: Bool = false) {
        self.mode = mode
        isHoveringLimit = limitHover
        self.alert = alert
        notchSize = notch
    }
    #endif
}
