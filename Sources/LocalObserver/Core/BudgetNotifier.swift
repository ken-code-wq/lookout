import Foundation
import Combine
import UserNotifications
import LocalObserverCore

/// Warns once per agent, period and level (nearing, then over) when spending crosses a budget. Remembered across
/// launches, so a restart doesn't repeat today's warning.
@MainActor
final class BudgetNotifier {
    static let shared = BudgetNotifier()

    private var cancellables: Set<AnyCancellable> = []
    private let defaults = UserDefaults.standard
    private static let key = "LocalObserver.budgetAlerts"

    func attach(to store: AgentStore) {
        guard cancellables.isEmpty else { return }
        store.$spend
            .combineLatest(store.$settings.map(\.budgets).removeDuplicates())
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] spend, budgets in self?.check(spend, budgets) }
            .store(in: &cancellables)
    }

    private func check(_ spend: [AgentKind: AgentSpend], _ budgets: [AgentKind: AgentBudget]) {
        var sent = Set(defaults.stringArray(forKey: Self.key) ?? [])
        let day = Date().formatted(.iso8601.year().month().day())
        let week = "w" + String(Calendar.current.component(.weekOfYear, from: Date()))
        for (agent, budget) in budgets {
            let s = spend[agent] ?? AgentSpend()
            for (cap, spent, period, stamp) in [(budget.daily, s.today, "today", day), (budget.weekly, s.week, "this week", week)] {
                guard let cap, cap > 0 else { continue }
                let fraction = spent / cap
                let level = fraction >= 1 ? "over" : (fraction >= budget.warnAt ? "near" : nil)
                guard let level else { continue }
                let id = "\(agent.rawValue)-\(period)-\(stamp)-\(level)"
                guard !sent.contains(id) else { continue }
                sent.insert(id)
                let title = level == "over" ? "\(agent.name) is over budget \(period)" : "\(agent.name) is at \(Int(fraction * 100))% of its budget \(period)"
                let body = "\(AgentFormat.cost(spent)) of \(AgentFormat.cost(cap)) spent."
                post(id: id, title: title, body: body)
                if Preferences.shared.notchAlerts {
                    NotchController.shared.show(NotchAlert(id: id, kind: .limit, agent: agent, title: title, detail: body,
                                                           badge: level == "over" ? "Over budget" : "Budget", sessionID: nil), seconds: 6)
                }
            }
        }
        // Keep the last few hundred so the list doesn't grow forever.
        defaults.set(Array(sent.suffix(300)), forKey: Self.key)
    }

    private func post(id: String, title: String, body: String) {
        guard AgentNotifier.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
