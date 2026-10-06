import SwiftUI
import Combine
import Sparkle

/// Sparkle auto-updates, reading the appcast at SUFeedURL (packaging/Info.plist).
/// Only runs in a packaged build that has the EdDSA public key baked in (build-app.sh fills SUPublicEDKey from
/// LOOKOUT_SPARKLE_PUBLIC_KEY). Without one, there's nothing to verify updates against, so the updater never
/// starts: no checks, no prompts, and the "Check for Updates…" items stay hidden.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false
    @Published var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    var isAvailable: Bool { controller != nil }

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let feed = info["SUFeedURL"] as? String ?? ""
        return Bundle.main.bundleURL.pathExtension == "app" && !key.isEmpty && !feed.isEmpty
    }

    private init() {
        guard Self.isConfigured else {
            controller = nil
            automaticallyChecks = false
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
    }

    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

/// "Check for Updates…" for the app menu; absent when this build can't update itself.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if updater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        }
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Text("Updates").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.top, 22).padding(.bottom, 8)
        SettingsGroup {
            if updater.isAvailable {
                SettingsRow(title: "Check for updates automatically", detail: "Once a day, from the release feed on GitHub") {
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Version \(Self.version)", detail: "Updates are signed and verified before they install") {
                    Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                }
            } else {
                SettingsRow(title: "Version \(Self.version)", detail: "This build doesn't update itself. Download new versions from GitHub.") {
                    Button("Releases") { NSWorkspace.shared.open(URL(string: "https://github.com/ken-code-wq/lookout/releases")!) }
                }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }
}
