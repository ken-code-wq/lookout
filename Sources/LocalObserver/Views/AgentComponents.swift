import SwiftUI
import AppKit
import LocalObserverCore

// MARK: - Agent identity

extension AgentKind {
    /// Series colour, drawn from the shared tag palette so no agent gets a one-off colour.
    var tag: TagColor {
        switch self {
        case .claude: return .orange
        case .codex: return .green
        case .openCode: return .gray
        case .antigravity: return .blue
        case .copilot: return .purple
        case .cursor: return .brown
        case .pi: return .pink
        case .qoder: return .yellow
        }
    }

    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .copilot: return "Copilot"
        default: return name
        }
    }
}

/// The agent's official mark. Monochrome marks are template images tinted to the text colour, so they
/// read in light and dark mode; Claude and Antigravity keep their brand colour.
struct AgentIconView: View {
    var agent: AgentKind
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = AgentIcons.image(for: agent) {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(N.text)
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.6, weight: .medium))
                    .foregroundStyle(N.text2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.name)
    }
}

enum AgentIcons {
    private static var cache: [AgentKind: NSImage] = [:]

    static func image(for agent: AgentKind) -> NSImage? {
        if let hit = cache[agent] { return hit }
        guard let image = AgentIconStore.image(for: agent) else { return nil }
        cache[agent] = image
        return image
    }
}

// MARK: - State

extension AgentActivityState {
    var tag: TagColor {
        switch self {
        case .needsInput: return .orange
        case .failed: return .red
        case .running, .working, .thinking, .toolUse: return .green
        case .waiting: return .blue
        case .idle, .unknown: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .needsInput: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .running, .working, .thinking, .toolUse: return "circle.fill"
        case .waiting: return "arrowshape.turn.up.left.fill"
        case .idle, .unknown: return "moon.fill"
        }
    }
}

/// Status pill in the same shape as the server `StatusTag`: dot or glyph plus a word, never colour alone.
struct AgentStateTag: View {
    var state: AgentActivityState

