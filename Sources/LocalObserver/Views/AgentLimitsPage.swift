import SwiftUI
import LocalObserverCore

/// Plan usage windows per agent: how much is used, when it resets, and whether the current pace gets there first.
struct AgentLimitsPage: View {
    @ObservedObject var store: AgentStore
    @State private var width: CGFloat = 900

    private var reports: [AgentLimitReport] { store.limitReports }
    private var withWindows: [AgentLimitReport] { reports.filter { !$0.windows.isEmpty } }
    private var connectable: [AgentLimitReport] {
        reports.filter { $0.windows.isEmpty && ($0.status == .notConnected || $0.status == .error) }
    }
    private var unsupported: [AgentLimitReport] { reports.filter { $0.windows.isEmpty && $0.status == .unsupported } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: "gauge.with.dots.needle.33percent", title: "Limits", subtitle: AnyView(subtitle))

                if reports.isEmpty {
                    EmptyStateView(symbol: "gauge.with.dots.needle.0percent", title: "No agents selected",
                                   message: "Choose which agents to watch, then connect the ones with plan limits.") {
                        SettingsLink { Text("Choose agents") }.buttonStyle(PrimaryButtonStyle())
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(alignment: .leading, spacing: 34) {
                            ForEach(withWindows) { report in
                                LimitReportSection(store: store, report: report, now: context.date, wide: contentWidth > 720)
                            }
                        }
                    }
                    if !connectable.isEmpty {
                        connectSection.padding(.top, withWindows.isEmpty ? 0 : 40)
                    }
                    if !unsupported.isEmpty {
                        unsupportedLine.padding(.top, 28)
                    }
                    legend.padding(.top, 36)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    private var horizontalPadding: CGFloat { width > 1100 ? 64 : (width > 800 ? 44 : 24) }
    private var contentWidth: CGFloat { width - horizontalPadding * 2 }

    private var subtitle: some View {
        HStack(spacing: 14) {
            let live = reports.filter { $0.status == .connected }.count
            Label("\(live) connected", systemImage: "link")
            if let tight = store.tightestWindow, tight.usedPercent >= 70 {
                Label("\(tight.agent.shortName) \(tight.label.lowercased()) at \(Int(tight.usedPercent.rounded()))%",
                      systemImage: "exclamationmark.circle")
                    .foregroundStyle(tight.usedPercent >= 90 ? TagColor.red.fg : TagColor.orange.fg)
            }
            if store.isRefreshingLimits {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Checking providers")
                }
            }
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .labelStyle(TightLabelStyle())
    }

    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(withWindows.isEmpty ? "Connect plan limits" : "Not connected", count: nil)
            VStack(spacing: 0) {
                ForEach(Array(connectable.enumerated()), id: \.element.id) { index, report in
                    ConnectRow(store: store, report: report)
                    if index < connectable.count - 1 { Rectangle().fill(N.divider).frame(height: 1) }
                }
            }
        }
    }

    private var unsupportedLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: -3) {
                ForEach(unsupported) { AgentIconView(agent: $0.agent, size: 14) }
            }
            Text("\(ListFormatter.localizedString(byJoining: unsupported.map(\.agent.name))) \(unsupported.count == 1 ? "has" : "have") no plan limits of \(unsupported.count == 1 ? "its" : "their") own. They use the limits of the provider you sign in with.")
                .font(NFont.small)
                .foregroundStyle(N.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Capsule().fill(N.text).frame(width: 2, height: 12)
                Text("Time elapsed in the window")
            }
            HStack(spacing: 6) {
                Capsule().fill(N.blue).frame(width: 18, height: 6)
                Text("Used")
            }
            Text("Past the marker means you are using the window faster than an even pace.")
                .foregroundStyle(N.text3)
        }
        .font(NFont.caption)
        .foregroundStyle(N.text2)
    }
}

// MARK: - Report section

