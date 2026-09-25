import SwiftUI
import AppKit
import LocalObserverCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let directory = SnapshotHarness.directory {
            NSApp.windows.forEach { $0.orderOut(nil) }
            SnapshotHarness.run(to: directory)
            return
        }
        #endif
        // `swift run` launches a bare executable; make it a proper foreground app with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running in the menu bar when the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct LocalObserverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var agentStore = AgentStore()

    var body: some Scene {
        Window("Local Observer", id: "main") {
            ContentView(state: state, agentStore: agentStore)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Server…") { state.draft = LauncherDraft() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    if state.sidebar.isAgentPage { agentStore.refresh() } else { state.refresh() }
                }
                    .keyboardShortcut("r")
                Picker("View", selection: $state.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show System Ports", isOn: $state.showSystem)
                Divider()
            }
            CommandMenu("Agents") {
                Button("Activity") { state.sidebar = .agentActivity }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Usage") { state.sidebar = .agentUsage }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Limits") { state.sidebar = .agentLimits }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                Button("Refresh Agents and Limits") { agentStore.refresh(forceLimits: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Jump to Session") {
                    if let session = agentStore.selectedSession { AgentActions.jump(to: session) }
                }
                .keyboardShortcut("j")
                .disabled(agentStore.selectedSession?.process?.host == nil)
            }
            CommandMenu("Server") {
                let s = state.selected
                Button("Open in Browser") { s.map(state.open) }
                    .keyboardShortcut("o")
                    .disabled(s == nil)
                Button("Copy URL") { s.map { state.copy($0.urlString, label: $0.urlString) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(s == nil)
                Button("Reveal in Finder") { s.map(state.reveal) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(s?.workingDirectory.isEmpty ?? true)
                Button("Toggle Favorite") { s.map(state.toggleFavorite) }
                    .keyboardShortcut("d")
                    .disabled(s == nil)
                Divider()
                Button("Stop") { s.map { state.stop($0) } }
                    .keyboardShortcut(.delete)
                    .disabled(s == nil)
                Button("Force Quit") { s.map { state.stop($0, force: true) } }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(s == nil)
            }
        }

        Settings {
            AgentSettingsView(store: agentStore)
        }

        MenuBarExtra {
            MenuBarView(state: state, agentStore: agentStore)
        } label: {
            MenuBarLabel(
                serverCount: state.visibleServers.count,
                agentCount: agentStore.runningSessions.count,
                attentionCount: agentStore.attentionSessions.count
            )
            .task { AgentNotifier.shared.attach(to: agentStore) }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    var serverCount: Int
    var agentCount: Int
    var attentionCount: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "server.rack")
            if serverCount > 0 { Text("\(serverCount)").monospacedDigit() }
            if attentionCount > 0 {
                // A raised hand reads as "needs you" even in a monochrome menu bar.
                Image(systemName: "hand.raised.fill")
                Text("\(attentionCount)").monospacedDigit()
            } else if agentCount > 0 {
                Image(systemName: "sparkles")
                Text("\(agentCount)").monospacedDigit()
            }
        }
    }
}
