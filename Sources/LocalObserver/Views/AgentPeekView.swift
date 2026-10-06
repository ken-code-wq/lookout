import SwiftUI
import AppKit
import LocalObserverCore

// MARK: - Liquid Glass helpers

enum LiquidGlass {
    /// Snapshot harness only: offscreen bitmap captures can't draw Liquid Glass, so they get the frosted fallback.
    @MainActor static var forceFallback = false
}

extension View {
    /// Liquid Glass on macOS 26; frosted material with a hairline edge before that.
    @MainActor @ViewBuilder
    func liquidGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false, clear: Bool = false) -> some View {
        if #available(macOS 26.0, *), !LiquidGlass.forceFallback {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive, clear: clear), in: shape)
        } else {
            self
                .background { shape.fill(.ultraThinMaterial) }
                .background { if let tint { shape.fill(tint.opacity(0.18)) } }
                .overlay { shape.stroke(.white.opacity(0.22), lineWidth: 0.6) }
        }
    }

    @available(macOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool, clear: Bool) -> Glass {
        var glass = clear ? Glass.clear : Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Groups glass shapes so they blend and morph together (GlassEffectContainer on macOS 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *), !LiquidGlass.forceFallback {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Round glass icon button.
private struct GlassIconButton: View {
    var symbol: String
    var help: String
    var spinning = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if spinning { ProgressView().controlSize(.mini) }
                else { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(.primary)
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .liquidGlass(Circle(), interactive: true)
        .help(help)
    }
}

// MARK: - Agent Peek

/// Floating Liquid Glass glance at running agents, today's spend, and plan limits.
struct AgentPeekView: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var state: AppState
    @ObservedObject var prefs = Preferences.shared
    var openMain: (SidebarItem) -> Void

    /// Every running CLI session, before the provider filter.
    private var allSessions: [AgentSession] {
        agentStore.runningSessions
            .filter { !($0.process.map { AgentDiscovery.isDesktopApp($0.processName) } ?? false) }
            .sorted { ($0.needsAttention ? 0 : 1, $1.updatedAt) < ($1.needsAttention ? 0 : 1, $0.updatedAt) }
    }

    private var sessions: [AgentSession] { allSessions.filter { !prefs.peekHiddenAgents.contains($0.agent) } }

    /// One tile per provider (chosen providers, or the three tightest windows).
    private var windows: [AgentQuotaWindow] {
        let all = agentStore.limitReports.flatMap(\.windows).filter { !prefs.peekHiddenAgents.contains($0.agent) }
        if !prefs.limitProviders.isEmpty { return Array(prefs.glanceWindows(from: all).prefix(4)) }
        return Array(all.sorted { $0.usedPercent > $1.usedPercent }.prefix(3))
    }

    /// Small: the 5-hour window of each chosen provider (all that have one when none are chosen). A provider without
    /// a session window shows its shortest one instead, so choosing it never leaves a blank.
    private var smallWindows: [AgentQuotaWindow] {
        let all = agentStore.limitReports.flatMap(\.windows).filter { !prefs.peekHiddenAgents.contains($0.agent) }
        let chosen = prefs.peekSmallProviders.isEmpty
            ? limitAgents.filter { agent in all.contains { $0.agent == agent && $0.kind == .session } }
            : prefs.peekSmallProviders
        let shown = chosen.compactMap { agent -> AgentQuotaWindow? in
            let own = all.filter { $0.agent == agent }
            return own.first { $0.kind == .session } ?? own.first { $0.kind == .daily } ?? own.min { ($0.windowDuration ?? .infinity) < ($1.windowDuration ?? .infinity) }
        }
        return shown.isEmpty ? windows : Array(shown.prefix(4))
    }

    /// Providers reporting plan limits, for the Small picker.
    private var limitAgents: [AgentKind] {
        AgentKind.allCases.filter { agent in agentStore.limitReports.contains { $0.agent == agent && !$0.windows.isEmpty } }
    }

    /// Medium has room for three tiles side by side; Large keeps up to four.
    private var shownWindows: [AgentQuotaWindow] { size == .medium ? Array(windows.prefix(3)) : windows }

    /// Providers worth offering in the filter menu: turned on in Settings, or currently hidden.
    private var providers: [AgentKind] {
        AgentKind.allCases.filter { agentStore.settings.enabledAgents.contains($0) || prefs.peekHiddenAgents.contains($0) }
    }

    private var size: PeekSize { prefs.peekSize }

    private var showsAgents: Bool { prefs.peekShowsAgents }
    private var showsLimits: Bool { prefs.peekShowsLimits && !(size == .small ? smallWindows : windows).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .small ? 8 : 10) {
            header
            if !prefs.peekSetupDone {
                PeekSetupCard(prefs: prefs, compact: size == .small)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if size == .small {
                // No section chrome at Small: agents, then limits, grouped by spacing alone.
                if showsAgents { compactAgentList }
                if showsLimits { compactLimits }
                if !showsAgents && !showsLimits { nothingShown }
            } else {
                if showsAgents {
                    GlassGroup(spacing: 6) {
                        VStack(alignment: .leading, spacing: 6) {
                            PeekSectionHeader(title: "Agents", key: "agents", count: sessions.count)
                            if !prefs.isCollapsed(peek: "agents") { agentList }
                        }
                    }
                }
                if showsLimits {
                    VStack(alignment: .leading, spacing: 6) {
                        PeekSectionHeader(title: "Limits", key: "limits", count: shownWindows.count)
                        if !prefs.isCollapsed(peek: "limits") { limitTiles }
                    }
                }
                if !showsAgents && !showsLimits { nothingShown }
                if showsAgents && !prefs.peekHiddenAgents.isEmpty { hiddenNote }
            }
        }
        .padding(size == .small ? 10 : 12)
        .frame(width: prefs.peekWidth)
        // The slab uses the see-through variant (or frosted, per Settings); cards inside stay frosted for legibility.
        .liquidGlass(RoundedRectangle(cornerRadius: size == .small ? 22 : 28, style: .continuous), clear: prefs.peekClearGlass)
        // Drag either side edge to resize; the layout steps between Small, Medium and Large as the width crosses them.
        .overlay(alignment: .leading) { PeekResizeHandle(edge: .leading).frame(width: 7).padding(.vertical, 18) }
        .overlay(alignment: .trailing) { PeekResizeHandle(edge: .trailing).frame(width: 7).padding(.vertical, 18) }
        .padding(8) // room for the window shadow around the glass
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: prefs.collapsedPeekGroups)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: sessions.map(\.id))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: size)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: prefs.peekSetupDone)
    }

    /// Everything is switched off: say so, and say how to get it back.
    private var nothingShown: some View {
        Button { withAnimation(.snappy) { prefs.peekSetupDone = false } } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Nothing to show. Choose what Peek shows")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        switch size {
        case .large:
            HStack(spacing: 8) {
                title
                Spacer(minLength: 4)
                todayPill(withUnit: true)
                GlassGroup(spacing: 4) {
                    HStack(spacing: 4) {
                        sizeButton
                        filterMenu
                        refreshButton
                        closeButton
                    }
                }
            }
            .padding(.leading, 4)
        case .medium:
            // The filter menu moves to a right-click on the header; the pill keeps its number and drops the unit.
            HStack(spacing: 8) {
                title
                Spacer(minLength: 4)
                todayPill(withUnit: false)
                GlassGroup(spacing: 4) {
                    HStack(spacing: 4) {
                        sizeButton
                        refreshButton
                        closeButton
                    }
                }
            }
            .padding(.leading, 4)
            .contentShape(Rectangle())
            .contextMenu { filterOptions }
        case .small:
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                GlassGroup(spacing: 4) {
                    HStack(spacing: 4) {
                        sizeButton
                        closeButton
                    }
                }
            }
            .contentShape(Rectangle())
            .contextMenu { filterOptions }
        }
    }

    /// Drops to "Peek", then to nothing, when a long today value needs the room.
    private var title: some View {
        ViewThatFits(in: .horizontal) {
            Text("Agent Peek").font(.system(size: 13, weight: .semibold)).fixedSize()
            Text("Peek").font(.system(size: 13, weight: .semibold)).fixedSize()
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Click cycles what the pill shows; right-click (or the filter menu) lists every option.
    private func todayPill(withUnit: Bool) -> some View {
        Button {
            let all = PeekTodayMetric.allCases
            let next = all[((all.firstIndex(of: prefs.peekTodayMetric) ?? 0) + 1) % all.count]
            withAnimation(.snappy(duration: 0.2)) { prefs.peekTodayMetric = next }
        } label: {
            HStack(spacing: 4) {
                Text(todayValue(prefs.peekTodayMetric))
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .fixedSize()
                if withUnit {
                    Text(todayUnit).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize()
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlass(Capsule(), tint: .green.opacity(0.25), interactive: true)
        .contextMenu { todayMetricOptions }
        .help("Today's \(prefs.peekTodayMetric.title.lowercased()). Click for the next measure, right-click to choose.")
    }

    /// One glyph that cycles Large, Medium, Small, so the size is a click away at every size.
    private var sizeButton: some View {
        Button {
            // From a dragged width, the button first snaps to its own preset, then cycles.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                if prefs.peekWidth != Double(size.width) { prefs.peekWidth = Double(size.width) } else { prefs.peekSize = size.next }
            }
        } label: {
            Text(size.letter)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .liquidGlass(Circle(), interactive: true)
        .contextMenu { sizePicker }
        .help("\(size.title) size. Click for \(size.next.title.lowercased()), right-click to choose, or drag Peek's side edges.")
        .accessibilityLabel("Peek size, \(size.title)")
    }

    private var sizePicker: some View {
        Picker("Size", selection: Binding(
            get: { prefs.peekSize },
            set: { new in withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { prefs.peekSize = new } }
        )) {
            ForEach(PeekSize.allCases) { Text($0.title).tag($0) }
        }
    }

    private var refreshButton: some View {
        GlassIconButton(symbol: "arrow.clockwise", help: "Refresh agents and limits", spinning: agentStore.isScanning) {
            state.refresh()
            agentStore.refresh(forceLimits: true)
        }
    }

    private var closeButton: some View {
        GlassIconButton(symbol: "xmark", help: "Close (\(prefs.peekHotKey?.display ?? "no shortcut"))") {
            LiveSurfaces.shared.hidePeek()
        }
    }

    @ViewBuilder private var todayMetricOptions: some View {
        Picker("Today shows", selection: $prefs.peekTodayMetric) {
            ForEach(PeekTodayMetric.allCases) { Text("\($0.title): \(todayValue($0))").tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Open usage") { openMain(.agentUsage) }
    }

    private func todayValue(_ metric: PeekTodayMetric) -> String {
        let today = agentStore.todayTotals
        switch metric {
        case .cost: return today.hasCost ? AgentFormat.cost(today.cost, estimated: today.costIsEstimated) : "–"
        case .tokens: return AgentFormat.compact(Double(today.processed))
        case .requests: return today.requests.formatted()
        case .sessions: return today.sessions.formatted()
        case .cacheHits: return today.cacheHitRate.map { AgentFormat.percent($0, digits: 0) } ?? "–"
        }
    }

    /// Word after the number, kept short so the header fits.
    private var todayUnit: String {
        switch prefs.peekTodayMetric {
        case .cost: return "today"
        case .tokens: return "tok today"
        case .requests: return "req today"
        case .sessions: return "sessions"
        case .cacheHits: return "cached"
        }
    }

    /// Shared by the Large filter button and the right-click menu Medium and Small use instead.
    @ViewBuilder private var filterOptions: some View {
        Section("Show providers") {
            ForEach(providers) { agent in
                Toggle(agent.name, isOn: Binding(
                    get: { !prefs.peekHiddenAgents.contains(agent) },
                    set: { on in withAnimation(.snappy) { prefs.setPeekHidden(agent, !on) } }
                ))
            }
        }
        if !prefs.peekHiddenAgents.isEmpty {
            Button("Show all providers") { withAnimation(.snappy) { prefs.peekHiddenAgents = [] } }
        }
        Divider()
        Picker("Today shows", selection: $prefs.peekTodayMetric) {
            ForEach(PeekTodayMetric.allCases) { Text($0.title).tag($0) }
        }
        sizePicker
        if !limitAgents.isEmpty {
            Menu("Small shows 5-hour limits for") {
                ForEach(limitAgents) { agent in
                    Toggle(agent.name, isOn: Binding(
                        get: { prefs.peekSmallProviders.contains(agent) },
                        set: { _ in withAnimation(.snappy) { prefs.toggleSmallPeekProvider(agent) } }
                    ))
                }
                if !prefs.peekSmallProviders.isEmpty {
                    Divider()
                    Button("Every provider with a 5-hour window") { prefs.peekSmallProviders = [] }
                }
            }
        }
        Toggle("Show agents", isOn: Binding(get: { prefs.peekShowsAgents }, set: { on in withAnimation(.snappy) { prefs.peekShowsAgents = on } }))
        Toggle("Show limits", isOn: Binding(get: { prefs.peekShowsLimits }, set: { on in withAnimation(.snappy) { prefs.peekShowsLimits = on } }))
        Picker("Limits as", selection: Binding(get: { prefs.peekLimitStyle }, set: { new in withAnimation(.snappy) { prefs.peekLimitStyle = new } })) {
            ForEach(PeekLimitStyle.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        Button("Choose what Peek shows…") { withAnimation(.snappy) { prefs.peekSetupDone = false } }
        Toggle("Clear glass", isOn: $prefs.peekClearGlass)
        if size != .small && showsAgents && showsLimits {
            Button(prefs.collapsedPeekGroups.isEmpty ? "Collapse all" : "Expand all") {
                withAnimation(.snappy) { prefs.collapsedPeekGroups = prefs.collapsedPeekGroups.isEmpty ? ["agents", "limits"] : [] }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            filterOptions
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prefs.peekHiddenAgents.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .liquidGlass(Circle(), tint: prefs.peekHiddenAgents.isEmpty ? nil : .accentColor.opacity(0.3), interactive: true)
        .help("Filter providers")
    }

    // MARK: Agents

    @ViewBuilder private var agentList: some View {
        if sessions.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                Text(allSessions.isEmpty ? "No agents running" : "Running agents are hidden")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .liquidGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            let limit = size == .large ? 6 : 4
            VStack(spacing: 6) {
                ForEach(sessions.prefix(limit)) { session in
                    PeekRow(session: session, detailed: size == .large) { select(session) }
                        .contextMenu { hideOption(session) }
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if size == .medium, sessions.count > limit { moreNote(sessions.count - limit) }
            }
        }
    }

    /// Small: one line per session, no cards, and a count for the rest instead of scrolling.
    @ViewBuilder private var compactAgentList: some View {
        if sessions.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                Text(allSessions.isEmpty ? "No agents running" : "Running agents are hidden")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 24)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sessions.prefix(3)) { session in
                    CompactPeekRow(session: session) { select(session) }
                        .contextMenu { hideOption(session) }
                        .transition(.opacity)
                }
                if sessions.count > 3 { moreNote(sessions.count - 3) }
            }
        }
    }

    private func hideOption(_ session: AgentSession) -> some View {
        Button("Hide \(session.agent.name) in Peek") { withAnimation(.snappy) { prefs.setPeekHidden(session.agent, true) } }
    }

    private func moreNote(_ count: Int) -> some View {
        Button { openMain(.agentActivity) } label: {
            Text("+\(count) more")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show every running session in Lookout")
    }

    // MARK: Limits

    private var limitTiles: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(shownWindows) { window in
                    Group {
                        if prefs.peekLimitStyle == .pie {
                            LimitTile(window: window, showsCaption: size == .large)
                        } else {
                            LimitBarTile(window: window, showsCaption: size == .large)
                        }
                    }
                    .onTapGesture { openMain(.agentLimits) }
                }
            }
        }
    }

    private var compactLimits: some View {
        VStack(spacing: 2) {
            ForEach(smallWindows) { window in
                CompactLimitLine(window: window, style: prefs.peekLimitStyle)
                    .onTapGesture { openMain(.agentLimits) }
            }
        }
    }

    private var hiddenNote: some View {
        Button { withAnimation(.snappy) { prefs.peekHiddenAgents = [] } } label: {
            HStack(spacing: 5) {
                Image(systemName: "eye.slash").font(.system(size: 10))
                Text("Hiding \(prefs.peekHiddenAgents.sorted { $0.name < $1.name }.map(\.shortName).joined(separator: ", "))")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("Show all").fontWeight(.semibold).foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlass(Capsule(), interactive: true)
    }

    private func select(_ session: AgentSession) {
        if !AgentActions.jump(to: session) {
            agentStore.selectedSessionID = session.id
            openMain(.agentActivity)
        }
    }
}

/// Small caps-free section label that folds its content, with the count while folded.
private struct PeekSectionHeader: View {
    var title: String
    var key: String
    var count: Int
    @ObservedObject private var prefs = Preferences.shared
    @State private var hover = false

    var body: some View {
        let collapsed = prefs.isCollapsed(peek: key)
        Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { prefs.toggleCollapsed(peek: key) } } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .opacity(hover || collapsed ? 1 : 0.4)
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
    }
}

/// What a session is doing, shared by every row size: the colour, a glyph for rows too small for the word, and the word.
private extension AgentSession {
    var peekBucket: AgentActivityBucket { AgentActivityBucket(self) }

    var peekStateColor: Color {
        switch peekBucket {
        case .needsYou: return state == .failed ? .red : .pink
        case .working: return .green
        case .yourTurn: return .blue
        case .idle: return .secondary
        }
    }

    var peekStateSymbol: String {
        switch peekBucket {
        case .needsYou: return state == .failed ? "exclamationmark.triangle.fill" : "hand.raised.fill"
        case .working: return "bolt.fill"
        case .yourTurn: return "arrowshape.turn.up.left.fill"
        case .idle: return "moon.fill"
        }
    }

    var peekStateWord: String { state == .failed ? "Failed" : peekBucket.rawValue }
}

private extension AgentQuotaWindow {
    /// "2h 14m left" for a short session window (Claude's and Codex's 5-hour). Nil for weekly and monthly windows,
    /// whose reset the tile's caption already covers.
    func sessionTimeLeft(at now: Date, suffix: Bool = true) -> String? {
        guard kind == .session, let resetsAt else { return nil }
        let remaining = max(0, resetsAt.timeIntervalSince(now))
        guard remaining > 0 else { return "Resetting now" }
        return AgentFormat.duration(remaining) + (suffix ? " left" : "")
    }

    /// The window's length alone ("Weekly"), for Small's lines.
    var peekShortLabel: String {
        switch kind {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        default: return label
        }
    }
}

/// A session as a glass card, tinted by what it's doing. Medium drops the host-app badge and the pill's word.
private struct PeekRow: View {
    var session: AgentSession
    var detailed = true
    var action: () -> Void

    private var bucket: AgentActivityBucket { session.peekBucket }

    private var tint: Color? {
        switch bucket {
        case .needsYou: return session.state == .failed ? .red.opacity(0.32) : .pink.opacity(0.3)
        case .working: return .green.opacity(0.14)
        case .yourTurn: return .blue.opacity(0.16)
        case .idle: return nil
        }
    }

    private var stateColor: Color { session.peekStateColor }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AgentIconView(agent: session.agent, size: 16)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.14), in: Circle())
                    // Where a click goes: the terminal or editor it runs in.
                    .overlay(alignment: .bottomTrailing) {
                        if detailed { HostAppIcon(session: session, size: 14).offset(x: 3, y: 3) }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.projectName)
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            Text("· \(AgentFormat.duration(ctx.date.timeIntervalSince(session.startedAt)))")
                        }
                        // In a worktree, which branch it is: two agents in one repo otherwise look identical.
                        if session.isInWorktree, let git = session.checkout {
                            Image(systemName: "square.stack.3d.down.right").font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(TagColor.purple.fg)
                            Text(git.refLabel).truncationMode(.middle).layoutPriority(-1)
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                statePill
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .liquidGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: tint, interactive: true)
        .help([session.process?.host.map { "Open \($0.name)" } ?? "Show in Lookout",
               detailed ? nil : session.peekStateWord,
               session.contextTokens.map { "\(AgentFormat.compact(Double($0))) tokens of context" }]
              .compactMap { $0 }.joined(separator: "\n"))
    }

    /// Word and pulse at Large; at Medium a round pill with the pulse or the state's glyph.
    @ViewBuilder private var statePill: some View {
        if detailed {
            HStack(spacing: 4) {
                if bucket == .working { PulsingDot(color: stateColor) }
                Text(session.peekStateWord)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(stateColor)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(stateColor.opacity(0.14), in: Capsule())
        } else {
            Group {
                if bucket == .working { PulsingDot(color: stateColor) }
                else { Image(systemName: session.peekStateSymbol).font(.system(size: 9, weight: .bold)) }
            }
            .foregroundStyle(stateColor)
            .frame(width: 20, height: 20)
            .background(stateColor.opacity(0.14), in: Circle())
            .accessibilityLabel(session.peekStateWord)
        }
    }
}

/// Small's session line, after the small Agents widget: icon, project, and a state glyph. No card, no title, no time.
private struct CompactPeekRow: View {
    var session: AgentSession
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                AgentIconView(agent: session.agent, size: 13)
                Text(session.projectName.isEmpty ? session.agent.shortName : session.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                // A glyph rather than a bare dot, so the state never rests on colour alone.
                Image(systemName: session.peekStateSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(session.peekStateColor)
                    .accessibilityLabel(session.peekStateWord)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(session.title)\n\(session.peekStateWord)")
    }
}

/// A plan window as a glass tile: provider-coloured ring, percentage, and what it is.
private struct LimitTile: View {
    var window: AgentQuotaWindow
    /// Medium leaves out the caption under the chip.
    var showsCaption = true

    var body: some View {
        // Re-evaluated every minute: the even-pace line moves even when usage doesn't, and the session countdown ticks.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            tile(PaceDeviation(window: window, now: context.date), timeLeft: window.sessionTimeLeft(at: context.date))
        }
    }

    private func tile(_ deviation: PaceDeviation, timeLeft: String?) -> some View {
        let color: Color = switch deviation.kind {
        case .ahead: .orange
        case .exhausted: .red
        case .under: .green
        case .onPace, .unknown: .secondary
        }
        let warning = deviation.kind == .ahead || deviation.kind == .exhausted
        return VStack(spacing: 6) {
            ZStack {
                // The tick marks where usage would be if spread evenly over the window.
                ProviderRing(windows: [window], lineWidth: 4)
                Text("\(Int(window.usedPercent.rounded()))")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded).monospacedDigit())
                + Text("%").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 40)
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    AgentIconView(agent: window.agent, size: 10)
                    Text(window.agent.shortName).font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(window.label).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                // The number people watch in a 5-hour window. Quiet, so the chip's colour still leads.
                if let timeLeft {
                    Text(timeLeft)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.top, 1)
                }
                // How far off the even line, then what that means.
                Text(deviation.chip)
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .frame(height: 17)
                    .background(color.opacity(deviation.kind == .onPace || deviation.kind == .unknown ? 0.1 : 0.16), in: Capsule())
                    .padding(.top, 3)
                if showsCaption {
                    Text(deviation.caption)
                        .font(.system(size: 9.5, weight: warning ? .medium : .regular))
                        .foregroundStyle(warning ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .liquidGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: warning ? color.opacity(0.12) : nil, interactive: true)
        .help("\(window.agent.name) \(window.label.lowercased())\n\(deviation.advice)")
    }
}

/// Small's limit line: provider, time left in a session window (or which window it is), and the percentage.
/// No ring, chip, or caption: at 200pt the name and the two numbers are what fit.
private struct CompactLimitLine: View {
    var window: AgentQuotaWindow
    var style: PeekLimitStyle = .pie

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if style == .line {
                VStack(spacing: 3) { row(context.date); LimitMeter(window: window, height: 4, showsPace: true).padding(.horizontal, 6) }
                    .padding(.vertical, 2)
            } else {
                row(context.date)
            }
        }
        .help([window.sessionTimeLeft(at: .now).map { "\(window.agent.name) \(window.label.lowercased()), \($0)" }
                ?? "\(window.agent.name) \(window.label.lowercased())",
               "\(Int(window.usedPercent.rounded()))% used"].joined(separator: "\n"))
    }

    private func row(_ date: Date) -> some View {
            HStack(spacing: 6) {
                if style == .pie {
                    ZStack { ProviderRing(windows: [window], lineWidth: 2.5) }.frame(width: 16, height: 16)
                }
                Text(window.agent.shortName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Group {
                    if let left = window.sessionTimeLeft(at: date, suffix: false) {
                        // The hourglass says "remaining" where there's no room for the word.
                        Label(left, systemImage: "hourglass").labelStyle(PeekTightLabel())
                    } else {
                        Text(window.peekShortLabel)
                    }
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
    }
}

/// The Line style of a limit tile: same facts as the pie tile, with a slim bar (and its even-pace tick) in place of the ring.
private struct LimitBarTile: View {
    var window: AgentQuotaWindow
    var showsCaption = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let deviation = PaceDeviation(window: window, now: context.date)
            let color: Color = switch deviation.kind {
            case .ahead: .orange
            case .exhausted: .red
            case .under: .green
            case .onPace, .unknown: .secondary
            }
            let warning = deviation.kind == .ahead || deviation.kind == .exhausted
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    AgentIconView(agent: window.agent, size: 11)
                    Text(window.agent.shortName).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    Text("\(Int(window.usedPercent.rounded()))%")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded).monospacedDigit())
                        .fixedSize()
                }
                LimitMeter(window: window, height: 5)
                HStack(spacing: 4) {
                    Text(window.label).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(window.sessionTimeLeft(at: context.date) ?? deviation.chip)
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(warning ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                if showsCaption {
                    Text(deviation.caption)
                        .font(.system(size: 9.5, weight: warning ? .medium : .regular))
                        .foregroundStyle(warning ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: warning ? color.opacity(0.12) : nil, interactive: true)
            .help("\(window.agent.name) \(window.label.lowercased())\n\(deviation.advice)")
        }
    }
}

