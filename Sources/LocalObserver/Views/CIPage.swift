import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverRepos

extension GHRunStatus {
    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .running: return "circle.dotted.circle"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .skipped: return "arrow.uturn.right.circle"
        case .neutral: return "circle"
        }
    }
    var tint: Color {
        switch self {
        case .queued, .running: return GH.attention
        case .success: return GH.open
        case .failure: return GH.closed
        default: return N.text3
        }
    }
}

struct RunStatusGlyph: View {
    var status: GHRunStatus
    var size: CGFloat = 13
    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(status.tint)
            .symbolEffect(.pulse, options: .repeating, isActive: status == .running)
            .help(status.title)
    }
}

/// Workflow runs and deployments across the repositories you work in.
struct CIPage: View {
    @ObservedObject var store: CIStore
    @ObservedObject var repos: RepoStore
    var agents: AgentStore
    @State private var width: CGFloat = 900

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: SidebarItem.ci.symbol, title: SidebarItem.ci.title, subtitle: AnyView(summary))
                GitHubStatusBanner(store: repos)
                if let error = store.error { GHErrorBox(message: error) { store.refresh() }.padding(.bottom, 12) }
                if !store.deployments.isEmpty { deploys.padding(.bottom, 26) }
                if !store.failedRuns.isEmpty {
                    section("Failing", symbol: "xmark.circle", count: store.failedRuns.count) {
                        ForEach(store.failedRuns) { CIRunRow(store: store, repos: repos, agents: agents, run: $0) }
                    }
                }
                let failing = Set(store.failedRuns.map(\.id))
                let recent = store.filteredRuns.filter { !failing.contains($0.id) }
                section("Recent runs", symbol: "clock.arrow.circlepath", count: recent.count) {
                    if store.runs.isEmpty {
                        Group {
                            if store.isLoading { GHLoading(text: "Asking GitHub for workflow runs…") }
                            else {
                                Text(repos.repos.contains { $0.github != nil }
                                     ? "No workflow runs yet in the repositories on this Mac."
                                     : "No GitHub repositories on this Mac yet. Runs show up for repositories cloned from GitHub.")
                                    .font(NFont.small).foregroundStyle(N.text2).padding(.vertical, 14)
                            }
                        }
                    }
                    ForEach(recent) { CIRunRow(store: store, repos: repos, agents: agents, run: $0) }
                }
            }
            .padding(.horizontal, width > 1100 ? 64 : (width > 800 ? 44 : 24))
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .onAppear { if store.lastRefresh.map({ Date().timeIntervalSince($0) > 30 }) ?? true { store.refresh() } }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            Label("\(store.activeRuns.count) running", systemImage: "circle.dotted.circle")
                .foregroundStyle(store.activeRuns.isEmpty ? N.text2 : GH.attention)
            if !store.failedRuns.isEmpty {
                Label("\(store.failedRuns.count) failing", systemImage: "xmark.circle").foregroundStyle(GH.closed)
            }
            let live = store.deployments.filter { $0.state == .success && $0.isProduction }.count
            if live > 0 { Label("\(live) in production", systemImage: "globe") }
            if store.isLoading { ProgressView().controlSize(.mini) } else { RelativeTimeText(date: store.lastRefresh) }
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .labelStyle(TightLabelStyle())
    }

    private func section<Content: View>(_ title: String, symbol: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11.5))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(count)").font(NFont.small).foregroundStyle(N.text3).monospacedDigit()
            }
            .foregroundStyle(N.text)
            .padding(.top, 14)
            .padding(.bottom, 6)
            Rectangle().fill(N.divider).frame(height: 1)
            LazyVStack(spacing: 1) { content() }.padding(.top, 2)
        }
        .padding(.bottom, 14)
    }

    private var deploys: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 11.5))
                Text("Deploys").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(N.text)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                ForEach(store.deployments.prefix(12)) { DeployCard(deployment: $0) }
            }
        }
    }
}

