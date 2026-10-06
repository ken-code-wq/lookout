import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverRepos

/// What an agent did in a session, step by step: prompts, messages, commands with their output, and every file it
/// changed with the diff. Steps can be played back in order, or filtered to one file.
struct SessionReplayView: View {
    var session: AgentSession
    var close: () -> Void

    @State private var replay: SessionReplay?
    @State private var loaded = false
    @State private var filter: Filter = .all
    @State private var file: String?
    @State private var selected: Int?
    @State private var playing = false
    @State private var query = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", changes = "Changes", commands = "Commands", conversation = "Conversation"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(N.divider).frame(height: 1)
            if let replay {
                if replay.events.isEmpty {
                    EmptyStateView(symbol: "film", title: "Nothing to replay",
                                   message: "This transcript has no prompts, commands or file changes Lookout can read.") { EmptyView() }
                        .frame(maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        sidebar(replay).frame(width: 260)
                        Rectangle().fill(N.divider).frame(width: 1)
                        timeline(replay)
                    }
                }
            } else if loaded {
                EmptyStateView(symbol: "film", title: "Replay isn't available",
                               message: SessionReplayReader.supports(session.agent)
                                   ? "The transcript couldn't be read. It may have been moved or deleted."
                                   : "\(session.agent.name) doesn't record its tool calls where Lookout can read them. Claude Code and Codex sessions can be replayed.") {
                    EmptyView()
                }
                .frame(maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, idealWidth: 1180, minHeight: 640, idealHeight: 820)
        .background(N.bg)
        .task(id: session.id) {
            let agent = session.agent, path = session.sourcePath
            replay = await Task.detached(priority: .userInitiated) { SessionReplayReader.read(agent: agent, path: path) }.value
            loaded = true
        }
        .task(id: playing) {
            // Playback: step through what's shown, a beat per step, longer on file changes so the diff can be read.
            guard playing, let replay else { return }
            let steps = visible(replay)
            var index = steps.firstIndex { $0.id == selected }.map { $0 + 1 } ?? 0
            while playing, index < steps.count {
                withAnimation(.snappy(duration: 0.25)) { selected = steps[index].id }
                try? await Task.sleep(for: .milliseconds(steps[index].isChange ? 1600 : 700))
                index += 1
            }
            playing = false
        }
        .onKeyPress(.space) { playing.toggle(); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            AgentIconView(agent: session.agent, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(N.text).lineLimit(1)
                HStack(spacing: 10) {
                    Text(session.projectName)
                    if let git = session.checkout { InlineBranch(git: git) } else if !session.branch.isEmpty { Text(session.branch) }
                    if let replay {
                        if let start = replay.start, let end = replay.end {
                            Text(Self.duration(end.timeIntervalSince(start)))
                        }
                        let totals = replay.totals
                        Text("\(replay.files.count) files").monospacedDigit()
                        if totals.added + totals.removed > 0 {
                            HStack(spacing: 4) {
                                Text("+\(totals.added)").foregroundStyle(GH.open)
                                Text("−\(totals.removed)").foregroundStyle(GH.closed)
                            }
                            .font(NFont.monoSmall)
                        }
                        Text("\(replay.commandCount) commands" + (replay.failedCommands > 0 ? ", \(replay.failedCommands) failed" : "")).monospacedDigit()
                    }
                }
                .font(NFont.small)
                .foregroundStyle(N.text2)
            }
            Spacer()
            if replay?.events.isEmpty == false {
                TextField("Filter steps", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button {
                    if !playing, selected == visible(replay!).last?.id { selected = nil }
                    playing.toggle()
                } label: {
                    Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Step through the session (Space)")
            }
            Button("Done", action: close).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    // MARK: Sidebar

    private func sidebar(_ replay: SessionReplay) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Filter.allCases) { f in
                    sideRow(f.rawValue, count: count(f, replay), selected: filter == f && file == nil) {
                        filter = f; file = nil
                    }
                }
                Text("Files changed").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(N.text2)
                    .padding(.top, 16).padding(.bottom, 4).padding(.horizontal, 8)
                if replay.files.isEmpty {
                    Text("No files changed").font(NFont.caption).foregroundStyle(N.text3).padding(.horizontal, 8)
                }
                ForEach(replay.files) { f in
                    Button { file = file == f.path ? nil : f.path } label: {
                        HStack(spacing: 6) {
                            Image(systemName: f.deleted ? "minus.square" : (f.created ? "plus.square" : "doc"))
                                .font(.system(size: 11)).foregroundStyle(f.deleted ? GH.closed : (f.created ? GH.open : N.text2))
                            VStack(alignment: .leading, spacing: 0) {
                                Text((f.path as NSString).lastPathComponent).font(NFont.small).foregroundStyle(N.text).lineLimit(1)
                                Text(relative(f.path)).font(.system(size: 10.5)).foregroundStyle(N.text3).lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 4)
                            HStack(spacing: 3) {
                                Text("+\(f.added)").foregroundStyle(GH.open)
                                Text("−\(f.removed)").foregroundStyle(GH.closed)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(file == f.path ? N.selected : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(f.path)
                    .contextMenu {
                        Button("Open in Editor") { ProcessManager.openInEditor(path: f.path) }
                        Button("Reveal in Finder") { RepoActions.reveal(f.path) }
                        Button("Copy Path") { RepoActions.copy(f.path) }
                    }
                }
            }
            .padding(10)
        }
        .background(N.bgSoft)
    }

    private func sideRow(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(NFont.small.weight(selected ? .semibold : .regular)).foregroundStyle(N.text)
                Spacer()
                Text("\(count)").font(NFont.caption).foregroundStyle(N.text3).monospacedDigit()
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(selected ? N.selected : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func count(_ f: Filter, _ replay: SessionReplay) -> Int {
        replay.events.filter { matches($0, f) }.count
    }

    private func relative(_ path: String) -> String {
        let root = session.checkout?.root ?? session.projectPath
        if !root.isEmpty, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: Timeline

    private func matches(_ event: ReplayEvent, _ f: Filter) -> Bool {
        switch (f, event.kind) {
        case (.all, _): return true
        case (.changes, .edit), (.changes, .delete): return true
        case (.commands, .command): return true
        case (.conversation, .prompt), (.conversation, .message): return true
        default: return false
        }
    }

    private func visible(_ replay: SessionReplay) -> [ReplayEvent] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return replay.events.filter { event in
            if let file { return event.path == file && event.isChange }
            guard matches(event, filter) else { return false }
            return q.isEmpty || Self.searchText(event).lowercased().contains(q)
        }
    }

    static func searchText(_ event: ReplayEvent) -> String {
        switch event.kind {
        case .prompt(let t), .message(let t), .search(let t): return t
        case .command(let c, let o, _): return c + "\n" + o
        case .edit(let p, let d, _): return p + "\n" + d
        case .delete(let p), .read(let p): return p
        case .tool(let n, let s): return n + " " + s
        case .compaction: return "compaction"
        }
    }

    private func step(_ delta: Int) {
        guard let replay else { return }
        let steps = visible(replay)
        let index = steps.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : steps.count)
        let next = min(max(index + delta, 0), steps.count - 1)
        if steps.indices.contains(next) { selected = steps[next].id }
    }

    private func timeline(_ replay: SessionReplay) -> some View {
        let steps = visible(replay)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, event in
                        ReplayStepRow(event: event, previous: index > 0 ? steps[index - 1].date : replay.start,
                                      relative: relative, selected: selected == event.id,
                                      expandedByDefault: file != nil || filter == .changes) {
                            selected = selected == event.id ? nil : event.id
                        }
                        .id(event.id)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 18)
            }
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// One step: a glyph on the timeline rail, a one-line summary, and the detail (diff, output, full message) when open.
struct ReplayStepRow: View {
    var event: ReplayEvent
    var previous: Date?
    var relative: (String) -> String
    var selected: Bool
    var expandedByDefault: Bool
    var toggle: () -> Void
    @State private var hover = false

    private var expanded: Bool { selected || (expandedByDefault && event.isChange) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(tint.opacity(0.14))
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                }
                .frame(width: 24, height: 24)
                Rectangle().fill(N.divider).frame(width: 1).frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    summary
                    Spacer(minLength: 8)
                    if case .edit = event.kind {
                        let c = event.lineCounts
                        HStack(spacing: 4) {
                            Text("+\(c.added)").foregroundStyle(GH.open)
                            Text("−\(c.removed)").foregroundStyle(GH.closed)
                        }
                        .font(NFont.monoSmall)
                    }
                    if let date = event.date {
                        Text(gap(date)).font(NFont.caption).foregroundStyle(N.text3).monospacedDigit()
                            .help(date.formatted(date: .abbreviated, time: .standard))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                if expanded { detail.transition(.opacity) }
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .background(selected ? N.selected.opacity(0.6) : (hover ? N.hover : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hover = $0 }
        .contextMenu {
            if let path = event.path {
                Button("Open in Editor") { ProcessManager.openInEditor(path: path) }
                Button("Copy Path") { RepoActions.copy(path) }
            }
            if case .command(let cmd, _, _) = event.kind { Button("Copy Command") { RepoActions.copy(cmd) } }
            if case .prompt(let t) = event.kind { Button("Copy Prompt") { RepoActions.copy(t) } }
            if case .message(let t) = event.kind { Button("Copy Message") { RepoActions.copy(t) } }
        }
    }

    /// Time since the step before: "+12s", "+3m".
    private func gap(_ date: Date) -> String {
        guard let previous else { return date.formatted(date: .omitted, time: .shortened) }
        let s = Int(date.timeIntervalSince(previous))
        if s < 1 { return date.formatted(date: .omitted, time: .shortened) }
        if s < 60 { return "+\(s)s" }
        if s < 3600 { return "+\(s / 60)m" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var symbol: String {
        switch event.kind {
        case .prompt: return "person.fill"
        case .message: return "text.bubble.fill"
        case .command(_, _, let failed): return failed ? "xmark" : "terminal"
        case .edit(_, _, let created): return created ? "plus" : "pencil"
        case .delete: return "trash"
        case .read: return "doc.text"
        case .search: return "magnifyingglass"
        case .tool: return "wrench.and.screwdriver"
        case .compaction: return "rectangle.compress.vertical"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .prompt: return N.blue
        case .message: return TagColor.purple.fg
        case .command(_, _, let failed): return failed ? GH.closed : N.text2
        case .edit: return GH.open
        case .delete: return GH.closed
        case .read, .search, .tool, .compaction: return N.text3
        }
    }

    @ViewBuilder private var summary: some View {
        switch event.kind {
        case .prompt(let t):
            Text(t.split(separator: "\n").first.map(String.init) ?? t).font(NFont.bodyMedium).foregroundStyle(N.text).lineLimit(expanded ? 3 : 1)
        case .message(let t):
            Text(t.split(separator: "\n").first.map(String.init) ?? t).font(NFont.body).foregroundStyle(N.text).lineLimit(expanded ? 3 : 1)
        case .command(let cmd, _, let failed):
            HStack(spacing: 6) {
                Text(cmd.split(separator: "\n").first.map(String.init) ?? cmd).font(NFont.mono).foregroundStyle(N.text).lineLimit(1)
                if failed { Tag(text: "Failed", color: .red) }
            }
        case .edit(let path, _, let created):
            HStack(spacing: 6) {
                Text(created ? "Created" : "Edited").font(NFont.body).foregroundStyle(N.text2)
                Text(relative(path)).font(NFont.mono).foregroundStyle(N.text).lineLimit(1).truncationMode(.head)
            }
        case .delete(let path):
            HStack(spacing: 6) {
                Text("Deleted").font(NFont.body).foregroundStyle(N.text2)
                Text(relative(path)).font(NFont.mono).foregroundStyle(N.text).lineLimit(1).truncationMode(.head)
            }
        case .read(let path):
            Text("Read \(relative(path))").font(NFont.small).foregroundStyle(N.text2).lineLimit(1).truncationMode(.head)
        case .search(let q):
            Text("Searched “\(q)”").font(NFont.small).foregroundStyle(N.text2).lineLimit(1)
        case .tool(let name, let s):
            Text(s.isEmpty ? name : "\(name) · \(s)").font(NFont.small).foregroundStyle(N.text2).lineLimit(1)
        case .compaction:
            Text("Context compacted").font(NFont.small).foregroundStyle(N.text3)
        }
    }

    @ViewBuilder private var detail: some View {
        switch event.kind {
        case .prompt(let t), .message(let t):
            Text(t).font(NFont.body).foregroundStyle(N.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .command(let cmd, let output, let failed):
            VStack(alignment: .leading, spacing: 0) {
                Text("$ " + cmd).font(NFont.monoSmall).foregroundStyle(.white.opacity(0.92)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !output.isEmpty {
                    Text(output).font(NFont.monoSmall).foregroundStyle(failed ? Color(red: 1, green: 0.55, blue: 0.5) : .white.opacity(0.65))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                } else {
                    Text("No output").font(NFont.monoSmall).foregroundStyle(.white.opacity(0.35)).padding(.top, 6)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .edit(_, let diff, _):
            let numbered = !diff.contains(ReplayDiff.replacedHeader)
            let lines = GHDiffLine.parse(diff).map { line -> GHDiffLine in
                guard !numbered else { return line }
                var l = line; l.old = nil; l.new = nil; return l
            }
            GHBox {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.prefix(500)) { GHDiffLineRow(line: $0) }
                        if lines.count > 500 {
                            Text("\(lines.count - 500) more lines").font(NFont.caption).foregroundStyle(N.text2).padding(8)
                        }
                    }
                    .frame(minWidth: 600, alignment: .leading)
                }
            }
        default:
            EmptyView()
        }
    }
}
