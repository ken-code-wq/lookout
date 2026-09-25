#if DEBUG
import SwiftUI
import AppKit
import LocalObserverCore

/// Debug-only: `LOCAL_OBSERVER_SNAPSHOT_DIR=/tmp/shots .build/debug/LocalObserver` renders each agent page
/// offscreen in light and dark mode, writes PNGs, and quits. Nothing is shown on screen or activated.
@MainActor
enum SnapshotHarness {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static var windows: [NSWindow] = []

    static func run(to directory: URL) {
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "LocalObserver.snapshots") ?? .standard
        let firstRun = ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_FIRST_RUN"] == "1"
        var settings = AgentSettings()
        settings.hasCompletedSetup = !firstRun
        settings.accountLimitAgents = firstRun ? [] : Set(AgentKind.allCases.filter(AgentLimitClients.supportsAccountLimits))
        defaults.set(try? JSONEncoder().encode(settings), forKey: "LocalObserver.agentSettings")
        let store = AgentStore(defaults: defaults)
        let width = Double(ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_WIDTH"] ?? "") ?? 1180

        Task { @MainActor in
            // Wait for the process scan and the (slower) account limits.
            for _ in 0..<240 where store.lastRefresh == nil || store.isScanning || store.accountReports.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(1))
            if let first = store.runningSessions.first { store.selectedSessionID = first.id }

            let pages: [(String, AnyView, CGSize)] = [
                ("activity", AnyView(AgentActivityPage(store: store)), CGSize(width: width, height: 1300)),
                ("usage", AnyView(AgentUsagePage(store: store)), CGSize(width: width, height: 1400)),
                ("limits", AnyView(AgentLimitsPage(store: store)), CGSize(width: width, height: 1100)),
                ("inspector", AnyView(inspector(store)), CGSize(width: 360, height: 900)),
                ("settings", AnyView(AgentSettingsView(store: store)), CGSize(width: 620, height: 560)),
                ("menubar", AnyView(MenuBarView(state: AppState(), agentStore: store)), CGSize(width: 360, height: 700))
            ]
            for (name, view, size) in pages {
                for dark in [false, true] {
                    let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                    await render(view, size: size, dark: dark, to: url)
                }
            }
            print("Snapshots written to \(directory.path)")
            exit(0)
        }
    }

    @ViewBuilder private static func inspector(_ store: AgentStore) -> some View {
        if let session = store.selectedSession ?? store.recentSessions.first {
            AgentInspectorView(store: store, session: session)
        } else {
            Text("No session")
        }
    }

    private static func render(_ view: AnyView, size: CGSize, dark: Bool, to url: URL) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(N.bg))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