/// First-run (and "Choose what Peek shows…") prompt: what to list, and how limits are drawn.
private struct PeekSetupCard: View {
    @ObservedObject var prefs: Preferences
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Text("What should Peek show?").font(.system(size: compact ? 12 : 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Running agents", isOn: $prefs.peekShowsAgents)
                Toggle("Plan limits and what's left", isOn: $prefs.peekShowsLimits)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            if prefs.peekShowsLimits {
                HStack(spacing: 6) {
                    ForEach(PeekLimitStyle.allCases) { style in
                        let selected = prefs.peekLimitStyle == style
                        Button { withAnimation(.snappy) { prefs.peekLimitStyle = style } } label: {
                            VStack(spacing: 5) {
                                preview(style)
                                Text(style.title).font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.2))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Text("Change it any time: right-click Peek.").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                Button("Done") { withAnimation(.snappy) { prefs.peekSetupDone = true } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func preview(_ style: PeekLimitStyle) -> some View {
        if style == .pie {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 4)
                Circle().trim(from: 0, to: 0.62).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 26, height: 26)
        } else {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(Color.accentColor).frame(width: 26)
            }
            .frame(width: 42, height: 5)
            .frame(height: 26)
        }
    }
}

private struct PeekTightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8.5, weight: .semibold))
            configuration.title
        }
    }
}