private struct LimitReportSection: View {
    @ObservedObject var store: AgentStore
    var report: AgentLimitReport
    var now: Date
    var wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                AgentIconView(agent: report.agent, size: 22)
                Text(report.agent.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(N.text)
                if !report.plan.isEmpty { Tag(text: report.plan, color: .gray) }
                if report.status == .local { Tag(text: "From session log", color: .yellow) }
                Spacer(minLength: 8)
                Text(freshness)
                    .font(NFont.caption)
                    .foregroundStyle(N.text3)
                    .lineLimit(1)
                    .help(report.source)
            }
            .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(report.windows) { window in
                    LimitWindowRow(window: window, now: now, wide: wide)
                    if window.id != report.windows.last?.id {
                        Rectangle().fill(N.divider).frame(height: 1)
                    }
                }
            }

            if !report.message.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: report.status == .error ? "exclamationmark.triangle" : "info.circle")
                        .font(.system(size: 11))
                    Text(report.message)
                }
                .font(NFont.caption)
                .foregroundStyle(report.status == .error ? TagColor.orange.fg : N.text2)
                .padding(.top, 8)
            }
            if report.status == .local, AgentLimitClients.supportsAccountLimits(report.agent),
               !store.settings.accountLimitAgents.contains(report.agent) {
                HStack(spacing: 8) {
                    Text("Session logs only update when \(report.agent.shortName) runs. Connect for live numbers.")
                        .font(NFont.caption).foregroundStyle(N.text2)
                    Button("Connect") { store.setAccountLimits(report.agent, enabled: true) }
                        .buttonStyle(GhostButtonStyle(tint: N.blue))
                }
                .padding(.top, 6)
            }
        }
    }

    private var freshness: String {
        let source = report.source.isEmpty ? "" : "\(report.source), "
        return "\(source)updated \(AgentFormat.ago(report.fetchedAt, now: now))"
    }
}

private struct LimitWindowRow: View {
    var window: AgentQuotaWindow
    var now: Date
    var wide: Bool

    var body: some View {
        let pace = LimitPace(window: window, now: now)
        Group {
            if wide {
                HStack(alignment: .center, spacing: 18) {
                    labelBlock.frame(width: 190, alignment: .leading)
                    LimitMeter(window: window).frame(maxWidth: .infinity)
                    percent.frame(width: 52, alignment: .trailing)
                    resetBlock(pace).frame(width: 230, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        labelBlock
                        Spacer()
                        percent
                    }
                    LimitMeter(window: window)
                    resetBlock(pace)
                }
            }
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private var labelBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(window.label).font(NFont.body).foregroundStyle(N.text).lineLimit(1)
            if !window.detail.isEmpty {
                Text(window.detail).font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
            }
        }
    }

    private var percent: some View {
        Text("\(Int(window.usedPercent.rounded()))%")
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(window.usedPercent >= 90 ? TagColor.red.fg : (window.usedPercent >= 70 ? TagColor.orange.fg : N.text))
            .contentTransition(.numericText())
    }

    private func resetBlock(_ pace: LimitPace) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AgentFormat.resetText(window.resetsAt, now: now))
                .font(NFont.small)
                .foregroundStyle(N.text2)
                .help(window.resetsAt.map { AgentFormat.dateTime($0) } ?? "")
            if !pace.sentence.isEmpty {
                HStack(spacing: 4) {
                    if pace.verdict == .ahead || pace.verdict == .exhausted {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9.5))
                    }
                    Text(pace.sentence)
                }
                .font(NFont.caption)
                .foregroundStyle(pace.tone == .gray ? N.text3 : pace.tone.fg)
            }
        }
    }
}

// MARK: - Connect

private struct ConnectRow: View {
    @ObservedObject var store: AgentStore
    var report: AgentLimitReport

    private var isOptedIn: Bool { store.settings.accountLimitAgents.contains(report.agent) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentIconView(agent: report.agent, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.agent.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                Text(message)
                    .font(NFont.small)
                    .foregroundStyle(report.status == .error ? TagColor.orange.fg : N.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if isOptedIn {
                Button("Try again") { store.refreshLimits(force: true) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Disconnect") { store.setAccountLimits(report.agent, enabled: false) }
                    .buttonStyle(GhostButtonStyle())
            } else if AgentLimitClients.supportsAccountLimits(report.agent) {
                Button("Connect") { store.setAccountLimits(report.agent, enabled: true) }
                    .buttonStyle(SecondaryButtonStyle(tint: N.blue))
            }
        }
        .padding(.vertical, 14)
    }

    private var message: String {
        if report.status == .error || isOptedIn, !report.message.isEmpty { return report.message }
        return AgentLimitClients.connectDescription(report.agent)
    }
}
