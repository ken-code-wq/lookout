import SwiftUI
import LocalObserverCore

// Where limit routing shows up: a banner on the Plan limits page and a line in the open notch. The digest builds
// its own line from the same advice; notifications come from LimitRouteNotifier.

extension LimitAdvice {
    var symbol: String {
        switch kind {
        case .switchProvider: return "arrow.triangle.branch"
        case .forecast: return severity == .calm ? "gauge.with.dots.needle.33percent" : "exclamationmark.circle"
        case .allTight: return "exclamationmark.triangle"
        case .allClear: return "checkmark.circle"
        case .stale: return "clock.badge.questionmark"
        case .noData: return "gauge.with.dots.needle.0percent"
        }
    }

    var tint: Color {
        switch severity {
        case .critical: return TagColor.red.fg
        case .warning: return TagColor.orange.fg
        case .calm: return kind == .stale ? TagColor.yellow.fg : N.text2
        }
    }
}

/// Top of the Plan limits page: the recommendation and the numbers behind it. Calm states shrink to one quiet line.
struct LimitAdviceBanner: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let advice = LimitRouting.advice(reports: store.limitReports, now: context.date)
            if advice.kind == .noData {
                EmptyView()
            } else if advice.isActionable || advice.kind == .stale {
                callout(advice)
            } else {
                quiet(advice)
            }
        }
    }

    private func callout(_ advice: LimitAdvice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: advice.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(advice.tint)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(advice.headline).font(NFont.bodyMedium).foregroundStyle(N.text)
                    if let from = advice.constrained, let to = advice.recommended {
                        HStack(spacing: 4) {
                            AgentIconView(agent: from, size: 13)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(N.text3)
                            AgentIconView(agent: to, size: 13)
                        }
                        .accessibilityHidden(true)
                    }
                }
                Text(advice.detail)
                    .font(NFont.small)
                    .foregroundStyle(N.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if advice.kind == .stale {
                Button("Refresh") { store.refreshLimits(force: true) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(store.isRefreshingLimits)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            // A thin accent rule; the icon and the words carry the meaning, the colour only reinforces it.
            RoundedRectangle(cornerRadius: 1.5).fill(advice.tint).frame(width: 3).padding(.vertical, 10)
        }
        .accessibilityElement(children: .combine)
    }

    private func quiet(_ advice: LimitAdvice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: advice.symbol).font(.system(size: 11.5))
            Text(advice.headline).foregroundStyle(N.text)
            if !advice.detail.isEmpty { Text(advice.detail).foregroundStyle(N.text2).lineLimit(1).truncationMode(.tail) }
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .accessibilityElement(children: .combine)
    }
}

/// The open notch's limits page: one line under the provider picker when there's something to act on.
struct NotchLimitAdviceLine: View {
    var advice: LimitAdvice

    static let height: CGFloat = 18

    /// Only what's worth a glance; all-clear stays off the notch.
    static func shows(_ advice: LimitAdvice) -> Bool { advice.isActionable || advice.kind == .stale }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: advice.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
            Text(advice.headline).fontWeight(.medium).foregroundStyle(.white)
            if let to = advice.recommended { AgentIconView(agent: to, size: 11).accessibilityHidden(true) }
            Text(advice.detail).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .frame(height: Self.height)
        .help(advice.detail)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch advice.severity {
        case .critical: return Color(red: 1, green: 0.42, blue: 0.4)
        case .warning: return Color(red: 1, green: 0.66, blue: 0.3)
        case .calm: return .white.opacity(0.5)
        }
    }
}