/// Live Dock icon: the app icon with a ring for the tightest limit and a pill for running / waiting agents.
struct DockTileView: View {
    var icon: NSImage
    var agents: Int
    var attention: Int
    var limitPercent: Double?

    var body: some View {
        ZStack {
            Image(nsImage: icon).resizable().padding(14)
            if let limitPercent {
                let fraction = min(max(limitPercent / 100, 0), 1)
                Circle().stroke(Color.black.opacity(0.18), lineWidth: 7).padding(5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(LimitMeter.fill(for: limitPercent), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(5)
            }
            if attention > 0 || agents > 0 {
                HStack(spacing: 4) {
                    Image(systemName: attention > 0 ? "hand.raised.fill" : "sparkles")
                    Text("\(attention > 0 ? attention : agents)").monospacedDigit()
                }
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Capsule().fill(attention > 0 ? Color.orange : Color.accentColor))
                .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(4)
            }
        }
        .frame(width: 128, height: 128)
    }
}

/// Invisible strip on one side edge of Peek that resizes it by dragging. An AppKit view rather than a SwiftUI
/// gesture: Peek moves when you drag its background, and only a view that refuses `mouseDownCanMoveWindow` keeps the
/// window still while its edge is dragged. Double-click snaps to the nearest preset size.
struct PeekResizeHandle: NSViewRepresentable {
    var edge: HorizontalEdge

