import SwiftUI
import LocalObserverCore

extension AgentKind {
    /// Provider colour on dark surfaces (the notch, the Dock ring). Codex is ChatGPT white.
    var brandColor: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(white: 0.93)
        case .openCode: return Color(red: 0.62, green: 0.64, blue: 0.69)
        case .antigravity: return Color(red: 0.31, green: 0.55, blue: 1)
        case .copilot: return Color(red: 0.64, green: 0.44, blue: 0.97)
        case .cursor: return Color(red: 0.37, green: 0.78, blue: 0.78)
        case .pi: return Color(red: 0.49, green: 0.9, blue: 0.53)
        case .qoder: return Color(red: 0.88, green: 0.67, blue: 0.31)
        }
    }
}

/// Outline ring split into one arc per provider. Each arc owns an equal share of the circle and is filled
/// in proportion to that provider's usage, so three providers at 50/20/90% read as three partly-lit thirds.
struct ProviderRing: View {
    struct Segment: Identifiable {
        var id: String
        var color: Color
        var fraction: Double
        /// Where usage "should" be if spread evenly across the window (0...1). Drawn as a tick across the arc.
        var pace: Double? = nil
    }

    var segments: [Segment]
    var lineWidth: CGFloat = 2.5

    var body: some View {
        GeometryReader { proxy in
            rings
                .overlay { paceTicks(radius: min(proxy.size.width, proxy.size.height) / 2) }
        }
    }

    /// A short bar across the arc at each segment's pace point.
    private func paceTicks(radius: CGFloat) -> some View {
        let count = max(segments.count, 1)
        let gap = count > 1 ? 0.035 + Double(lineWidth) / 400 : 0
        return ZStack {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if let pace = segment.pace {
                    let start = Double(index) / Double(count) + gap / 2
                    let end = Double(index + 1) / Double(count) - gap / 2
                    let position = start + (end - start) * min(max(pace, 0), 1)
                    // Sized to the ring: a small ring gets a short hairline, a big one a clear notch.
                    // Centred on the stroke's centreline (the circle's radius), so it crosses the arc evenly.
                    let length = lineWidth + min(5, radius * 0.24)
                    let width = min(max(lineWidth * 0.4, 1), 1.6)
                    Capsule()
                        .fill(Color.white)
                        .overlay(Capsule().strokeBorder(Color.black.opacity(0.45), lineWidth: 0.5))
                        .frame(width: width, height: length)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(position * 360))
                }
            }
        }
    }

    private var rings: some View {
        let count = max(segments.count, 1)
        // Leave a gap between arcs so each provider reads as its own slice; round caps need a little extra.
        let gap = count > 1 ? 0.035 + Double(lineWidth) / 400 : 0
        return ZStack {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                let start = Double(index) / Double(count) + gap / 2
                let end = Double(index + 1) / Double(count) - gap / 2
                let filled = start + (end - start) * min(max(segment.fraction, 0), 1)
                Circle()
                    .trim(from: start, to: end)
                    .stroke(segment.color.opacity(0.22), style: StrokeStyle(lineWidth: lineWidth, lineCap: count > 1 ? .round : .butt))
                if segment.fraction > 0.005 {
                    Circle()
                        .trim(from: start, to: max(filled, start + 0.004))
                        .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }
        }
        .rotationEffect(.degrees(-90))
        .animation(.easeOut(duration: 0.4), value: segments.map(\.fraction))
    }
}

extension ProviderRing {
    init(windows: [AgentQuotaWindow], lineWidth: CGFloat = 2.5, showsPace: Bool = true) {
        self.init(segments: windows.map {
            Segment(id: $0.id, color: $0.agent.brandColor, fraction: $0.usedPercent / 100,
                    pace: showsPace ? LimitPace(window: $0).elapsed : nil)
        }, lineWidth: lineWidth)
    }
}

