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

/// How a window's usage compares with an even burn across the window.
struct LimitPace {
    enum Verdict { case unknown, comfortable, onPace, ahead, exhausted }

    var verdict: Verdict
    var elapsed: Double?
    /// When the window runs out at the current rate, if that happens before the reset.
    var runsOutAt: Date?

    init(window: AgentQuotaWindow, now: Date = .now) {
        elapsed = window.elapsedFraction(now: now)
        runsOutAt = nil
        let used = window.usedPercent / 100
        if used >= 1 {
            verdict = .exhausted
            return
        }
        guard let elapsed, elapsed > 0.02, let reset = window.resetsAt else {
            verdict = .unknown
            return
        }
        let elapsedSeconds = elapsed * (window.windowDuration ?? 0)
        if used > 0, elapsedSeconds > 0 {
            let rate = used / elapsedSeconds
            let outAt = now.addingTimeInterval((1 - used) / rate)
            if outAt < reset { runsOutAt = outAt }
        }
        if runsOutAt != nil {
            verdict = .ahead
        } else if used > elapsed - 0.05 {
            verdict = .onPace
        } else {
            verdict = .comfortable
        }
    }

    var sentence: String {
        switch verdict {
        case .unknown: return ""
        case .exhausted: return "Limit reached"
        case .comfortable: return "Under pace"
        case .onPace: return "On pace"
        case .ahead:
            guard let runsOutAt else { return "Ahead of pace" }
            return "At this rate, runs out \(AgentFormat.relative(runsOutAt))"
        }
    }

    var tone: TagColor {
        switch verdict {
        case .exhausted: return .red
        case .ahead: return .orange
        default: return .gray
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

// MARK: - Formatting

enum AgentFormat {
    static let unavailable = "Unavailable"

    static func tokens(_ value: Int64?) -> String {
        guard let value else { return unavailable }
        return compact(Double(value))
    }

    static func compact(_ value: Double) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000_000 { return trim(value / 1_000_000_000, "B") }
        if absolute >= 1_000_000 { return trim(value / 1_000_000, "M") }
        if absolute >= 1_000 { return trim(value / 1_000, "K") }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    /// 1.62B, 26K, 4.72M: two decimals below 10, one below 100, none above.
    private static func trim(_ value: Double, _ suffix: String) -> String {
        let digits = abs(value) < 10 ? 2 : (abs(value) < 100 ? 1 : 0)
        return value.formatted(.number.precision(.fractionLength(0...digits))) + suffix
    }

    static func cost(_ value: Double?, estimated: Bool = false) -> String {
        guard let value else { return unavailable }
        let text: String
        if value == 0 { text = "$0.00" }
        else if value < 0.01 { text = "<$0.01" }
        else { text = value.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
        return estimated ? "≈\(text)" : text
    }

    static func metric(_ value: Double, _ metric: AgentMetricKind) -> String {
        switch metric {
        case .tokens: return compact(value)
        case .cost: return cost(value)
        case .requests: return compact(value)
        }
    }

    static func percent(_ fraction: Double, digits: Int = 1) -> String {
        (fraction).formatted(.percent.precision(.fractionLength(0...digits)))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60)m" }
        if s < 86_400 { return s % 3_600 >= 60 ? "\(s / 3_600)h \((s % 3_600) / 60)m" : "\(s / 3_600)h" }
        let days = s / 86_400
        let hours = (s % 86_400) / 3_600
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }

    /// "in 2h 14m", "tomorrow at 09:00", "Thu at 09:00".
    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        if seconds < 12 * 3_600 { return "in \(duration(seconds))" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        if seconds < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) at \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func resetText(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Reset time unavailable" }
        if date <= now { return "Resetting now" }
        return "Resets \(relative(date, now: now))"
    }

    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < 10 { return "just now" }
        return "\(duration(s)) ago"
    }
}

// MARK: - Actions

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
        guard let app = running else { return false }
        if !process.terminal.isEmpty, process.terminal != "??" {
            selectTab(tty: "/dev/\(process.terminal)", bundleID: app.bundleIdentifier)
        }
        return app.activate(options: [.activateAllWindows])
    }

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
