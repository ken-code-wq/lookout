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
        defer { knownAttention = ids; primed = true }
        // Skip the first scan so launching the app doesn't replay everything already waiting.
        guard primed, store.settings.notifyNeedsInput else { return }
        for session in attention where !knownAttention.contains(session.id) {
            let body = session.state == .failed
                ? "\(session.title) stopped with an error."
                : "\(session.title) is waiting for you in \(session.process?.host?.name ?? session.projectName)."
            post(id: "attention-\(session.id)", title: "\(session.agent.name) needs you", body: body)
        }
    }

    private func checkLimits(_ store: AgentStore) {
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
