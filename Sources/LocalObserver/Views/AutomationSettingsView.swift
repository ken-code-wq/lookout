import SwiftUI
import AppKit
import LocalObserverCore

/// Settings › Automation: the `lookout` CLI, lookout:// links, and whether Shortcuts can see Lookout's actions.
struct AutomationSettingsPane: View {
    @State private var installedPath = CLIInstaller.installedPath
    @State private var message: (text: String, ok: Bool)?

    /// Shortcuts lists App Intents only from bundles carrying the metadata Xcode's processor generates.
    private let hasIntentsMetadata = Bundle.main.url(forResource: "Metadata", withExtension: "appintents") != nil

    var body: some View {
        SettingsPage(title: "Automation", message: "Drive Lookout from scripts, Raycast, and Shortcuts. Everything here goes through the same actions as the app's own buttons.") {
            SettingsHeader("Command line", first: true)
            SettingsGroup {
                SettingsRow(title: "Command-line tool",
                            detail: installedPath.map { "Installed at \(($0 as NSString).abbreviatingWithTildeInPath)" }
                                ?? "lookout status --json, lookout open usage, lookout launcher start web") {
                    Button(installedPath == nil ? "Install command-line tool" : "Reinstall") { install() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(CLIInstaller.bundledTool == nil)
                }
            }
            if let message {
                Text(message.text)
                    .font(NFont.caption)
                    .foregroundStyle(message.ok ? N.text2 : TagColor.orange.fg)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            SettingsHeader("Links")
            SettingsGroup {
                ForEach(Array(Self.examples.enumerated()), id: \.offset) { index, example in
                    SettingsRow(title: example.url, detail: example.detail) {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(example.url, forType: .string)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if index < Self.examples.count - 1 { SettingsDivider() }
                }
            }

            SettingsHeader("Shortcuts")
            Text(hasIntentsMetadata
                 ? "Lookout's actions are in the Shortcuts app: agents needing you, plan limit left, launchers, pages, keep-awake and the focus timer."
                 : "This build doesn't include Shortcuts actions (they need Xcode to package). Use a “Run Shell Script” action with the lookout tool, or an “Open URLs” action with a lookout:// link.")
                .font(NFont.small).foregroundStyle(N.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let examples: [(url: String, detail: String)] = [
        ("lookout://open/limits", "Open a page: dashboard, sessions, usage, limits, repos, servers, launchers…"),
        ("lookout://launcher/web/start", "Start, stop or toggle a launcher by name"),
        ("lookout://palette", "Open the ⌘K palette"),
        ("lookout://new-task", "Start a new agent task; lookout://weekly-report opens the weekly report"),
        ("lookout://keep-awake/toggle", "Keep-awake on, off or toggle"),
        ("lookout://timer/start/25", "Start a focus timer; lookout://timer/stop ends it")
    ]

    private func install() {
        do {
            let link = try CLIInstaller.install()
            installedPath = link
            let directory = (link as NSString).deletingLastPathComponent
            let pathHint = directory == "/usr/local/bin" ? "" : " If your shell can't find it, add \((directory as NSString).abbreviatingWithTildeInPath) to your PATH."
            message = ("Linked \(link). Try `lookout status` in a new terminal.\(pathHint)", true)
        } catch {
            message = (error.localizedDescription, false)
        }
    }
}
