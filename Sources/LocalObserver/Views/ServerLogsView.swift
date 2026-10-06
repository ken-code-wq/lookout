import SwiftUI
import AppKit
import LocalObserverCore

// MARK: - Inspector section

/// The logs part of the server inspector: the live log for a server Lookout launched, or, for one started
/// elsewhere, why there's none and how to get it.
struct ServerLogsSection: View {
    @ObservedObject var state: AppState
    var server: ServerEntry

    var body: some View {
        if let launcher = state.managed.first(where: { $0.id == server.managedID }) {
            ServerLogsPanel(state: state, launcher: launcher)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Logs").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
                Text("Logs are only available for servers Lookout launched. This one was started somewhere else (a terminal, an editor, or an agent), so its output goes there.")
                    .font(NFont.caption).foregroundStyle(N.text3).fixedSize(horizontal: false, vertical: true)
                if let match = state.launcherMatching(server) {
                    HStack(spacing: 8) {
                        Button { state.relaunchWithLookout(server, as: match) } label: {
                            Label("Relaunch with Lookout", systemImage: "arrow.triangle.2.circlepath").labelStyle(TightLabelStyle())
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Text("Stops this process and starts “\(match.name)” instead.").font(NFont.caption).foregroundStyle(N.text3)
                    }
                } else if !server.workingDirectory.isEmpty {
                    HStack(spacing: 8) {
                        Button { state.draftLauncher(from: server) } label: {
                            Label("Save as launcher", systemImage: "plus.square.on.square").labelStyle(TightLabelStyle())
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Text("Then relaunch it from here to capture its output.").font(NFont.caption).foregroundStyle(N.text3)
                    }
                }
            }
        }
    }
}

extension AppState {
    /// A saved launcher for the same folder (and port, if it pins one) as a server started outside Lookout.
    func launcherMatching(_ server: ServerEntry) -> ManagedServer? {
        guard !server.isManaged else { return nil }
        let folders = Set([server.workingDirectory, server.projectRoot].filter { !$0.isEmpty }.map { ($0 as NSString).standardizingPath })
        return managed.first { launcher in
            folders.contains((launcher.workingDirectory as NSString).standardizingPath)
                && (launcher.port == nil || launcher.port == server.port) && !isRunning(launcher)
        }
    }

    /// Stops a server started elsewhere and starts its launcher once the old process lets go of the port.
    func relaunchWithLookout(_ server: ServerEntry, as launcher: ManagedServer) {
        stop(server)
        Task { @MainActor [weak self] in
            for _ in 0..<40 where ProcessManager.isAlive(pid: server.pid) || ProcessManager.isPortInUse(server.port) {
                try? await Task.sleep(for: .milliseconds(150))
            }
            self?.start(launcher)
        }
    }
}

// MARK: - Logs panel

/// Live tail of a launcher's output: colour, stdout/stderr, levels, search, and the usual Copy / Clear / Reveal.
/// Follows new lines until you scroll up; then a button takes you back to the latest.
struct ServerLogsPanel: View {
    @ObservedObject var state: AppState
    var launcher: ManagedServer
    var height: CGFloat = 260
    var showsExpand = true
    @ObservedObject private var store = ServerLogStore.shared
    @ObservedObject private var supervisor = ServerSupervisor.shared
    @State private var query = ServerLogQuery()
    @State private var following = true
    @State private var expanded = false

