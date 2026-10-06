import Foundation
import Combine
import UserNotifications
import LocalObserverRepos
import LocalObserverWidgetUI

/// Points CI & Deploys at the GitHub repositories cloned on this Mac, and tells you when one of your runs finishes
/// on a branch without an open pull request (those already alert through their checks).
@MainActor
final class CICoordinator {
    static let shared = CICoordinator()
    private var cancellables: Set<AnyCancellable> = []

    func attach(state: AppState) {
        guard cancellables.isEmpty else { return }
        let ci = CIStore.shared
        ci.onActionResult = { [weak state] message, ok in
            state?.show(Toast(message: message, symbol: ok ? "checkmark.circle" : "exclamationmark.triangle", tone: ok ? .success : .danger))
        }
        ci.onRunFinished = { run in CICoordinator.shared.finished(run) }
        let repos = RepoStore.shared
        repos.$repos
            .combineLatest(repos.$gitHub)
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { list, status in
                guard status.login != nil, repos.settings.gitHubEnabled else { return }
                // Most recently worked-on first; a dozen keeps polling light.
                let slugs = list.filter { $0.github != nil && !repos.settings.hidden.contains($0.root) }
                    .sorted { ($0.lastTouched ?? .distantPast) > ($1.lastTouched ?? .distantPast) }
                    .compactMap(\.github)
                ci.watch(Array(slugs.prefix(12)))
            }
            .store(in: &cancellables)
    }

    private func finished(_ run: GHRun) {
        let repos = RepoStore.shared
        guard let login = repos.gitHub.login, run.actor.caseInsensitiveCompare(login) == .orderedSame,
              run.status == .failure || run.status == .success else { return }
        if repos.pulls.contains(where: { $0.repo.caseInsensitiveCompare(run.repo) == .orderedSame && $0.branch == run.branch }) { return }
        let failed = run.status == .failure
        let title = failed ? "\(run.workflow) failed on \(run.branch)" : "\(run.workflow) passed on \(run.branch)"
        let detail = "\(run.repoName): \(run.title)"
        if AgentNotifier.isAvailable {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = detail
            content.sound = .default
            content.userInfo = ["url": "\(WidgetLink.scheme)://ci"]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "run-\(run.id)-\(run.attempt)", content: content, trigger: nil))
        }
        if Preferences.shared.notchAlerts {
            NotchController.shared.show(NotchAlert(id: "run-\(run.id)", kind: failed ? .checksFailed : .checksPassed, agent: nil,
                                                   title: title, detail: detail, badge: failed ? "CI failed" : "CI passed", sessionID: nil,
                                                   symbol: failed ? "xmark.circle.fill" : "checkmark.circle.fill",
                                                   url: "\(WidgetLink.scheme)://ci"), seconds: 6)
        }
        if failed { CIStore.shared.selectedRun = run.id }
    }
}
