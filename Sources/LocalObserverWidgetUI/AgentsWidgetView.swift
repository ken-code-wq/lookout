import SwiftUI
import WidgetKit
import LocalObserverCore

extension WidgetSnapshot {
    /// Running sessions in the order a developer deals with them: waiting on you, failed, your turn, working, idle.
    var queuedSessions: [Session] {
        sessions.sorted {
            if $0.state.widgetRank != $1.state.widgetRank { return $0.state.widgetRank < $1.state.widgetRank }
            return $0.startedAt > $1.startedAt
        }
    }

    var attentionCount: Int { sessions.filter(\.needsAttention).count }
    var yourTurnCount: Int { sessions.filter { $0.state == .waiting }.count }

    /// Worktrees often share a project name; when they do, the task says which session is which.
    func rowName(_ session: Session) -> String {
        let project = session.project.isEmpty ? session.agent.widgetShortName : session.project
        let clashes = sessions.filter { $0.project == session.project }.count > 1
        return clashes && !session.title.isEmpty ? session.title : project
    }
    var workingCount: Int { sessions.filter { $0.state.widgetRank == 3 }.count }
}

/// Running agents. The headline is the most urgent fact ("2 need you"), rows are the sessions behind it.
public struct AgentsWidgetView: View {
    var snapshot: WidgetSnapshot?
    var now: Date
    var family: WidgetFamily

    public init(snapshot: WidgetSnapshot?, now: Date, family: WidgetFamily) {
        self.snapshot = snapshot
        self.now = now
        self.family = family
    }

    private var rowLimit: Int {
        switch family {
        case .systemSmall: return 4
        case .systemMedium: return 3
        default: return 7
        }
    }

    public var body: some View {
        Group {
            if let snapshot {
                content(snapshot)
            } else {
                WidgetEmpty(symbol: "sparkles", title: "Open Lookout",
                            detail: family == .systemSmall ? nil : "Running agents appear here once the app is running.")
            }
        }
        .widgetURL(WidgetLink.activity)
    }

    @ViewBuilder private func content(_ snapshot: WidgetSnapshot) -> some View {
        let sessions = snapshot.queuedSessions
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            AgentsHeadline(snapshot: snapshot, compact: family == .systemSmall)
            if sessions.isEmpty {
                WidgetEmpty(symbol: "moon.zzz", title: "No agents running",
                            detail: family == .systemSmall ? nil : "Sessions from Claude Code, Codex, and others show up here.")
            } else {
                VStack(alignment: .leading, spacing: family == .systemSmall ? 7 : 9) {
                    ForEach(sessions.prefix(rowLimit)) { session in
                        if family == .systemSmall {
                            CompactSessionRow(session: session, name: snapshot.rowName(session))
                        } else {
                            RowLink(destination: WidgetLink.session(session.id)) {
                                SessionRow(session: session, now: now)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                footer(snapshot, hidden: max(sessions.count - rowLimit, 0))
            }
        }
    }

    @ViewBuilder private func footer(_ snapshot: WidgetSnapshot, hidden: Int) -> some View {
        let stale = FreshnessNote.isStale(snapshot.generatedAt, now: now)
        if family == .systemLarge || family == .systemExtraLarge {
            Rectangle().fill(WTheme.rule).frame(height: 1)
            HStack(spacing: 6) {
                if snapshot.today.processed > 0 {
                    Text("Today").foregroundStyle(.secondary)
                    Text(AgentFormat.compact(Double(snapshot.today.processed)) + " tokens").monospacedDigit()
                    if let cost = snapshot.today.cost {
                        Text(AgentFormat.cost(cost, estimated: snapshot.today.costIsEstimated))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if stale { FreshnessNote(generatedAt: snapshot.generatedAt, now: now) }
                else if hidden > 0 { Text("\(hidden) more").foregroundStyle(.tertiary) }
            }
            .font(WFont.caption)
            .lineLimit(1)
        } else if stale {
            FreshnessNote(generatedAt: snapshot.generatedAt, now: now)
        } else if hidden > 0, family != .systemSmall {
            Text("\(hidden) more").font(WFont.micro).foregroundStyle(.tertiary)
        }
    }
}

/// The most pressing fact first: "2 need you" (blocked), then "3 your turn" (finished, waiting for a prompt),
/// then how many are working. Tone and symbol match the rows' state marks.
struct AgentsHeadline: View {
    var snapshot: WidgetSnapshot
    var compact: Bool

    var body: some View {
        let attention = snapshot.attentionCount
        let turn = snapshot.yourTurnCount
        let working = snapshot.workingCount
        let total = snapshot.sessions.count
        let lead: (symbol: String?, text: String, tone: Color) =
            attention > 0 ? ("hand.raised.fill", "\(attention) \(attention == 1 ? "needs" : "need") you", WTheme.attention)
            : turn > 0 ? ("arrowshape.turn.up.left.fill", "\(turn) your turn", WTheme.turn)
            : total == 0 ? (nil, "Agents", .primary)
            : (nil, working > 0 ? "\(working) working" : "\(total) running", .primary)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol = lead.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .widgetAccentable()
                }
                Text(lead.text)
                    .font(compact ? WFont.title : .system(size: 15, weight: .semibold))
            }
            .foregroundStyle(lead.tone)
            Spacer(minLength: 4)
            if !compact, total > 0 {
                Text(lead.symbol != nil && working > 0 ? "\(working) working, \(total) running" : "\(total) running")
                    .font(WFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// Icon, project, and a state glyph: all a small widget has room for.
private struct CompactSessionRow: View {
    var session: WidgetSnapshot.Session
    var name: String

    var body: some View {
        HStack(spacing: 7) {
            WAgentIcon(agent: session.agent, size: 14)
            Text(name)
                .font(WFont.bodyMedium)
                .lineLimit(1)
            Spacer(minLength: 4)
            StateMark(state: session.state, showsTitle: false)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Project and task on the left, state and time on the right. Taps jump to the session's terminal.
struct SessionRow: View {
    var session: WidgetSnapshot.Session
    var now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            WAgentIcon(agent: session.agent, size: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project.isEmpty ? session.agent.widgetShortName : session.project)
                    .font(WFont.bodyMedium)
                Text(session.title.isEmpty || session.title == session.project
                     ? [session.agent.widgetShortName, session.model].filter { !$0.isEmpty }.joined(separator: ", ")
                     : session.title)
                    .font(WFont.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                StateMark(state: session.state)
                Text(AgentFormat.duration(now.timeIntervalSince(session.startedAt)))
                    .font(WFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
