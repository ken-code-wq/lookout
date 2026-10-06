import Foundation
import Combine
import UserNotifications
import LocalObserverRepos

/// Tells you when a pull request changes in a way you'd act on: checks fail or pass on one of yours, it's approved
/// or gets changes requested, or someone asks for your review. Each change alerts once, as a notification and a
/// drop-down from the notch. The first fetch after launch only primes, so nothing already true is replayed.
@MainActor
final class RepoNotifier {
    static let shared = RepoNotifier()

    private var cancellables: Set<AnyCancellable> = []
    private var attached = false
    private var previous: [String: PullRequest] = [:]
    private var primed = false

    func attach(to store: RepoStore) {
        guard !attached else { return }
        attached = true
        store.$pulls
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] pulls in
                guard let self, let store else { return }
                self.check(pulls, settings: store.settings, signedIn: store.gitHub.login != nil)
            }
            .store(in: &cancellables)
    }

    private func check(_ pulls: [PullRequest], settings: RepoSettings, signedIn: Bool) {
        defer {
            previous = Dictionary(pulls.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            if signedIn { primed = true }
        }
        guard primed else { return }
        var alert: NotchAlert?
        for pull in pulls {
            let old = previous[pull.url]
            switch pull.role {
            case .reviewRequested:
                guard old == nil, settings.notifyReviewRequested else { continue }
                post(id: "review-\(pull.url)", title: "\(pull.author) asked for your review",
                     body: "\(pull.repoName) #\(pull.number): \(pull.title)", url: pull.url)
                alert = alert ?? NotchAlert(id: "review-\(pull.url)", kind: .review, agent: nil, title: pull.title,
                                            detail: "\(pull.author) asked for your review on \(pull.repoName) #\(pull.number)",
                                            badge: "Review", sessionID: nil, symbol: "eye.fill", url: pull.url)
            case .mine:
                guard let old else { continue }
                if old.checks != .failure, pull.checks == .failure, settings.notifyChecksFailed {
                    post(id: "checks-failed-\(pull.url)-\(pull.updatedAt.timeIntervalSince1970)", title: "Checks failed on \(pull.repoName) #\(pull.number)",
                         body: pull.title, url: pull.url + "/checks")
                    // A failure outranks anything else in the same fetch.
                    alert = NotchAlert(id: "checks-failed-\(pull.url)", kind: .checksFailed, agent: nil, title: pull.title,
                                       detail: "Checks failed on \(pull.repoName) #\(pull.number)", badge: "Checks failed",
                                       sessionID: nil, symbol: "xmark.circle.fill", url: pull.url + "/checks")
                } else if old.checks == .pending, pull.checks == .success, settings.notifyChecksPassed {
                    post(id: "checks-passed-\(pull.url)-\(pull.updatedAt.timeIntervalSince1970)", title: "Checks passed on \(pull.repoName) #\(pull.number)",
                         body: pull.isReadyToMerge ? "\(pull.title). Approved and ready to merge." : pull.title, url: pull.url)
                    alert = alert ?? NotchAlert(id: "checks-passed-\(pull.url)", kind: .checksPassed, agent: nil, title: pull.title,
                                                detail: pull.isReadyToMerge ? "Green and approved: ready to merge" : "Checks passed on \(pull.repoName) #\(pull.number)",
                                                badge: "Checks passed", sessionID: nil, symbol: "checkmark.circle.fill", url: pull.url)
                }
                if old.review != pull.review, settings.notifyApproved {
                    if pull.review == .approved {
                        post(id: "approved-\(pull.url)", title: "\(pull.repoName) #\(pull.number) was approved", body: pull.title, url: pull.url)
                        alert = alert ?? NotchAlert(id: "approved-\(pull.url)", kind: .checksPassed, agent: nil, title: pull.title,
                                                    detail: "Approved on \(pull.repoName) #\(pull.number)", badge: "Approved",
                                                    sessionID: nil, symbol: "hand.thumbsup.fill", url: pull.url)
                    } else if pull.review == .changesRequested {
                        post(id: "changes-\(pull.url)-\(pull.updatedAt.timeIntervalSince1970)", title: "Changes requested on \(pull.repoName) #\(pull.number)",
                             body: pull.title, url: pull.url)
                        alert = alert ?? NotchAlert(id: "changes-\(pull.url)", kind: .checksFailed, agent: nil, title: pull.title,
                                                    detail: "Changes requested on \(pull.repoName) #\(pull.number)", badge: "Changes requested",
                                                    sessionID: nil, symbol: "text.bubble.fill", url: pull.url)
                    }
                }
            }
        }
        if let alert, Preferences.shared.notchAlerts { NotchController.shared.show(alert, seconds: 6) }
    }

    private func post(id: String, title: String, body: String, url: String) {
        guard AgentNotifier.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["url": url]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
