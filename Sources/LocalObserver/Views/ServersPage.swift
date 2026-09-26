import SwiftUI
import AppKit

struct ServersPage: View {
    @ObservedObject var state: AppState
    @State private var width: CGFloat = 900
    @FocusState private var focused: Bool

    var body: some View {
        let servers = state.filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: state.sidebar.symbol, title: state.sidebar.title, subtitle: AnyView(summary))
                ViewBar(state: state)
                Rectangle().fill(N.divider).frame(height: 1)
                ServerFilterBar(state: state)
                    .padding(.vertical, 8)

                if servers.isEmpty {
                    empty
                } else if state.viewMode == .table {
                    TableHeader(columns: columns)
                    LazyVStack(spacing: 1) {
                        ForEach(servers) { server in
                            ServerRow(state: state, server: server, columns: columns,
                                      selected: state.selection == server.id,
                                      favorite: state.favorites.contains(server.port),
                                      stopping: state.stopping.contains(server.id))
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.top, 2)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)], spacing: 14) {
                        ForEach(servers) { server in
                            GalleryCard(state: state, server: server,
                                        selected: state.selection == server.id,
                                        stopping: state.stopping.contains(server.id))
                                .transition(.scale(scale: 0.96).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1, in: servers) }
        .onKeyPress(.upArrow) { move(-1, in: servers) }
        .onKeyPress(.return) {
            guard let s = state.selected else { return .ignored }
            state.open(s); return .handled
        }
        .onKeyPress(.escape) {
            guard state.selection != nil else { return .ignored }
            state.selection = nil; return .handled
        }
        .onTapGesture { state.selection = nil }
        .animation(.snappy(duration: 0.25), value: state.viewMode)
        .animation(.snappy(duration: 0.25), value: state.sidebar)
    }

    private var horizontalPadding: CGFloat { width > 1100 ? 64 : (width > 800 ? 44 : 24) }

    private var columns: Columns { Columns(width: width - horizontalPadding * 2) }

    private var summary: some View {
        HStack(spacing: 14) {
            Label("\(state.filtered.count) listening", systemImage: "dot.radiowaves.left.and.right")
            Label("\(state.filtered.filter(\.isResponding).count) responding", systemImage: "checkmark.circle")
            RelativeTimeText(date: state.lastScan)
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .labelStyle(TightLabelStyle())
    }

    @ViewBuilder private var empty: some View {
        if state.serverFilter.isNarrowed && !state.groupServers.isEmpty {
            EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches these filters",
                           message: "\(state.groupServers.count) server\(state.groupServers.count == 1 ? " is" : "s are") hidden by the current filters.") {
                Button("Clear filters") { state.clearServerFilters() }.buttonStyle(SecondaryButtonStyle())
            }
        } else if !state.searchText.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "No matches",
                           message: "Nothing is listening that matches “\(state.searchText)”.") {
                Button("Clear search") { state.searchText = "" }.buttonStyle(SecondaryButtonStyle())
            }
        } else if state.lastScan == nil {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for local servers…").font(NFont.small).foregroundStyle(N.text2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 64)
        } else if state.sidebar == .favorites {
            EmptyStateView(symbol: "star", title: "No favorites running",
                           message: "Star a server to pin it to the top and find it here.") {
                Button("Show all servers") { state.sidebar = .all }.buttonStyle(SecondaryButtonStyle())
            }
        } else {
            EmptyStateView(symbol: "moon.zzz", title: "Nothing running",
                           message: "No local servers are listening right now. Drop a project folder here, or start one.") {
                Button("Start a server…") { state.draft = LauncherDraft() }.buttonStyle(PrimaryButtonStyle())
                if !state.showSystem {
                    Button("Show system ports") { state.showSystem = true }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func move(_ delta: Int, in list: [ServerEntry]) -> KeyPress.Result {
        guard !list.isEmpty else { return .ignored }
        let current = list.firstIndex { $0.id == state.selection }
        let next = current.map { min(max($0 + delta, 0), list.count - 1) } ?? (delta > 0 ? 0 : list.count - 1)
        state.selection = list[next].id
        return .handled
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 11))
            configuration.title
        }
    }
}

// MARK: - View bar (Notion database header)

