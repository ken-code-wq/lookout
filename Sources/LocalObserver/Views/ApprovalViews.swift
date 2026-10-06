import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverHooks

// MARK: - Preview

/// What a tool call will do: the command, or the file and a short diff. Changed lines keep their +/− so the
/// difference doesn't rest on color alone.
struct ApprovalPreviewView: View {
    var preview: HookToolPreview
    /// The notch is always dark; Peek and the menu bar follow the system.
    var onNotch: Bool
    var maxLines = 6
    /// The session's folder: file paths inside it are shown relative to it.
    var root = ""

    private var text: Color { onNotch ? NotchColor.text : .primary }
    private var text2: Color { onNotch ? NotchColor.text2 : .secondary }
    private var box: Color { onNotch ? Color.white.opacity(0.06) : Color.primary.opacity(0.05) }
    private var added: Color { onNotch ? NotchColor.green : N.green }
    private var removed: Color { onNotch ? NotchColor.red : N.red }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !preview.detail.isEmpty {
                Text(preview.detail).font(.system(size: 11)).foregroundStyle(text2).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 1) {
                switch preview.body {
                case .command(let command):
                    lines(command.components(separatedBy: "\n").map { ("$", $0) }, firstPrefixOnly: true)
                case .edit(let path, let old, let new):
                    pathLine(path)
                    diff(ReplayDiff.replace(old, new))
                case .write(let path, let content):
                    pathLine(path)
                    diff(ReplayDiff.created(content))
                case .text(let body):
                    Text(body.isEmpty ? preview.subject : body)
                        .font(.system(size: 11.5)).foregroundStyle(text).lineLimit(maxLines)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(box, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .textSelection(.enabled)
    }

    private func pathLine(_ path: String) -> some View {
        let shown = !root.isEmpty && path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : (path as NSString).abbreviatingWithTildeInPath
        return Text(shown)
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(text2)
            .lineLimit(1).truncationMode(.head)
            .padding(.bottom, 2)
    }

    private func diff(_ diff: String) -> some View {
        let rows = diff.components(separatedBy: "\n").filter { !$0.hasPrefix("@@") }.map { line -> (String, String) in
            (line.first.map(String.init) ?? " ", String(line.dropFirst()))
        }
        let counts = ReplayDiff.counts(diff)
        return VStack(alignment: .leading, spacing: 1) {
            lines(rows, firstPrefixOnly: false)
            Text("+\(counts.added) −\(counts.removed)")
                .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(text2)
                .padding(.top, 2)
        }
    }

    private func lines(_ rows: [(String, String)], firstPrefixOnly: Bool) -> some View {
        let shown = rows.prefix(maxLines)
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(firstPrefixOnly && index > 0 ? " " : row.0)
                        .foregroundStyle(row.0 == "+" ? added : row.0 == "-" ? removed : text2)
                        .frame(width: 8, alignment: .leading)
                    Text(row.1.isEmpty ? " " : row.1)
                        .foregroundStyle(row.0 == "+" ? added : row.0 == "-" ? removed : text)
                        .lineLimit(firstPrefixOnly ? 2 : 1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            if rows.count > shown.count {
                Text("… \(rows.count - shown.count) more line\(rows.count - shown.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5)).foregroundStyle(text2)
            }
        }
    }
}

// MARK: - Notch

/// The open notch while a permission request waits: who's asking, what it will do, and the answers.
struct NotchApprovalPage: View {
    @ObservedObject var center: ApprovalCenter
    @FocusState private var focused: Bool

    static let height: CGFloat = 248

    var body: some View {
        NotchCard {
            if let request = center.current() {
                content(request)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle")
                    Text("Nothing is waiting on you")
                }
                .font(.system(size: 12)).foregroundStyle(NotchColor.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return) { answer(.allow) }
        .onKeyPress(.escape) { answer(.deny) }
        .onKeyPress(.leftArrow) { center.step(by: -1); return .handled }
        .onKeyPress(.rightArrow) { center.step(by: 1); return .handled }
        .onAppear { focused = center.keyboardArmed }
        .onChange(of: center.keyboardArmed) { _, armed in focused = armed }
    }

    private func answer(_ decision: HookDecision) -> KeyPress.Result {
        guard center.keyboardArmed, let request = center.current() else { return .ignored }
        center.decide(request.id, decision)
        return .handled
    }

    @ViewBuilder private func content(_ request: ApprovalRequest) -> some View {
        let session = center.session(for: request)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                AgentIconView(agent: request.agent, size: 17)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(request.agent.shortName) wants to \(request.event.preview?.title.lowercasedFirst ?? "use \(request.event.toolName)")")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(NotchColor.text).lineLimit(1)
                    Text(([request.projectName, session?.title ?? "", session?.process?.host?.name ?? ""]).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(NotchColor.text2).lineLimit(1)
                }
                Spacer(minLength: 6)
                if center.pending.count > 1 { stepper(request) }
                ApprovalCountdown(deadline: request.deadline, onNotch: true)
            }
            if let preview = request.event.preview {
                ApprovalPreviewView(preview: preview, onNotch: true, maxLines: 5, root: request.event.cwd)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button { center.release(request.id, jump: true) } label: {
                    Label("Answer in terminal", systemImage: "terminal")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(NotchColor.text2)
                }
                .buttonStyle(.plain)
                .help("Stop waiting here; \(request.agent.shortName) asks in its own terminal")
                Spacer(minLength: 6)
                NotchAnswerButton(title: "Deny", key: center.keyboardArmed ? "⎋" : nil, style: .deny) { center.decide(request.id, .deny) }
                NotchAnswerButton(title: "Always allow", key: nil, style: .secondary) { center.decide(request.id, .alwaysAllow) }
                    .help(request.alwaysAllow.summary)
                NotchAnswerButton(title: "Allow", key: center.keyboardArmed ? "⏎" : nil, style: .primary) { center.decide(request.id, .allow) }
            }
        }
    }

    private func stepper(_ request: ApprovalRequest) -> some View {
        let index = (center.pending.firstIndex { $0.id == request.id } ?? 0) + 1
        return HStack(spacing: 2) {
            Button { center.step(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 16, height: 18) }
                .buttonStyle(.plain).help("Previous request")
            Text("\(index) of \(center.pending.count)").monospacedDigit()
            Button { center.step(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 16, height: 18) }
                .buttonStyle(.plain).help("Next request")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(NotchColor.text2)
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

/// "0:32" until the agent stops waiting and asks in its terminal.
private struct ApprovalCountdown: View {
    var deadline: Date
    var onNotch: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded()))
            Text(String(format: "%d:%02d", left / 60, left % 60))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(onNotch ? NotchColor.text3 : Color.secondary)
                .help("If you don't answer by then, the agent asks in its own terminal")
        }
    }
}

private struct NotchAnswerButton: View {
    enum Style { case primary, secondary, deny }
    var title: String
    var key: String?
    var style: Style
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let key { Text(key).opacity(0.6) }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(style == .primary ? Color.black : style == .deny ? NotchColor.red : NotchColor.text)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var background: Color {
        switch style {
        case .primary: return Color.white.opacity(hover ? 1 : 0.9)
        case .secondary, .deny: return Color.white.opacity(hover ? 0.18 : 0.1)
        }
    }
}

/// Pill in the open notch's header while requests wait; opens the approval page.
struct NotchApprovalPill: View {
    @ObservedObject var center: ApprovalCenter

