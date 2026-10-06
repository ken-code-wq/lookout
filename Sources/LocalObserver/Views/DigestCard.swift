import SwiftUI
import LocalObserverCore
import LocalObserverRepos
import LocalObserverDisk

/// The morning digest: what happened since you last looked. Agents that finished, pull requests waiting on you,
/// failing CI, inbox items for you, which agent to use while a plan limit runs short, budgets nearing their cap, and
/// disk space. Each line goes to its page; dismissing hides it until the next morning.
struct DigestCard: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var repos: RepoStore = .shared
    @ObservedObject var ci: CIStore = .shared
    @ObservedObject var github: GitHubStore = .shared
    @ObservedObject var disk: DiskStore = .shared
    var navigate: (SidebarItem) -> Void
    @AppStorage("LocalObserver.digestDismissed") private var dismissed: Double = 0

    /// Since the last dismissal, or 6pm yesterday when there's been none in a day.
    static func since(dismissed: Date?, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let evening = calendar.date(byAdding: .hour, value: -6, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(-86_400)
        guard let dismissed, now.timeIntervalSince(dismissed) < 86_400 else { return evening }
        return dismissed
    }

    private var since: Date { Self.since(dismissed: dismissed > 0 ? Date(timeIntervalSince1970: dismissed) : nil) }

    /// Hidden after dismissing until the next calendar day.
    var isVisible: Bool {
        dismissed == 0 || !Calendar.current.isDateInToday(Date(timeIntervalSince1970: dismissed))
    }

    struct Line: Identifiable {
        var id: String
        var symbol: String
        var tint: Color
        var text: String
        var detail: String
        var page: SidebarItem
    }

    var lines: [Line] {
        var lines: [Line] = []
        let finished = agentStore.snapshot.sessions.filter { $0.updatedAt >= since && $0.process == nil }
        if !finished.isEmpty {
            let cost = finished.compactMap(\.cost).reduce(0, +)
            let tokens = finished.reduce(Int64(0)) { $0 + ($1.usage?.processedTokens ?? 0) }
            lines.append(Line(id: "agents", symbol: "sparkles", tint: TagColor.purple.fg,
                              text: "\(finished.count) agent session\(finished.count == 1 ? "" : "s") finished",
                              detail: ([finished.prefix(2).map(\.title).joined(separator: ", ")]
                                       + [AgentFormat.compact(Double(tokens)) + " tokens", cost > 0 ? AgentFormat.cost(cost) : nil].compactMap { $0 })
                                .joined(separator: " · "),
                              page: .agentActivity))
        }
        let waiting = agentStore.attentionSessions
        if !waiting.isEmpty {
            lines.append(Line(id: "waiting", symbol: "hand.raised.fill", tint: TagColor.orange.fg,
                              text: "\(waiting.count) agent\(waiting.count == 1 ? " is" : "s are") waiting for you",
                              detail: waiting.prefix(2).map { "\($0.agent.shortName): \($0.title)" }.joined(separator: ", "), page: .agentActivity))
        }
        let reviews = repos.reviewRequests
        if !reviews.isEmpty {
            lines.append(Line(id: "reviews", symbol: "eye", tint: GH.link, text: "\(reviews.count) review\(reviews.count == 1 ? "" : "s") requested",
                              detail: reviews.prefix(2).map { "\($0.repoName) #\($0.number) by \($0.author)" }.joined(separator: ", "), page: .pullRequests))
        }
        let ready = repos.readyPulls
        if !ready.isEmpty {
            lines.append(Line(id: "ready", symbol: "checkmark.circle.fill", tint: GH.open, text: "\(ready.count) pull request\(ready.count == 1 ? " is" : "s are") ready to merge",
                              detail: ready.prefix(2).map { "\($0.repoName) #\($0.number)" }.joined(separator: ", "), page: .pullRequests))
        }
        let failing = repos.failingPulls.count + ci.failedRuns.count
        if failing > 0 {
            let names = repos.failingPulls.prefix(1).map { "\($0.repoName) #\($0.number)" } + ci.failedRuns.prefix(2).map { "\($0.workflow) on \($0.branch)" }
            lines.append(Line(id: "ci", symbol: "xmark.circle.fill", tint: GH.closed, text: "\(failing) failing check\(failing == 1 ? "" : "s")",
                              detail: names.joined(separator: ", "), page: .ci))
        }
        let forYou = github.notifications.filter { $0.unread && $0.isDirect }
        if !forYou.isEmpty {
            lines.append(Line(id: "inbox", symbol: "tray.full", tint: GH.link, text: "\(forYou.count) GitHub notification\(forYou.count == 1 ? "" : "s") for you",
                              detail: forYou.prefix(2).map { "\($0.reasonTitle): \($0.title)" }.joined(separator: ", "), page: .inbox))
        }
        let advice = LimitRouting.advice(reports: agentStore.limitReports)
        if advice.isActionable {
            lines.append(Line(id: "route", symbol: advice.symbol, tint: advice.tint, text: advice.headline, detail: advice.detail, page: .agentLimits))
        }
        for (agent, budget) in agentStore.settings.budgets {
            guard let p = (agentStore.spend[agent] ?? AgentSpend()).progress(budget), p.fraction >= budget.warnAt else { continue }
            lines.append(Line(id: "budget-\(agent.rawValue)", symbol: "dollarsign.circle", tint: p.fraction >= 1 ? TagColor.red.fg : TagColor.orange.fg,
                              text: "\(agent.name) is at \(Int(p.fraction * 100))% of its budget \(p.period)",
                              detail: "\(AgentFormat.cost(p.spent)) of \(AgentFormat.cost(p.cap))", page: .agentLimits))
        }
        if let volume = disk.volume, disk.isLowOnSpace || disk.safeBytes > 5_000_000_000 {
            lines.append(Line(id: "disk", symbol: "internaldrive", tint: disk.isLowOnSpace ? TagColor.red.fg : N.text2,
                              text: "\(DiskFormat.bytes(volume.available)) free" + (disk.isLowOnSpace ? ", running low" : ""),
                              detail: disk.safeBytes > 0 ? "\(DiskFormat.bytes(disk.safeBytes)) is safe to clear" : "Scan to see what's safe to clear",
                              page: .cleanup))
        }
        return lines
    }

    var body: some View {
        let lines = self.lines
        if isVisible, !lines.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: Self.greetingSymbol).foregroundStyle(TagColor.yellow.fg)
                    Text(Self.greeting).font(.system(size: 16, weight: .semibold)).foregroundStyle(N.text)
                    Text("Since \(since.formatted(date: Calendar.current.isDateInToday(since) ? .omitted : .abbreviated, time: .shortened))")
                        .font(NFont.small).foregroundStyle(N.text2)
                    Spacer()
                    Button("Dismiss") { withAnimation(.snappy(duration: 0.2)) { dismissed = Date().timeIntervalSince1970 } }
                        .buttonStyle(GhostButtonStyle())
                        .help("Hide until tomorrow; the next digest starts from now")
                }
                VStack(spacing: 2) {
                    ForEach(lines) { line in DigestRow(line: line) { navigate(line.page) } }
                }
            }
            .padding(18)
            .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 20)
        }
    }

    static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
    }
    static var greetingSymbol: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "sun.max.fill" : (hour < 18 ? "sun.haze.fill" : "moon.stars.fill")
    }
}

private struct DigestRow: View {
    var line: DigestCard.Line
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: line.symbol).font(.system(size: 13)).foregroundStyle(line.tint).frame(width: 20)
                Text(line.text).font(NFont.bodyMedium).foregroundStyle(N.text)
                Text(line.detail).font(NFont.small).foregroundStyle(N.text2).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(N.text3).opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