struct DeployCard: View {
    var deployment: GHDeployment
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(deployment.repo.split(separator: "/").last.map(String.init) ?? deployment.repo)
                    .font(NFont.bodyMedium).foregroundStyle(N.text).lineLimit(1)
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(deployment.state.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
                }
            }
            HStack(spacing: 6) {
                Tag(text: deployment.environment, color: deployment.isProduction ? .green : .gray)
                Text(deployment.provider).font(NFont.caption).foregroundStyle(N.text2)
                if !deployment.sha.isEmpty { Text(String(deployment.sha.prefix(7))).font(NFont.monoSmall).foregroundStyle(N.text3) }
                Spacer()
                Text(RepoFormat.ago(deployment.createdAt)).font(NFont.caption).foregroundStyle(N.text3)
            }
            if let url = deployment.url {
                Button { ProcessManager.openURL(url) } label: {
                    Label(url.replacingOccurrences(of: "https://", with: ""), systemImage: "arrow.up.right.square")
                        .font(NFont.small).foregroundStyle(N.blue).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(hover ? N.hover : N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hover = $0 }
        .contextMenu {
            if let url = deployment.url { Button("Open Deployment") { ProcessManager.openURL(url) }; Button("Copy URL") { RepoActions.copy(url) } }
            if let log = deployment.logURL { Button("Open Build Log") { ProcessManager.openURL(log) } }
        }
    }

    private var color: Color {
        switch deployment.state {
        case .success: return GH.open
        case .failure: return GH.closed
        case .pending, .inProgress: return GH.attention
        default: return N.text3
        }
    }
}

/// A workflow run; opens in place to its jobs, steps and log.
struct CIRunRow: View {
    @ObservedObject var store: CIStore
    @ObservedObject var repos: RepoStore
    var agents: AgentStore
    var run: GHRun
    @State private var hover = false

    private var open: Bool { store.selectedRun == run.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RunStatusGlyph(status: run.status, size: 14).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(run.title.isEmpty ? run.workflow : run.title).font(NFont.bodyMedium).foregroundStyle(N.text).lineLimit(1)
                        if !run.branch.isEmpty { GHBranchName(name: run.branch, maxWidth: 200, copyable: true) }
                    }
                    Text("\(run.repoName) · \(run.workflow) #\(run.number)\(run.attempt > 1 ? " (attempt \(run.attempt))" : "") · \(run.event)\(run.actor.isEmpty ? "" : " by \(run.actor)")")
                        .font(NFont.caption).foregroundStyle(N.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let d = run.duration() {
                    Text(GHFormat.duration(d) ?? "").font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
                }
                Text(RepoFormat.ago(run.createdAt)).font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(N.text3)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 8)
            .frame(height: 50)
            .background(open ? N.selected : (hover ? N.hover : .clear), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) { store.selectedRun = open ? nil : run.id }
                if !open { store.loadJobs(run) }
            }
            .contextMenu {
                Button("Open on GitHub") { ProcessManager.openURL(run.url) }
                if run.status == .failure { Button("Re-run Failed Jobs") { store.rerun(run, failedOnly: true) } }
                if !run.status.isActive { Button("Re-run All Jobs") { store.rerun(run, failedOnly: false) } }
                if run.status.isActive { Button("Cancel Run") { store.cancel(run) } }
                Button("Copy Commit SHA") { RepoActions.copy(run.sha) }
            }
            if open { CIRunDetail(store: store, repos: repos, agents: agents, run: run).padding(.leading, 36).padding(.vertical, 10) }
        }
    }
}

struct CIRunDetail: View {
    @ObservedObject var store: CIStore
    @ObservedObject var repos: RepoStore
    var agents: AgentStore
    var run: GHRun
    @State private var logJob: Int?

