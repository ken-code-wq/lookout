import SwiftUI
import AppKit
import LocalObserverCore

/// Notion-style "peek" page for the selected server.
struct InspectorView: View {
    @ObservedObject var state: AppState
    var server: ServerEntry

    private var launcher: ManagedServer? { state.managed.first { $0.id == server.managedID } }
    private var favorite: Bool { state.favorites.contains(server.port) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                actions.padding(.top, 14)
                Rectangle().fill(N.divider).frame(height: 1).padding(.vertical, 16)
                properties
                ServiceSection(state: state, server: server)
                commandBlock.padding(.top, 18)
                ShareSection(port: server.port).padding(.top, 18)
                if let launcher {
                    RequestLogView(path: launcher.logPath).padding(.top, 18)
                    LogTail(path: launcher.logPath).padding(.top, 18)
                } else if !server.workingDirectory.isEmpty {
                    Button { state.draftLauncher(from: server) } label: {
                        Label("Save as launcher", systemImage: "plus.square.on.square").labelStyle(TightLabelStyle())
                    }
                    .buttonStyle(GhostButtonStyle(tint: N.text2))
                    .padding(.top, 12)
                    .padding(.leading, -7)
                }
                danger.padding(.top, 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(N.bg)
        .id(server.id)
        .transition(.opacity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            FaviconView(server: server, size: 52)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                .onDrag { NSItemProvider(object: (URL(string: server.urlString) ?? URL(fileURLWithPath: "/")) as NSURL) }
                .help("Drag to a browser to open")
            Text(server.projectName)
                .font(NFont.title)
                .foregroundStyle(N.text)
                .textSelection(.enabled)
                .padding(.top, 6)
            if !server.pageTitle.isEmpty && server.pageTitle != server.projectName {
                Text(server.pageTitle).font(NFont.small).foregroundStyle(N.text2)
            }
            if let git = server.git { BranchTag(git, maxWidth: 300) }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { state.open(server) } label: {
                Label("Open", systemImage: "arrow.up.right").labelStyle(TightLabelStyle())
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)

            if let launcher {
                Button { state.restart(launcher) } label: {
                    Label("Restart", systemImage: "arrow.clockwise").labelStyle(TightLabelStyle())
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Spacer(minLength: 0)
            IconButton(symbol: "doc.on.doc", help: "Copy URL") { state.copy(server.urlString, label: server.urlString) }
            IconButton(symbol: "folder", help: "Reveal in Finder") { state.reveal(server) }
                .disabled(server.workingDirectory.isEmpty)
            IconButton(symbol: "terminal", help: "Open in Terminal") { state.openTerminal(server) }
                .disabled(server.workingDirectory.isEmpty)
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") { state.openEditor(server) }
                .disabled(server.workingDirectory.isEmpty)
            IconButton(symbol: favorite ? "star.fill" : "star", help: favorite ? "Unfavorite" : "Favorite",
                       tint: favorite ? TagColor.yellow.fg : N.text2) { state.toggleFavorite(server) }
        }
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 2) {
            PropertyRow(symbol: "circle.dashed", label: "Status") {
                StatusTag(server: server, stopping: state.stopping.contains(server.id))
            }
            PropertyRow(symbol: "link", label: "URL") {
                Link(server.urlString, destination: URL(string: server.urlString) ?? URL(fileURLWithPath: "/"))
                    .foregroundStyle(N.text)
                    .underline(color: N.text3)
            }
            PropertyRow(symbol: "number", label: "Port") {
                Text(verbatim: ":\(server.port)  ·  \(server.bindAddress == "*" ? "all interfaces" : server.bindAddress)")
                    .font(NFont.mono)
            }
            PropertyRow(symbol: "folder", label: "Folder") {
                Button { state.reveal(server) } label: {
                    Text(server.displayPath.isEmpty ? "Unknown" : server.displayPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .disabled(server.workingDirectory.isEmpty)
            }
            if let git = server.git {
                PropertyRow(symbol: "arrow.triangle.branch", label: "Branch") { BranchTag(git) }
                if git.isLinkedWorktree {
                    PropertyRow(symbol: "square.stack.3d.down.right", label: "Worktree") { WorktreeValue(git: git) }
                }
            }
            PropertyRow(symbol: "tag", label: "Type") {
                Tag(text: server.projectType.rawValue, color: server.projectType.tag)
            }
            PropertyRow(symbol: "gearshape.2", label: "Process") {
                Text("\(server.processName)  ·  PID \(String(server.pid))").textSelection(.enabled)
            }
            PropertyRow(symbol: "clock", label: "Uptime") { Text(server.uptimeText).monospacedDigit() }
            PropertyRow(symbol: "cpu", label: "CPU") { Text(String(format: "%.1f%%", server.cpu)).monospacedDigit() }
            PropertyRow(symbol: "memorychip", label: "Memory") { Text(server.memoryText).monospacedDigit() }
            if let launcher {
                PropertyRow(symbol: "play.square.stack", label: "Launcher") {
                    Button(launcher.name) { state.edit(launcher) }.buttonStyle(.plain).underline(color: N.text3)
                }
            }
        }
    }

    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Command").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
                Spacer()
                IconButton(symbol: "doc.on.doc", help: "Copy command", size: 22) { state.copy(server.command, label: "command") }
            }
            Text(server.command)
                .font(NFont.monoSmall)
                .foregroundStyle(N.text)
                .textSelection(.enabled)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
        }
    }

    private var danger: some View {
        HStack(spacing: 8) {
            ArmedStopButton(compact: false) { state.stop(server) }
                .overlay(RoundedRectangle(cornerRadius: N.radius).strokeBorder(N.red.opacity(0.35)))
            Button("Force quit") { state.stop(server, force: true) }
                .buttonStyle(GhostButtonStyle(tint: N.red))
                .help("Send SIGKILL — the process gets no chance to clean up")
            Spacer()
        }
    }
}

/// Live tail of a launcher's log file.
struct LogTail: View {
    var path: String
    @State private var text = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
                Spacer()
                IconButton(symbol: "arrow.up.forward.app", help: "Open log file", size: 22) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "No output yet." : text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? N.text3 : N.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .scrollIndicators(.never)
                .frame(height: 200)
                .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
                .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .onAppear(perform: load)
        .onReceive(timer) { _ in load() }
    }

