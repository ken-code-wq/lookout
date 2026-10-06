import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverServices

extension DockerState {
    /// Each state has its own word and glyph, so it never rests on colour alone.
    var tag: (color: TagColor, symbol: String) {
        switch self {
        case .running: return (.green, "play.fill")
        case .paused: return (.yellow, "pause.fill")
        case .restarting: return (.orange, "arrow.clockwise")
        case .created: return (.gray, "circle.dashed")
        case .exited: return (.gray, "stop.fill")
        case .dead: return (.red, "xmark")
        case .removing: return (.gray, "trash")
        }
    }
}

extension DockerContainer {
    /// "Running", "Stopped", or "Exited 1" when it stopped with an error.
    var stateTag: (text: String, color: TagColor, symbol: String) {
        if let code = exitCode, code != 0 { return ("Exited \(code)", .red, "exclamationmark.triangle.fill") }
        let t = state.tag
        return (state.title, t.color, t.symbol)
    }

    var uptimeText: String {
        if state.isUp, let uptime { return "Up \(ServerEntry.formatDuration(uptime))" }
        return status
    }
}

/// How the quick check on a service's port went. Checks on appear and on request; never sends credentials.
struct ServiceLivenessTag: View {
    var kind: ServiceKind?
    var port: Int
    @State private var result: ServiceLiveness?
    @State private var checking = false

    var body: some View {
        HStack(spacing: 4) {
            if let result {
                let look = Self.look(result)
                Tag(text: look.text, color: look.color, symbol: look.symbol)
                    .help(result.milliseconds.map { "\(result.title) in \($0) ms" } ?? result.title)
            } else {
                ProgressView().controlSize(.mini)
            }
            IconButton(symbol: "arrow.clockwise", help: "Check again", size: 22) { check() }
                .disabled(checking)
        }
        .task(id: port) { check() }
    }

    private func check() {
        guard !checking else { return }
        checking = true
        let kind = kind, port = port
        Task {
            let found = await Task.detached(priority: .userInitiated) { ServiceProbe.check(kind: kind, port: port) }.value
            result = found
            checking = false
        }
    }

    static func look(_ l: ServiceLiveness) -> (text: String, color: TagColor, symbol: String) {
        switch l {
        case .responding(let detail, _): return (detail, .green, "checkmark")
        case .needsAuth: return ("Responding · needs password", .green, "lock")
        case .portOpen: return ("Port open", .gray, "circle.dotted")
        case .unexpected: return ("Unexpected reply", .orange, "questionmark")
        case .refused: return ("Refused", .red, "xmark")
        case .timedOut: return ("No answer", .red, "clock.badge.xmark")
        }
    }
}

/// A service's connection URL (password masked until revealed), its parts, and ways to open it.
struct ServiceConnectionCard: View {
    @ObservedObject var state: AppState
    var connection: ServiceConnection
    var container: DockerContainer?
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Connection").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
                Spacer()
                ServiceLivenessTag(kind: connection.kind, port: connection.port)
            }
            HStack(alignment: .top, spacing: 2) {
                Text(connection.url(revealPassword: revealed))
                    .font(NFont.monoSmall)
                    .foregroundStyle(N.text)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                if connection.hasPassword {
                    IconButton(symbol: revealed ? "eye.slash" : "eye", help: revealed ? "Hide password" : "Show password", size: 22) {
                        revealed.toggle()
                    }
                }
                IconButton(symbol: "doc.on.doc", help: connection.hasPassword ? "Copy URL, password included" : "Copy URL", size: 22) {
                    state.copy(connection.url(revealPassword: true), label: "connection URL")
                }
            }
            .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
            .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                if connection.user != nil || connection.kind.role == .database {
                    PropertyRow(symbol: "person", label: "User") { part(connection.user ?? "None", .user) }
                }
                if connection.hasPassword || connection.passwordInFile || connection.kind.role == .database {
                    PropertyRow(symbol: "key", label: "Password") { password }
                }
                if connection.database != nil || [.postgres, .mysql, .mariadb, .mongodb].contains(connection.kind) {
                    PropertyRow(symbol: "cylinder", label: connection.kind == .rabbitmq ? "Virtual host" : "Database") {
                        part(connection.database ?? "None set", .database)
                    }
                }
            }
            if !connection.guessed.isEmpty {
                Text(container == nil
                     ? "Parts marked “default” are what the installer sets up; Lookout can't read a native server's settings."
                     : "Parts marked “default” weren't set in the container's environment, so they're the image's defaults.")
                    .font(NFont.caption).foregroundStyle(N.text3).fixedSize(horizontal: false, vertical: true)
            }
            ServiceOpenButtons(state: state, connection: connection, container: container)
        }
    }

    private func part(_ value: String, _ field: ServiceConnection.Field) -> some View {
        HStack(spacing: 6) {
            Text(value).font(NFont.monoSmall).textSelection(.enabled)
            if connection.guessed.contains(field) { Tag(text: "default", color: .gray).help("Not read from the service; a default") }
        }
    }

    @ViewBuilder private var password: some View {
        if connection.hasPassword {
            HStack(spacing: 6) {
                Text(revealed ? (connection.password ?? "") : ServiceConnection.mask).font(NFont.monoSmall)
                    .textSelection(.enabled)
                if connection.guessed.contains(.password) { Tag(text: "default", color: .gray) }
            }
        } else if connection.passwordInFile {
            Text("In a secret file; Lookout doesn't read it").foregroundStyle(N.text2)
        } else {
            Text(container == nil ? "Unknown" : "None set").foregroundStyle(N.text2)
        }
    }
}

