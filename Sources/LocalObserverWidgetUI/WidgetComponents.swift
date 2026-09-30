import SwiftUI
import Charts
import WidgetKit
import LocalObserverCore

// MARK: - Identity

/// The agent's official mark. Monochrome marks tint with the text colour; Claude and Antigravity keep theirs.
struct WAgentIcon: View {
    var agent: AgentKind
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = AgentIconStore.image(for: agent) {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .desaturatedWhenAccented()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.7, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.name)
    }
}

private extension Image {
    /// Brand marks go grey in the tinted desktop style instead of being flattened into a solid tint.
    @ViewBuilder func desaturatedWhenAccented() -> some View {
        if #available(macOS 15, *) { widgetAccentedRenderingMode(.desaturated) } else { self }
    }
}

/// Symbol plus word for a session state. Never colour alone: the word survives the desaturated desktop.
struct StateMark: View {
    var state: AgentActivityState
    var showsTitle = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.widgetSymbol)
                .font(.system(size: 9, weight: .bold))
                .widgetAccentable()
            if showsTitle {
                Text(state.title).font(WFont.captionMedium)
            }
        }
        .foregroundStyle(state.widgetTone)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Limits

/// A quota window as a ring: the arc is usage, the short bar across it is where usage would be at an even pace.
struct LimitRing: View {
    var window: WidgetSnapshot.Window
    var now: Date
    var lineWidth: CGFloat = 6
    var figureSize: CGFloat = 17

    var body: some View {
        let pace = LimitPace(window: window.quotaWindow, now: now)
        let used = min(max(window.usedPercent / 100, 0), 1)
        let color = window.agent.widgetColor
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            ZStack {
                Circle().stroke(WTheme.track, lineWidth: lineWidth)
                if used > 0.004 {
                    Circle()
                        .trim(from: 0, to: max(used, 0.01))
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .widgetAccentable()
                }
                if let elapsed = pace.elapsed, pace.verdict != .exhausted {
                    Capsule()
                        .fill(.primary)
                        .frame(width: 1.5, height: lineWidth + 5)
                        .offset(y: -(radius - lineWidth / 2))
                        .rotationEffect(.degrees(elapsed * 360))
                        .accessibilityHidden(true)
                }
                figure
            }
            .padding(lineWidth / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.agent.name) \(window.label), \(Int(window.usedPercent.rounded())) percent used")
    }

    @ViewBuilder private var figure: some View {
        if figureSize > 0 {
            (Text("\(Int(window.usedPercent.rounded()))")
                .font(WFont.figure(figureSize))
                .foregroundStyle(.primary)
             + Text("%")
                .font(WFont.figure(figureSize * 0.55))
                .foregroundStyle(.secondary))
            .monospacedDigit()
            .minimumScaleFactor(0.7)
            .lineLimit(1)
        }
    }
}

/// "71%", turning to the warning tone with a symbol when the window is burning faster than it resets.
struct UsedFigure: View {
    var window: WidgetSnapshot.Window
    var now: Date
    var size: CGFloat = 13

    var body: some View {
        let verdict = LimitPace(window: window.quotaWindow, now: now).verdict
        let hot = verdict == .ahead || verdict == .exhausted
        HStack(spacing: 3) {
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(WFont.figure(size))
                .monospacedDigit()
            if hot {
                Image(systemName: verdict == .exhausted ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: size * 0.62, weight: .bold))
                    .accessibilityLabel(verdict == .exhausted ? "Used up" : "Ahead of pace")
            }
        }
        .foregroundStyle(hot ? (verdict == .exhausted ? WTheme.danger : WTheme.attention) : Color.primary)
    }
}

/// One line of the answer to "when do I get this back": reset time normally, the run-out warning when ahead of pace.
struct PaceNote: View {
    var window: WidgetSnapshot.Window
    var now: Date
    var font: Font = WFont.caption