    private func load() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 12_000 ? size - 12_000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let fresh = Self.stripANSI(String(decoding: data, as: UTF8.self))
        if fresh != text { text = fresh }
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}


/// Sharing a server on a public URL through cloudflared or ngrok.
struct ShareSection: View {
    var port: Int
    @ObservedObject private var tunnels = TunnelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
            if let tunnel = tunnels.tunnels[port] {
                if let url = tunnel.url {
                    HStack(spacing: 6) {
                        Circle().fill(N.green).frame(width: 7, height: 7)
                        Link(url.replacingOccurrences(of: "https://", with: ""), destination: URL(string: url)!)
                            .font(NFont.small).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        IconButton(symbol: "doc.on.doc", help: "Copy public URL") { RepoActions.copy(url) }
                        Button("Stop") { tunnels.stop(port: port) }.buttonStyle(SecondaryButtonStyle(tint: N.red))
                    }
                    Text("Anyone with the link can reach this server through \(tunnel.tool) until you stop it or quit Lookout.")
                        .font(NFont.caption).foregroundStyle(N.text3)
                } else if let error = tunnel.error {
                    Text(error).font(NFont.small).foregroundStyle(TagColor.orange.fg).fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") { tunnels.stop(port: port) }.buttonStyle(GhostButtonStyle())
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Opening a tunnel with \(tunnel.tool)…").font(NFont.small).foregroundStyle(N.text2)
                        Spacer()
                        Button("Cancel") { tunnels.stop(port: port) }.buttonStyle(GhostButtonStyle())
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button { tunnels.start(port: port) } label: { Label("Share publicly", systemImage: "globe") }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!TunnelManager.isAvailable)
                    Text(TunnelManager.isAvailable ? "A temporary public URL for :\(port)"
                         : "Needs cloudflared or ngrok: brew install cloudflared")
                        .font(NFont.caption).foregroundStyle(N.text3)
                }
            }
        }
    }
}

/// Requests a launcher's server has logged: method, path, status, time; errors counted.
struct RequestLogView: View {
    var path: String
    @State private var requests: [ServerRequest] = []
    @State private var errors = 0
    @State private var onlyProblems = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Requests").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
                if !requests.isEmpty {
                    let failed = requests.filter(\.isError).count, client = requests.filter(\.isClientError).count
                    Text("\(requests.count)").font(NFont.caption).foregroundStyle(N.text3)
                    if failed > 0 { Tag(text: "\(failed) 5xx", color: .red) }
                    if client > 0 { Tag(text: "\(client) 4xx", color: .orange) }
                }
                if errors > 0 { Tag(text: "\(errors) error line\(errors == 1 ? "" : "s")", color: .red) }
                Spacer()
                Toggle("Problems only", isOn: $onlyProblems).toggleStyle(.checkbox).font(NFont.caption)
            }
            let shown = Array(requests.reversed().filter { !onlyProblems || $0.status >= 400 }.prefix(60))
            if shown.isEmpty {
                Text(requests.isEmpty ? "No requests logged yet. Lookout reads them from the server's output." : "No failed requests.")
                    .font(NFont.caption).foregroundStyle(N.text3)
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { r in
                        HStack(spacing: 8) {
                            Text(r.method).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(N.text2).frame(width: 52, alignment: .leading)
                            Text(r.path).font(NFont.monoSmall).foregroundStyle(N.text).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            if let ms = r.milliseconds {
                                Text(ms >= 1000 ? String(format: "%.1fs", ms / 1000) : "\(Int(ms))ms").font(NFont.monoSmall)
                                    .foregroundStyle(ms > 1000 ? TagColor.orange.fg : N.text3)
                            }
                            Text("\(r.status)").font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(r.isError ? TagColor.red.fg : (r.isClientError ? TagColor.orange.fg : TagColor.green.fg))
                                .frame(width: 32, alignment: .trailing)
                        }
                        .frame(height: 22)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
            }
        }
        .onAppear(perform: load)
        .onReceive(timer) { _ in load() }
    }

    private func load() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        let text = LogTail.stripANSI(String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self))
        let parsed = ServerRequest.parse(text)
        if parsed != requests { requests = parsed }
        errors = ServerRequest.errorLines(text).count
    }
}