/// "Open in" for a connection: installed desktop clients, a shell client in Terminal, and the web UI if it has one.
struct ServiceOpenButtons: View {
    @ObservedObject var state: AppState
    var connection: ServiceConnection
    var container: DockerContainer?

    var body: some View {
        let coordinator = ServicesCoordinator.shared
        let apps = coordinator.installedApps(for: connection.kind)
        let shell = coordinator.shellCommand(for: .init(kind: connection.kind, basis: .process, container: container, connection: connection))
        let web = webURL
        HStack(spacing: 6) {
            if !apps.isEmpty || shell != nil {
                Menu {
                    ForEach(apps, id: \.0.id) { app, url in
                        Button(app.name) { coordinator.open(connection, in: app, at: url, state: state) }
                    }
                    if let shell {
                        if !apps.isEmpty { Divider() }
                        Button("\(shell.label) in Terminal") { coordinator.runInTerminal(shell.command, title: connection.kind.name) }
                        Button("Copy \(shell.label) command") { state.copy(shell.command, label: "command") }
                    }
                } label: {
                    Label("Open in", systemImage: "arrow.up.forward.app")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(shell.map { "The shell client prompts for the password; it's never put on the command line. \($0.command)" } ?? "")
            } else if ServiceShell.localBinary(connection.kind) != nil {
                Text("No client found. Install TablePlus, or \(ServiceShell.localBinary(connection.kind)!) with Homebrew.")
                    .font(NFont.caption).foregroundStyle(N.text3)
            }
            if let web {
                Button { NSWorkspace.shared.open(web) } label: {
                    Label("Web UI", systemImage: "safari").labelStyle(TightLabelStyle())
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(web.absoluteString)
            }
        }
    }

    /// The management or inbox page, on the host port it's published to.
    private var webURL: URL? {
        for port in connection.kind.webPorts {
            if let container {
                if let host = container.ports.first(where: { $0.containerPort == port })?.hostPort {
                    return URL(string: "http://localhost:\(host)")
                }
            } else if port == connection.port {
                return URL(string: "http://localhost:\(port)")
            }
        }
        return nil
    }
}

/// One container: its state, image and ports, with Start/Stop/Restart and logs. Used in the server inspector.
struct ContainerCard: View {
    @ObservedObject var services: ServicesStore
    var container: DockerContainer
    @State private var showingLogs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Container").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
            VStack(alignment: .leading, spacing: 0) {
                PropertyRow(symbol: "shippingbox", label: "Name") { Text(container.name).textSelection(.enabled) }
                PropertyRow(symbol: "square.stack.3d.up", label: "Image") { Text(container.image).font(NFont.monoSmall).textSelection(.enabled) }
                if let project = container.composeProject {
                    PropertyRow(symbol: "square.grid.3x1.below.line.grid.1x2", label: "Compose") {
                        Text(project + (container.composeService.map { " · \($0)" } ?? ""))
                    }
                }
                PropertyRow(symbol: "circle.dashed", label: "State") {
                    HStack(spacing: 6) {
                        let t = container.stateTag
                        Tag(text: t.text, color: t.color, symbol: t.symbol)
                        Text(container.uptimeText).foregroundStyle(N.text2)
                    }
                }
            }
            ContainerActions(services: services, container: container, showingLogs: $showingLogs, compact: false)
        }
        .sheet(isPresented: $showingLogs) { ContainerLogsSheet(services: services, container: container) }
    }
}

struct ContainerActions: View {
    @ObservedObject var services: ServicesStore
    var container: DockerContainer
    @Binding var showingLogs: Bool
    var compact: Bool