    var body: some View {
        let all = store.lines(for: launcher.id)
        let shown = query.isNarrowed ? all.filter(query.matches) : all
        let errors = all.filter { $0.level == .error && $0.stream != .lookout }.count
        let warnings = all.filter { $0.level == .warn && $0.stream != .lookout }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Logs").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2).fixedSize()
                ServerHealthBadge(managedID: launcher.id)
                Spacer(minLength: 4)
                IconButton(symbol: "doc.on.doc", help: "Copy the lines shown", size: 22) {
                    state.copy(shown.map(\.text).joined(separator: "\n"), label: "\(shown.count) log line\(shown.count == 1 ? "" : "s")")
                }
                .disabled(shown.isEmpty)
                IconButton(symbol: "trash", help: "Clear the log (also empties its file)", size: 22) { store.clear(launcher) }
                    .disabled(all.isEmpty)
                IconButton(symbol: "folder", help: "Reveal the log file in Finder", size: 22) { store.reveal(launcher) }
                if showsExpand {
                    IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open in a larger window", size: 22) { expanded = true }
                }
            }
            filters
            ZStack(alignment: .bottom) {
                LogTextView(lines: shown, search: query.text, following: $following)
                    .frame(height: height)
                    .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: N.radius, style: .continuous))
                if shown.isEmpty {
                    Text(all.isEmpty ? (state.isRunning(launcher) ? "No output yet." : "No output yet. Start the launcher to see its log here.")
                         : "No lines match.")
                        .font(NFont.caption).foregroundStyle(N.text3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                } else if !following {
                    Button { following = true } label: {
                        Label("Jump to latest", systemImage: "arrow.down").labelStyle(TightLabelStyle())
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .background(N.bgRaised, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                    .padding(.bottom, 10)
                    .help("Paused while you read. New lines keep arriving.")
                }
            }
            .frame(height: height)
            HStack(spacing: 10) {
                Legend(symbol: "rectangle.portrait.fill", text: "stderr", color: TagColor.orange.fg)
                Legend(symbol: "xmark.octagon.fill", text: "\(errors) error\(errors == 1 ? "" : "s")", color: TagColor.red.fg)
                Legend(symbol: "exclamationmark.triangle.fill", text: "\(warnings) warning\(warnings == 1 ? "" : "s")", color: TagColor.orange.fg)
                Spacer()
                if store.droppedCount(for: launcher.id) > 0 {
                    Text("Last \(ServerLogStore.capacity.formatted()) lines; the file has the rest.")
                        .font(NFont.caption).foregroundStyle(N.text3).lineLimit(1)
                }
            }
            .help("Levels are guessed from each line's wording (ERROR, warn, stack traces, 5xx responses).")
        }
        .onAppear { store.watch(launcher) }
        .onDisappear { store.unwatch(launcher.id) }
        .sheet(isPresented: $expanded) { ServerLogsSheet(state: state, launcher: launcher) }
    }

    private var filters: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(N.text3)
                TextField("Filter", text: $query.text).textFieldStyle(.plain).font(NFont.small)
                if !query.text.isEmpty {
                    Button { query.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(N.text3) }
                        .buttonStyle(.plain).help("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
            Picker("Level", selection: $query.minimumLevel) {
                Text("All levels").tag(ServerLogLevel.info)
                Text("Warnings and errors").tag(ServerLogLevel.warn)
                Text("Errors only").tag(ServerLogLevel.error)
            }
            .labelsHidden().fixedSize()
            Picker("Stream", selection: $query.stream) {
                Text("stdout and stderr").tag(ServerLogStream?.none)
                Text("stdout").tag(ServerLogStream?.some(.stdout))
                Text("stderr").tag(ServerLogStream?.some(.stderr))
            }
            .labelsHidden().fixedSize()
        }
        .controlSize(.small)
    }

    private struct Legend: View {
        var symbol: String
        var text: String
        var color: Color
        var body: some View {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(color)
                Text(text).font(NFont.caption).foregroundStyle(N.text3)
            }
        }
    }
}

/// The logs panel at full size, with the launcher's crash (if any) on top.
struct ServerLogsSheet: View {
    @ObservedObject var state: AppState
    var launcher: ManagedServer
    @ObservedObject private var supervisor = ServerSupervisor.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                FolderIconView(folder: launcher.workingDirectory, name: launcher.name, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(launcher.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                    Text(launcher.command).font(NFont.monoSmall).foregroundStyle(N.text2).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            if let crash = supervisor.crashes[launcher.id] {
                ServerCrashCard(state: state, launcher: launcher, crash: crash)
            } else {
                AutoRestartToggle(launcher: launcher)
            }
            ServerLogsPanel(state: state, launcher: launcher, height: 440, showsExpand: false)
        }
        .padding(22)
        .frame(width: 780)
        .background(N.bg)
    }
}

// MARK: - Crash

