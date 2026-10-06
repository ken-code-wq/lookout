import Foundation
import Combine
import UserNotifications
import LocalObserverCore
import LocalObserverWidgetUI

/// Watches the servers Lookout launched: notices when one exits without being asked to, keeps its exit status and
/// last words, tells you once, and restarts it with backoff if you turned that on. Also flags launchers whose logs
/// start filling with errors.
///
/// While Lookout runs it is the launched shell's parent and gets the real exit status. Across a restart of the app
/// it only sees the process group disappear, and reads the status from the exit note the launch script wrote to the
/// log; if there's none, it says the status is unknown rather than guessing.
@MainActor
final class ServerSupervisor: ObservableObject {
    static let shared = ServerSupervisor()

    /// A launch Lookout expects to keep running.
    struct Run: Codable {
        var pgid: Int32
        var name: String
        var startedAt: Date
        /// Automatic restarts so far in the current run of crashes.
        var attempts = 0
    }

    struct Crash: Codable, Identifiable, Equatable {
        enum Restart: Codable, Equatable {
            case scheduled(at: Date, attempt: Int, of: Int)
            case restarted(attempt: Int, of: Int)
            case gaveUp(attempts: Int)
        }
        /// The launcher's id.
        var id: UUID
        var name: String
        /// Nil when it ended while Lookout wasn't watching and left no exit note.
        var status: ServerExitStatus?
        /// Exited with status 0, which for a server is still unexpected.
        var clean: Bool
        var at: Date
        var ranFor: TimeInterval
        var lastLines: [String]
        var restart: Restart?

        var title: String {
            if status == nil { return "\(name) stopped unexpectedly" }
            return clean ? "\(name) stopped on its own" : "\(name) crashed"
        }

        var statusText: String {
            guard let status else { return "Exit status unknown: it ended while Lookout wasn't running" }
            return clean ? "Exited cleanly (exit code 0) while it was meant to keep running" : status.summary.prefix(1).uppercased() + status.summary.dropFirst()
        }
    }

    @Published private(set) var crashes: [UUID: Crash] = [:]
    /// Launchers logging errors past the spike threshold, with how many in the last minute.
    @Published private(set) var spiking: [UUID: Int] = [:]
    @Published private(set) var autoRestart: Set<UUID> = []