    var body: some View {
        let busy = services.busy.contains(container.id)
        HStack(spacing: compact ? 0 : 6) {
            if busy { ProgressView().controlSize(.small).padding(.horizontal, 4) }
            if container.state.isUp {
                if compact {
                    IconButton(symbol: "arrow.clockwise", help: "Restart") { services.perform(.restart, on: [container]) }.disabled(busy)
                    ArmedStopButton { services.perform(.stop, on: [container]) }.disabled(busy)
                } else {
                    Button { services.perform(.restart, on: [container]) } label: {
                        Label("Restart", systemImage: "arrow.clockwise").labelStyle(TightLabelStyle())
                    }
                    .buttonStyle(SecondaryButtonStyle()).disabled(busy)
                    ArmedStopButton(compact: false) { services.perform(.stop, on: [container]) }.disabled(busy)
                }
            } else if compact {
                IconButton(symbol: "play.fill", help: "Start") { services.perform(.start, on: [container]) }.disabled(busy)
            } else {
                Button { services.perform(.start, on: [container]) } label: {
                    Label("Start", systemImage: "play.fill").labelStyle(TightLabelStyle())
                }
                .buttonStyle(SecondaryButtonStyle()).disabled(busy)
            }
            if compact {
                IconButton(symbol: "text.alignleft", help: "View logs") { showingLogs = true }
            } else {
                Button { showingLogs = true } label: {
                    Label("Logs", systemImage: "text.alignleft").labelStyle(TightLabelStyle())
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }
}

/// The last few hundred lines of a container's output (`docker logs --tail`), stderr marked.
struct ContainerLogsSheet: View {
    @ObservedObject var services: ServicesStore
    var container: DockerContainer
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [DockerLogLine] = []
    @State private var error: String?
    @State private var loading = true
    @State private var tail = 300

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft").foregroundStyle(N.text2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(container.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                    Text("docker logs --tail \(tail) · \(container.image)").font(NFont.caption).foregroundStyle(N.text2)
                }
                Spacer()
                Picker("Lines", selection: $tail) {
                    ForEach([100, 300, 1000], id: \.self) { Text("\($0) lines").tag($0) }
                }
                .labelsHidden().fixedSize()
                IconButton(symbol: "arrow.clockwise", help: "Reload") { load() }
                IconButton(symbol: "doc.on.doc", help: "Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
                }
                .disabled(lines.isEmpty)
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Rectangle().fill(N.divider).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if let error {
                            Text(error).font(NFont.small).foregroundStyle(TagColor.red.fg)
                        } else if lines.isEmpty {
                            Text(loading ? "Reading…" : "No output.").font(NFont.small).foregroundStyle(N.text3)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(line.time.map { Self.time.string(from: $0) } ?? "")
                                    .foregroundStyle(N.text3).frame(width: 58, alignment: .leading)
                                Text(ANSI.strip(line.text)).foregroundStyle(N.text).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.leading, 6)
                            .overlay(alignment: .leading) {
                                if line.isStderr { Rectangle().fill(TagColor.orange.fg.opacity(0.6)).frame(width: 2) }
                            }
                            .help(line.isStderr ? "Written to stderr" : "")
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                }
                .onChange(of: lines) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .background(N.bgSoft)
        }
        .frame(width: 760, height: 520)
        .background(N.bg)
        .task(id: tail) { load() }
    }

    private func load() {
        loading = true
        Task {
            switch await services.logs(for: container, tail: tail) {
            case .success(let fresh): lines = fresh; error = nil
            case .failure(let failure): error = failure.message
            }
            loading = false
        }
    }
}

/// The server inspector's section for databases and Docker-published ports: connection details, and the container.
struct ServiceSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var services: ServicesStore = .shared
    var server: ServerEntry

    var body: some View {
        let forwarded = ServiceRecognizer.isContainerForwarder(processName: server.processName, command: server.command)
        let service = ServicesCoordinator.shared.service(for: server)
        let container = service?.container ?? (forwarded ? services.container(publishing: server.port) : nil)
        // Spacing lives on each part, so an ordinary server gets no gap at all.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if let service {
                VStack(alignment: .leading, spacing: 6) {
                    ServiceConnectionCard(state: state, connection: service.connection, container: service.container)
                    Text("\(service.kind.name) · \(service.basis.explanation.lowercased())" + (container.map { " (\($0.image))" } ?? ""))
                        .font(NFont.caption).foregroundStyle(N.text3)
                }
                .padding(.top, 18)
            }
            if let container { ContainerCard(services: services, container: container).padding(.top, 18) }
            if forwarded, container == nil, !services.availability.isReady, services.lastRefresh != nil {
                Text("Docker forwards this port, but Lookout couldn't read the container list.")
                    .font(NFont.caption).foregroundStyle(N.text3).padding(.top, 18)
            }
        }
        .onAppear { if forwarded || service != nil { services.refreshIfStale() } }
    }
}
