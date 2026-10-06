import SwiftUI
import AppKit
import LocalObserverCore

/// Live sessions grouped by what they need from the user, then recent history.
struct AgentActivityPage: View {
    @ObservedObject var store: AgentStore
    @State private var width: CGFloat = 900
    @State private var recentLimit = 25
    @FocusState private var focused: Bool

    private var filter: AgentActivityFilter { store.activityFilter }

    /// Running sessions after search, before the page filters — the basis for filter options and counts.
    private var allRunning: [AgentSession] { store.runningSessions }

    private var running: [AgentSession] { allRunning.filter(filter.matchesRunning) }

    private var groups: [(title: String, sessions: [AgentSession])] {
        let sessions = running.filter { $0.process.map { !AgentDiscovery.isDesktopApp($0.processName) } ?? true }
        return AgentActivityBucket.allCases.compactMap { bucket in
            let matches = sessions.filter { AgentActivityBucket($0) == bucket }.sorted { $0.updatedAt > $1.updatedAt }
            return matches.isEmpty ? nil : (bucket.rawValue, matches)
        }
    }

    private var openApps: [AgentSession] {
        running.filter { $0.process.map { AgentDiscovery.isDesktopApp($0.processName) } ?? false }
    }

    private var filteredRecent: [AgentSession] {
        let now = Date.now
        return store.recentSessions.filter { filter.matchesRecent($0, now: now) }
    }

    private var recent: [AgentSession] { Array(filteredRecent.prefix(recentLimit)) }

    private var isFiltering: Bool { filter.isNarrowed || !store.searchText.isEmpty }

    private var navigable: [AgentSession] { groups.flatMap(\.sessions) + recent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: "waveform.path.ecg", title: "Sessions", subtitle: AnyView(summary))
                ActivityFilterBar(store: store)
                    .padding(.bottom, 24)

                if !store.settings.hasCompletedSetup {
                    AgentSetupPanel(store: store)
                        .padding(.bottom, 28)
                }

