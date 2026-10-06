import AppKit
import Combine
import UserNotifications
import LocalObserverCore
import LocalObserverHooks

/// A permission request an agent is blocked on until it's answered here, the wait runs out, or the agent gives up.
struct ApprovalRequest: Identifiable {
    let id: String
    var event: HookEvent
    var agent: AgentKind
    /// The running session it came from (`AgentSession.id`), once matched.
    var sessionID: String?
    var projectName: String
    let deadline: Date
    let connection: HookConnection

    var alwaysAllow: HookAlwaysAllow { HookAlwaysAllow(event: event) }
}

/// Live agent events from `lookout-hook`: listens on the hook socket, keeps the queue of permission requests, answers
/// them, and tells the agent store what each session is doing so hook events beat transcript inference.
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    enum NotchPage: Equatable {
        case approvals
        case reply(sessionID: String)
    }

    /// Oldest first.
    @Published private(set) var pending: [ApprovalRequest] = []
    /// What the open notch shows instead of its tabs. Cleared whenever the notch closes.
    @Published var notchPage: NotchPage?
    /// The request the notch page shows; nil means the oldest.
    @Published var selectedID: String?
    /// Opened from the shortcut with the keyboard: ⏎ allows, ⎋ denies. Never set when a request merely arrives,
    /// so a Return typed into your editor can't approve anything.
    @Published var keyboardArmed = false
    /// The agent's last message when its turn ended, by session id, for the quick-reply page.
    @Published private(set) var lastMessages: [String: String] = [:]
    @Published private(set) var replyStatus: String?
    /// Sessions with a live reply waiter (`HookReply`): `AgentSession.id` → Claude Code's `session_id`.
    @Published private(set) var replyTargets: [String: String] = [:]
    /// Whether Claude Code's settings have Lookout's current hooks, for saying why a reply can't be sent.
    @Published private(set) var claudeHookStatus: HookInstallStatus = .notConnected
    @Published private(set) var listenerError: String?
    @Published private(set) var isListening = false
    /// When each agent last sent a hook event, so Settings can show the connection is live.
    @Published private(set) var lastEventAt: [AgentKind: Date] = [:]

    /// Show permission requests in the notch, Peek and the menu bar. Off answers nothing: agents ask in the terminal.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }
    /// How long an agent waits on Lookout before asking in its terminal instead.
    @Published var waitSeconds: Int { didSet { defaults.set(waitSeconds, forKey: Keys.wait) } }
    /// Let the agent ask in its own terminal when that terminal is already the frontmost app.
    @Published var passWhenTerminalFront: Bool { didSet { defaults.set(passWhenTerminalFront, forKey: Keys.passFront) } }

    static let waitChoices = [15, 45, 120, 300]
    /// How long a finished session stays open to a reply from Lookout. Capped by the hook's own ceiling.
    @Published var replyWaitHours: Int { didSet { defaults.set(replyWaitHours, forKey: Keys.replyWait); expireReplyWaiters() } }
    static let replyWaitChoices = [1, 3, 8]
    static let notificationCategory = "lookout.approval"

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "LocalObserver.approvals.enabled"
        static let wait = "LocalObserver.approvals.waitSeconds"
        static let passFront = "LocalObserver.approvals.passWhenTerminalFront"
        static let replyWait = "LocalObserver.approvals.replyWaitHours"
    }

    private weak var agentStore: AgentStore?
    private var server: HookServer?
    private var hookStates: [String: AgentHookState] = [:]
    /// Events from sessions the last scan hadn't found yet (a session that just started). Retried after the next scan.
    private var unmatched: [HookEvent] = []
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var replyWaiters = ReplyWaiters<HookConnection>()
    /// The Stop event each waiter registered with, by Claude session id, to match it to a running session.
    private var waiterEvents: [String: HookEvent] = [:]
    private var replySweep: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        let wait = defaults.integer(forKey: Keys.wait)
        waitSeconds = Self.waitChoices.contains(wait) ? wait : 45
        passWhenTerminalFront = defaults.object(forKey: Keys.passFront) as? Bool ?? true
        let hours = defaults.integer(forKey: Keys.replyWait)
        replyWaitHours = Self.replyWaitChoices.contains(hours) ? hours : 3
    }

    /// Debug/demo only: show requests without a socket or a waiting agent.
    #if DEBUG
    func loadDemo(_ requests: [ApprovalRequest], lastMessages: [String: String] = [:]) {
        pending = requests
        self.lastMessages = lastMessages
    }
    #endif

    func attach(agentStore: AgentStore) {
        guard self.agentStore == nil else { return }
        self.agentStore = agentStore
        startListening()
        // Hang up on anything still waiting and remove the socket, so agents fall back to their terminal at once.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.pending.forEach { $0.connection.reply(nil) }
                self?.releaseAllReplyWaiters()
                self?.server?.stop()
            }
            .store(in: &cancellables)
        agentStore.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sessionsChanged() }
            .store(in: &cancellables)
        NotchController.shared.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                guard mode == .compact else { return }
                self?.notchPage = nil
                self?.keyboardArmed = false
                self?.replyStatus = nil
            }
            .store(in: &cancellables)
        Preferences.shared.$approvalsHotKey
            .removeDuplicates()
            .sink { GlobalHotKeys.shared.register(.approvals, $0) }
            .store(in: &cancellables)
        registerNotificationActions()
        refreshHookStatus()
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshHookStatus() }
            .store(in: &cancellables)
        // Waiters past the cap are released; once a minute is plenty for a cap measured in hours.
        replySweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.expireReplyWaiters()
            }
        }
    }

    func refreshHookStatus() {
        claudeHookStatus = HookInstallation.status(.claude)
    }

    func startListening() {
        guard server == nil else { return }
        #if DEBUG
        // Snapshot runs render and quit; they mustn't take real agents' requests.
        if SnapshotHarness.directory != nil { return }
        #endif
        let server = HookServer { line, connection in
            guard let event = HookEvent.parse(envelope: line) else { connection.reply(nil); return }
            Task { @MainActor in ApprovalCenter.shared.receive(event, connection) }
        }
        do {
            try server.start()
            self.server = server
            isListening = true
            listenerError = nil
        } catch {
            isListening = false
            listenerError = error.localizedDescription
        }
    }

    // MARK: Events

    private func receive(_ event: HookEvent, _ connection: HookConnection) {
        guard let agent = AgentKind(rawValue: event.agent.rawValue) else { connection.reply(nil); return }
        lastEventAt[agent] = event.receivedAt
        let session = match(event, agent: agent)
        if event.awaitsReply {
            registerReplyWaiter(event, connection: connection)
            return
        }
        // Typed in its own UI, or ended: nobody will reply from here, so the waiter exits quietly.
        releaseReplyWaiters(for: event)
        if event.awaitsDecision {
            request(event, agent: agent, session: session, connection: connection)
        } else {
            connection.reply(nil)
            apply(event, to: session)
        }
    }

    private func request(_ event: HookEvent, agent: AgentKind, session: AgentSession?, connection: HookConnection) {
        if let session { setState(.needsInput, for: session.id, at: event.receivedAt, pinned: false) }
        // Off, or the user is already looking at the agent's terminal: let the agent ask there.
        guard enabled, !(passWhenTerminalFront && isFrontmost(session)) else {
            connection.reply(nil)
            return
        }
        let request = ApprovalRequest(
            id: UUID().uuidString, event: event, agent: agent, sessionID: session?.id,
            projectName: session?.projectName ?? (event.cwd as NSString).lastPathComponent,
            deadline: event.receivedAt.addingTimeInterval(TimeInterval(waitSeconds)), connection: connection
        )
        pending.append(request)
        if let session { setState(.needsInput, for: session.id, at: event.receivedAt, pinned: true) }
        // The helper hangs up when the agent stops waiting (its hook timed out, or the session was interrupted).
        connection.watchForHangup(on: .main) { [id = request.id] in
            Task { @MainActor in ApprovalCenter.shared.drop(id, answered: false) }
        }
        expiryTasks[request.id] = Task { [id = request.id, wait = waitSeconds] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            ApprovalCenter.shared.release(id)
        }
        present(request)
        notify(request)
    }

    private func apply(_ event: HookEvent, to session: AgentSession?) {
        guard let signal = event.signal else { return }
        guard let session else {
            // A session that just started: rescan so it shows up, then apply what it said.
            if signal != .ended {
                unmatched.append(event)
                unmatched.removeAll { event.receivedAt.timeIntervalSince($0.receivedAt) > 30 }
                agentStore?.refresh(quiet: true)
            }
            return
        }
        switch signal {
        case .working: setState(.working, for: session.id, at: event.receivedAt)
        case .needsYou: setState(.needsInput, for: session.id, at: event.receivedAt)
        case .yourTurn:
            setState(.waiting, for: session.id, at: event.receivedAt)
            if !event.message.isEmpty { lastMessages[session.id] = event.message }
        case .ended:
            hookStates[session.id] = nil
            pushStates()
        }
        if case .sessionStart = event.kind { agentStore?.refresh(quiet: true) }
    }

    private func sessionsChanged() {
        guard let agentStore else { return }
        let running = Set(agentStore.snapshot.processes.map(\.id))
        let stale = hookStates.keys.filter { !running.contains($0) }
        if !stale.isEmpty {
            stale.forEach { hookStates[$0] = nil }
            pushStates()
        }
        lastMessages = lastMessages.filter { running.contains($0.key) }
        refreshReplyTargets()
        // Requests that arrived before their session was scanned.
        for index in pending.indices where pending[index].sessionID == nil {
            if let session = match(pending[index].event, agent: pending[index].agent) {
                pending[index].sessionID = session.id
                pending[index].projectName = session.projectName
                setState(.needsInput, for: session.id, at: pending[index].event.receivedAt, pinned: true)
            }
        }
        let retry = unmatched
        unmatched = []
        for event in retry {
            guard let agent = AgentKind(rawValue: event.agent.rawValue), let session = match(event, agent: agent) else { continue }
            apply(event, to: session)
        }
    }

    private func match(_ event: HookEvent, agent: AgentKind) -> AgentSession? {
        guard let agentStore else { return nil }
        return AgentHookOverlay.match(agent: agent, pids: event.pids, sessionID: event.sessionID, cwd: event.cwd,
                                      in: agentStore.snapshot.processes)
    }

    private func setState(_ state: AgentActivityState, for sessionID: String, at: Date, pinned: Bool = false) {
        // A request still waiting keeps its session on "Needs you" whatever else arrives meanwhile.
        if !pinned, hookStates[sessionID]?.pinned == true, pending.contains(where: { $0.sessionID == sessionID }) { return }
        hookStates[sessionID] = AgentHookState(state: state, at: at, pinned: pinned)
        pushStates()
    }

    private func pushStates() { agentStore?.setHookStates(hookStates) }

    // MARK: Answers

    func current() -> ApprovalRequest? {
        pending.first { $0.id == selectedID } ?? pending.first
    }

    func hasPending(sessionID: String) -> Bool { pending.contains { $0.sessionID == sessionID } }

    func session(for request: ApprovalRequest) -> AgentSession? {
        guard let id = request.sessionID else { return nil }
        return agentStore?.snapshot.processes.first { $0.id == id }
    }

    func decide(_ id: String, _ decision: HookDecision) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        request.connection.reply(HookResponse.claudePermission(decision, for: request.event))
        drop(id, answered: true)
    }

    /// Stop waiting: the agent asks in its terminal, which is brought forward when `jump` is set.
    func release(_ id: String, jump: Bool = false) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        request.connection.reply(nil)
        drop(id, answered: false)
        if jump, let session = session(for: request) { AgentActions.jump(to: session) }
    }

    private func drop(_ id: String, answered: Bool) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        expiryTasks.removeValue(forKey: id)?.cancel()
        if selectedID == id { selectedID = nil }
        if AgentNotifier.isAvailable {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["approval-\(id)"])
        }
        if let sessionID = request.sessionID {
            // Answered here: the agent carries on. Otherwise its own prompt is up now, so it still needs you.
            hookStates[sessionID] = AgentHookState(state: answered ? .working : .needsInput, at: Date())
            pushStates()
        }
        if pending.isEmpty, notchPage == .approvals {
            notchPage = nil
            keyboardArmed = false
            NotchController.shared.collapse()
        }
    }

    // MARK: Presentation

    /// A new request opens the notch on it, without taking the keyboard.
    private func present(_ request: ApprovalRequest) {
        let notch = NotchController.shared
        guard notch.isAvailable else { return }
        if notchPage == nil || notch.mode != .expanded { selectedID = request.id }
        notchPage = .approvals
        notch.expand()
    }

    /// The shortcut: the oldest request, keyboard ready. With nothing waiting it just opens the notch.
    func openOldest() {
        let notch = NotchController.shared
        guard let first = pending.first else {
            if notch.isAvailable { notch.toggle() } else { LiveSurfaces.shared.toggleMenuBarPanel() }
            return
        }
        guard notch.isAvailable else {
            LiveSurfaces.shared.toggleMenuBarPanel()
            return
        }
        selectedID = first.id
        notchPage = .approvals
        notch.expand()
        notch.takeKeyboard()
        keyboardArmed = true
    }

    func show(_ id: String) {
        selectedID = id
        notchPage = .approvals
        NotchController.shared.expand()
    }

    func step(by delta: Int) {
        guard let current = current(), let index = pending.firstIndex(where: { $0.id == current.id }) else { return }
        selectedID = pending[(index + delta + pending.count) % pending.count].id
    }

    // MARK: Reply waiters

    private func registerReplyWaiter(_ event: HookEvent, connection: HookConnection) {
        let id = UUID().uuidString
        let replaced = replyWaiters.register(id: id, sessionID: event.sessionID, handle: connection, at: event.receivedAt)
        replaced?.reply(nil)
        guard replyWaiters.has(event.sessionID) else { return }
        waiterEvents[event.sessionID] = event
        // Claude Code killed it, the user interrupted, or the session closed.
        connection.watchForHangup(on: .main) { [id] in
            Task { @MainActor in ApprovalCenter.shared.replyWaiterGone(id) }
        }
        refreshReplyTargets()
    }

    private func replyWaiterGone(_ id: String) {
        replyWaiters.remove(id: id)
        refreshReplyTargets()
    }

    private func releaseReplyWaiters(for event: HookEvent) {
        let released = replyWaiters.release(for: event)
        guard !released.isEmpty else { return }
        released.forEach { $0.reply(nil) }
        refreshReplyTargets()
    }

    private func expireReplyWaiters() {
        let cap = TimeInterval(min(replyWaitHours * 3600, ClaudeHookConfig.replyWaitCeiling))
        let expired = replyWaiters.expire(now: Date(), cap: cap)
        guard !expired.isEmpty else { return }
        expired.forEach { $0.reply(nil) }
        refreshReplyTargets()
    }

    private func releaseAllReplyWaiters() {
        _ = replyWaiters.expire(now: .distantFuture, cap: 0).map { $0.reply(nil) }
        refreshReplyTargets()
    }

    private func refreshReplyTargets() {
        waiterEvents = waiterEvents.filter { replyWaiters.has($0.key) }
        var targets: [String: String] = [:]
        for (sessionID, event) in waiterEvents {
            if let session = match(event, agent: .claude) { targets[session.id] = sessionID }
        }
        if targets != replyTargets { replyTargets = targets }
    }

    /// How a reply would reach this session right now, or why it can't.
    func replyRoute(for session: AgentSession) -> ReplyRoute {
        let host = session.process?.host
        let bundleID = host.flatMap { Bundle(path: $0.bundlePath)?.bundleIdentifier }
        return ReplyRoute.choose(hasWaiter: replyTargets[session.id] != nil, isClaude: session.agent == .claude,
                                 hookStatus: claudeHookStatus, hostBundleID: bundleID, tty: session.process?.terminal ?? "")
    }

    // MARK: Quick reply

    func openReply(sessionID: String) {
        replyStatus = nil
        notchPage = .reply(sessionID: sessionID)
        let notch = NotchController.shared
        guard notch.isAvailable else { return }
        notch.expand()
        notch.takeKeyboard()
    }

    func sendReply(_ text: String, to session: AgentSession) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        replyStatus = nil
        if let claudeSession = replyTargets[session.id], let waiter = replyWaiters.take(claudeSession) {
            waiter.reply(HookReply.answer(trimmed))
            refreshReplyTargets()
            replyStatus = "Sent to Claude. It's working on it"
            setState(.working, for: session.id, at: Date())
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                if notchPage == .reply(sessionID: session.id) { NotchController.shared.collapse() }
            }
            return
        }
        guard replyRoute(for: session) == .terminal else {
            replyStatus = replyRoute(for: session).reason
            return
        }
        Task {
            let outcome = await TerminalReply.send(trimmed, to: session)
            switch outcome {
            case .typed(let host):
                replyStatus = "Sent to \(host)"
                setState(.working, for: session.id, at: Date())
                try? await Task.sleep(for: .seconds(1.2))
                if notchPage == .reply(sessionID: session.id) { NotchController.shared.collapse() }
            case .missing(let host):
                replyStatus = "Couldn't find its tab in \(host)"
            case .failed(let reason):
                replyStatus = reason
            }
        }
    }

    // MARK: Notifications

    private func registerNotificationActions() {
        guard AgentNotifier.isAvailable else { return }
        let allow = UNNotificationAction(identifier: "allow", title: "Allow")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.notificationCategory, actions: [allow, deny], intentIdentifiers: [])
        // Setting categories replaces them all; keep any another part of the app registered.
        Task {
            let center = UNUserNotificationCenter.current()
            let others = await center.notificationCategories().filter { $0.identifier != category.identifier }
            center.setNotificationCategories(others.union([category]))
        }
    }

    private func notify(_ request: ApprovalRequest) {
        guard AgentNotifier.isAvailable, agentStore?.settings.notifyNeedsInput == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(request.agent.name) asks to \(request.event.preview?.title.lowercasedFirst ?? "use \(request.event.toolName)")"
        content.body = [request.projectName, request.event.preview?.subject ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["approvalID": request.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "approval-\(request.id)", content: content, trigger: nil))
    }

    /// A click on an approval notification or one of its buttons. True when it was one of ours.
    func handleNotification(category: String, action: String, userInfo: [AnyHashable: Any]) -> Bool {
        guard category == Self.notificationCategory else { return false }
        guard let id = userInfo["approvalID"] as? String, pending.contains(where: { $0.id == id }) else { return true }
        switch action {
        case "allow": decide(id, .allow)
        case "deny": decide(id, .deny)
        default: show(id)
        }
        return true
    }

    // MARK: Helpers

    private func isFrontmost(_ session: AgentSession?) -> Bool {
        guard let host = session?.process?.host, let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.processIdentifier == host.pid
            || front.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: host.bundlePath).standardizedFileURL.path
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
