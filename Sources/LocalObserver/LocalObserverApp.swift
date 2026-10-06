import SwiftUI
import AppKit
import WidgetKit
import LocalObserverCore
import LocalObserverShelf
import LocalObserverRepos
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let directory = SnapshotHarness.directory {
            NSApp.windows.forEach { $0.orderOut(nil) }
            SnapshotHarness.run(to: directory)
            return
        }
        #endif
        // `swift run` launches a bare executable; make it a proper foreground app with a Dock icon.
        NSApp.setActivationPolicy(Preferences.shared.showDockIcon ? .regular : .accessory)
        NSApp.activate(ignoringOtherApps: true)
        // The Shelf stands on its own: it records the clipboard and feeds its widget with no servers or agents at all.
        MainActor.assumeIsolated {
            ShelfStore.shared.widgetDidChange = { WidgetCenter.shared.reloadTimelines(ofKind: ShelfWidgetSnapshot.widgetKind) }
            ShelfStore.shared.start()
            // Repos too: it scans git and asks GitHub on its own schedule, whatever else is running.
            RepoStore.shared.start()
            RepoNotifier.shared.attach(to: RepoStore.shared)
        }
        if AgentNotifier.isAvailable { UNUserNotificationCenter.current().delegate = self }
    }

    /// Clicking a pull request notification opens it on GitHub; any other brings Lookout forward.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let url = response.notification.request.content.userInfo["url"] as? String
        DispatchQueue.main.async {
            if let url, let link = URL(string: url) { NSWorkspace.shared.open(link) } else { NSApp.activate(ignoringOtherApps: true) }
        }
        completionHandler()
    }

    /// Show banners even while Lookout is the frontmost app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicks on the desktop widgets arrive as `localobserver://` URLs.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(LiveSurfaces.shared.handle) }
    }

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { LiveSurfaces.shared.dockMenu() }

    func applicationWillTerminate(_ notification: Notification) {
        SystemControls.restoreDisplays()
        MainActor.assumeIsolated {
            AppAudio.shared.stopAll()
            ShelfStore.shared.saveNow()
        }
    }

    /// Keep running in the menu bar when the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct LocalObserverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var agentStore = AgentStore()
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some Scene {
        Window("Lookout", id: "main") {
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
                    if state.sidebar.isAgentPage { agentStore.refresh() }
                    else if state.sidebar == .github { GitHubStore.shared.refreshCurrent() }
                    else if state.sidebar == .cleanup { DiskCoordinator.shared.scan() }
                    else if state.sidebar == .ci { CIStore.shared.refresh() }
                    else if state.sidebar.isRepoPage { RepoStore.shared.refresh(); RepoStore.shared.refreshGitHub() }
                    else { state.refresh() }
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
                // The global shortcut fires first; this just shows it in the menu.
                Button("Toggle Agent Peek") { LiveSurfaces.shared.togglePeek() }
                    .keyboardShortcut(prefs.peekHotKey?.keyboardShortcut)
                Button("Open Menu Bar Panel") { LiveSurfaces.shared.toggleMenuBarPanel() }
                    .keyboardShortcut(prefs.menuBarHotKey?.keyboardShortcut)
                Button("Open Notch") { NotchController.shared.toggle() }
                    .keyboardShortcut(prefs.notchHotKey?.keyboardShortcut)
                    .disabled(!prefs.notchEnabled)
                Divider()
                Button("Refresh Agents and Limits") { agentStore.refresh(forceLimits: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Jump to Session") {
                    if let session = agentStore.selectedSession { AgentActions.jump(to: session) }
                }
                .keyboardShortcut("j")
                .disabled(agentStore.selectedSession?.process?.host == nil)
            }
            CommandMenu("Repos") {
                Button("Repositories") { state.sidebar = .repos }
                    .keyboardShortcut("4", modifiers: [.command, .option])
                Button("GitHub") { state.sidebar = .github }
                    .keyboardShortcut("5", modifiers: [.command, .option])
                Button("Pull Requests") { state.sidebar = .pullRequests }
                    .keyboardShortcut("6", modifiers: [.command, .option])
                Divider()
                Button("Fetch All Repositories") { RepoStore.shared.fetchAll() }
                Button("Refresh Pull Requests") { RepoStore.shared.refreshGitHub() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                let repo = state.sidebar == .repos ? RepoStore.shared.selected : nil
                Button("Open Repository in Editor") { repo.map { RepoActions.openEditor($0.root) } }
                    .keyboardShortcut("e")
                    .disabled(repo == nil)
                Button("Pull Selected Repository") { repo.map { RepoStore.shared.pull($0) } }
                    .disabled(repo?.status.upstream == nil)
            }
            CommandMenu("Shelf") {
                // The global shortcut fires first; this just shows it in the menu.
                Button("Search Clipboard History") { NotchController.shared.toggleClipboardHistory() }
                    .keyboardShortcut(prefs.shelfHotKey?.keyboardShortcut)
                    .disabled(!prefs.notchEnabled)
                Button("Open Shelf") { NotchController.shared.openShelf(.shelf) }
                    .disabled(!prefs.notchEnabled)
                Divider()
                Toggle("Pause Clipboard History", isOn: $shelf.isPaused)
                Button("Clear Shelf") { shelf.clearShelf() }
                    .disabled(!shelf.shelf.contains { !$0.pinned })
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
            MenuBarLabel(state: state, agentStore: agentStore)
                .task { AgentNotifier.shared.attach(to: agentStore) }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar title built from the items chosen in Settings › Menu Bar & Dock.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var repoStore: RepoStore = .shared
    @ObservedObject var prefs = Preferences.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let parts = prefs.menuBarItems.compactMap(part)
        HStack(spacing: 3) {
            if parts.isEmpty {
                Image(systemName: "server.rack")
            } else {
                ForEach(parts, id: \.item) { part in
                    Image(systemName: part.item.symbol)
                    if !part.text.isEmpty { Text(part.text).monospacedDigit() }
                }
            }
        }
        .task {
            LiveSurfaces.shared.attach(state: state, agentStore: agentStore) { _ in openWindow(id: "main") }
        }
    }

    private func part(_ item: MenuBarItem) -> (item: MenuBarItem, text: String)? {
        let running = agentStore.runningSessions.count
        let attention = agentStore.attentionSessions.count
        let today = agentStore.todayTotals
        switch item {
        case .servers:
            // Always show the anchor icon, even when nothing is listening.
            let count = state.visibleServers.count
            return (item, count > 0 ? "\(count)" : "")
        case .agents:
            if prefs.menuBarItems.contains(.attention) && attention > 0 { return nil }
            return running > 0 ? (item, "\(running)") : nil
        case .attention:
            return attention > 0 ? (item, "\(attention)") : nil
        case .limit:
            // Same providers as the notch ring (Settings › Menu Bar & Notch › Plan limits).
            let windows = prefs.glanceWindows(from: agentStore.limitReports.flatMap(\.windows))
            return windows.max { $0.usedPercent < $1.usedPercent }.map { (item, "\(Int($0.usedPercent.rounded()))%") }
        case .todayCost:
            return today.hasCost ? (item, AgentFormat.cost(today.cost)) : nil
        case .todayTokens:
            return today.processed > 0 ? (item, AgentFormat.compact(Double(today.processed))) : nil
        case .pullRequests:
            let count = repoStore.pullsNeedingYou.count
            return count > 0 ? (item, "\(count)") : nil
        }
    }
}
