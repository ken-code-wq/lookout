import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverRepos
import LocalObserverShelf

/// Notch silhouette: small outward "ears" where it meets the top edge, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, (rect.height - t) / 2, (rect.width - 2 * t) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Palette for content drawn on the always-black notch, independent of the system appearance.
enum NotchColor {
    static let card = Color.white.opacity(0.07)
    static let cardHover = Color.white.opacity(0.11)
    static let text = Color.white.opacity(0.92)
    static let text2 = Color.white.opacity(0.58)
    static let text3 = Color.white.opacity(0.34)
    static let pink = Color(red: 1, green: 0.42, blue: 0.62)
    static let green = Color(red: 0.36, green: 0.84, blue: 0.56)
    static let orange = Color(red: 1, green: 0.62, blue: 0.2)
    static let red = Color(red: 1, green: 0.38, blue: 0.36)
}

struct NotchRootView: View {
    @ObservedObject var controller: NotchController
    @ObservedObject var state: AppState
    @ObservedObject var agentStore: AgentStore
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var timer = FocusTimer.shared
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var keepAwake = KeepAwake.shared
    @ObservedObject private var repos = RepoStore.shared
    /// Its own pillar: the Shelf tab reads nothing from the agent or server stores.
    var shelf: ShelfStore = .shared
    @State private var dropTargeted = false

    private var scale: CGFloat { CGFloat(prefs.notchWidth) }
    private var wing: CGFloat { 74 * scale }
    private var expandedWidth: CGFloat { 640 * scale }

    /// Each page gets the height it needs; media is a compact strip.
    private var expandedBody: CGFloat {
        switch prefs.notchTab {
        case .media: return 138
        case .sound: return 214
        // Sized to the content (+ card padding and page insets) so nothing is ever clipped.
        case .limits: return min(NotchLimitsPage.height(agentStore: agentStore, prefs: prefs) + 24 + 22 + 2, 440)
        case .agents, .usage, .servers, .repos: return 214
        case .shelf: return 256
        }
    }

    private var notch: CGSize { controller.notchSize }

    private var sessions: [AgentSession] {
        agentStore.runningSessions
            .filter { !($0.process.map { AgentDiscovery.isDesktopApp($0.processName) } ?? false) }
            .sorted { ($0.needsAttention ? 0 : 1, $1.updatedAt) < ($1.needsAttention ? 0 : 1, $0.updatedAt) }
    }

    private var hasWings: Bool {
        timer.isRunning || wingHasContent(prefs.notchLeft) || wingHasContent(prefs.notchRight)
    }

    /// Windows for the limit wing: one per chosen provider, or the tightest overall.
    private var glanceWindows: [AgentQuotaWindow] {
        prefs.glanceWindows(from: agentStore.limitReports.flatMap(\.windows))
    }

    private var size: CGSize {
        switch controller.mode {
        case .expanded:
            return CGSize(width: expandedWidth, height: notch.height + expandedBody)
        case .alert:
            return CGSize(width: max(notch.width + 2 * wing + 60, 460), height: notch.height + 54)
        case .hud:
            return CGSize(width: max(notch.width + 2 * wing + 40, 400), height: notch.height + 34)
        case .compact:
            let swell: CGFloat = controller.isHovering ? 8 : 0
            let width = notch.width + (hasWings ? 2 * wing : 0) + 20 + swell
            return CGSize(width: width, height: notch.height + swell / 2)
        }
    }