private struct ViewBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases) { mode in
                ViewTab(mode: mode, active: state.viewMode == mode) { state.viewMode = mode }
            }
            Spacer(minLength: 8)
            // Drop the text labels before anything gets clipped.
            ViewThatFits(in: .horizontal) {
                controls(labels: true)
                controls(labels: false)
            }
        }
        .padding(.bottom, 6)
    }

    private func controls(labels: Bool) -> some View {
        HStack(spacing: 2) {
            Menu {
                Picker("Sort by", selection: $state.sortKey) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Reverse order", isOn: $state.sortDescending)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .labelStyle(labels ? AnyLabelStyle(TightLabelStyle()) : AnyLabelStyle(.iconOnly))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(NFont.small)
            .foregroundStyle(N.text2)
            .padding(.horizontal, 8)
            .help("Sort by \(state.sortKey.rawValue.lowercased())")

            Button {
                state.showSystem.toggle()
            } label: {
                Label(state.showSystem ? "Hide system" : "Show system", systemImage: state.showSystem ? "eye.slash" : "eye")
                    .labelStyle(labels ? AnyLabelStyle(TightLabelStyle()) : AnyLabelStyle(.iconOnly))
                    .font(NFont.small)
            }
            .buttonStyle(GhostButtonStyle())
            .help(state.showSystem ? "Hide system ports" : "Show system ports")

            Button { state.draft = LauncherDraft() } label: {
                Text("New")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.leading, 6)
        }
        .fixedSize()
    }
}

// MARK: - Filter bar

/// Notion-style filter pills for the servers table: status, type, origin, address, port, memory, uptime.
private struct ServerFilterBar: View {
    @ObservedObject var state: AppState

    private var filter: ServerFilter { state.serverFilter }

    /// Only offer types that are actually present in the current sidebar group.
    private var types: [ProjectType] {
        let present = Set(state.groupServers.map(\.projectType))
        return ProjectType.allCases.filter { present.contains($0) || filter.types.contains($0) }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                FilterChip(title: setTitle("Status", filter.statuses.map(\.rawValue)), symbol: "circle.dashed",
                           active: !filter.statuses.isEmpty) {
                    Button("Any status") { state.serverFilter.statuses = [] }
                    Divider()
                    ForEach(ServerStatusFilter.allCases) { status in
                        Toggle("\(status.rawValue)  (\(count { ServerStatusFilter($0) == status }))",
                               isOn: toggle(\.statuses, status))
                    }
                }
                FilterChip(title: setTitle("Type", filter.types.map(\.rawValue)), symbol: "tag", active: !filter.types.isEmpty) {
                    Button("All types") { state.serverFilter.types = [] }
                    if !types.isEmpty { Divider() }
                    ForEach(types, id: \.self) { type in
                        Toggle("\(type.rawValue)  (\(count { $0.projectType == type }))", isOn: toggle(\.types, type))
                    }
                }
                single("Origin", symbol: "play.square.stack", value: \.origin, all: ServerOrigin.allCases, title: \.rawValue)
                single("Address", symbol: "network", value: \.exposure, all: ServerExposure.allCases, title: \.rawValue)
                single("Port", symbol: "number", value: \.ports, all: PortRangeFilter.allCases, title: \.rawValue)
                single("Memory", symbol: "memorychip", value: \.memory, all: ServerMemoryFilter.allCases, title: \.title)
                single("Uptime", symbol: "clock", value: \.uptime, all: ServerUptimeFilter.allCases, title: \.rawValue)
                if filter.isNarrowed || !state.searchText.isEmpty {
                    Button("Clear") { state.clearServerFilters() }
                        .buttonStyle(GhostButtonStyle())
                        .help("Remove every filter and the search")
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
    }

    private func count(_ test: (ServerEntry) -> Bool) -> Int { state.groupServers.filter(test).count }

    /// A single-choice pill whose first case means "no filter".
    private func single<V: Hashable & Identifiable>(
        _ name: String, symbol: String, value: WritableKeyPath<ServerFilter, V>, all: [V], title: KeyPath<V, String>
    ) -> some View {
        let current = filter[keyPath: value]
        let active = current != all.first
        return FilterChip(title: active ? current[keyPath: title] : name, symbol: symbol, active: active) {
            Picker(name, selection: Binding(get: { state.serverFilter[keyPath: value] },
                                            set: { state.serverFilter[keyPath: value] = $0 })) {
                ForEach(all) { Text($0[keyPath: title]).tag($0) }
            }
            .pickerStyle(.inline)
        }
    }

    private func toggle<T: Hashable>(_ key: WritableKeyPath<ServerFilter, Set<T>>, _ value: T) -> Binding<Bool> {
        Binding(
            get: { state.serverFilter[keyPath: key].contains(value) },
            set: { on in
                if on { state.serverFilter[keyPath: key].insert(value) } else { state.serverFilter[keyPath: key].remove(value) }
            }
        )
    }

    private func setTitle(_ name: String, _ values: [String]) -> String {
        switch values.count {
        case 0: return name
        case 1: return "\(name): \(values[0])"
        default: return "\(name): \(values.count)"
        }
    }
}

/// Type-erased label style so the compact and full variants can share one view.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct ViewTab: View {
    var mode: ViewMode
    var active: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: mode.symbol).font(.system(size: 11.5))
                    Text(mode.rawValue).font(.system(size: 13, weight: active ? .medium : .regular))
                }
                .foregroundStyle(active ? N.text : N.text2)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: N.radius))
                Rectangle()
                    .fill(active ? N.text : .clear)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .padding(.bottom, -7)
    }
}