    /// Running agent sessions on this run's branch: who to hand a failure to.
    private var sessions: [AgentSession] {
        AgentLinks.sessions(slug: run.repo, branch: run.branch, agents: agents, repos: repos).filter { $0.process != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if run.status == .failure {
                    Button { store.rerun(run, failedOnly: true) } label: { Label("Re-run failed", systemImage: "arrow.clockwise") }
                        .buttonStyle(SecondaryButtonStyle())
                    if repos.localRepo(slug: run.repo) != nil {
                        Button { fixWithAgent(nil) } label: { Label("Fix with an agent", systemImage: "plus.bubble") }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("Start an agent on \(run.branch) with a prompt to fix this run")
                    }
                }
                if !run.status.isActive {
                    Button { store.rerun(run, failedOnly: false) } label: { Label("Re-run all", systemImage: "arrow.clockwise.circle") }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button { store.cancel(run) } label: { Label("Cancel", systemImage: "stop.circle") }
                        .buttonStyle(SecondaryButtonStyle(tint: N.red))
                }
                Button { ProcessManager.openURL(run.url) } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                    .buttonStyle(SecondaryButtonStyle())
                if store.working.contains(run.id) || store.loadingJobs.contains(run.id) { ProgressView().controlSize(.small) }
            }
            if let jobs = store.jobs[run.id] {
                ForEach(jobs) { job in jobView(job) }
            }
        }
    }

    private func jobView(_ job: GHJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RunStatusGlyph(status: job.status, size: 12)
                Text(job.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                if let start = job.startedAt {
                    Text(GHFormat.duration((job.completedAt ?? Date()).timeIntervalSince(start)) ?? "")
                        .font(NFont.caption).foregroundStyle(N.text3).monospacedDigit()
                }
                Spacer()
                Button(logJob == job.id ? "Hide log" : "Log") {
                    logJob = logJob == job.id ? nil : job.id
                    if logJob != nil { store.loadLog(job, repo: run.repo) }
                }
                .buttonStyle(GhostButtonStyle(tint: N.blue))
                .disabled(job.status == .queued)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(job.steps) { step in
                    HStack(spacing: 6) {
                        RunStatusGlyph(status: step.status, size: 10).frame(width: 14)
                        Text(step.name).font(NFont.small)
                            .foregroundStyle(step.status == .failure ? GH.closed : (step.status == .skipped ? N.text3 : N.text2))
                            .fontWeight(step.status == .failure ? .semibold : .regular)
                    }
                }
            }
            .padding(.leading, 20)
            if logJob == job.id { logView(job) }
        }
        .padding(10)
        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private func logView(_ job: GHJob) -> some View {
        if let lines = store.logs[job.id] {
            let firstError = lines.first { $0.kind == .error }?.id
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(lines.count) lines" + (firstError != nil ? " · \(lines.filter { $0.kind == .error }.count) errors" : ""))
                        .font(NFont.caption).foregroundStyle(N.text2)
                    Spacer()
                    Button {
                        RepoActions.copy(handoffText(job, lines))
                    } label: { Label("Copy failure for an agent", systemImage: "doc.on.doc") }
                        .buttonStyle(GhostButtonStyle(tint: N.blue))
                        .help("The failing step and the log around the first error, as a prompt")
                    if repos.localRepo(slug: run.repo) != nil {
                        Button { fixWithAgent(handoffText(job, lines)) } label: { Label("Start an agent", systemImage: "plus.bubble") }
                            .buttonStyle(GhostButtonStyle(tint: N.blue))
                            .help("A new agent task with this failure as its prompt")
                    }
                    ForEach(sessions.prefix(2)) { session in
                        Button {
                            RepoActions.copy(handoffText(job, lines))
                            AgentActions.jump(to: session)
                            LiveSurfaces.shared.toast("Copied the failure. Paste it into \(session.agent.shortName).")
                        } label: { Label("Send to \(session.agent.shortName)", systemImage: "paperplane") }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("Copies the failure and jumps to \(session.title)")
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 11.5, weight: line.kind == .group ? .semibold : .regular, design: .monospaced))
                                    .foregroundStyle(color(line.kind))
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(line.kind == .error ? Color.red.opacity(0.18) : .clear)
                                    .id(line.id)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 8)
                    }
                    .frame(height: 340)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onAppear { if let firstError { proxy.scrollTo(firstError, anchor: .center) } }
                }
            }
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading log…").font(NFont.small).foregroundStyle(N.text2) }
        }
    }

    private func color(_ kind: GHLogLine.Kind) -> Color {
        switch kind {
        case .error: return Color(red: 1, green: 0.6, blue: 0.55)
        case .warning: return Color(red: 1, green: 0.8, blue: 0.4)
        case .group: return .white.opacity(0.95)
        case .command: return Color(red: 0.55, green: 0.75, blue: 1)
        case .plain: return .white.opacity(0.72)
        }
    }

    /// A new agent task for this run: in the checkout that has its branch, else a worktree from it. The prompt is
    /// the failure itself when the log is loaded, otherwise the "Fix failing CI" template.
    private func fixWithAgent(_ failure: String?) {
        guard let repo = repos.localRepo(slug: run.repo) else { return }
        let checkout = repo.branch == run.branch ? repo.root : repo.worktrees.first { $0.branch == run.branch }?.path
        let template = AgentTaskStore.shared.templates.first { $0.title == AgentPromptTemplate.fixCI }
            ?? AgentPromptTemplate.defaults[0]
        let prompt = failure ?? template.expanded(repo: repo.name, branch: run.branch) + "\nFailing run: \(run.url)"
        AgentTaskCoordinator.shared.present(AgentTaskDraft(repoRoot: repo.root, prompt: prompt,
                                                           base: checkout == nil ? run.branch : nil, checkout: checkout))
    }

    private func handoffText(_ job: GHJob, _ lines: [GHLogLine]) -> String {
        """
        CI failed on \(run.branch) (\(run.repo), \(run.workflow) #\(run.number), job "\(job.name)"\(job.failedStep.map { ", step \"\($0.name)\"" } ?? "")).
        Find the cause and fix it. Log around the first error:

        ```
        \(GHLogLine.excerpt(lines))
        ```
        """
    }
}
