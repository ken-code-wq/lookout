import Foundation
import Combine
import UserNotifications
import LocalObserverCore

/// Opt-in notifications: a session starts needing the user, or a limit window crosses the chosen threshold.
/// Each event fires once; the same window alerts again only after it resets.
@MainActor
final class AgentNotifier {
    static let shared = AgentNotifier()

    /// UNUserNotificationCenter traps without a bundle identifier (a bare `swift run` binary has none).
    nonisolated static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private var cancellables: Set<AnyCancellable> = []
    private var attached = false
    private var knownAttention: Set<String> = []
    private var lastBuckets: [String: AgentActivityBucket] = [:]
    private var paceAlerted: [String: Date?] = [:]
    /// Used-up windows with a pending "it's back" alert, keyed by agent|label, valued by the reset time scheduled.
    private var resetScheduled: [String: Date] = [:]
    private var resetTasks: [String: Task<Void, Never>] = [:]
    private var alertedWindows: [String: Date?] = [:]
    private var primed = false

    func attach(to store: AgentStore) {
        guard !attached else { return }
        attached = true
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.checkSessions(store)
            }
            .store(in: &cancellables)
        store.$accountReports
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.checkLimits(store)
            }
            .store(in: &cancellables)
    }

    private func checkSessions(_ store: AgentStore) {
        let attention = store.snapshot.processes.filter(\.needsAttention)
        let ids = Set(attention.map(\.id))
        let buckets = Dictionary(store.snapshot.processes.map { ($0.id, AgentActivityBucket($0)) }, uniquingKeysWith: { a, _ in a })
        defer { knownAttention = ids; lastBuckets = buckets; primed = true }
        if primed, Preferences.shared.notifyFinished {
            for session in store.snapshot.processes
            where lastBuckets[session.id] == .working && buckets[session.id] == .yourTurn {
                post(id: "finished-\(session.id)-\(Int(session.updatedAt.timeIntervalSince1970))",
                     title: "\(session.agent.name) finished",
                     body: "\(session.title) in \(session.projectName) is ready for you.")
            }
        }
        // Skip the first scan so launching the app doesn't replay everything already waiting.
        guard primed, store.settings.notifyNeedsInput else { return }
        // Sessions with a request waiting in Lookout already got a notification with Allow and Deny (ApprovalCenter).
        for session in attention where !knownAttention.contains(session.id) && !ApprovalCenter.shared.hasPending(sessionID: session.id) {
            let body = session.state == .failed
                ? "\(session.title) stopped with an error."
                : "\(session.title) is waiting for you in \(session.process?.host?.name ?? session.projectName)."
            post(id: "attention-\(session.id)", title: "\(session.agent.name) needs you", body: body)
        }
    }

    private func checkLimits(_ store: AgentStore) {
        checkPace(store)
        scheduleResets(store)
        guard let threshold = store.settings.limitAlertPercent else { return }
        for window in store.limitReports.flatMap(\.windows) {
            let key = "\(window.agent.rawValue)|\(window.label)"
            if let alerted = alertedWindows[key], alerted == window.resetsAt { continue }
            guard window.usedPercent >= Double(threshold) else { continue }
            alertedWindows[key] = window.resetsAt
            let reset = AgentFormat.resetText(window.resetsAt).lowercased()
            post(
                id: "limit-\(key)",
                title: "\(window.agent.shortName) \(window.label.lowercased()) at \(Int(window.usedPercent.rounded()))%",
                body: "It \(reset)."
            )
        }
    }

    /// Once per window: at the current burn rate, the window runs dry before it resets.
    private func checkPace(_ store: AgentStore) {
        guard Preferences.shared.notifyPace else { return }
        for window in store.limitReports.flatMap(\.windows) {
            let pace = LimitPace(window: window)
            guard pace.verdict == .ahead, let runsOut = pace.runsOutAt else { continue }
            let key = "\(window.agent.rawValue)|\(window.label)"
            if let alerted = paceAlerted[key], alerted == window.resetsAt { continue }
            paceAlerted[key] = window.resetsAt
            post(
                id: "pace-\(key)",
                title: "\(window.agent.shortName) \(window.label.lowercased()) is running hot",
                body: "At this rate it runs out \(AgentFormat.relative(runsOut)), before it \(AgentFormat.resetText(window.resetsAt).lowercased())."
            )
        }
    }

    /// When a window is used up, line up a "back" alert for its reset time: a scheduled system notification
    /// (delivered even if the Mac was asleep) and a notch drop-down if the app is running then.
    private func scheduleResets(_ store: AgentStore) {
        guard Preferences.shared.notifyReset else { return }
        for window in store.limitReports.flatMap(\.windows) {
            guard window.usedPercent >= 95, let reset = window.resetsAt, reset > .now else { continue }
            let key = "\(window.agent.rawValue)|\(window.label)"
            guard resetScheduled[key] != reset else { continue }
            resetScheduled[key] = reset
            let title = "\(window.agent.shortName) \(window.label.lowercased()) is back"
            let body = "Your \(window.agent.name) limit just reset. You can pick up where you left off."

            if Self.isAvailable {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(reset.timeIntervalSinceNow + 5, 1), repeats: false)
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "reset-\(key)", content: content, trigger: trigger))
            }
            resetTasks[key]?.cancel()
            let agent = window.agent
            resetTasks[key] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(reset.timeIntervalSinceNow + 5, 1)))
                guard !Task.isCancelled else { return }
                NotchController.shared.show(NotchAlert(
                    id: "reset-\(key)-\(reset.timeIntervalSince1970)", kind: .reset, agent: agent,
                    title: title, detail: "Limit reset. Agents can run again.", badge: "Back", sessionID: nil
                ), seconds: 6)
            }
        }
    }

    private func post(id: String, title: String, body: String) {
        guard Self.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in completion(granted) }
        }
    }
}