// MARK: - Table

/// Column layout that adapts to the available width.
struct Columns {
    var width: CGFloat
    var showFolder: Bool { width > 540 }
    var showType: Bool { width > 760 }
    var showUptime: Bool { width > 860 }
    var showMemory: Bool { width > 980 }

    let port: CGFloat = 76
    let status: CGFloat = 128
    let type: CGFloat = 84
    let uptime: CGFloat = 70
    let memory: CGFloat = 72
}

private struct TableHeader: View {
    var columns: Columns

    var body: some View {
        HStack(spacing: 0) {
            cell("textformat", "Name").frame(maxWidth: .infinity, alignment: .leading)
            cell("number", "Port").frame(width: columns.port, alignment: .leading)
            cell("circle.dashed", "Status").frame(width: columns.status, alignment: .leading)
            if columns.showFolder { cell("folder", "Folder").frame(maxWidth: .infinity, alignment: .leading) }
            if columns.showType { cell("tag", "Type").frame(width: columns.type, alignment: .leading) }
            if columns.showUptime { cell("clock", "Uptime").frame(width: columns.uptime, alignment: .leading) }
            if columns.showMemory { cell("memorychip", "Memory").frame(width: columns.memory, alignment: .leading) }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
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

private struct ServerRow: View {
    @ObservedObject var state: AppState
    var server: ServerEntry
    var columns: Columns
    var selected: Bool
    var favorite: Bool
    var stopping: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                FaviconView(server: server, size: 20)
                Text(server.projectName)
                    .font(NFont.bodyMedium)
                    .foregroundStyle(N.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if favorite {
                    Image(systemName: "star.fill").font(.system(size: 9.5)).foregroundStyle(TagColor.yellow.fg)
                }
                if server.isManaged { Tag(text: "Launcher", color: .purple) }
                if !server.pageTitle.isEmpty && server.pageTitle != server.projectName {
                    Text(server.pageTitle).font(NFont.small).foregroundStyle(N.text3).lineLimit(1)
                }
            }
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: ":\(server.port)")
                .font(NFont.mono)
                .foregroundStyle(N.text)
                .frame(width: columns.port, alignment: .leading)

            StatusTag(server: server, stopping: stopping)
                .frame(width: columns.status, alignment: .leading)

            if columns.showFolder {
                Text(server.displayPath.isEmpty ? "—" : server.displayPath)
                    .font(NFont.small)
                    .foregroundStyle(N.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if columns.showType {
                Tag(text: server.projectType.rawValue, color: server.projectType.tag)
                    .frame(width: columns.type, alignment: .leading)
            }
            if columns.showUptime {
                Text(server.uptimeText).font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
                    .frame(width: columns.uptime, alignment: .leading)
            }
            if columns.showMemory {
                Text(server.memoryText).font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
                    .frame(width: columns.memory, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: N.rowHeight)
        .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(alignment: .trailing) {
            if hover && !stopping {
                RowActions(state: state, server: server, favorite: favorite)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 { state.open(server) }
            state.selection = server.id
        }
        .onDrag { NSItemProvider(object: (URL(string: server.urlString) ?? URL(fileURLWithPath: "/")) as NSURL) }
        .contextMenu { ServerMenu(state: state, server: server) }
        .opacity(stopping ? 0.55 : 1)
        .help(server.friendlyCommand)
    }

    private var background: Color {
        if selected { return N.selected }
        return hover ? N.hover : .clear
    }
}

private struct RowActions: View {
    @ObservedObject var state: AppState
    var server: ServerEntry
    var favorite: Bool

    var body: some View {
        HStack(spacing: 0) {
            if server.isResponding {
                IconButton(symbol: "arrow.up.right.square", help: "Open \(server.urlString)") { state.open(server) }
            }
            IconButton(symbol: "doc.on.doc", help: "Copy URL") { state.copy(server.urlString, label: server.urlString) }
            IconButton(symbol: favorite ? "star.fill" : "star", help: favorite ? "Unfavorite" : "Favorite",
                       tint: favorite ? TagColor.yellow.fg : N.text2) { state.toggleFavorite(server) }
            ArmedStopButton { state.stop(server) }
        }
        .padding(.horizontal, 3)
        .background(N.bgRaised, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: N.radius, style: .continuous).strokeBorder(N.divider))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        .padding(.trailing, 6)
    }
}

struct ServerMenu: View {
    @ObservedObject var state: AppState
    var server: ServerEntry

    var body: some View {
        Button("Open in Browser") { state.open(server) }
        Button("Copy URL") { state.copy(server.urlString, label: server.urlString) }
        Button("Copy Command") { state.copy(server.command, label: "command") }
        Divider()
        Button("Reveal in Finder") { state.reveal(server) }.disabled(server.workingDirectory.isEmpty)
        Button("Open in Terminal") { state.openTerminal(server) }.disabled(server.workingDirectory.isEmpty)
        Button("Open in Editor") { state.openEditor(server) }.disabled(server.workingDirectory.isEmpty)
        Divider()
        Button(state.favorites.contains(server.port) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(server) }
        if !server.isManaged && !server.workingDirectory.isEmpty {
            Button("Save as Launcher…") { state.draftLauncher(from: server) }
        }
        Divider()
        Button("Stop") { state.stop(server) }
        Button("Force Quit") { state.stop(server, force: true) }
    }
}

// MARK: - Gallery

private struct GalleryCard: View {
    @ObservedObject var state: AppState
    var server: ServerEntry
    var selected: Bool
    var stopping: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                TagColor.hashed(server.projectName).bg.opacity(0.7)
                FaviconView(server: server, size: 44)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
            .frame(height: 92)
            .overlay(alignment: .topTrailing) {
                if hover && !stopping {
                    HStack(spacing: 0) {
                        if server.isResponding {
                            IconButton(symbol: "arrow.up.right.square", help: "Open") { state.open(server) }
                        }
                        ArmedStopButton { state.stop(server) }
                    }
                    .padding(.horizontal, 2)
                    .background(N.bgRaised, in: RoundedRectangle(cornerRadius: N.radius))
                    .padding(8)
                    .transition(.opacity)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(server.projectName).font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text).lineLimit(1)
                    if state.favorites.contains(server.port) {
                        Image(systemName: "star.fill").font(.system(size: 9.5)).foregroundStyle(TagColor.yellow.fg)
                    }
                }
                Text(server.pageTitle.isEmpty ? (server.displayPath.isEmpty ? server.processName : server.displayPath) : server.pageTitle)
                    .font(NFont.small).foregroundStyle(N.text2).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Tag(text: ":\(server.port)", mono: true)
                    StatusTag(server: server, stopping: stopping)
                    Tag(text: server.projectType.rawValue, color: server.projectType.tag)
                }
                .padding(.top, 2)
            }
            .padding(12)
        }
        .background(N.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? N.blue.opacity(0.8) : N.divider, lineWidth: selected ? 2 : 1)
        )
        .shadow(color: .black.opacity(hover ? 0.08 : 0.02), radius: hover ? 10 : 2, y: hover ? 4 : 1)
        .offset(y: hover ? -1 : 0)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hover = h } }
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 { state.open(server) }
            state.selection = server.id
        }
        .onDrag { NSItemProvider(object: (URL(string: server.urlString) ?? URL(fileURLWithPath: "/")) as NSURL) }
        .contextMenu { ServerMenu(state: state, server: server) }
        .opacity(stopping ? 0.55 : 1)
    }
}