    let policy = RestartPolicy()
    private var runs: [UUID: Run] = [:]
    /// Process groups whose shell Lookout is waiting on itself; the rest are found by polling.
    private var children: Set<Int32> = []
    private var automaticLaunches: Set<UUID> = []
    private var spikeWindows: [UUID: ErrorSpikeWindow] = [:]
    private var restartTasks: [UUID: Task<Void, Never>] = [:]
    private weak var state: AppState?
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let runs = "LocalObserver.serverRuns"
        static let crashes = "LocalObserver.serverCrashes"
        static let autoRestart = "LocalObserver.serverAutoRestart"
    }

    private init() {
        if let data = defaults.data(forKey: Keys.runs), let saved = try? JSONDecoder().decode([UUID: Run].self, from: data) { runs = saved }
        if let data = defaults.data(forKey: Keys.crashes), let saved = try? JSONDecoder().decode([UUID: Crash].self, from: data) {
            // A restart scheduled before Lookout quit won't happen now; say so instead of counting down forever.
            crashes = saved.mapValues { crash in
                var c = crash
                if case .scheduled = c.restart { c.restart = nil }
                return c
            }
        }
        autoRestart = Set((defaults.stringArray(forKey: Keys.autoRestart) ?? []).compactMap(UUID.init(uuidString:)))
    }

    /// Starts watching the launchers of the app's state. The first state wins (the snapshot harness makes more).
    func attach(_ state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        follow()
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in ServerSupervisor.shared.poll() }
        }
        timer.tolerance = 2
        self.timer = timer
        poll()
    }

    // MARK: Lifecycle hooks (from AppState)

    func didLaunch(_ launcher: ManagedServer, pgid: Int32) {
        let automatic = automaticLaunches.remove(launcher.id) != nil
        var run = Run(pgid: pgid, name: launcher.name, startedAt: Date())
        if automatic, var crash = crashes[launcher.id], case .scheduled(_, let attempt, let of) = crash.restart {
            run.attempts = attempt
            crash.restart = .restarted(attempt: attempt, of: of)
            crashes[launcher.id] = crash
        } else {
            crashes[launcher.id] = nil
        }
        restartTasks[launcher.id]?.cancel()
        restartTasks[launcher.id] = nil
        runs[launcher.id] = run
        children.insert(pgid)
        spikeWindows[launcher.id] = nil
        spiking[launcher.id] = nil
        persist()
        follow()
    }

    /// Called from the background thread that reaped the launched shell.
    nonisolated static func shellExited(_ id: UUID, pgid: Int32, waitStatus: Int32) {
        Task { @MainActor in
            ServerSupervisor.shared.children.remove(pgid)
            await ServerSupervisor.shared.handleExit(id, pgid: pgid, status: ServerExitStatus(waitStatus: waitStatus))
        }
    }

    /// You (or Lookout) are stopping it: whatever happens next isn't a crash.
    func willStop(_ id: UUID?) {
        guard let id else { return }
        runs[id] = nil
        restartTasks[id]?.cancel()
        restartTasks[id] = nil
        automaticLaunches.remove(id)
        if var crash = crashes[id], case .scheduled = crash.restart {
            crash.restart = nil
            crashes[id] = crash
        }
        spiking[id] = nil
        spikeWindows[id] = nil
        persist()
        follow()
    }

    // MARK: Actions

    func dismiss(_ id: UUID) {
        restartTasks[id]?.cancel()
        restartTasks[id] = nil
        crashes[id] = nil
        persist()
    }

    func setAutoRestart(_ id: UUID, _ on: Bool) {
        if on { autoRestart.insert(id) } else {
            autoRestart.remove(id)
            if var crash = crashes[id], case .scheduled = crash.restart {
                restartTasks[id]?.cancel()
                restartTasks[id] = nil
                crash.restart = nil
                crashes[id] = crash
            }
        }
        persist()
    }

    func isRunning(_ id: UUID) -> Bool { runs[id] != nil }

    // MARK: Errors

    func noteErrors(_ id: UUID, count: Int) {
        guard runs[id] != nil else { return }
        var window = spikeWindows[id] ?? ErrorSpikeWindow()
        window.record(count, at: Date())
        spikeWindows[id] = window
        updateSpike(id, window)
    }

    private func updateSpike(_ id: UUID, _ window: ErrorSpikeWindow) {
        let now = Date()
        let value: Int? = window.isSpiking(now: now) ? window.count(now: now) : nil
        if spiking[id] != value { spiking[id] = value }
    }

    // MARK: Exits

    private func poll() {
        for (id, var window) in spikeWindows {
            window.prune(now: Date())
            spikeWindows[id] = window
            updateSpike(id, window)
        }
        for (id, run) in runs where !children.contains(run.pgid) && !ProcessManager.isGroupAlive(pgid: run.pgid) {
            let code = ServerLogStore.shared.lastExitCode(for: id)
            Task { await handleExit(id, pgid: run.pgid, status: code.map(ServerExitStatus.exited)) }
        }
    }

    private func handleExit(_ id: UUID, pgid: Int32, status: ServerExitStatus?) async {
        // Not ours to report: stopped on purpose, or an older launch.
        guard let run = runs[id], run.pgid == pgid else { return }
        // A command that puts its server in the background (`docker compose up -d`, `… &`) exits cleanly while the
        // group lives on; keep watching the group instead.
        if status?.isSuccess == true, ProcessManager.isGroupAlive(pgid: pgid) { return }
        runs[id] = nil
        persist()
        follow()

        let launcher = state?.managed.first { $0.id == id }
        var lines: [String] = []
        if let launcher {
            await ServerLogStore.shared.catchUp(launcher)
            lines = ServerLogStore.shared.lines(for: id).filter { $0.stream != .lookout }.suffix(20).map(\.text)
        }
        // The poll may have read the exit note in the meantime.
        let finalStatus = status ?? ServerLogStore.shared.lastExitCode(for: id).map(ServerExitStatus.exited)
        let verdict = ServerExitClassifier.verdict(finalStatus, stopRequested: false)
        guard verdict != .stopped else { return }
        let ranFor = Date().timeIntervalSince(run.startedAt)
        var crash = Crash(id: id, name: launcher?.name ?? run.name, status: finalStatus, clean: verdict == .exitedEarly,
                          at: Date(), ranFor: ranFor, lastLines: lines)

        var notifyTitle: String? = crash.title
        if let launcher, autoRestart.contains(id) {
            switch policy.decide(attempts: run.attempts, ranFor: ranFor) {
            case .restart(let delay, let attempt):
                crash.restart = .scheduled(at: Date().addingTimeInterval(delay), attempt: attempt, of: policy.maxAttempts)
                // One alert per run of crashes: the first, and the give-up.
                if attempt > 1 { notifyTitle = nil }
                scheduleRestart(launcher, after: delay)
            case .giveUp(let attempts):
                crash.restart = .gaveUp(attempts: attempts)
                notifyTitle = "\(crash.name) keeps crashing"
            }
        }
        crashes[id] = crash
        persist()
        if let notifyTitle { notify(crash, title: notifyTitle, key: "\(id.uuidString)-\(pgid)") }
    }

    private func scheduleRestart(_ launcher: ManagedServer, after delay: TimeInterval) {
        restartTasks[launcher.id]?.cancel()
        restartTasks[launcher.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let state = self.state,
                  let current = state.managed.first(where: { $0.id == launcher.id }), !state.isRunning(current) else { return }
            self.automaticLaunches.insert(launcher.id)
            state.start(current)
            // Start can refuse (port taken, folder gone); don't leave the flag for a later manual start.
            if self.runs[launcher.id] == nil { self.automaticLaunches.remove(launcher.id) }
        }
    }

    private func notify(_ crash: Crash, title: String, key: String) {
        guard Preferences.shared.notifyServerCrash else { return }
        var body = crash.statusText + "."
        if let last = crash.lastLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { body += " Last line: \(last)" }
        if case .scheduled(let at, let attempt, let of) = crash.restart {
            body += " Restarting in \(max(Int(at.timeIntervalSinceNow.rounded()), 1))s (try \(attempt) of \(of))."
        }
        if AgentNotifier.isAvailable {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["url": "\(WidgetLink.scheme)://launchers"]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "server-crash-\(key)", content: content, trigger: nil))
        }
        if Preferences.shared.notchAlerts {
            NotchController.shared.show(NotchAlert(id: "server-crash-\(key)", kind: .failed, agent: nil, title: title,
                                                   detail: crash.statusText, badge: crash.clean ? "Stopped" : "Crashed", sessionID: nil,
                                                   symbol: "exclamationmark.octagon.fill", url: "\(WidgetLink.scheme)://launchers"), seconds: 6)
        }
    }

    // MARK: Plumbing

    private func follow() {
        guard let state else { return }
        ServerLogStore.shared.follow(state.managed.filter { runs[$0.id] != nil })
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(runs) { defaults.set(data, forKey: Keys.runs) }
        if let data = try? JSONEncoder().encode(crashes) { defaults.set(data, forKey: Keys.crashes) }
        defaults.set(autoRestart.map(\.uuidString), forKey: Keys.autoRestart)
    }

    #if DEBUG
    /// Snapshot harness: a crash and an error spike to show, without watching anything.
    func loadDemo(crash: Crash?, spiking demoSpiking: [UUID: Int], autoRestart demoAuto: Set<UUID>) {
        timer?.invalidate()
        timer = nil
        crashes = crash.map { [$0.id: $0] } ?? [:]
        spiking = demoSpiking
        autoRestart = demoAuto
    }
    #endif
}