    var body: some View {
        let pace = LimitPace(window: window.quotaWindow, now: now)
        Group {
            switch pace.verdict {
            case .exhausted:
                Label {
                    Text(window.resetsAt.map { "Used up, back \(AgentFormat.relative($0, now: now))" } ?? "Used up")
                } icon: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundStyle(WTheme.danger)
            case .ahead:
                Label {
                    Text(pace.runsOutAt.map { "Runs out \(AgentFormat.relative($0, now: now))" } ?? "Ahead of pace")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(WTheme.attention)
            default:
                Text(AgentFormat.resetText(window.resetsAt, now: now))
                    .foregroundStyle(.secondary)
            }
        }
        .labelStyle(TightLabel())
        .font(font)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}

/// Label, percentage, and a thin bar with the pace tick. The tick is the part that answers "am I burning too fast".
struct PaceBar: View {
    var window: WidgetSnapshot.Window
    var now: Date
    var title: String?
    var showsReset = false

    var body: some View {
        let pace = LimitPace(window: window.quotaWindow, now: now)
        let used = min(max(window.usedPercent / 100, 0), 1)
        let hot = pace.verdict == .ahead || pace.verdict == .exhausted
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title ?? window.label)
                    .font(WFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsReset {
                    PaceNote(window: window, now: now, font: WFont.micro)
                        .layoutPriority(-1)
                }
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(WFont.figure(12))
                    .monospacedDigit()
                    .foregroundStyle(hot ? (pace.verdict == .exhausted ? WTheme.danger : WTheme.attention) : .primary)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(WTheme.track).frame(height: 4)
                    Capsule()
                        .fill(window.agent.widgetColor)
                        .frame(width: used > 0 ? max(4, width * used) : 0, height: 4)
                        .widgetAccentable()
                    if let elapsed = pace.elapsed, pace.verdict != .exhausted {
                        Capsule()
                            .fill(.primary)
                            .frame(width: 1.5, height: 9)
                            .offset(x: min(max(width * elapsed - 0.75, 0), width - 1.5))
                    }
                }
                .frame(height: 9)
            }
            .frame(height: 9)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.agent.name) \(title ?? window.label), \(Int(window.usedPercent.rounded())) percent. \(pace.sentence)")
    }
}

// MARK: - Usage

/// Last 24 hours as stacked hourly bars, one colour per agent. No axes in compact form: the shape is the point.
struct HourlyBars: View {
    var buckets: [WidgetSnapshot.Bucket]
    var showsAxis = false

    var body: some View {
        Chart(buckets, id: \.self) { bucket in
            BarMark(
                x: .value("Hour", bucket.date, unit: .hour),
                y: .value("Tokens", bucket.value),
                width: .ratio(0.62)
            )
            .foregroundStyle(bucket.agent.widgetColor)
            .cornerRadius(1.5)
        }
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis {
            if showsAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .narrow)))
                        .font(WFont.micro)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(alignment: .bottom) {
                Rectangle().fill(WTheme.rule).frame(height: 1)
            }
        }
        .widgetAccentable()
        .accessibilityLabel("Tokens per hour over the last 24 hours")
    }
}

// MARK: - Structure

/// Small grey heading with an optional trailing note. Plain type, no container.
struct WidgetHeading<Trailing: View>: View {
    var title: String
    var symbol: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            Text(title).font(WFont.captionMedium)
            Spacer(minLength: 6)
            trailing.font(WFont.caption)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

extension WidgetHeading where Trailing == EmptyView {
    init(title: String, symbol: String? = nil) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}

/// Shown only when the snapshot is old, so a quiet widget never passes stale numbers off as live.
struct FreshnessNote: View {
    var generatedAt: Date
    var now: Date

    /// Longer than a timeline (30 minutes) plus the app's heartbeat, so it only shows when the app isn't writing.
    static let staleAfter: TimeInterval = 40 * 60

    static func isStale(_ generatedAt: Date, now: Date) -> Bool { now.timeIntervalSince(generatedAt) > staleAfter }

    var body: some View {
        if Self.isStale(generatedAt, now: now) {
            Label("Updated \(AgentFormat.ago(generatedAt, now: now))", systemImage: "clock")
                .labelStyle(TightLabel())
                .font(WFont.micro)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

/// A widget link that keeps the text colours of its content instead of turning it into accent-tinted link text.
struct RowLink<Content: View>: View {
    var destination: URL
    @ViewBuilder var content: Content

    var body: some View {
        Link(destination: destination) {
            content.foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Icon and title with less space than the default label.
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

/// What a widget shows before the app has ever written a snapshot, or when a section has nothing yet.
struct WidgetEmpty: View {
    var symbol: String
    var title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title).font(WFont.bodyMedium).foregroundStyle(.primary)
            if let detail {
                Text(detail).font(WFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}