    var body: some View {
        let color = state.tag
        HStack(spacing: 5) {
            if case .working = state {
                PulsingDot(color: color.fg)
            } else if state == .running {
                PulsingDot(color: color.fg)
            } else {
                Image(systemName: state.symbol).font(.system(size: 8, weight: .bold))
            }
            Text(state.title).font(.system(size: 12))
        }
        .foregroundStyle(color.fg)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(color.bg, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .fixedSize()
    }
}

/// A live-activity dot. Holds still when Reduce Motion is on.
struct PulsingDot: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1 : (on ? 0.35 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

// MARK: - Limit meter

/// How far a window is from an even burn, in words you can act on: how much you're over or under,
/// what that means in time, and the rate that would last until the reset.
struct PaceDeviation {
    enum Kind { case ahead, under, onPace, exhausted, unknown }

    var kind: Kind
    /// Used minus elapsed, in percentage points. Positive means ahead of an even pace.
    var points: Double
    /// Ahead: how much sooner than an even pace you reached this usage.
    var early: TimeInterval?
    /// Share of the window you can still use per hour (or per day for long windows) and last until the reset.
    var sustainableRate: (value: Double, perDay: Bool)?
    var resetIn: TimeInterval?
    private var usedPercent: Double
    private var elapsedPercent: Double?

    /// Within this many points of the even line counts as on pace.
    static let tolerance = 3.0

    init(window: AgentQuotaWindow, now: Date = .now) {
        usedPercent = window.usedPercent
        resetIn = window.resetsAt.map { max(0, $0.timeIntervalSince(now)) }
        let elapsed = window.elapsedFraction(now: now)
        elapsedPercent = elapsed.map { $0 * 100 }
        points = elapsed.map { window.usedPercent - $0 * 100 } ?? 0
        if window.usedPercent >= 100 {
            kind = .exhausted
        } else if elapsed == nil {
            kind = .unknown
        } else if points > Self.tolerance {
            kind = .ahead
        } else if points < -Self.tolerance {
            kind = .under
        } else {
            kind = .onPace
        }
        if kind == .ahead, let duration = window.windowDuration { early = points / 100 * duration }
        if let remaining = resetIn, remaining > 60, window.usedPercent < 100 {
            let perDay = (window.windowDuration ?? 0) > 2 * 86_400
            let units = remaining / (perDay ? 86_400 : 3_600)
            sustainableRate = ((100 - window.usedPercent) / max(units, 0.01), perDay)
        }
    }

    /// Short chip: "+12%", "−18%", "On pace", "Used up".
    var chip: String {
        switch kind {
        case .ahead: return "+\(Int(points.rounded()))%"
        case .under: return "−\(Int((-points).rounded()))%"
        case .onPace: return "On pace"
        case .exhausted: return "Used up"
        case .unknown: return "\(Int(usedPercent.rounded()))%"
        }
    }

    /// One short line under the chip: "36m early", "18% spare", "Back in 1h 2m".
    var caption: String {
        switch kind {
        case .ahead: return early.map { "\(AgentFormat.duration($0)) early" } ?? "ahead of pace"
        case .under: return "\(Int((-points).rounded()))% spare"
        case .onPace: return resetIn.map { "resets in \(AgentFormat.duration($0))" } ?? "on track"
        case .exhausted: return resetIn.map { "back in \(AgentFormat.duration($0))" } ?? "waiting for reset"
        case .unknown: return resetIn.map { "resets in \(AgentFormat.duration($0))" } ?? ""
        }
    }

    var rateText: String? {
        sustainableRate.map { rate in
            let value = rate.value >= 10 ? String(Int(rate.value.rounded())) : String(format: "%.1f", rate.value)
            return "\(value)%/\(rate.perDay ? "day" : "h")"
        }
    }

    /// The full explanation, for tooltips.
    var advice: String {
        let reset = resetIn.map { " until it resets in \(AgentFormat.duration($0))" } ?? " until the reset"
        let context = elapsedPercent.map { "You've used \(Int(usedPercent.rounded()))% with \(Int($0.rounded()))% of the window gone." } ?? ""
        switch kind {
        case .ahead:
            let time = early.map { ", about \(AgentFormat.duration($0)) early" } ?? ""
            let rate = rateText.map { " Keep under \($0) to last\(reset)." } ?? ""
            return "\(context) That's \(Int(points.rounded())) points over an even pace\(time).\(rate)"
        case .under:
            let rate = rateText.map { " You can use up to \($0) and still last\(reset)." } ?? ""
            return "\(context) That's \(Int((-points).rounded())) points under an even pace.\(rate)"
        case .onPace:
            return "\(context) Right on an even pace\(rateText.map { ", about \($0)" } ?? "")."
        case .exhausted:
            return "Used up. It comes back\(resetIn.map { " in \(AgentFormat.duration($0))" } ?? " at the reset")."
        case .unknown:
            return "No window length reported, so pace can't be judged."
        }
    }
}


/// Horizontal usage bar with a pace tick at the share of the window that has elapsed.
struct LimitMeter: View {
    var window: AgentQuotaWindow
    var height: CGFloat = 8
    var showsPace = true

    var body: some View {
        let used = min(max(window.usedPercent / 100, 0), 1)
        let pace = LimitPace(window: window)
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(N.divider)
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(Self.fill(for: window.usedPercent))
                    .frame(width: max(used > 0 ? height : 0, width * used))
                if showsPace, let elapsed = pace.elapsed {
                    Capsule()
                        .fill(N.text)
                        .frame(width: 2, height: height + 6)
                        .offset(x: min(max(width * elapsed - 1, 0), width - 2))
                        .help("\(Int((elapsed * 100).rounded()))% of this window has elapsed")
                }
            }
            .frame(height: height + 6)
        }
        .frame(height: height + 6)
        .animation(.easeOut(duration: 0.25), value: window.usedPercent)
        .accessibilityElement()
        .accessibilityLabel(window.label)
        .accessibilityValue("\(Int(window.usedPercent.rounded())) percent used. \(pace.sentence)")
    }

