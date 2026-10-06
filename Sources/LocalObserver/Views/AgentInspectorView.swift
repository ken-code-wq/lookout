import SwiftUI
import LocalObserverCore
import LocalObserverRepos

/// Right-hand panel for one agent session: where it runs, what it is doing, and what it has used.
struct AgentInspectorView: View {
    @ObservedObject var store: AgentStore
    var session: AgentSession
    @ObservedObject private var repos = RepoStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    AgentIconView(agent: session.agent, size: 20)
                    Text(session.agent.name).font(NFont.small).foregroundStyle(N.text2)
                    Spacer()
                    Button {
                        store.selectedSessionID = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Close (Esc)")
                }
                Text(session.title)
                    .font(NFont.title)
                    .foregroundStyle(N.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    AgentStateTag(state: session.state)
                        .help(session.stateSource == .hook ? "Reported live by the agent's hook" : "Inferred from the session's transcript")
                    if session.process == nil { Tag(text: "Finished", color: .gray) }
                    if session.process != nil && session.stateSource == .hook { Tag(text: "Live", color: .blue, symbol: "dot.radiowaves.left.and.right") }
                }
                actions.padding(.top, 4)
            }
            .padding(20)
            Rectangle().fill(N.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if AgentLinks.target(of: session, in: repos) != nil {
                        group(session.process == nil || session.state != .working ? "Hand-off" : "Work so far") {
                            AgentHandoffPanel(session: session)
                        }
                    }
                    group("Session") {
                        PropertyRow(symbol: "folder", label: "Project") {
                            Text(session.projectName).help(session.projectPath)
                        }
                        if !session.branch.isEmpty || session.checkout != nil {
                            PropertyRow(symbol: "arrow.triangle.branch", label: "Branch") { SessionBranchTag(session: session) }
                        }
                        if let pull = AgentLinks.pull(for: session, in: repos) {
                            PropertyRow(symbol: "arrow.triangle.pull", label: "Pull request") {
                                AgentPullValue(pull: pull)
                            }
                        }
                        if let git = session.checkout, git.isLinkedWorktree {
                            PropertyRow(symbol: "square.stack.3d.down.right", label: "Worktree") {
                                WorktreeValue(git: git)
                            }
                        }
                        PropertyRow(symbol: "cpu", label: "Model") { valueText(session.model) }
                        if let host = session.process?.host {
                            PropertyRow(symbol: "macwindow", label: "Running in") { Text(host.name) }
                        }
                        if let process = session.process {
                            PropertyRow(symbol: "terminal", label: "Process") {
                                Text(verbatim: "PID \(process.pid)" + (process.terminal == "??" ? "" : ", \(process.terminal)"))
                                    .font(NFont.monoSmall)
                            }
                        }
                        PropertyRow(symbol: "clock", label: "Started") { Text(AgentFormat.dateTime(session.startedAt)) }
                        PropertyRow(symbol: "arrow.triangle.2.circlepath", label: "Last activity") {
                            Text(AgentFormat.ago(session.updatedAt))
                        }
                        if !session.account.isEmpty {
                            PropertyRow(symbol: "person.crop.circle", label: "Account") { Text(session.account) }
                        }
                    }
                    group("Usage") {
                        if session.usage == nil {
                            Text(session.agent.capabilities.tokens
                                 ? "No token usage recorded for this session yet."
                                 : "\(session.agent.name) does not record token usage locally.")
                                .font(NFont.small)
                                .foregroundStyle(N.text2)
                        } else {
                            if let context = session.contextTokens {
                                PropertyRow(symbol: "text.alignleft", label: "Context") {
                                    Text(AgentFormat.compact(Double(context)) + " tokens")
                                }
                            }
                            PropertyRow(symbol: "number", label: "Processed") { Text(AgentFormat.tokens(session.usage?.processedTokens)) }
                            PropertyRow(symbol: "shippingbox", label: "Cached input") { Text(AgentFormat.tokens(session.usage?.cachedInputTokens)) }
                            PropertyRow(symbol: "tray.and.arrow.down", label: "Uncached input") {
                                Text(AgentFormat.tokens(session.usage?.derivedUncachedInputTokens))
                            }
                            PropertyRow(symbol: "arrow.up.right", label: "Output") { Text(AgentFormat.tokens(session.usage?.outputTokens)) }
                            PropertyRow(symbol: "arrow.left.arrow.right", label: "Requests") {
                                Text(session.requests.map { $0.formatted() } ?? AgentFormat.unavailable)
                            }
                            PropertyRow(symbol: "dollarsign", label: session.costIsEstimated ? "Est. cost" : "Cost") {
                                Text(AgentFormat.cost(session.cost))
                                    .help(session.costIsEstimated ? "Estimated from public API prices" : "Reported by the agent")
                            }
                            if session.agent.capabilities.estimatedTokens {
                                Text("\(session.agent.name) does not record token counts, so these are estimated from the transcript.")
                                    .font(NFont.caption)
                                    .foregroundStyle(N.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !session.sourcePath.isEmpty {
                        group("Source") {
                            Text((session.sourcePath as NSString).abbreviatingWithTildeInPath)
                                .font(NFont.monoSmall)
                                .foregroundStyle(N.text2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Read-only. Lookout never writes to agent files.")
                                .font(NFont.caption)
                                .foregroundStyle(N.text3)
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.never)
        }
        .background(N.bg)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if let host = session.process?.host {
                Button("Jump to \(host.name)") { AgentActions.jump(to: session) }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("⌘J")
            }
            if SessionReplayReader.supports(session.agent), !session.sourcePath.isEmpty {
                Button {
                    LiveSurfaces.shared.replay(session)
                } label: {
                    Label("Replay", systemImage: "play.rectangle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Step through everything this session did")
            }
            if !session.projectPath.isEmpty {
                Button("Reveal project") { AgentActions.reveal(session.projectPath) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(NFont.bodyMedium).foregroundStyle(N.text).padding(.bottom, 4)
            content()
        }
    }

    private func valueText(_ value: String) -> some View {
        Text(value.isEmpty ? AgentFormat.unavailable : value)
            .foregroundStyle(value.isEmpty ? N.text3 : N.text)
    }
}