/// What happened when a launched server went down: status, last lines, and what to do about it.
struct ServerCrashCard: View {
    @ObservedObject var state: AppState
    var launcher: ManagedServer
    var crash: ServerSupervisor.Crash

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: crash.clean ? "stop.circle.fill" : "exclamationmark.octagon.fill")
                    .foregroundStyle(crash.clean ? TagColor.orange.fg : TagColor.red.fg)
                Text(crash.title).font(NFont.bodyMedium).foregroundStyle(N.text)
                Spacer()
                Text(crash.at, format: .relative(presentation: .named)).font(NFont.caption).foregroundStyle(N.text3)
            }
            Text("\(crash.statusText), after running \(Self.duration(crash.ranFor)).")
                .font(NFont.small).foregroundStyle(N.text2).fixedSize(horizontal: false, vertical: true)
            if let restart = crash.restart { restartText(restart) }
            if !crash.lastLines.isEmpty {
                ScrollView {
                    Text(crash.lastLines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(N.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: min(CGFloat(crash.lastLines.count) * 14 + 18, 160))
                .background(N.bg.opacity(0.7), in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
            }
            HStack(spacing: 8) {
                Button { state.start(launcher) } label: {
                    Label("Restart", systemImage: "arrow.clockwise").labelStyle(TightLabelStyle())
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.isRunning(launcher))
                Button("Dismiss") { ServerSupervisor.shared.dismiss(launcher.id) }.buttonStyle(GhostButtonStyle())
                Spacer()
                AutoRestartToggle(launcher: launcher)
            }
        }
        .padding(12)
        .background((crash.clean ? TagColor.orange : TagColor.red).bg.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private func restartText(_ restart: ServerSupervisor.Crash.Restart) -> some View {
        switch restart {
        case .scheduled(let at, let attempt, let of):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label("Restarting automatically in \(max(Int(at.timeIntervalSince(context.date).rounded()), 0))s (try \(attempt) of \(of))",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(NFont.caption).foregroundStyle(N.text2)
            }
        case .restarted(let attempt, let of):
            Label("Restarted automatically (try \(attempt) of \(of))", systemImage: "arrow.triangle.2.circlepath")
                .font(NFont.caption).foregroundStyle(N.text2)
        case .gaveUp(let attempts):
            Label("Stopped retrying after \(attempts) automatic restart\(attempts == 1 ? "" : "s")", systemImage: "hand.raised")
                .font(NFont.caption).foregroundStyle(TagColor.red.fg)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

struct AutoRestartToggle: View {
    var launcher: ManagedServer
    @ObservedObject private var supervisor = ServerSupervisor.shared

    var body: some View {
        Toggle("Restart automatically if it crashes", isOn: Binding(
            get: { supervisor.autoRestart.contains(launcher.id) },
            set: { supervisor.setAutoRestart(launcher.id, $0) }
        ))
        .toggleStyle(.checkbox)
        .font(NFont.small)
        .help("Up to \(supervisor.policy.maxAttempts) tries, waiting \(supervisor.policy.delays.map { "\(Int($0))s" }.joined(separator: ", ")) between them. A run that stays up for \(Int(supervisor.policy.stableAfter / 60)) minutes resets the count.")
    }
}

// MARK: - Badges

/// On a server row: its logs are filling with errors.
struct ServerHealthBadge: View {
    var managedID: UUID?
    @ObservedObject private var supervisor = ServerSupervisor.shared

    var body: some View {
        if let id = managedID, let count = supervisor.spiking[id] {
            Tag(text: "\(count) errors/min", color: .red, symbol: "flame.fill")
                .help("\(count) error lines in the last minute. Open the inspector to see them.")
        }
    }
}

/// On a launcher row: it crashed (or stopped on its own), or it's throwing errors.
struct LauncherHealthTag: View {
    var launcher: ManagedServer
    @ObservedObject private var supervisor = ServerSupervisor.shared

    var body: some View {
        if let crash = supervisor.crashes[launcher.id] {
            let restarting: Bool = { if case .scheduled = crash.restart { return true }; return false }()
            Tag(text: restarting ? "Crashed · restarting" : (crash.clean ? "Stopped on its own" : "Crashed"),
                color: crash.clean ? .orange : .red, symbol: crash.clean ? "stop.circle" : "exclamationmark.octagon")
                .help("\(crash.statusText).")
        } else {
            ServerHealthBadge(managedID: launcher.id)
        }
    }
}

/// Opens a launcher's logs (and crash details) in a sheet.
struct LauncherLogsButton: View {
    @ObservedObject var state: AppState
    var launcher: ManagedServer
    @State private var open = false

    var body: some View {
        IconButton(symbol: "text.alignleft", help: "Logs") { open = true }
            .sheet(isPresented: $open) { ServerLogsSheet(state: state, launcher: launcher) }
    }
}

// MARK: - Notch

/// Small error-spike marker for a notch server row.
struct NotchServerHealthBadge: View {
    var managedID: UUID?
    @ObservedObject private var supervisor = ServerSupervisor.shared

    var body: some View {
        if let id = managedID, let count = supervisor.spiking[id] {
            HStack(spacing: 2) {
                Image(systemName: "flame.fill").font(.system(size: 8.5))
                Text("\(count)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(NotchColor.red)
            .help("\(count) error lines in the last minute")
        }
    }
}

/// Launchers that crashed, listed above the notch's running servers with a one-click restart.
struct NotchCrashedLaunchers: View {
    @ObservedObject var state: AppState
    @ObservedObject private var supervisor = ServerSupervisor.shared

    var body: some View {
        let crashed = state.managed.filter { supervisor.crashes[$0.id] != nil && !state.isRunning($0) }
        if !crashed.isEmpty {
            VStack(spacing: 2) {
                ForEach(crashed.prefix(3)) { launcher in
                    let crash = supervisor.crashes[launcher.id]!
                    HStack(spacing: 8) {
                        Image(systemName: crash.clean ? "stop.circle.fill" : "exclamationmark.octagon.fill")
                            .font(.system(size: 11)).foregroundStyle(crash.clean ? NotchColor.orange : NotchColor.red)
                        Text(launcher.name).font(.system(size: 12)).foregroundStyle(NotchColor.text).lineLimit(1)
                        Text(crash.clean ? "stopped" : (crash.status?.summary ?? "crashed"))
                            .font(.system(size: 11)).foregroundStyle(NotchColor.text2).lineLimit(1)
                        Spacer(minLength: 4)
                        Button { state.start(launcher) } label: {
                            Label("Restart", systemImage: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(NotchColor.text)
                        }
                        .buttonStyle(.plain)
                        .help("Start \(launcher.name) again")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                }
            }
        }
    }
}

// MARK: - Log text view

private extension NSAttributedString.Key {
    /// Per-line marker read when drawing the gutter: stderr, level, and line parity (so neighbours never merge).
    static let serverLogLine = NSAttributedString.Key("LocalObserver.serverLogLine")
}

/// AppKit text view for the log: fast to append to, selectable across lines, and its gutter (stderr bar, level
/// icons, row tints) is drawn rather than typed, so copying a selection gives exactly the log's text.
struct LogTextView: NSViewRepresentable {
    var lines: [ServerLogLine]
    var search: String
    @Binding var following: Bool

    final class Coordinator: NSObject {
        var parent: LogTextView
        var ids: [Int] = []
        var lengths: [Int] = []
        var search = ""
        var following = true
        weak var scrollView: NSScrollView?

        init(_ parent: LogTextView) { self.parent = parent }

        @objc func scrolled(_ note: Notification) {
            guard let scroll = scrollView, let doc = scroll.documentView else { return }
            let atBottom = scroll.contentView.bounds.maxY >= doc.frame.height - 12
            guard atBottom != following else { return }
            following = atBottom
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.following != atBottom else { return }
                self.parent.following = atBottom
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let text = LogNSTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        scroll.documentView = text

        context.coordinator.scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let text = scroll.documentView as? LogNSTextView, let storage = text.textStorage else { return }
        let newIDs = lines.map(\.id)
        var appended = false

        storage.beginEditing()
        if c.search != search || newIDs.isEmpty || c.ids.isEmpty {
            storage.setAttributedString(Self.render(lines, search: search))
            c.ids = newIDs
            c.lengths = lines.map { Self.length(of: $0) }
            c.search = search
            appended = true
        } else if let first = newIDs.first {
            // Lines evicted from the front of the buffer leave the top of the text.
            var drop = 0, dropLength = 0
            while drop < c.ids.count, c.ids[drop] < first { dropLength += c.lengths[drop]; drop += 1 }
            let kept = c.ids.count - drop
            if kept > 0, newIDs.count >= kept, newIDs[kept - 1] == c.ids.last {
                if dropLength > 0 { storage.deleteCharacters(in: NSRange(location: 0, length: dropLength)) }
                c.ids.removeFirst(drop)
                c.lengths.removeFirst(drop)
                let fresh = Array(lines[kept...])
                if !fresh.isEmpty {
                    storage.append(Self.render(fresh, search: search))
                    c.ids += fresh.map(\.id)
                    c.lengths += fresh.map { Self.length(of: $0) }
                    appended = true
                }
            } else {
                storage.setAttributedString(Self.render(lines, search: search))
                c.ids = newIDs
                c.lengths = lines.map { Self.length(of: $0) }
                appended = true
            }
        }
        storage.endEditing()

        let jump = following && !c.following
        if jump { c.following = true }
        if c.following && (appended || jump) {
            DispatchQueue.main.async { text.scrollToEndOfDocument(nil) }
        }
    }

    // MARK: Rendering

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    private static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = LogNSTextView.gutter
        p.headIndent = LogNSTextView.gutter + 12
        p.lineSpacing = 1.5
        return p
    }()

    private static func length(of line: ServerLogLine) -> Int { (line.text as NSString).length + 1 }

    static func render(_ lines: [ServerLogLine], search: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let needle = search.trimmingCharacters(in: .whitespaces)
        for line in lines {
            let start = out.length
            if line.stream == .lookout {
                out.append(NSAttributedString(string: line.text, attributes: [
                    .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
            } else {
                for span in line.spans { out.append(NSAttributedString(string: span.text, attributes: attributes(span.style))) }
            }
            out.append(NSAttributedString(string: "\n"))
            let range = NSRange(location: start, length: out.length - start)
            let marker = (line.stream == .stderr ? 1 : 0) | (line.level.rawValue << 1) | ((line.id & 1) << 3)
            out.addAttributes([.paragraphStyle: paragraph, .serverLogLine: marker], range: range)
            if !needle.isEmpty {
                let text = line.text as NSString
                var from = 0
                while from < text.length {
                    let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                           range: NSRange(location: from, length: text.length - from))
                    guard found.location != NSNotFound, found.length > 0 else { break }
                    out.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4),
                                     range: NSRange(location: start + found.location, length: found.length))
                    from = found.location + found.length
                }
            }
        }
        return out
    }

    private static func attributes(_ style: ANSIStyle) -> [NSAttributedString.Key: Any] {
        var font = style.bold ? boldFont : self.font
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var fg = style.foreground.map(color) ?? NSColor.labelColor
        var bg = style.background.map(color)
        if style.inverse { (fg, bg) = (bg ?? NSColor.textBackgroundColor, fg) }
        if style.dim { fg = fg.withAlphaComponent(0.6) }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        if let bg { attrs[.backgroundColor] = bg.withAlphaComponent(0.28) }
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    /// Palette and 24-bit colours are exact; the 16 named ones adapt.
    private static func color(_ c: ANSIColor) -> NSColor {
        switch c {
        case .standard(let n): return named(n)
        case .palette(let n) where n < 16: return named(n)
        case .palette(let n) where n >= 232:
            let v = CGFloat(8 + Int(n - 232) * 10) / 255
            return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        case .palette(let n):
            let i = Int(n) - 16
            func level(_ x: Int) -> CGFloat { x == 0 ? 0 : CGFloat(55 + x * 40) / 255 }
            return NSColor(srgbRed: level(i / 36), green: level((i / 6) % 6), blue: level(i % 6), alpha: 1)
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// The 16 named colours follow the system's, so they read in light and dark mode.
    private static func named(_ n: UInt8) -> NSColor {
        switch n % 8 {
        case 0: return n < 8 ? .secondaryLabelColor : .tertiaryLabelColor
        case 1: return .systemRed
        case 2: return .systemGreen
        case 3: return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemYellow : NSColor(srgbRed: 0.62, green: 0.47, blue: 0, alpha: 1) }
        case 4: return .systemBlue
        case 5: return .systemPurple
        case 6: return .systemTeal
        default: return .labelColor
        }
    }
}

/// Draws the gutter under the text: a bar for stderr lines, an icon and a faint row tint for errors and warnings.
final class LogNSTextView: NSTextView {
    static let gutter: CGFloat = 18

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.serverLogLine, in: chars) { value, range, _ in
            guard let marker = value as? Int else { return }
            let stderr = marker & 1 == 1
            let level = ServerLogLevel(rawValue: (marker >> 1) & 3) ?? .info
            let tint: NSColor? = level == .error ? .systemRed : (level == .warn ? .systemOrange : nil)
            let text = storage.string as NSString
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { fragment, _, _, glyphs, _ in
                // The icon goes on a log line's first row only, not on the rows it wraps onto.
                let start = layout.characterIndexForGlyph(at: glyphs.location)
                let first = start == 0 || text.character(at: start - 1) == 0x0A
                let row = NSRect(x: 0, y: fragment.minY + origin.y, width: self.bounds.width, height: fragment.height)
                if let tint {
                    tint.withAlphaComponent(0.07).setFill()
                    row.fill()
                }
                if stderr {
                    NSColor.systemOrange.withAlphaComponent(0.75).setFill()
                    NSRect(x: 2, y: row.minY, width: 2.5, height: row.height).fill()
                }
                if first, let tint {
                    let symbol = level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                    let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold).applying(.init(paletteColors: [tint]))
                    if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: level == .error ? "Error" : "Warning")?
                        .withSymbolConfiguration(config) {
                        let size = image.size
                        image.draw(in: NSRect(x: origin.x + 6, y: row.minY + (min(row.height, 16) - size.height) / 2,
                                              width: size.width, height: size.height))
                    }
                }
            }
        }
    }
}