    var body: some View {
        if !center.pending.isEmpty && center.notchPage != .approvals {
            Button { center.show(center.pending[0].id) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 9.5, weight: .bold))
                    Text("\(center.pending.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(NotchColor.pink)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(NotchColor.pink.opacity(0.16), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("\(center.pending.count) agent request\(center.pending.count == 1 ? "" : "s") waiting on your permission")
            .accessibilityLabel("\(center.pending.count) agent requests waiting")
        }
    }
}

/// Reply button on a "Your turn" row in the notch. Disabled, with the reason as its tooltip, when there's no way to
/// deliver a reply to the session.
struct NotchReplyButton: View {
    @ObservedObject var center: ApprovalCenter = .shared
    var session: AgentSession
    @State private var hover = false

    var body: some View {
        let route = center.replyRoute(for: session)
        Button { center.openReply(sessionID: session.id) } label: {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(route.canSend ? (hover ? NotchColor.text : NotchColor.text2) : NotchColor.text3)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(hover ? 0.16 : 0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(!route.canSend)
        .help(route.reason ?? "Reply to \(session.agent.shortName)")
    }
}

/// Quick reply at "Your turn": what the agent last said, and a line to send back to the session.
struct NotchReplyPage: View {
    @ObservedObject var center: ApprovalCenter
    @ObservedObject var agentStore: AgentStore
    var sessionID: String
    @State private var text = ""
    @FocusState private var focused: Bool

    static let height: CGFloat = 176

    var body: some View {
        NotchCard {
            if let session = agentStore.runningSessions.first(where: { $0.id == sessionID }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        AgentIconView(agent: session.agent, size: 17)
                            .frame(width: 26, height: 26)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Reply to \(session.agent.shortName)").font(.system(size: 13, weight: .semibold)).foregroundStyle(NotchColor.text)
                            Text([session.projectName, session.title, session.process?.host?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(NotchColor.text2).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        HostAppIcon(session: session, size: 16)
                    }
                    if let last = center.lastMessages[session.id], !last.isEmpty {
                        Text(last)
                            .font(.system(size: 11.5)).foregroundStyle(NotchColor.text2)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    let route = center.replyRoute(for: session)
                    HStack(spacing: 8) {
                        TextField("Type a reply and press Return", text: $text)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(NotchColor.text)
                            .focused($focused)
                            .onSubmit { send(session) }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        NotchAnswerButton(title: "Send", key: nil, style: .primary) { send(session) }
                            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || !route.canSend)
                    }
                    .disabled(!route.canSend)
                    Text(center.replyStatus ?? hint(session, route))
                        .font(.system(size: 10.5)).foregroundStyle(NotchColor.text3).lineLimit(1)
                }
            } else {
                Text("This session has ended").font(.system(size: 12)).foregroundStyle(NotchColor.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { focused = true }
    }

    private func send(_ session: AgentSession) {
        guard center.replyRoute(for: session).canSend else { return }
        center.sendReply(text, to: session)
        text = ""
    }

    private func hint(_ session: AgentSession, _ route: ReplyRoute) -> String {
        switch route {
        case .hook: return "Goes straight to Claude in this session, wherever it runs"
        case .terminal: return "Typed straight into its \(session.process?.host?.name ?? "terminal") tab"
        case .unavailable(let reason): return reason
        }
    }
}

// MARK: - Peek and menu bar

/// Waiting permission requests, for Peek and the menu bar panel, in the system's colors.
struct ApprovalListSection: View {
    @ObservedObject var center: ApprovalCenter = .shared
    /// Peek at Small: one line per request.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.pink)
                Text("Waiting on you").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(center.pending.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 6)
            ForEach(center.pending.prefix(compact ? 2 : 3)) { request in
                ApprovalRow(center: center, request: request, compact: compact)
            }
            if center.pending.count > (compact ? 2 : 3) {
                Text("+\(center.pending.count - (compact ? 2 : 3)) more").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 6)
            }
        }
    }
}

private struct ApprovalRow: View {
    @ObservedObject var center: ApprovalCenter
    var request: ApprovalRequest
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentIconView(agent: request.agent, size: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(request.event.preview?.title ?? request.event.toolName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(request.projectName).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                ApprovalCountdown(deadline: request.deadline, onNotch: false)
            }
            if !compact, let preview = request.event.preview {
                ApprovalPreviewView(preview: preview, onNotch: false, maxLines: 3, root: request.event.cwd)
            }
            HStack(spacing: 6) {
                Menu {
                    Button("Always allow") { center.decide(request.id, .alwaysAllow) }
                    Text(request.alwaysAllow.summary)
                    Divider()
                    Button("Answer in terminal") { center.release(request.id, jump: true) }
                    if NotchController.shared.isAvailable {
                        Button("Show in the notch") { center.show(request.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More answers")
                Spacer(minLength: 4)
                Button("Deny") { center.decide(request.id, .deny) }
                    .controlSize(.small)
                Button("Allow") { center.decide(request.id, .allow) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Palette

enum ApprovalPalette {
    /// ⌘K actions: answer what's waiting, reply to sessions whose turn it is.
    @MainActor
    static func items(agentStore: AgentStore) -> [PaletteItem] {
        let center = ApprovalCenter.shared
        var items: [PaletteItem] = []
        if let first = center.pending.first {
            items.append(PaletteItem(id: "a:approvals", group: .actions,
                                     title: center.pending.count == 1 ? "Answer \(first.agent.shortName)'s request" : "Answer \(center.pending.count) agent requests",
                                     subtitle: [first.event.preview?.title ?? first.event.toolName, first.projectName].joined(separator: " · "),
                                     symbol: "hand.raised", keywords: "approve allow deny permission") { center.openOldest() })
        }
        let yourTurn = agentStore.runningSessions.filter { AgentActivityBucket($0) == .yourTurn && $0.process != nil }
        items += yourTurn.prefix(6).map { session in
            let route = center.replyRoute(for: session)
            // No way to deliver: say why, and go to the session instead.
            let subtitle = [session.projectName, route.reason ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            return PaletteItem(id: "reply:\(session.id)", group: .actions, title: "Reply to \(session.agent.shortName): \(session.title)",
                               subtitle: subtitle, symbol: "arrowshape.turn.up.left", keywords: "reply answer message your turn") {
                if route.canSend, NotchController.shared.isAvailable {
                    center.openReply(sessionID: session.id)
                } else {
                    AgentActions.jump(to: session)
                }
            }
        }
        return items
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