    static func fill(for percent: Double) -> Color {
        if percent >= 90 { return TagColor.red.fg }
        if percent >= 70 { return TagColor.orange.fg }
        return N.blue
    }
}

// MARK: - Database-style filter bar

/// Tab in a Notion database header: icon + title with an underline when active.
struct HeaderTab: View {
    var title: String
    var symbol: String
    var active: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 11.5))
                    Text(title).font(.system(size: 13, weight: active ? .medium : .regular))
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
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Notion filter pill: grey when showing everything, blue once it narrows the view.
struct FilterChip<Content: View>: View {
    var title: String
    var symbol: String
    var active: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .medium))
                Text(title).font(NFont.small).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.7)
            }
            .foregroundStyle(active ? N.blue : N.text2)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(active ? N.selected : N.hover.opacity(0.0001),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? N.blue.opacity(0.35) : N.divider)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Section title used inside agent pages: medium weight, optional count, trailing accessory.
struct SectionTitle<Accessory: View>: View {
    var title: String
    var count: Int?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(N.text)
            if let count {
                Text("\(count)").font(NFont.small).foregroundStyle(N.text3).monospacedDigit()
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.bottom, 8)
    }
}

extension SectionTitle where Accessory == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Inline, non-blocking notice: icon, sentence, optional action. For partial data and first-run prompts.
struct InlineNotice<Actions: View>: View {
    var symbol: String
    var title: String
    var message: String
    var tone: TagColor = .gray
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tone == .gray ? N.text2 : tone.fg)
                .frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NFont.bodyMedium).foregroundStyle(N.text)
                Text(message).font(NFont.small).foregroundStyle(N.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tone == .gray ? N.bgSoft : tone.bg, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
    }
}


extension LimitPace {
    var tone: TagColor {
        switch verdict {
        case .exhausted: return .red
        case .ahead: return .orange
        default: return .gray
        }
    }
}

// MARK: - Actions

/// Small icon of the terminal or editor a session runs in, so rows show where a click will take you.
struct HostAppIcon: View {
    var session: AgentSession
    var size: CGFloat = 16

    var body: some View {
        if let icon = AgentActions.hostIcon(for: session) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .help(session.process?.host.map { "Runs in \($0.name)" } ?? "")
        }
    }
}

enum AgentActions {
    static func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openSource(_ path: String) {
        guard !path.isEmpty else { return }
        if let url = URL(string: path), url.scheme != nil, url.scheme != "file" {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    /// Brings the terminal, editor, or app that hosts the session to the front.
    /// For Terminal and iTerm it also selects the exact tab by TTY when macOS allows automation.
    @discardableResult
    static func jump(to session: AgentSession) -> Bool {
        guard let process = session.process, let host = process.host else { return false }
        let bundleURL = URL(fileURLWithPath: host.bundlePath)
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == bundleURL.standardizedFileURL
        } ?? NSRunningApplication(processIdentifier: host.pid)
        if let app = running, !process.terminal.isEmpty, process.terminal != "??" {
            selectTab(tty: "/dev/\(process.terminal)", bundleID: app.bundleIdentifier)
        }
        // macOS 14+ ignores activate() from an app that isn't frontmost (the notch and menu bar never are),
        // so hand activation over explicitly, then open the bundle, which always brings it forward.
        if let app = running { NSApp.yieldActivation(to: app) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
            return true
        }
        return running?.activate() ?? false
    }

    /// The Dock icon of the app hosting a session, cached by bundle path.
    static func hostIcon(for session: AgentSession) -> NSImage? {
        guard let path = session.process?.host?.bundlePath, !path.isEmpty else { return nil }
        if let cached = hostIcons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        hostIcons[path] = icon
        return icon
    }

    private nonisolated(unsafe) static var hostIcons: [String: NSImage] = [:]

    private static func selectTab(tty: String, bundleID: String?) {
        let script: String
        switch bundleID {
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                        end if
                    end repeat
                end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select t
                                select s
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }
}
