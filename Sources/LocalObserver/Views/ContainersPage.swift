import SwiftUI
import AppKit
import LocalObserverServices

/// Every Docker container, running or stopped, grouped by compose project, with the connection details of the
/// databases among them. Says plainly when Docker isn't installed or isn't running.
struct ContainersPage: View {
    @ObservedObject var store: ServicesStore
    @ObservedObject var state: AppState
    @State private var width: CGFloat = 900
    @State private var collapsed: Set<String> = []
    @State private var expanded: String?
    @State private var logsFor: DockerContainer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: SidebarItem.containers.symbol, title: SidebarItem.containers.title, subtitle: AnyView(summary))
                content
            }
            .padding(.horizontal, width > 1100 ? 64 : (width > 800 ? 44 : 24))
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .task {
            // Brisk while the page is open; Docker isn't asked at all otherwise.
            while !Task.isCancelled {
                store.refreshIfStale(8)
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .sheet(item: $logsFor) { ContainerLogsSheet(services: store, container: $0) }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            if store.availability.isReady {
                let stopped = store.containers.count - store.runningCount
                Label("\(store.runningCount) running", systemImage: "play.circle")
                if stopped > 0 { Label("\(stopped) stopped", systemImage: "stop.circle") }
                let services = store.containers.filter { $0.kind != nil && $0.state.isUp }.count
                if services > 0 { Label("\(services) database\(services == 1 ? "" : "s") and services", systemImage: "cylinder.split.1x2") }
            }
            if store.isRefreshing && store.lastRefresh == nil {
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Asking Docker…") }
            } else {
                RelativeTimeText(date: store.lastRefresh)
            }
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .labelStyle(TightLabelStyle())
    }

    @ViewBuilder private var content: some View {
        switch store.availability {
        case .unknown:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for Docker…").font(NFont.small).foregroundStyle(N.text2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 60)
        case .notInstalled:
            EmptyStateView(symbol: "shippingbox", title: "Docker isn't installed",
                           message: "Lookout looks for the docker command from Docker Desktop, OrbStack, Colima or Homebrew. Databases running natively still show under Databases.") {
                Button("Check again") { store.refresh() }.buttonStyle(SecondaryButtonStyle())
            }
        case .daemonDown(let message):
            EmptyStateView(symbol: "shippingbox", title: "Docker isn't running",
                           message: "The docker command is installed, but nothing answers it. Start Docker Desktop, OrbStack or Colima.\n\(message)") {
                ForEach(dockerApps, id: \.0) { name, url in
                    Button("Open \(name)") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                Button("Check again") { store.refresh() }.buttonStyle(SecondaryButtonStyle())
            }
        case .failed(let message):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Docker didn't answer", message: message) {
                Button("Try again") { store.refresh() }.buttonStyle(SecondaryButtonStyle())
            }
        case .ready:
            if store.containers.isEmpty {
                EmptyStateView(symbol: "shippingbox", title: "No containers",
                               message: "Docker is running, but there are no containers, running or stopped.") { EmptyView() }
            } else if store.groups.isEmpty {
                Text("No containers match “\(store.searchText)”.").font(NFont.small).foregroundStyle(N.text2).padding(.top, 20)
            } else {
                ForEach(store.groups) { section($0) }
            }
        }
    }

    /// Docker Desktop, OrbStack: whichever is installed, to start from the "isn't running" state.
    private var dockerApps: [(String, URL)] {
        [("Docker Desktop", "com.docker.docker"), ("OrbStack", "dev.kdrag0n.MacVirt")].compactMap { name, id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { (name, $0) }
        }
    }

    private func section(_ group: DockerGroup) -> some View {
        let folded = collapsed.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { if folded { collapsed.remove(group.id) } else { collapsed.insert(group.id) } }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(N.text3)
                            .rotationEffect(.degrees(folded ? 0 : 90))
                        Image(systemName: group.project == nil ? "shippingbox" : "square.stack.3d.up").font(.system(size: 12.5))
                            .foregroundStyle(N.text2)
                        Text(group.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                        Text("\(group.running) of \(group.containers.count) running").font(NFont.small).foregroundStyle(N.text3).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if let folder = group.folder {
                    IconButton(symbol: "folder", help: "Reveal \(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))") {
                        ProcessManager.reveal(path: folder)
                    }
                }
                if group.project != nil {
                    let stopped = group.containers.filter { !$0.state.isUp }
                    let running = group.containers.filter(\.state.isUp)
                    if !stopped.isEmpty {
                        Button("Start all") { store.perform(.start, on: stopped, label: group.title) }
                            .buttonStyle(GhostButtonStyle(tint: N.blue))
                    }
                    if !running.isEmpty {
                        ArmedButton(title: "Stop project", armedTitle: "Stop \(running.count)?") {
                            store.perform(.stop, on: running, label: group.title)
                        }
                        .help("docker stop for every running container in \(group.title). Volumes and data stay.")
                    }
                }
            }
            .padding(.top, 22)
            .padding(.bottom, 6)
            if !folded {
                Rectangle().fill(N.divider).frame(height: 1)
                LazyVStack(spacing: 1) {
                    ForEach(group.containers) { container in
                        ContainerRow(state: state, store: store, container: container, expanded: expanded == container.id,
                                     showLogs: { logsFor = container }) {
                            withAnimation(.snappy(duration: 0.2)) { expanded = expanded == container.id ? nil : container.id }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

struct ContainerRow: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ServicesStore
    var container: DockerContainer
    var expanded: Bool
    var showLogs: () -> Void
    var toggle: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: container.kind?.symbol ?? "shippingbox")
                    .font(.system(size: 13)).foregroundStyle(container.kind == nil ? N.text3 : TagColor.purple.fg).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(container.composeService ?? container.name).font(NFont.bodyMedium).foregroundStyle(N.text).lineLimit(1)
                        if let kind = container.kind { Tag(text: kind.name, color: .purple) }
                        if let health = container.health {
                            Tag(text: health.capitalized, color: health == "unhealthy" ? .red : (health == "healthy" ? .green : .gray),
                                symbol: health == "unhealthy" ? "heart.slash" : "heart")
                        }
                    }
                    Text(container.image + " · " + container.uptimeText)
                        .font(NFont.caption).foregroundStyle(N.text2).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 10)
                if hover {
                    ContainerActions(services: store, container: container,
                                     showingLogs: Binding(get: { false }, set: { if $0 { showLogs() } }), compact: true)
                } else if store.busy.contains(container.id) {
                    ProgressView().controlSize(.small)
                }
                ports
                let t = container.stateTag
                Tag(text: t.text, color: t.color, symbol: t.symbol)
                    .help(container.status)
                    .frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if expanded { detail.padding(.leading, 36).padding(.trailing, 8).padding(.bottom, 14) }
        }
        .background(expanded ? N.bgSoft : (hover ? N.hover : .clear), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onHover { hover = $0 }
        .opacity(store.busy.contains(container.id) ? 0.6 : 1)
        .contextMenu {
            if container.state.isUp {
                Button("Restart") { store.perform(.restart, on: [container]) }
                Button("Stop") { store.perform(.stop, on: [container]) }
            } else {
                Button("Start") { store.perform(.start, on: [container]) }
            }
            Button("View Logs") { showLogs() }
            Divider()
            if let connection = store.connection(for: container) {
                Button("Copy Connection URL") { state.copy(connection.url(revealPassword: true), label: "connection URL") }
            }
            Button("Copy Name") { state.copy(container.name, label: container.name) }
            Button("Copy ID") { state.copy(container.id, label: "container ID") }
            if let folder = container.composeFolder {
                Button("Reveal Compose Folder") { ProcessManager.reveal(path: folder) }
            }
        }
    }

    private var ports: some View {
        HStack(spacing: 4) {
            ForEach(container.publishedPorts.prefix(3), id: \.self) { port in
                Text(port.label).font(NFont.monoSmall).foregroundStyle(N.text2)
                    .help(port.hostIP.map { "\($0):\(port.hostPort ?? 0) → container \(port.containerPort)/\(port.proto)" } ?? "")
            }
            if container.publishedPorts.count > 3 {
                Text("+\(container.publishedPorts.count - 3)").font(NFont.caption).foregroundStyle(N.text3)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let connection = store.connection(for: container), container.state.isUp {
                ServiceConnectionCard(state: state, connection: connection, container: container)
            } else if container.kind != nil, container.primaryHostPort == nil {
                Text("This container doesn't publish a port to the Mac, so there's nothing to connect to from here.")
                    .font(NFont.caption).foregroundStyle(N.text2)
            }
            VStack(alignment: .leading, spacing: 0) {
                PropertyRow(symbol: "number", label: "ID") { Text(container.shortID).font(NFont.monoSmall).textSelection(.enabled) }
                PropertyRow(symbol: "info.circle", label: "Status") { Text(container.status) }
                if !container.ports.isEmpty {
                    PropertyRow(symbol: "network", label: "Ports") {
                        Text(container.ports.map(\.label).joined(separator: ", ")).font(NFont.monoSmall)
                    }
                }
                if let created = container.createdAt {
                    PropertyRow(symbol: "calendar", label: "Created") { Text(created.formatted(date: .abbreviated, time: .shortened)) }
                }
                if let folder = container.composeFolder {
                    PropertyRow(symbol: "folder", label: "Compose") {
                        Button { ProcessManager.reveal(path: folder) } label: {
                            Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
