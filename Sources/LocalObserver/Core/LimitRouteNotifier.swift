import Foundation
import Combine
import UserNotifications
import LocalObserverCore

/// Warns once per window and reset cycle when a limit crosses 80% at a pace that empties it before the reset, and
/// says which provider has room. Remembered across launches, so a restart doesn't repeat the same cycle's warning.
@MainActor
final class LimitRouteNotifier {
    static let shared = LimitRouteNotifier()

    private var cancellables: Set<AnyCancellable> = []
    private let defaults = UserDefaults.standard
    private static let key = "LocalObserver.routeAlerts"

    func attach(to store: AgentStore) {
        guard cancellables.isEmpty else { return }
        // Account reads and local session logs both carry windows; wait for a quiet moment after either changes.
        store.$accountReports.map { _ in () }
            .merge(with: store.$snapshot.map(\.limitReports).removeDuplicates().map { _ in () })
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self, weak store] in
                guard let self, let store else { return }
                self.check(store.limitReports)
            }
            .store(in: &cancellables)
    }

    private func check(_ reports: [AgentLimitReport]) {
        guard Preferences.shared.notifyRouting else { return }
        var sent = Set(defaults.stringArray(forKey: Self.key) ?? [])
        for alert in LimitRouting.alerts(reports: reports) where !sent.contains(alert.id) {
            sent.insert(alert.id)
            post(alert)
            if Preferences.shared.notchAlerts {
                NotchController.shared.show(NotchAlert(id: alert.id, kind: .limit, agent: alert.window.agent, title: alert.title,
                                                       detail: alert.body, badge: "Running hot", sessionID: nil), seconds: 6)
            }
        }
        // Keep the last few hundred so the list doesn't grow forever.
        defaults.set(Array(sent.suffix(300)), forKey: Self.key)
    }

    private func post(_ alert: LimitRouteAlert) {
        guard AgentNotifier.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        // Same identifier as AgentNotifier's pace alert for this window, so the routed version replaces that one
        // in Notification Center instead of stacking a second banner about the same window.
        let identifier = "pace-\(alert.window.agent.rawValue)|\(alert.window.label)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
