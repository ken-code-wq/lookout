import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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

    var body: some Scene {
        Window("Local Observer", id: "main") {
            ContentView(state: state)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Server…") { state.draft = LauncherDraft() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { state.refresh() }
                    .keyboardShortcut("r")
                Picker("View", selection: $state.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show System Ports", isOn: $state.showSystem)
                Divider()
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

        MenuBarExtra {
            MenuBarView(state: state)
        } label: {
            MenuBarLabel(count: state.visibleServers.count)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    var count: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "server.rack" : "server.rack")
            if count > 0 { Text("\(count)").monospacedDigit() }
        }
    }
}