                if store.settings.enabledAgents.isEmpty {
                    EmptyStateView(symbol: "sparkles", title: "No agents selected",
                                   message: "Choose the coding agents Lookout should watch.") {
                        SettingsLink { Text("Choose agents") }.buttonStyle(PrimaryButtonStyle())
                    }
                } else if store.lastRefresh == nil {
                    ActivitySkeleton()
                } else {
                    runningSection
                    if !openApps.isEmpty { openAppsLine.padding(.top, 14) }
                    recentSection.padding(.top, 36)
                    SourceHealthView(store: store).padding(.top, 36)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) {
            guard let session = store.selectedSession, AgentActions.jump(to: session) else { return .ignored }
            return .handled
        }
        .onKeyPress(.escape) {
            guard store.selectedSessionID != nil else { return .ignored }
            store.selectedSessionID = nil
            return .handled
        }
        .animation(.snappy(duration: 0.22), value: running.map(\.state))
    }

    private var horizontalPadding: CGFloat { width > 1100 ? 64 : (width > 800 ? 44 : 24) }
    private var columns: ActivityColumns { ActivityColumns(width: width - horizontalPadding * 2) }

    private var summary: some View {
        HStack(spacing: 14) {
            Label("\(running.count - openApps.count) running", systemImage: "sparkles")
            let urgent = store.attentionSessions.count
            if urgent > 0 {
                Label("\(urgent) need\(urgent == 1 ? "s" : "") you", systemImage: "hand.raised.fill")
                    .foregroundStyle(TagColor.orange.fg)
            }
            RelativeTimeText(date: store.lastRefresh)
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .labelStyle(TightLabelStyle())
    }

    // MARK: Running

    @ViewBuilder private var runningSection: some View {
        if groups.isEmpty {
            EmptyStateView(
                symbol: "terminal",
                title: isFiltering && !allRunning.isEmpty ? "No running sessions match" : "No agents running",
                message: !isFiltering
                    ? "Start \(startHint) in a terminal or editor. It shows up here within 15 seconds."
                    : (store.searchText.isEmpty
                        ? "\(allRunning.count) running session\(allRunning.count == 1 ? " is" : "s are") hidden by the current filters."
                        : "Nothing running matches “\(store.searchText)” with the current filters.")
            ) {
                if isFiltering {
                    Button("Clear filters") { store.clearActivityFilters() }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Refresh now") { store.refresh() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.vertical, -24)
        } else {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle(group.title, count: group.sessions.count)
                        VStack(spacing: 1) {
                            ForEach(group.sessions) { session in
                                RunningSessionRow(
                                    session: session,
                                    columns: columns,
                                    selected: store.selectedSessionID == session.id
                                ) { select(session) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var startHint: String {
        let names = store.enabledAgentsSorted.prefix(2).map(\.name)
        return names.count == 2 ? "\(names[0]) or \(names[1])" : (names.first ?? "an agent")
    }

    private var openAppsLine: some View {
        HStack(spacing: 8) {
            Text("Also open").foregroundStyle(N.text3)
            ForEach(openApps) { app in
                Button {
                    AgentActions.jump(to: app)
                } label: {
                    HStack(spacing: 5) {
                        AgentIconView(agent: app.agent, size: 14)
                        Text(app.agent.name)
                    }
                }
                .buttonStyle(GhostButtonStyle(tint: N.text2))
                .help("Bring \(app.agent.name) to the front")
            }
        }
        .font(NFont.small)
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Recent sessions", count: filteredRecent.count) {
                Text(filter.recentRange.map { "Updated \($0.phrase)" } ?? "Last \(store.settings.historyDays) days")
                    .font(NFont.small).foregroundStyle(N.text3)
            }
            if recent.isEmpty {
                Text(!isFiltering
                     ? "Finished sessions from the enabled agents appear here."
                     : "No recent sessions match the current search and filters.")
                    .font(NFont.small)
                    .foregroundStyle(N.text2)
                    .padding(.vertical, 12)
            } else {
                RecentHeader(columns: columns)
                LazyVStack(spacing: 1) {
                    ForEach(recent) { session in
                        RecentSessionRow(
                            session: session,
                            columns: columns,
                            selected: store.selectedSessionID == session.id
                        ) { select(session) }
                    }
                }
                .padding(.top, 2)
                if filteredRecent.count > recent.count {
                    Button("Show \(min(25, filteredRecent.count - recent.count)) more") { recentLimit += 25 }
                        .buttonStyle(GhostButtonStyle())
                        .padding(.top, 6)
                }
            }
        }
    }

    private func select(_ session: AgentSession) {
        focused = true
        store.selectedSessionID = store.selectedSessionID == session.id ? nil : session.id
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let list = navigable
        guard !list.isEmpty else { return .ignored }
        let current = list.firstIndex { $0.id == store.selectedSessionID }
        let next = current.map { min(max($0 + delta, 0), list.count - 1) } ?? (delta > 0 ? 0 : list.count - 1)
        store.selectedSessionID = list[next].id
        return .handled
    }
}

// MARK: - Filter bar

/// Notion-style filter pills for the Activity page: agent, state, project, model, recency, and size.
private struct ActivityFilterBar: View {
    @ObservedObject var store: AgentStore

    private var filter: AgentActivityFilter { store.activityFilter }

    /// Options come from everything currently visible (after search), so a filter can never hide its own choices.
    private var pool: [AgentSession] { store.runningSessions + store.recentSessions }

    private var projects: [String] {
        Set(pool.map(\.projectName).filter { !$0.isEmpty }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var models: [String] {
        Set(pool.map(\.model).filter { !$0.isEmpty }).sorted()
    }

    private static let tokenSteps: [(String, Int64)] = [
        ("Any size", 0), ("10K+ tokens", 10_000), ("100K+ tokens", 100_000), ("1M+ tokens", 1_000_000), ("10M+ tokens", 10_000_000)
    ]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                FilterChip(title: setTitle("Agent", filter.agents.map(\.shortName)), symbol: "sparkles", active: !filter.agents.isEmpty) {
                    Button("All agents") { store.activityFilter.agents = [] }
                    Divider()
                    ForEach(store.enabledAgentsSorted) { agent in
                        Toggle(agent.name, isOn: toggle(\.agents, agent))
                    }
                }
                FilterChip(title: setTitle("State", filter.buckets.map(\.rawValue)), symbol: "circle.dashed", active: !filter.buckets.isEmpty) {
                    Button("Any state") { store.activityFilter.buckets = [] }
                    Divider()
                    ForEach(AgentActivityBucket.allCases) { bucket in
                        Toggle(bucket.rawValue, isOn: toggle(\.buckets, bucket))
                    }
                }
                FilterChip(title: setTitle("Project", filter.projects), symbol: "folder", active: !filter.projects.isEmpty) {
                    Button("All projects") { store.activityFilter.projects = [] }
                    if !projects.isEmpty { Divider() }
                    ForEach(projects, id: \.self) { Toggle($0, isOn: toggle(\.projects, $0)) }
                }
                FilterChip(title: setTitle("Model", filter.models), symbol: "cpu", active: !filter.models.isEmpty) {
                    Button("All models") { store.activityFilter.models = [] }
                    if !models.isEmpty { Divider() }
                    ForEach(models, id: \.self) { Toggle($0, isOn: toggle(\.models, $0)) }
                }
                FilterChip(title: filter.recentRange.map { "Updated \($0.title.lowercased())" } ?? "Any time",
                           symbol: "calendar", active: filter.recentRange != nil) {
                    Picker("Updated", selection: $store.activityFilter.recentRange) {
                        Text("Any time").tag(AgentDateRange?.none)
                        ForEach(AgentDateRange.allCases) { Text($0.title).tag(AgentDateRange?.some($0)) }
                    }
                    .pickerStyle(.inline)
                }
                FilterChip(title: Self.tokenSteps.first { $0.1 == filter.minTokens }?.0 ?? "Any size",
                           symbol: "number", active: filter.minTokens > 0) {
                    Picker("Size", selection: $store.activityFilter.minTokens) {
                        ForEach(Self.tokenSteps, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .pickerStyle(.inline)
                }
                if filter.isNarrowed || !store.searchText.isEmpty {
                    Button("Clear") { store.clearActivityFilters() }
                        .buttonStyle(GhostButtonStyle())
                        .help("Show every agent, state, project, and model")
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
    }

    private func toggle<T: Hashable>(_ key: WritableKeyPath<AgentActivityFilter, Set<T>>, _ value: T) -> Binding<Bool> {
        Binding(
            get: { store.activityFilter[keyPath: key].contains(value) },
            set: { on in
                if on { store.activityFilter[keyPath: key].insert(value) } else { store.activityFilter[keyPath: key].remove(value) }
            }
        )
    }

    private func setTitle<S: Collection>(_ name: String, _ values: S) -> String where S.Element == String {
        switch values.count {
        case 0: return name
        case 1: return "\(name): \(values.first!)"
        default: return "\(name): \(values.count)"
        }
    }
}

// MARK: - Columns

struct ActivityColumns {
    var width: CGFloat
    var showModel: Bool { width > 640 }
    var showContext: Bool { width > 780 }
    var showHost: Bool { width > 900 }
    var showCost: Bool { width > 720 }

    let state: CGFloat = 108
    let model: CGFloat = 132
    let context: CGFloat = 78
    let host: CGFloat = 104
    let time: CGFloat = 70
    let agent: CGFloat = 116
    let tokens: CGFloat = 76
    let cost: CGFloat = 72
}

// MARK: - Rows

private struct RunningSessionRow: View {
    var session: AgentSession
    var columns: ActivityColumns
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                AgentIconView(agent: session.agent, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.title)
                            .font(NFont.bodyMedium)
                            .foregroundStyle(N.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                        SessionBranchTag(session: session, maxWidth: 170)
                        SessionPullChip(session: session)
                        SessionDiffChip(session: session)
                    }
                    Text(subtitle)
                        .font(NFont.caption)
                        .foregroundStyle(N.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            AgentStateTag(state: session.state)
                .frame(width: columns.state, alignment: .leading)
            if columns.showModel {
                Text(session.model.isEmpty ? "Model unknown" : session.model)
                    .font(NFont.small)
                    .foregroundStyle(session.model.isEmpty ? N.text3 : N.text2)
                    .lineLimit(1)
                    .frame(width: columns.model, alignment: .leading)
            }
            if columns.showContext {
                Text(session.contextTokens.map { AgentFormat.compact(Double($0)) } ?? "–")
                    .font(NFont.small).monospacedDigit()
                    .foregroundStyle(session.contextTokens == nil ? N.text3 : N.text2)
                    .frame(width: columns.context, alignment: .leading)
                    .help("Tokens in the current context window")
            }
            if columns.showHost {
                Text(session.process?.host?.name ?? session.process?.terminal ?? "–")
                    .font(NFont.small)
                    .foregroundStyle(N.text2)
                    .lineLimit(1)
                    .frame(width: columns.host, alignment: .leading)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(AgentFormat.duration(context.date.timeIntervalSince(session.startedAt)))
                    .font(NFont.small).monospacedDigit()
                    .foregroundStyle(N.text2)
            }
            .frame(width: columns.time, alignment: .trailing)
            .help("Running since \(AgentFormat.dateTime(session.startedAt))")
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(selected ? N.selected : (hover ? N.hover : .clear), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(alignment: .trailing) {
            if hover { SessionRowActions(session: session).transition(.opacity) }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 { AgentActions.jump(to: session) } else { action() }
        }
        .contextMenu { SessionMenu(session: session) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        var parts = [session.projectName]
        if let owner = session.checkout?.worktreeOwner { parts.append("\(owner) worktree") }
        if !session.projectPath.isEmpty { parts.append((session.projectPath as NSString).abbreviatingWithTildeInPath) }
        return parts.joined(separator: "  ·  ")
    }
}

private struct SessionRowActions: View {
    var session: AgentSession

    var body: some View {
        HStack(spacing: 0) {
            if let host = session.process?.host {
                IconButton(symbol: "arrow.up.forward.app", help: "Jump to \(host.name) (⌘J)") { AgentActions.jump(to: session) }
            }
            if !session.projectPath.isEmpty {
                IconButton(symbol: "folder", help: "Reveal project in Finder") { AgentActions.reveal(session.projectPath) }
            }
            if !session.sourcePath.isEmpty {
                IconButton(symbol: "doc.text", help: "Show transcript file") { AgentActions.openSource(session.sourcePath) }
            }
        }
        .padding(.horizontal, 3)
        .background(N.bgRaised, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: N.radius, style: .continuous).strokeBorder(N.divider))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        .padding(.trailing, 6)
    }
}

struct SessionMenu: View {
    var session: AgentSession

    var body: some View {
        if let host = session.process?.host {
            Button("Jump to \(host.name)") { AgentActions.jump(to: session) }
            Divider()
        }
        Button("Replay Session") { LiveSurfaces.shared.replay(session) }
            .disabled(session.sourcePath.isEmpty || !SessionReplayReader.supports(session.agent))
        Divider()
        Button("Reveal Project in Finder") { AgentActions.reveal(session.projectPath) }
            .disabled(session.projectPath.isEmpty)
        Button("Show Transcript File") { AgentActions.openSource(session.sourcePath) }
            .disabled(session.sourcePath.isEmpty)
        Divider()
        Button("Copy Project Path") { copy(session.projectPath) }
            .disabled(session.projectPath.isEmpty)
        Button("Copy Session ID") { copy(session.sessionID) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct RecentHeader: View {
    var columns: ActivityColumns

    var body: some View {
        HStack(spacing: 0) {
            cell("textformat", "Session").frame(maxWidth: .infinity, alignment: .leading)
            cell("sparkles", "Agent").frame(width: columns.agent, alignment: .leading)
            if columns.showModel { cell("cpu", "Model").frame(width: columns.model, alignment: .leading) }
            cell("number", "Tokens").frame(width: columns.tokens, alignment: .trailing)
            if columns.showCost { cell("dollarsign", "Cost").frame(width: columns.cost, alignment: .trailing) }
            cell("clock", "Updated").frame(width: columns.time + 16, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(N.divider).frame(height: 1) }
    }

    private func cell(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5))
            Text(title).font(NFont.small)
        }
        .foregroundStyle(N.text2)
    }
}

private struct RecentSessionRow: View {
    var session: AgentSession
    var columns: ActivityColumns
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title).font(NFont.body).foregroundStyle(N.text).lineLimit(1)
            }
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(session.projectPath)

            HStack(spacing: 6) {
                AgentIconView(agent: session.agent, size: 14)
                Text(session.agent.shortName).font(NFont.small).foregroundStyle(N.text2).lineLimit(1)
            }
            .frame(width: columns.agent, alignment: .leading)
            if columns.showModel {
                Text(session.model.isEmpty ? "–" : session.model)
                    .font(NFont.small).foregroundStyle(N.text2).lineLimit(1)
                    .frame(width: columns.model, alignment: .leading)
            }
            Text(session.usage?.processedTokens.map { AgentFormat.compact(Double($0)) } ?? "–")
                .font(NFont.small).monospacedDigit().foregroundStyle(N.text)
                .frame(width: columns.tokens, alignment: .trailing)
            if columns.showCost {
                Text(session.cost.map { AgentFormat.cost($0, estimated: session.costIsEstimated) } ?? "–")
                    .font(NFont.small).monospacedDigit().foregroundStyle(N.text2)
                    .frame(width: columns.cost, alignment: .trailing)
                    .help(session.costIsEstimated ? "Estimated from public API prices" : "Reported by the agent")
            }
            Text(AgentFormat.ago(session.updatedAt))
                .font(NFont.small).monospacedDigit().foregroundStyle(N.text3)
                .frame(width: columns.time + 16, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: N.rowHeight)
        .background(selected ? N.selected : (hover ? N.hover : .clear), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .contextMenu { SessionMenu(session: session) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Source health

/// Which agents Local Observer can read, and how fresh that is. Keeps uncertainty visible.
struct SourceHealthView: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Sources", count: nil) {
                SettingsLink { Text("Manage agents") }.buttonStyle(GhostButtonStyle())
            }
            let columns = [GridItem(.adaptive(minimum: 250), spacing: 18, alignment: .topLeading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(store.enabledAgentsSorted) { agent in
                    if let integration = store.integration(for: agent) {
                        HStack(alignment: .top, spacing: 9) {
                            AgentIconView(agent: agent, size: 16).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(agent.name).font(NFont.small.weight(.medium)).foregroundStyle(N.text)
                                    Circle().fill(dot(integration.sourceState)).frame(width: 6, height: 6)
                                        .accessibilityHidden(true)
                                }
                                Text(detail(integration))
                                    .font(NFont.caption)
                                    .foregroundStyle(N.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func dot(_ state: AgentSourceState) -> Color {
        switch state {
        case .available: return N.green
        case .stale: return TagColor.yellow.fg
        case .error: return N.red
        case .unavailable, .disabled: return N.text3
        }
    }

    private func detail(_ integration: AgentIntegration) -> String {
        guard integration.isInstalled || integration.runningProcessCount > 0 else { return "Not found on this Mac" }
        var parts: [String] = []
        parts.append("\(integration.sessionCount) session\(integration.sessionCount == 1 ? "" : "s")")
        if let updated = integration.lastUpdated { parts.append("active \(AgentFormat.ago(updated))") }
        if integration.sourceState == .error || integration.sourceState == .stale { parts.append(integration.message) }
        return parts.joined(separator: ", ")
    }
}

private struct ActivitySkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(N.bgSoft).frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(N.bgSoft).frame(width: 220 - CGFloat(index * 24), height: 10)
                        RoundedRectangle(cornerRadius: 3).fill(N.bgSoft).frame(width: 140, height: 8)
                    }
                    Spacer()
                }
                .frame(height: 46)
            }
        }
        .accessibilityLabel("Looking for running agents")
    }
}