    func makeNSView(context: Context) -> HandleView { HandleView(edge: edge) }
    func updateNSView(_ view: HandleView, context: Context) { view.edge = edge }

    final class HandleView: NSView {
        var edge: HorizontalEdge
        private var startMouseX: CGFloat = 0
        private var startWidth: Double = 0

        init(edge: HorizontalEdge) {
            self.edge = edge
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                MainActor.assumeIsolated {
                    let prefs = Preferences.shared
                    let nearest = PeekSize.allCases.min { abs(Double($0.width) - prefs.peekWidth) < abs(Double($1.width) - prefs.peekWidth) } ?? .large
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { prefs.peekWidth = Double(nearest.width) }
                }
                return
            }
            // Screen coordinates: the window itself moves while its leading edge is dragged.
            startMouseX = NSEvent.mouseLocation.x
            MainActor.assumeIsolated {
                startWidth = Preferences.shared.peekWidth
                LiveSurfaces.shared.beginPeekResize(pinning: edge == .leading ? .trailing : .leading)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            let dx = Double(NSEvent.mouseLocation.x - startMouseX)
            let width = startWidth + (edge == .leading ? -dx : dx)
            MainActor.assumeIsolated {
                let clamped = min(max(width, PeekSize.widthRange.lowerBound), PeekSize.widthRange.upperBound).rounded()
                if Preferences.shared.peekWidth != clamped { Preferences.shared.peekWidth = clamped }
            }
        }

        override func mouseUp(with event: NSEvent) {
            MainActor.assumeIsolated { LiveSurfaces.shared.endPeekResize() }
        }
    }
}