    private var radii: (top: CGFloat, bottom: CGFloat) {
        switch controller.mode {
        case .expanded: return (19, 24)
        case .alert: return (14, 20)
        case .hud: return (12, 18)
        case .compact: return (6, 14)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            let shape = NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                content
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            .frame(width: size.width, height: size.height)
            .overlay { if dropTargeted { dropHint(shape) } }
            .clipShape(shape)
            .contentShape(shape)
            // Anything dragged onto the notch lands on the Shelf, whichever tab is showing.
            .onDrop(of: ShelfDrop.types, isTargeted: $dropTargeted) { providers in
                ShelfPresentation.shared.section = .shelf
                prefs.notchTab = .shelf
                return shelf.add(providers: providers)
            }
            .onChange(of: dropTargeted) { _, targeted in
                guard targeted else { return }
                ShelfPresentation.shared.section = .shelf
                if controller.mode == .expanded { prefs.notchTab = .shelf } else { controller.expand(tab: .shelf) }
            }
            // Drawn as blurred pixels rather than with .shadow: in this transparent, borderless panel a layer shadow
            // shows while the spring animates and then drops out once the view settles.
            // Two layers, a wide soft one and a tight one at the edge, each a little wider than the shape so the
            // blur isn't mostly hidden underneath it.
            .background {
                let open = controller.mode != .compact
                ZStack {
                    shape.fill(Color.black)
                        .frame(width: size.width + 24, height: size.height + 6)
                        // Room around the shape before blurring: a blur is cut at its view's bounds, which left a
                        // hard edge where the shadow should fade out.
                        .padding(50)
                        .blur(radius: 18)
                        .padding(-50)
                        .offset(y: 12)
                        .opacity(0.42)
                    shape.fill(Color.black)
                        .frame(width: size.width + 6, height: size.height)
                        .padding(20)
                        .blur(radius: 5)
                        .padding(-20)
                        .offset(y: 4)
                        .opacity(0.35)
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .opacity(open ? 1 : 0)
                .allowsHitTesting(false)
            }
            .onTapGesture {
                switch controller.mode {
                case .compact: controller.expand()
                case .alert:
                    if let url = controller.alert?.url {
                        ProcessManager.openURL(url)
                        controller.collapse()
                    } else {
                        controller.open(sessionID: controller.alert?.sessionID)
                    }
                case .hud, .expanded: break
                }
            }
            .onAppear { controller.shapeSize = size }
            .onChange(of: size) { _, new in controller.shapeSize = new }
            if controller.mode == .compact && controller.isHoveringLimit && !glanceWindows.isEmpty {
                LimitHoverCard(windows: glanceWindows)
                    .padding(.top, 8)
                    .padding(.horizontal, 6)
                    .frame(width: max(size.width, 290), alignment: prefs.notchLeft == .limit && prefs.notchRight != .limit ? .leading : .trailing)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.panelSize.width, height: NotchController.panelSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private func dropHint(_ shape: NotchShape) -> some View {
        ZStack(alignment: .bottom) {
            shape.fill(Color.white.opacity(0.06))
            Label("Drop to keep on the Shelf", systemImage: "tray.and.arrow.down.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(NotchColor.text)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Color.white.opacity(0.14), in: Capsule())
                .padding(.bottom, 12)
                .opacity(controller.mode == .expanded ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var content: some View {
        switch controller.mode {
        case .compact: compact.id("compact")
        case .alert: alertView.id("alert")
        case .hud(let kind): NotchLevelHUD(kind: kind, notchHeight: notch.height).id("hud")
        case .expanded: expanded.id("expanded")
        }
    }

    // MARK: Compact

    private var compact: some View {
        HStack(spacing: 0) {
            wingView(prefs.notchLeft, leading: true)
                .frame(width: hasWings ? wing : 0, alignment: .leading)
                .padding(.leading, 16)
            Spacer(minLength: notch.width)
            Group {
                if timer.isRunning { timerWing } else { wingView(prefs.notchRight, leading: false) }
            }
                .frame(width: hasWings ? wing : 0, alignment: .trailing)
                .padding(.trailing, 16)
        }
        .frame(height: notch.height)
        .opacity(hasWings ? 1 : 0)
    }

    private func wingHasContent(_ wing: NotchWing) -> Bool {
        switch wing {
        case .none: return false
        case .nowPlaying: return media.track != nil
        case .agents: return !sessions.isEmpty
        case .limit: return !glanceWindows.isEmpty
        case .todayCost: return agentStore.todayTotals.hasCost
        case .todayTokens: return agentStore.todayTotals.processed > 0
        case .servers: return !state.visibleServers.isEmpty
        case .checks: return !repos.myPulls.isEmpty || !repos.reviewRequests.isEmpty
        }
    }

    @ViewBuilder private func wingView(_ wing: NotchWing, leading: Bool) -> some View {
        switch wing {
        case .none:
            EmptyView()
        case .agents:
            if let first = sessions.first {
                let waiting = sessions.filter(\.needsAttention).count
                HStack(spacing: 5) {
                    ZStack(alignment: .topTrailing) {
                        AgentIconView(agent: first.agent, size: 16)
                        if waiting > 0 {
                            Circle().fill(NotchColor.pink).frame(width: 6, height: 6).offset(x: 2, y: -2)
                        }
                    }
                    if sessions.count > 1 || waiting > 0 {
                        Text(waiting > 0 ? "\(waiting)" : "\(sessions.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(waiting > 0 ? NotchColor.pink : NotchColor.text)
                    }
                    if AgentActivityBucket(first) == .working && waiting == 0 {
                        PulsingDot(color: NotchColor.green)
                    }
                }
            }
        case .nowPlaying:
            NowPlayingWing()
        case .limit:
            // Just the ring: one arc per provider with its pace tick. Hover it for the numbers.
            let windows = glanceWindows
            if !windows.isEmpty {
                ProviderRing(windows: windows, lineWidth: windows.count > 1 ? 2.5 : 2.8)
                    .frame(width: 18, height: 18)
                    .padding(3)
                    .contentShape(Circle())
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { controller.limitRingFrame = $0 }
                    .onDisappear { controller.limitRingFrame = .zero }
            }
        case .checks:
            checksWing
        case .todayCost:
            let today = agentStore.todayTotals
            if today.hasCost {
                Text(AgentFormat.cost(today.cost))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(NotchColor.text)
            }
        case .todayTokens:
            let today = agentStore.todayTotals
            if today.processed > 0 {
                Text(AgentFormat.compact(Double(today.processed)))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(NotchColor.text)
            }
        case .servers:
            if !state.visibleServers.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack").font(.system(size: 10.5, weight: .semibold))
                    Text("\(state.visibleServers.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(NotchColor.text)
            }
        }
    }

    /// Your pull requests at a glance: red with a count when checks fail, a pulse while they run, else green.
    @ViewBuilder private var checksWing: some View {
        let failing = repos.failingPulls.count, running = repos.runningPulls.count, reviews = repos.reviewRequests.count
        HStack(spacing: 4) {
            if failing > 0 {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchColor.red)
                Text("\(failing)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(NotchColor.red)
            } else if running > 0 {
                PulsingDot(color: NotchColor.orange)
                Text("\(running)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(NotchColor.text)
            } else if reviews > 0 {
                Image(systemName: "eye.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 0.45, green: 0.66, blue: 1))
                Text("\(reviews)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(NotchColor.text)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchColor.green)
                Text("\(repos.myPulls.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(NotchColor.text)
            }
        }
        .help("\(repos.myPulls.count) open, \(failing) failing, \(running) running, \(reviews) waiting on your review")
    }

    /// Countdown that takes over the right wing while a timer runs.
    private var timerWing: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = timer.remaining(at: context.date)
            HStack(spacing: 6) {
                ProviderRing(segments: [.init(id: "timer", color: NotchColor.orange, fraction: remaining / max(timer.length, 1))], lineWidth: 2.5)
                    .frame(width: 14, height: 14)
                Text(FocusTimer.format(remaining))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(NotchColor.text)
            }
        }
    }

    private func ringColor(_ percent: Double) -> Color {
        percent >= 90 ? NotchColor.red : percent >= 70 ? NotchColor.orange : NotchColor.green
    }

    // MARK: Alert

    @ViewBuilder private var alertView: some View {
        if let alert = controller.alert {
            VStack(spacing: 0) {
                HStack {
                    Group {
                        if let agent = alert.agent {
                            AgentIconView(agent: agent, size: 16)
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else if let symbol = alert.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(color(for: alert.kind))
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                    Spacer(minLength: notch.width)
                    Text(alert.badge)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(color(for: alert.kind))
                }
                .padding(.horizontal, 28)
                .frame(height: notch.height)
                VStack(spacing: 2) {
                    Text(alert.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(NotchColor.text).lineLimit(1)
                    Text(alert.detail).font(.system(size: 11.5)).foregroundStyle(NotchColor.text2).lineLimit(1)
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
            }
        }
    }

    private func color(for kind: NotchAlert.Kind) -> Color {
        switch kind {
        case .needsYou: return NotchColor.pink
        case .failed: return NotchColor.red
        case .finished: return NotchColor.green
        case .limit: return NotchColor.orange
        case .reset: return NotchColor.green
        case .checksFailed: return NotchColor.red
        case .checksPassed: return NotchColor.green
        case .review: return Color(red: 0.45, green: 0.66, blue: 1)
        }
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabBar
                Spacer(minLength: notch.width + 16)
                HStack(spacing: 2) {
                    timerButton
                    NotchIconButton(symbol: "arrow.clockwise", help: "Refresh", spinning: agentStore.isScanning) {
                        state.refresh()
                        agentStore.refresh(forceLimits: true)
                    }
                    NotchIconButton(symbol: "macwindow", help: "Open Lookout") {
                        LiveSurfaces.shared.openMain(tabPage)
                        controller.collapse()
                    }
                    NotchIconButton(symbol: "gearshape.fill", help: "Settings") {
                        controller.collapse()
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
            }
            // Content starts inside the top "ears" (radius 19) plus a margin.
            .padding(.leading, 31)
            .padding(.trailing, 29)
            .frame(height: max(notch.height, 30))
            .padding(.top, 2)

            Group {
                switch prefs.notchTab {
                case .agents: agentsTab
                case .usage: usageTab
                case .limits: limitsTab
                case .repos: reposTab
                case .servers: serversTab
                case .shelf: ShelfNotchPage(store: shelf) { controller.collapse() }
                case .media: NotchMediaPage()
                case .sound:
                    NotchCard {
                        ScrollView { SoundMixerView(maxRows: 12) }.scrollIndicators(.never)
                    }
                }
            }
            .padding(.horizontal, 31)
            .padding(.top, 8)
            .padding(.bottom, 14)
            // Fixed box, top-aligned and clipped: a page taller than this scrolls or is cut at the bottom,
            // instead of SwiftUI centering it and pushing the tab bar up off the screen.
            .frame(height: expandedBody, alignment: .top)
            .clipped()
        }
    }

    private var tabPage: SidebarItem {
        switch prefs.notchTab {
        case .agents: return .agentActivity
        case .usage: return .agentUsage
        case .limits: return .agentLimits
        case .repos: return .pullRequests
        case .servers: return .all
        case .shelf, .media, .sound: return .agentActivity
        }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(NotchTab.allCases) { tab in
                let selected = prefs.notchTab == tab
                Button {
                    withAnimation(.snappy(duration: 0.2)) { prefs.notchTab = tab }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(selected ? NotchColor.text : NotchColor.text2)
                            .frame(width: 31, height: 24)
                            .background(selected ? Color.white.opacity(0.16) : .clear, in: Capsule())
                        if tab == .agents && !agentStore.attentionSessions.isEmpty {
                            Circle().fill(NotchColor.pink).frame(width: 5, height: 5).offset(x: -6, y: 4)
                        }
                        if tab == .repos && !repos.pullsNeedingYou.isEmpty {
                            Circle().fill(repos.failingPulls.isEmpty ? Color(red: 0.45, green: 0.66, blue: 1) : NotchColor.red)
                                .frame(width: 5, height: 5).offset(x: -5, y: 4)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.07), in: Capsule())
    }

    // MARK: Tabs

    private var agentsTab: some View {
        HStack(alignment: .top, spacing: 10) {
            NotchCard {
                VStack(alignment: .leading, spacing: 2) {
                    NotchCardTitle(title: "Running", value: "\(sessions.count)")
                    if sessions.isEmpty {
                        NotchEmpty(symbol: "moon.zzz", text: "No agents running")
                    } else {
                        ForEach(sessions.prefix(4)) { session in
                            NotchSessionRow(session: session) { controller.open(sessionID: session.id) }
                        }
                        if sessions.count > 4 {
                            Text("+\(sessions.count - 4) more").font(.system(size: 11)).foregroundStyle(NotchColor.text3).padding(.leading, 8)
                        }
                    }
                }
            }
            .frame(width: (expandedWidth - 72) * 0.56)
            NotchCard {
                VStack(alignment: .leading, spacing: 10) {
                    keepAwakeRow
                    topModelRow
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                    let today = agentStore.todayTotals
                    NotchStatRow(symbol: "number", tint: .blue, title: "Tokens today", value: AgentFormat.compact(Double(today.processed)))
                    NotchStatRow(symbol: "dollarsign", tint: .green, title: today.costIsEstimated ? "Est. cost" : "Cost",
                                 value: today.hasCost ? AgentFormat.cost(today.cost) : "–")
                    NotchStatRow(symbol: "arrow.up.arrow.down", tint: .purple, title: "Requests", value: today.requests.formatted())
                }
            }
        }
    }

    private var keepAwakeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cup.and.heat.waves.fill")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.teal)
                .frame(width: 20, height: 20)
                .background(Color.teal.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text("Keep awake").font(.system(size: 12, weight: .medium)).foregroundStyle(NotchColor.text)
                Text(keepAwakeDetail).font(.system(size: 10)).foregroundStyle(NotchColor.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Toggle("Keep awake", isOn: Binding(
                get: { prefs.keepAwake != .off },
                set: { prefs.keepAwake = $0 ? .whileWorking : .off }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help("Keep the Mac from sleeping while an agent is working")
        }
    }

    private var keepAwakeDetail: String {
        switch prefs.keepAwake {
        case .off: return "Mac can sleep"
        case .always: return "Always, until turned off"
        case .whileWorking: return keepAwake.isHolding ? "Awake, agents working" : "While agents work"
        }
    }

    /// The model that did the most work today, with its share of today's tokens.
    private var topModelRow: some View {
        let top = agentStore.todayModels.first
        return HStack(spacing: 8) {
            Group {
                if let agent = top?.agent ?? top?.agents.first {
                    AgentIconView(agent: agent, size: 12)
                        .frame(width: 20, height: 20)
                        .background(agent.brandColor.opacity(0.22), in: Circle())
                } else {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.indigo)
                        .frame(width: 20, height: 20)
                        .background(Color.indigo.opacity(0.22), in: Circle())
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Top model today").font(.system(size: 12, weight: .medium)).foregroundStyle(NotchColor.text)
                Text(top?.title ?? "No usage yet")
                    .font(.system(size: 10)).foregroundStyle(NotchColor.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let top {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(AgentFormat.compact(Double(top.totals.processed)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(NotchColor.text)
                    Text("\(Int((top.share * 100).rounded()))% of today")
                        .font(.system(size: 10)).foregroundStyle(NotchColor.text3)
                }
            }
        }
        .help(agentStore.todayModels.prefix(4).map { "\($0.title): \(AgentFormat.compact(Double($0.totals.processed)))" }.joined(separator: "\n"))
    }

    /// Header control: start a 15/25/50 minute timer, or see and stop the running one.
    private var timerButton: some View {
        Menu {
            if timer.isRunning {
                Button("Stop timer") { timer.stop() }
            } else {
                ForEach([15, 25, 50], id: \.self) { minutes in
                    Button("\(minutes) minutes") { timer.start(minutes: minutes) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer").font(.system(size: 12, weight: .semibold))
                if timer.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(FocusTimer.format(timer.remaining(at: context.date)))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                }
            }
            .foregroundStyle(timer.isRunning ? NotchColor.orange : NotchColor.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: 24)
        .padding(.horizontal, 5)
        .help(timer.isRunning ? "Timer running" : "Start a timer")
    }

    private var usageTab: some View {
        NotchCard {
            GlanceUsageChart(store: agentStore, chartHeight: 96) {
                agentStore.filter = agentStore.glanceFilter
                LiveSurfaces.shared.openMain(.agentUsage)
                controller.collapse()
            }
        }
    }

    private var limitsTab: some View {
        NotchCard { NotchLimitsPage(agentStore: agentStore) }
    }

    private var reposTab: some View {
        let pulls = Array((repos.pullsNeedingYou + repos.runningPulls + repos.myPulls)
            .reduce(into: [PullRequest]()) { list, pr in if !list.contains(where: { $0.url == pr.url }) { list.append(pr) } }
            .prefix(4))
        let unsaved = repos.attentionRepos.filter(\.hasLocalOnlyWork)
        return HStack(alignment: .top, spacing: 10) {
            NotchCard {
                VStack(alignment: .leading, spacing: 2) {
                    NotchCardTitle(title: "Pull requests", value: "\(repos.pulls.count)")
                    if pulls.isEmpty {
                        NotchEmpty(symbol: repos.gitHub.login == nil ? "person.crop.circle.badge.questionmark" : "checkmark.circle",
                                   text: repos.gitHub.login == nil ? "Sign in with gh auth login" : "Nothing open")
                    } else {
                        ForEach(pulls) { pull in
                            NotchPullRow(pull: pull) { controller.collapse() }
                        }
                    }
                }
            }
            .frame(width: (expandedWidth - 72) * 0.56)
            NotchCard {
                VStack(alignment: .leading, spacing: 10) {
                    NotchStatRow(symbol: "xmark", tint: .red, title: "Failing checks", value: "\(repos.failingPulls.count)")
                    NotchStatRow(symbol: "eye.fill", tint: .blue, title: "Reviews for you", value: "\(repos.reviewRequests.count)")
                    NotchStatRow(symbol: "checkmark", tint: .green, title: "Ready to merge", value: "\(repos.readyPulls.count)")
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                    Button {
                        LiveSurfaces.shared.openMain(.repos)
                        controller.collapse()
                    } label: {
                        NotchStatRow(symbol: "pencil", tint: .orange, title: "Unsaved work", value: "\(unsaved.count)")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(unsaved.prefix(6).map { "\($0.name): \($0.changes.summary)" }.joined(separator: "\n"))
                }
            }
        }
    }

    private var serversTab: some View {
        let servers = state.visibleServers.sorted { $0.port < $1.port }
        return NotchCard {
            VStack(alignment: .leading, spacing: 2) {
                NotchCardTitle(title: "Listening", value: "\(servers.count)")
                if servers.isEmpty {
                    NotchEmpty(symbol: "moon.zzz", text: "Nothing running")
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 2) {
                        ForEach(servers.prefix(8)) { server in
                            NotchServerRow(state: state, server: server)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

/// Card under the closed notch while the pointer rests on the limit ring.
private struct LimitHoverCard: View {
    var windows: [AgentQuotaWindow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(windows) { window in
                let pace = LimitPace(window: window)
                HStack(alignment: .top, spacing: 9) {
                    AgentIconView(agent: window.agent, size: 14)
                        .frame(width: 24, height: 24)
                        .background(window.agent.brandColor.opacity(0.2), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        PaceLine(window: window, color: window.agent.brandColor, title: "\(window.agent.shortName) · \(window.label)")
                        Text(pace.verdict == .ahead || pace.verdict == .exhausted ? pace.sentence : AgentFormat.resetText(window.resetsAt))
                            .font(.system(size: 10))
                            .foregroundStyle(pace.verdict == .exhausted ? NotchColor.red : pace.verdict == .ahead ? NotchColor.orange : NotchColor.text3)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 270)
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .environment(\.colorScheme, .dark)
    }
}

private struct NotchPill: View {
    var title: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchColor.text)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Color.white.opacity(hover ? 0.18 : 0.1), in: Capsule())
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct NotchCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(NotchColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct NotchCardTitle: View {
    var title: String
    var value: String?
    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(NotchColor.text2)
            if let value { Text(value).font(.system(size: 11)).monospacedDigit().foregroundStyle(NotchColor.text3) }
        }
        .padding(.leading, 2)
        .padding(.bottom, 4)
    }
}

private struct NotchEmpty: View {
    var symbol: String
    var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(NotchColor.text3)
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

private struct NotchStatRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var value: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.18), in: Circle())
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(NotchColor.text)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(NotchColor.text)
        }
    }
}

private struct NotchSessionRow: View {
    var session: AgentSession
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AgentIconView(agent: session.agent, size: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.system(size: 12, weight: .medium)).foregroundStyle(NotchColor.text).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        HStack(spacing: 5) {
                            Text("\(session.projectName) · \(AgentFormat.duration(context.date.timeIntervalSince(session.startedAt)))")
                                .font(.system(size: 10.5)).foregroundStyle(NotchColor.text2).lineLimit(1)
                            if session.isInWorktree, let git = session.checkout { NotchBranch(git: git) }
                        }
                    }
                }
                Spacer(minLength: 6)
                HostAppIcon(session: session, size: 16)
                stateLabel
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(hover ? NotchColor.cardHover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(session.process?.host.map { "Jump to \($0.name)" } ?? "Show in Lookout")
    }

    private var stateLabel: some View {
        let bucket = AgentActivityBucket(session)
        let color: Color = switch bucket {
        case .needsYou: session.state == .failed ? NotchColor.red : NotchColor.pink
        case .working: NotchColor.green
        case .yourTurn: Color(red: 0.45, green: 0.66, blue: 1)
        case .idle: NotchColor.text3
        }
        return HStack(spacing: 4) {
            if bucket == .working { PulsingDot(color: color) }
            Text(session.state == .failed ? "Failed" : bucket.rawValue)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
    }
}

private struct NotchServerRow: View {
    @ObservedObject var state: AppState
    var server: ServerEntry
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            FaviconView(server: server, size: 16)
            Text(server.projectName).font(.system(size: 12)).foregroundStyle(NotchColor.text).lineLimit(1)
                .layoutPriority(1)
            if let git = server.git { NotchBranch(git: git) }
            Spacer(minLength: 4)
            if hover {
                Button { state.stop(server) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9)).foregroundStyle(NotchColor.red)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
            Text(verbatim: ":\(server.port)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(server.isResponding ? NotchColor.text : NotchColor.text3)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(hover ? NotchColor.cardHover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { state.open(server) }
        .help("Open \(server.urlString)")
    }
}

private struct NotchIconButton: View {
    var symbol: String
    var help: String
    var spinning = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Group {
                if spinning { ProgressView().controlSize(.mini) }
                else { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
            }
            .foregroundStyle(hover ? NotchColor.text : NotchColor.text2)
            .frame(width: 26, height: 24)
            .background(hover ? Color.white.opacity(0.1) : .clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Circular progress used in the closed notch.
struct RingGauge: View {
    var fraction: Double
    var color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Branch on the notch's dark glass; worktrees get a purple glyph.
struct NotchBranch: View {
    var git: GitCheckout
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: git.isLinkedWorktree ? "square.stack.3d.down.right" : "arrow.triangle.branch")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(git.isLinkedWorktree ? Color(red: 0.74, green: 0.6, blue: 1) : NotchColor.text3)
            Text(git.refLabel).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(NotchColor.text3)
        .help(BranchTag.describe(git))
    }
}

private struct NotchPullRow: View {
    var pull: PullRequest
    var done: () -> Void
    @State private var hover = false

    var body: some View {
        Button {
            ProcessManager.openURL(pull.checks == .failure ? pull.url + "/checks" : pull.url)
            done()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: pull.checks.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pull.title).font(.system(size: 12, weight: .medium)).foregroundStyle(NotchColor.text).lineLimit(1)
                    Text("\(pull.repoName) #\(pull.number)" + (pull.role == .reviewRequested ? " · review for you" : ""))
                        .font(.system(size: 10.5)).foregroundStyle(NotchColor.text2).lineLimit(1)
                }
                Spacer(minLength: 6)
                if pull.isReadyToMerge {
                    Text("Ready").font(.system(size: 11, weight: .medium)).foregroundStyle(NotchColor.green)
                } else if pull.role == .reviewRequested {
                    Text("Review").font(.system(size: 11, weight: .medium)).foregroundStyle(Color(red: 0.45, green: 0.66, blue: 1))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(hover ? NotchColor.cardHover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(pull.checks.title)
    }

    private var color: Color {
        switch pull.checks {
        case .success: return NotchColor.green
        case .failure: return NotchColor.red
        case .pending: return NotchColor.orange
        case .none: return NotchColor.text3
        }
    }
}