/// Limits page of the open notch: pick providers, then one column per provider with its headline window as a ring
/// and the remaining windows as slim pace lines.
struct NotchLimitsPage: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject private var prefs = Preferences.shared

    private var allWindows: [AgentQuotaWindow] { agentStore.limitReports.flatMap(\.windows) }

    /// Providers that actually report limits, in a stable order.
    private var available: [AgentKind] {
        AgentKind.allCases.filter { agent in allWindows.contains { $0.agent == agent } }
    }

    /// What the page shows: the chosen providers, or every provider when none are chosen.
    private var shown: [AgentKind] {
        let chosen = prefs.limitProviders.filter(available.contains)
        return chosen.isEmpty ? available : chosen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            providerPicker
            if available.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "gauge.with.dots.needle.0percent")
                    Text("No plan limits reported yet. Connect providers in Settings › Limits.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let layout = Self.layout(for: shown.count)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.columnSpacing, alignment: .top), count: layout.columns),
                          alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(shown) { agent in
                        ProviderLimitColumn(agent: agent, windows: allWindows.filter { $0.agent == agent },
                                            wide: shown.count == 1, maxOthers: layout.maxOthers)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: Layout (shared with the notch so it can size itself to fit, never clip)

    static let columnSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 16
    private static let pickerHeight: CGFloat = 22
    private static let ringBlock: CGFloat = 50
    private static let lineHeight: CGFloat = 27
    private static let lineSpacing: CGFloat = 10

    /// 1 provider: one wide column. 2–3: side by side. 4: a 2×2 grid. More: rows of three.
    static func layout(for count: Int) -> (columns: Int, maxOthers: Int) {
        switch count {
        case ...1: return (1, 6)
        case 2: return (2, 3)
        case 3: return (3, 2)
        case 4: return (2, 2)
        default: return (3, 1)
        }
    }

    /// Exact height of the page for the given data, so the open notch grows instead of cutting it off.
    static func height(agentStore: AgentStore, prefs: Preferences) -> CGFloat {
        let windows = agentStore.limitReports.flatMap(\.windows)
        let available = AgentKind.allCases.filter { agent in windows.contains { $0.agent == agent } }
        let chosen = prefs.limitProviders.filter(available.contains)
        let shown = chosen.isEmpty ? available : chosen
        guard !shown.isEmpty else { return pickerHeight + 12 + 80 }
        let layout = layout(for: shown.count)
        func columnHeight(_ agent: AgentKind) -> CGFloat {
            let own = windows.filter { $0.agent == agent }
            let others = min(max(own.count - 1, 0), layout.maxOthers)
            let rows = shown.count == 1 ? (others + 1) / 2 : others
            return ringBlock + (rows > 0 ? 12 + CGFloat(rows) * lineHeight + CGFloat(rows - 1) * lineSpacing : 0)
        }
        var total: CGFloat = 0
        var index = 0
        while index < shown.count {
            let row = shown[index..<min(index + layout.columns, shown.count)]
            total += row.map(columnHeight).max() ?? 0
            index += layout.columns
        }
        let gridRows = (shown.count + layout.columns - 1) / layout.columns
        return pickerHeight + 12 + total + CGFloat(max(gridRows - 1, 0)) * rowSpacing
    }

    private var providerPicker: some View {
        HStack(spacing: 6) {
            ForEach(available) { agent in
                let on = prefs.limitProviders.contains(agent)
                Button {
                    withAnimation(.snappy(duration: 0.25)) { prefs.toggleLimitProvider(agent) }
                } label: {
                    HStack(spacing: 5) {
                        AgentIconView(agent: agent, size: 12)
                        Text(agent.shortName)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(on ? .white : .white.opacity(0.5))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(on ? agent.brandColor.opacity(0.22) : .white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? agent.brandColor.opacity(0.55) : .clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(on ? "Remove \(agent.name) from the notch" : "Show \(agent.name) in the notch")
            }
            Spacer(minLength: 6)
            if !prefs.limitProviders.isEmpty {
                ProviderRing(windows: prefs.glanceWindows(from: allWindows), lineWidth: 2.5)
                    .frame(width: 16, height: 16)
                    .help("How the closed notch shows these providers")
            }
            Menu {
                Picker("Headline window", selection: $prefs.limitWindowChoice) {
                    ForEach(LimitWindowChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(prefs.limitWindowChoice.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Which window each provider's ring shows")
        }
    }
}

/// One provider: a ring for its headline window, then every other window as a slim line with a pace notch.
private struct ProviderLimitColumn: View {
    var agent: AgentKind
    var windows: [AgentQuotaWindow]
    var wide: Bool
    var maxOthers: Int
    @ObservedObject private var prefs = Preferences.shared

    private var headline: AgentQuotaWindow? { prefs.primaryWindow(for: agent, in: windows) }
    private var others: [AgentQuotaWindow] {
        windows.filter { $0.id != headline?.id }.sorted { $0.usedPercent > $1.usedPercent }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let headline {
                HStack(spacing: 12) {
                    ZStack {
                        ProviderRing(windows: [headline], lineWidth: 5)
                        Text("\(Int(headline.usedPercent.rounded()))")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        + Text("%").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            AgentIconView(agent: agent, size: 12)
                            Text(agent.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        }
                        Text(headline.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        PaceCaption(window: headline)
                    }
                    .lineLimit(1)
                }
            }
            let rows = Array(others.prefix(maxOthers))
            if !rows.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: wide ? 2 : 1), alignment: .leading, spacing: 10) {
                    ForEach(rows) { PaceLine(window: $0, color: agent.brandColor) }
                }
            }
        }
    }
}

/// "Resets in 2h" normally; the run-out warning when usage is ahead of pace.
private struct PaceCaption: View {
    var window: AgentQuotaWindow
    var body: some View {
        let pace = LimitPace(window: window)
        switch pace.verdict {
        case .ahead, .exhausted:
            Text(pace.verdict == .exhausted ? "Used up" : pace.runsOutAt.map { "Runs out \(AgentFormat.relative($0))" } ?? "Ahead of pace")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(pace.verdict == .exhausted ? Color(red: 1, green: 0.42, blue: 0.4) : Color(red: 1, green: 0.66, blue: 0.3))
                .help("\(pace.sentence). \(AgentFormat.resetText(window.resetsAt)).")
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Text(AgentFormat.resetText(window.resetsAt)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// Label and percentage over a 3pt line. The notch marks where usage would be if spread evenly over the window.
struct PaceLine: View {
    var window: AgentQuotaWindow
    var color: Color
    var title: String? = nil

    var body: some View {
        let pace = LimitPace(window: window)
        let used = min(max(window.usedPercent / 100, 0), 1)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title ?? window.label).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(window.usedPercent.rounded()))%")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(pace.verdict == .ahead || pace.verdict == .exhausted ? Color(red: 1, green: 0.66, blue: 0.3) : .white)
            }
            .font(.system(size: 11))
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08)).frame(height: 3)
                    Capsule().fill(color).frame(width: max(used > 0 ? 3 : 0, width * used), height: 3)
                    if let elapsed = pace.elapsed {
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: 1.5, height: 9)
                            .offset(x: min(max(width * elapsed - 0.75, 0), width - 1.5))
                    }
                }
                .frame(height: 9)
            }
            .frame(height: 9)
        }
        .help("\(AgentFormat.resetText(window.resetsAt)). \(pace.sentence)")
    }
}
