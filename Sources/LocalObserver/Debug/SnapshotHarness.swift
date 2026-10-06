#if DEBUG
import SwiftUI
import AppKit
import WidgetKit
import LocalObserverCore
import LocalObserverWidgetUI
import LocalObserverShelf
import LocalObserverRepos
import LocalObserverDisk

/// Debug-only: `LOCAL_OBSERVER_SNAPSHOT_DIR=/tmp/shots .build/debug/LocalObserver` renders each agent page
/// offscreen in light and dark mode, writes PNGs, and quits. Nothing is shown on screen or activated.
@MainActor
enum SnapshotHarness {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static var windows: [NSWindow] = []

    /// A server list for a render: this Mac's, or the fake one in demo mode.
    private static func makeState() -> AppState {
        let state = AppState()
        if SnapshotDemo.isEnabled { SnapshotDemo.loadServers(into: state) }
        return state
    }

    /// `LOCAL_OBSERVER_SNAPSHOT_ONLY=peek` renders just the shots whose names start with it.
    private static func wanted(_ name: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_ONLY"], !only.isEmpty else { return true }
        return name.hasPrefix(only)
    }

    static func run(to directory: URL) {
        if ProcessInfo.processInfo.environment["LOCAL_OBSERVER_AUDIO_LIST"] == "1" {
            AppAudio.shared.refresh()
            for app in AppAudio.shared.apps { print("app:", app.name, app.bundleID, "processes:", app.processObjects.count, "playing:", app.isPlaying, app.bundleIDs) }
            for device in AppAudio.shared.outputs { print("output:", device.name, device.uid, device.transport, device.uid == AppAudio.shared.systemOutputUID ? "(system)" : "") }
            exit(0)
        }
        NSApp.setActivationPolicy(.prohibited)
        if ProcessInfo.processInfo.environment["LOCAL_OBSERVER_BENCH"] == "1" {
            // Times full agent scans back to back: the first fills the caches, the rest are what every refresh costs.
            Task.detached {
                for agent in [nil] + AgentKind.allCases.map(Optional.some) {
                    let agents = agent.map { Set([$0]) } ?? []
                    var times: [Int] = []
                    for _ in 1...3 {
                        let start = Date()
                        _ = await AgentDiscovery.scan(enabledAgents: agents, historyDays: 90)
                        times.append(Int(Date().timeIntervalSince(start) * 1000))
                    }
                    print("\(agent?.name ?? "none (processes only)"): \(times.map { "\($0) ms" }.joined(separator: ", "))")
                }
                exit(0)
            }
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_WIDGETS"] == "1" {
            Task { @MainActor in
                if ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_PUBLISH"] == "1" {
                    // Publish live data (servers with their resolved icons) through the app's own path first.
                    let state = AppState()
                    let store = AgentStore()
                    state.refresh()
                    try? await Task.sleep(for: .seconds(8))
                    for server in state.visibleServers { _ = await IconStore.shared.icon(for: server) }
                    WidgetPublisher.shared.publish(state: state, agentStore: store)
                }
                for dark in [false, true] {
                    let url = directory.appendingPathComponent("widgets-\(dark ? "dark" : "light").png")
                    await render(AnyView(WidgetSheet(snapshot: WidgetSnapshot.load() ?? .sample(), shelf: ShelfWidgetSnapshot.load() ?? .sample())),
                                 size: WidgetSheet.size, dark: dark, to: url)
                }
                let empty = directory.appendingPathComponent("widgets-empty.png")
                await render(AnyView(WidgetSheet(snapshot: nil, shelf: nil)), size: WidgetSheet.size, dark: false, to: empty)
                print("Widget sheets written to \(directory.path)")
                exit(0)
            }
            return
        }
        let defaults = UserDefaults(suiteName: "LocalObserver.snapshots") ?? .standard
        let firstRun = ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_FIRST_RUN"] == "1"
        var settings = AgentSettings()
        settings.hasCompletedSetup = !firstRun
        settings.accountLimitAgents = firstRun ? [] : Set(AgentKind.allCases.filter(AgentLimitClients.supportsAccountLimits))
        settings.budgets = [.claude: AgentBudget(daily: 8, weekly: 40), .codex: AgentBudget(daily: 1)]
        defaults.set(try? JSONEncoder().encode(settings), forKey: "LocalObserver.agentSettings")
        let demo = SnapshotDemo.isEnabled
        // Demo stores never read or write the real usage ledger, and never scan.
        let store = demo ? AgentStore(defaults: defaults, autoStart: false, persistsLedger: false) : AgentStore(defaults: defaults)
        let width = Double(ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_WIDTH"] ?? "") ?? 1180

        if demo {
            SnapshotDemo.loadAgents(into: store)
            SnapshotDemo.loadAudio()
            SnapshotDemo.loadRepos(into: RepoStore.shared)
            SnapshotDemo.loadGitHub(into: GitHubStore.shared)
            SnapshotDemo.loadDisk(into: DiskStore.shared)
            SnapshotDemo.loadCI(into: CIStore.shared)
        } else {
            AppAudio.shared.refresh()
        }
        Task { @MainActor in
            if demo {
                // Usage reports are built off the main actor; wait until they've landed.
                for _ in 0..<240 where !store.isUsageReady { try? await Task.sleep(for: .milliseconds(100)) }
            } else {
                // Wait for the process scan and the (slower) account limits.
                for _ in 0..<240 where store.lastRefresh == nil || store.isScanning || store.accountReports.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            try? await Task.sleep(for: .seconds(1))
            if let first = store.runningSessions.first { store.selectedSessionID = first.id }

            let pages: [(String, AnyView, CGSize)] = [
                ("activity", AnyView(AgentActivityPage(store: store)), CGSize(width: width, height: 1300)),
                ("usage", AnyView(AgentUsagePage(store: store)), CGSize(width: width, height: 1400)),
                ("limits", AnyView(AgentLimitsPage(store: store)), CGSize(width: width, height: 1100)),
                ("inspector", AnyView(inspector(store)), CGSize(width: 360, height: 900)),
                ("settings", AnyView(AgentSettingsView(store: store)), CGSize(width: 620, height: 560)),
                ("menubar", AnyView(MenuBarView(state: makeState(), agentStore: store)), CGSize(width: 360, height: 1300)),
                ("servers", AnyView(ServersPage(state: makeState())), CGSize(width: width, height: 700)),
                ("repos", AnyView(reposPage()), CGSize(width: width, height: 900)),
                ("repo-inspector", AnyView(repoInspector()), CGSize(width: 360, height: 1000)),
                ("pulls", AnyView(PullRequestsPage(store: RepoStore.shared)), CGSize(width: width, height: 800)),
                ("settings-repos", AnyView(RepoSettingsPane()), CGSize(width: 620, height: 900)),
                ("cleanup", AnyView(CleanupPage(store: DiskStore.shared)), CGSize(width: width, height: 1500)),
                ("ci", AnyView(CIPage(store: CIStore.shared, repos: RepoStore.shared, agents: store)), CGSize(width: width, height: 1200)),
                ("replay", AnyView(replay(store)), CGSize(width: 1180, height: 820)),
                ("settings-disk", AnyView(DiskSettingsPane()), CGSize(width: 620, height: 560)),
                ("gh-issues", AnyView(GHRepoView(store: GitHubStore.shared, repos: RepoStore.shared, slug: "acme/aurora-api", tab: .issues)), CGSize(width: width, height: 700)),
                ("gh-issue", AnyView(GHIssueView(store: GitHubStore.shared, slug: "acme/aurora-api", number: 231)), CGSize(width: width, height: 900)),
                ("inbox", AnyView(InboxPage(store: GitHubStore.shared, repos: RepoStore.shared)), CGSize(width: width, height: 700)),
                ("gh-repos", AnyView(GitHubPage(store: GitHubStore.shared, repos: RepoStore.shared, agents: store)), CGSize(width: width, height: 1100)),
                ("gh-code", AnyView(GHRepoView(store: GitHubStore.shared, repos: RepoStore.shared, slug: "acme/aurora-api", tab: .code)), CGSize(width: width, height: 1100)),
                ("gh-branches", AnyView(GHRepoView(store: GitHubStore.shared, repos: RepoStore.shared, slug: "acme/aurora-api", tab: .branches)), CGSize(width: width, height: 900)),
                ("gh-pulls", AnyView(GHRepoView(store: GitHubStore.shared, repos: RepoStore.shared, slug: "acme/aurora-api", tab: .pulls)), CGSize(width: width, height: 700)),
                ("gh-commits", AnyView(GHRepoView(store: GitHubStore.shared, repos: RepoStore.shared, slug: "acme/aurora-api", tab: .commits)), CGSize(width: width, height: 900)),
                ("gh-pull", AnyView(GHPullView(store: GitHubStore.shared, repos: RepoStore.shared, agents: store, slug: "acme/aurora-api", number: 214)), CGSize(width: width, height: 1700)),
                ("gh-files", AnyView(GHPullView(store: GitHubStore.shared, repos: RepoStore.shared, agents: store, slug: "acme/aurora-api", number: 214, initialTab: .files)), CGSize(width: width, height: 1000)),
            ]
            // Notch states, each as its own controller so modes don't bleed between renders.
            let sample = store.runningSessions.first
            let notchStates: [(String, NotchController.Mode, NotchAlert?)] = [
                ("notch-compact", .compact, nil),
                ("notch-alert", .alert, NotchAlert(id: "x", kind: .needsYou, agent: sample?.agent ?? .claude,
                                                   title: sample?.projectName ?? (demo ? "aurora-api" : "local-observer"),
                                                   detail: demo ? "Claude is waiting for you: Add rate limiting to /search"
                                                                : "Claude is waiting for you: Custom filters for filtering",
                                                   badge: "Needs approval", sessionID: nil)),
                ("notch-alert-reset", .alert, NotchAlert(id: "r", kind: .reset, agent: .claude, title: "Claude 5-hour session is back",
                                                         detail: "Limit reset. Agents can run again.", badge: "Back", sessionID: nil)),
                ("notch-expanded", .expanded, nil),
                ("notch-usage", .expanded, nil),
                ("notch-limits", .expanded, nil),
                ("notch-servers", .expanded, nil),
                ("notch-repos", .expanded, nil),
                ("notch-alert-checks", .alert, NotchAlert(id: "c", kind: .checksFailed, agent: nil, title: "Fix flaky auth test",
                                                          detail: "Checks failed on pixel-garden #88", badge: "Checks failed",
                                                          sessionID: nil, symbol: "xmark.circle.fill")),
                ("notch-media", .expanded, nil),
                ("notch-sound", .expanded, nil),
                ("notch-hud", .hud(.volume), nil),
                ("notch-limits-multi", .expanded, nil),
                ("notch-compact-multi", .compact, nil),
                ("notch-hover-multi", .compact, nil),
                ("notch-limits-p1", .expanded, nil),
                ("notch-limits-p3", .expanded, nil),
                ("notch-limits-p4", .expanded, nil),
            ]
            let providerSets: [String: [AgentKind]] = ["notch-limits-p1": [.claude], "notch-limits-p3": [.claude, .codex, .antigravity],
                                                       "notch-limits-p4": [.claude, .codex, .antigravity, .copilot]]
            let tabs: [String: NotchTab] = ["notch-usage": .usage, "notch-limits": .limits, "notch-servers": .servers, "notch-repos": .repos,
                                            "notch-media": .media, "notch-sound": .sound,
                                            "notch-limits-p1": .limits, "notch-limits-p3": .limits, "notch-limits-p4": .limits, "notch-limits-multi": .limits]
            for (name, mode, alert) in notchStates where wanted(name) {
                Preferences.shared.notchTab = tabs[name] ?? .agents
                Preferences.shared.limitProviders = providerSets[name] ?? (name.hasSuffix("-multi") ? [.claude, .codex, .copilot] : [])
                let controller = NotchController()
                controller.debugShow(mode, alert: alert, limitHover: name.hasPrefix("notch-hover"))
                let view = AnyView(NotchRootView(controller: controller, state: makeState(), agentStore: store)
                    .background(LinearGradient(colors: [Color(red: 0.2, green: 0.16, blue: 0.3), Color(red: 0.35, green: 0.18, blue: 0.3)],
                                               startPoint: .top, endPoint: .bottom)))
                let url = directory.appendingPathComponent("\(name).png")
                await render(view, size: NotchController.panelSize, dark: true, to: url)
            }
            for (name, view, size) in pages where wanted(name) {
                for dark in [false, true] {
                    let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                    await render(view, size: size, dark: dark, to: url)
                }
            }
            if wanted("home") {
                let shelf = await sampleShelf()
                for dark in [false, true] {
                    let view = AnyView(HomePage(state: makeState(), agentStore: store, shelf: shelf))
                    await render(view, size: CGSize(width: width, height: 1400), dark: dark,
                                 to: directory.appendingPathComponent("home-\(dark ? "dark" : "light").png"))
                }
            }
            // Shelf: a sample store in a temp folder (the user's real shelf is never read or written here), and an
            // empty one for the empty states. Agents and servers are whatever this Mac has; the Shelf doesn't care.
            if wanted("notch-shelf") || wanted("menubar-shelf") || wanted("settings-shelf") {
                let sample = await sampleShelf()
                let empty = ShelfStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("lookout-shelf-empty-\(UUID().uuidString)"),
                                       defaults: UserDefaults(suiteName: "LocalObserver.snapshots.shelf-empty") ?? .standard, publishesWidget: false)
                let shelfShots: [(String, ShelfStore, ShelfPresentation.Section)] = [
                    ("notch-shelf", sample, .shelf), ("notch-shelf-clipboard", sample, .clipboard),
                    ("notch-shelf-empty", empty, .shelf), ("notch-shelf-clipboard-empty", empty, .clipboard),
                ]
                Preferences.shared.notchTab = .shelf
                for (name, shelf, section) in shelfShots where wanted(name) {
                    ShelfPresentation.shared.section = section
                    let controller = NotchController()
                    controller.debugShow(.expanded)
                    let view = AnyView(NotchRootView(controller: controller, state: makeState(), agentStore: store, shelf: shelf)
                        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.16, blue: 0.3), Color(red: 0.35, green: 0.18, blue: 0.3)],
                                                   startPoint: .top, endPoint: .bottom)))
                    await render(view, size: NotchController.panelSize, dark: true, to: directory.appendingPathComponent("\(name).png"))
                }
                Preferences.shared.notchTab = .agents
                for dark in [false, true] {
                    let suffix = dark ? "dark" : "light"
                    if wanted("menubar-shelf") {
                        let menu = AnyView(MenuBarView(state: makeState(), agentStore: store, shelf: sample))
                        await render(menu, size: CGSize(width: 360, height: 1300), dark: dark, to: directory.appendingPathComponent("menubar-shelf-\(suffix).png"))
                        // The section alone: in the full panel it sits below the scroll area's fold.
                        for (label, shelf) in [("section", sample), ("section-empty", empty)] {
                            let section = AnyView(ShelfMenuContent(store: shelf) {}.padding(6).frame(width: 360, alignment: .top))
                            await render(section, size: CGSize(width: 360, height: 260), dark: dark,
                                         to: directory.appendingPathComponent("menubar-shelf-\(label)-\(suffix).png"))
                        }
                    }
                    if wanted("settings-shelf") {
                        await render(AnyView(ShelfSettingsPane(store: sample)), size: CGSize(width: 620, height: 760), dark: dark,
                                     to: directory.appendingPathComponent("settings-shelf-\(suffix).png"))
                    }
                }
            }

            // Agent Peek at each size. The canvas is the widest panel plus its shadow margin; the view sits top-leading.
            let peekState = makeState()
            let savedSize = Preferences.shared.peekSize
            let savedWidth = Preferences.shared.peekWidth
            LiquidGlass.forceFallback = true
            let prefs = Preferences.shared
            let saved = (prefs.peekShowsAgents, prefs.peekShowsLimits, prefs.peekLimitStyle, prefs.peekSetupDone)
            // Each size in each configuration: pie (the default), line, agents off, and the first-run prompt.
            let variants: [(String, Bool, PeekLimitStyle, Bool)] = [
                ("", true, .pie, true), ("-line", true, .line, true), ("-noagents", false, .pie, true), ("-noagents-line", false, .line, true),
                ("-setup", true, .pie, false),
            ]
            for size in PeekSize.allCases {
                for (suffix, agents, style, done) in variants where wanted("peek-\(size.rawValue)\(suffix)") {
                    prefs.peekSize = size
                    prefs.peekShowsAgents = agents
                    prefs.peekShowsLimits = true
                    prefs.peekLimitStyle = style
                    prefs.peekSetupDone = done
                    let view = AnyView(AgentPeekView(agentStore: store, state: peekState) { _ in }
                        .frame(width: 336, height: 620, alignment: .topLeading))
                    for dark in [false, true] {
                        let url = directory.appendingPathComponent("peek-\(size.rawValue)\(suffix)-\(dark ? "dark" : "light").png")
                        await render(view, size: CGSize(width: 336, height: 620), dark: dark, to: url)
                    }
                }
            }
            // Dragged widths between and beyond the presets.
            for width in [236.0, 300, 420] where wanted("peek-width-\(Int(width))") {
                prefs.peekWidth = width
                prefs.peekSetupDone = true
                prefs.peekShowsAgents = true
                prefs.peekLimitStyle = .pie
                let view = AnyView(AgentPeekView(agentStore: store, state: peekState) { _ in }
                    .frame(width: 476, height: 620, alignment: .topLeading))
                await render(view, size: CGSize(width: 476, height: 620), dark: true,
                             to: directory.appendingPathComponent("peek-width-\(Int(width))-dark.png"))
            }
            (prefs.peekShowsAgents, prefs.peekShowsLimits, prefs.peekLimitStyle, prefs.peekSetupDone) = saved
            Preferences.shared.peekSize = savedSize
            Preferences.shared.peekWidth = savedWidth
            LiquidGlass.forceFallback = false
            print("Snapshots written to \(directory.path)")
            exit(0)
        }
    }

    /// Every widget in every family on a wallpaper-ish backdrop, at macOS desktop widget sizes.
    private struct WidgetSheet: View {
        var snapshot: WidgetSnapshot?
        var shelf: ShelfWidgetSnapshot?
        static let size = CGSize(width: 1640, height: 1500)
        private let now = Date.now

        private static func frame(_ family: WidgetFamily) -> CGSize {
            switch family {
            case .systemSmall: return CGSize(width: 170, height: 170)
            case .systemMedium: return CGSize(width: 364, height: 170)
            case .systemLarge: return CGSize(width: 364, height: 382)
            default: return CGSize(width: 780, height: 382)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                row([("Agents", .systemSmall), ("Agents", .systemMedium), ("Limits", .systemSmall), ("Limits", .systemMedium)])
                row([("Usage", .systemSmall), ("Usage", .systemMedium), ("Servers", .systemSmall), ("Servers", .systemMedium)])
                row([("Agents", .systemLarge), ("Limits", .systemLarge), ("Usage", .systemLarge), ("Servers", .systemLarge)])
                row([("Overview", .systemLarge), ("Overview", .systemExtraLarge)])
                row([("Shelf", .systemSmall), ("Shelf", .systemMedium), ("ShelfEmpty", .systemSmall), ("ShelfEmpty", .systemMedium)])
            }
            .padding(36)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(LinearGradient(colors: [Color(red: 0.36, green: 0.45, blue: 0.56), Color(red: 0.62, green: 0.52, blue: 0.47)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        }

        private func row(_ items: [(String, WidgetFamily)]) -> some View {
            HStack(alignment: .top, spacing: 28) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    tile(item.0, item.1)
                }
            }
        }

        private func tile(_ kind: String, _ family: WidgetFamily) -> some View {
            let size = Self.frame(family)
            return Group {
                switch kind {
                case "Agents": AgentsWidgetView(snapshot: snapshot, now: now, family: family)
                case "Limits": LimitsWidgetView(snapshot: snapshot, now: now, family: family)
                case "Usage": UsageWidgetView(snapshot: snapshot, now: now, family: family)
                case "Servers": ServersWidgetView(snapshot: snapshot, now: now, family: family)
                case "Shelf": ShelfWidgetView(snapshot: shelf, now: now, family: family)
                case "ShelfEmpty":
                    ShelfWidgetView(snapshot: shelf.map { ShelfWidgetSnapshot(generatedAt: $0.generatedAt, total: 0, pinned: 0, items: []) },
                                    now: now, family: family)
                default: OverviewWidgetView(snapshot: snapshot, now: now, family: family)
                }
            }
            .padding(16)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(WidgetBackground())
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }

    /// A shelf with one of each kind on it and a short clipboard history, built through the store's own paths.
    private static func sampleShelf() async -> ShelfStore {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lookout-shelf-sample", isDirectory: true)
        try? fm.removeItem(at: root)
        let samples = root.appendingPathComponent("samples", isDirectory: true)
        try? fm.createDirectory(at: samples, withIntermediateDirectories: true)
        let notes = samples.appendingPathComponent("Release notes.md")
        try? Data("# Lookout 1.4\n\n- Shelf: drop zone and clipboard history\n- Agent Peek sizes\n- Session time left\n".utf8).write(to: notes)
        let mockup = samples.appendingPathComponent("Hero mockup.png")
        try? samplePNG(colors: [.systemIndigo, .systemPink], symbol: "sparkles").write(to: mockup)

        let store = ShelfStore(directory: root.appendingPathComponent("Shelf"),
                               defaults: UserDefaults(suiteName: "LocalObserver.snapshots.shelf") ?? .standard, publishesWidget: false)
        let shelfContents: [ShelfContent] = [
            .text("Ship the shelf before Friday. Pinned items survive Clear shelf."),
            .color(hex: "#FF6A3D", original: "#ff6a3d"),
            .link(URL(string: "https://developer.apple.com/documentation/swiftui/view/ondrop(of:istargeted:perform:)")!),
            .image(samplePNG(colors: [.systemTeal, .systemBlue], symbol: "photo"), ext: "png"),
            .file(notes),
            .file(mockup),
        ]
        for content in shelfContents {
            store.add([content], sourceApp: "com.apple.finder")
            try? await Task.sleep(for: .milliseconds(250))
        }
        let history: [(ShelfContent, String)] = [
            (.text("git rebase -i HEAD~3"), "com.apple.Terminal"),
            (.image(samplePNG(colors: [.systemOrange, .systemYellow], symbol: "camera.viewfinder"), ext: "png"), "com.apple.screencaptureui"),
            (.link(URL(string: "https://github.com/anthropics/claude-code/issues/412")!), "com.apple.Safari"),
            (.color(hex: "#2383E2", original: "#2383E2"), "com.figma.Desktop"),
            (.text("func arranged(_ items: [ShelfItem], query: String = \"\") -> [ShelfItem] {\n    let matching = items.filter { $0.matches(query) }\n    return matching.filter(\\.pinned) + matching.filter { !$0.pinned }\n}"), "com.microsoft.VSCode"),
            (.file(notes), "com.apple.finder"),
            (.text("Meeting moved to 3:30, same room. Bring the Q3 numbers and the widget screenshots."), "com.apple.MobileSMS"),
        ]
        for (content, app) in history {
            store.capture([content], sourceApp: app)
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(500))
        if let text = store.shelf.last { store.togglePin(text) }
        if let command = store.history.last { store.togglePin(command) }
        return store
    }

    private static func samplePNG(colors: [NSColor], symbol: String) -> Data {
        let size = NSSize(width: 480, height: 320)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: 35)
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 110, weight: .regular).applying(.init(paletteColors: [.white]))) {
                glyph.draw(in: NSRect(x: (rect.width - glyph.size.width) / 2, y: (rect.height - glyph.size.height) / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            }
            return true
        }
        return ImageThumbnail.png(NSImage(data: image.tiffRepresentation ?? Data()) ?? image) ?? Data()
    }

    /// `LOCAL_OBSERVER_SNAPSHOT_REPLAY=/path/to/transcript.jsonl` replays that file under a demo session's name.
    @ViewBuilder private static func replay(_ store: AgentStore) -> some View {
        if var session = store.runningSessions.first ?? store.recentSessions.first {
            let path = ProcessInfo.processInfo.environment["LOCAL_OBSERVER_SNAPSHOT_REPLAY"] ?? ""
            let _ = { session.sourcePath = path; session.agent = path.contains("/.codex/") ? .codex : .claude }()
            SessionReplayView(session: session) {}
        }
    }

    private static func reposPage() -> some View {
        let repos = RepoStore.shared
        repos.selection = nil
        return ReposPage(store: repos)
    }

    @ViewBuilder private static func repoInspector() -> some View {
        if let repo = RepoStore.shared.repos.first { RepoInspectorView(store: RepoStore.shared, repo: repo) }
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
