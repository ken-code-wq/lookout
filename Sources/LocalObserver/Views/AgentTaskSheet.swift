import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverRepos

/// "New agent task": pick a repository, an agent and a prompt, and Lookout opens the agent in your terminal on a
/// fresh worktree (or the checkout you choose). Shows exactly what it will run and where before it does.
struct AgentTaskSheet: View {
    @ObservedObject var coordinator: AgentTaskCoordinator
    @ObservedObject var repos: RepoStore
    @ObservedObject var tasks: AgentTaskStore
    var draft: AgentTaskDraft
    @Environment(\.dismiss) private var dismiss

    @State private var repoRoot = ""
    @State private var cli: AgentCLI?
    @State private var prompt = ""
    @State private var useWorktree = true
    @State private var base = ""
    @State private var checkout = ""
    @State private var branches: [String] = []
    @State private var error: String?
    @State private var editingTemplates = false
    @FocusState private var promptFocused: Bool

    private var repoList: [Repo] { AgentTaskStore.recentFirst(repos.visibleRepos, tasks: tasks.tasks) }
    private var repo: Repo? { repos.repos.first { $0.root == repoRoot } }
    private var available: [AgentCLI] { AgentCLI.allCases.filter { coordinator.installed?[$0] != nil } }
    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The main checkout and every worktree that still has its folder.
    private var checkouts: [(path: String, label: String)] {
        guard let repo else { return [] }
        return [(repo.root, "\(repo.refLabel) · main checkout")]
            + repo.worktrees.filter { !$0.isPrunable }.map { ($0.path, "\($0.refLabel) · \($0.name)") }
    }

    private var canStart: Bool {
        repo != nil && cli != nil && !trimmedPrompt.isEmpty && !coordinator.launching && (useWorktree ? !base.isEmpty : !checkout.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(N.text2)
                Text("New agent task").font(.system(size: 17, weight: .semibold)).foregroundStyle(N.text)
            }
            Text("Starts an agent in your terminal with this prompt. Lookout keeps track of it in Sessions.")
                .font(NFont.small).foregroundStyle(N.text2).padding(.top, 4)

            VStack(alignment: .leading, spacing: 14) {
                row("Repository") { repoPicker }
                row("Agent") { agentPicker }
                promptField
                row("Where") { placePicker }
                row("Terminal") { terminalPicker }
            }
            .padding(.top, 18)

            preview.padding(.top, 16)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(NFont.small).foregroundStyle(N.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            HStack {
                if coordinator.launching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Start task") { start() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canStart)
                    .help("⌘↩")
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 580)
        .background(N.bg)
        .onAppear(perform: setUp)
        .onChange(of: repoRoot) { _, _ in repoChanged() }
        .onChange(of: coordinator.installed) { _, _ in pickAgent() }
        .sheet(isPresented: $editingTemplates) { AgentTemplatesEditor(tasks: tasks) }
    }

    // MARK: Fields

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2).frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var repoPicker: some View {
        Group {
            if repoList.isEmpty {
                Text(repos.isScanning ? "Looking for repositories…" : "No repositories found. Add folders in Settings › Repos.")
                    .font(NFont.small).foregroundStyle(N.text2)
            } else {
                Menu {
                    ForEach(repoList) { r in
                        Button { repoRoot = r.root } label: { Text("\(r.name)  ·  \(r.displayPath)") }
                    }
                } label: {
                    menuLabel(repo.map { "\($0.name)  ·  \($0.displayPath)" } ?? "Choose a repository")
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
        }
    }

    @ViewBuilder private var agentPicker: some View {
        if coordinator.installed == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Looking for agent CLIs…").font(NFont.small).foregroundStyle(N.text2)
            }
        } else if available.isEmpty {
            Text("No agent CLI found. Install Claude Code, Codex, OpenCode, Cursor Agent, Copilot CLI or Pi, then reopen this sheet.")
                .font(NFont.small).foregroundStyle(N.text2).fixedSize(horizontal: false, vertical: true)
        } else {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(available) { option in
                    Button { cli = option } label: {
                        HStack(spacing: 6) {
                            AgentIconView(agent: option.agent, size: 14)
                            Text(option.name).font(NFont.small)
                            if cli == option { Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)) }
                        }
                    }
                    .buttonStyle(AgentChoiceStyle(selected: cli == option))
                    .help(coordinator.installed?[option] ?? "")
                    .accessibilityAddTraits(cli == option ? .isSelected : [])
                }
            }
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Prompt").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
                Spacer()
                Menu {
                    ForEach(tasks.templates) { template in
                        Button(template.title) { prompt = template.expanded(repo: repo?.name ?? "the repository", branch: branchForTemplates) }
                    }
                    Divider()
                    Button("Save Prompt as Template") { tasks.saveTemplate(title: String(trimmedPrompt.split(separator: "\n").first ?? ""), prompt: prompt) }
                        .disabled(trimmedPrompt.isEmpty)
                    Button("Edit Templates…") { editingTemplates = true }
                } label: {
                    Label("Templates", systemImage: "text.badge.star").font(NFont.small)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .focused($promptFocused)
                if prompt.isEmpty {
                    Text("What should the agent do?").font(.system(size: 13)).foregroundStyle(N.text3)
                        .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
            .frame(height: 120)
            .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: N.radius, style: .continuous).strokeBorder(N.divider))
        }
    }

    @ViewBuilder private var placePicker: some View {
        Picker("", selection: $useWorktree) {
            Text("New worktree").tag(true)
            Text("Existing checkout").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        if useWorktree {
            HStack(spacing: 6) {
                Text("from").font(NFont.small).foregroundStyle(N.text2)
                Menu {
                    ForEach(branches, id: \.self) { b in Button(b) { base = b } }
                } label: { menuLabel(base.isEmpty ? "Choose a branch" : base) }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .disabled(branches.isEmpty)
            }
            if let plan = worktreePlan {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow {
                        Text("Branch").foregroundStyle(N.text3)
                        Text(plan.branch).font(NFont.monoSmall).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Folder").foregroundStyle(N.text3)
                        Text(abbreviate(plan.path)).font(NFont.monoSmall).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                .font(NFont.caption).foregroundStyle(N.text2)
            }
        } else {
            Menu {
                ForEach(checkouts, id: \.path) { c in Button(c.label) { checkout = c.path } }
            } label: { menuLabel(checkouts.first { $0.path == checkout }?.label ?? "Choose a checkout") }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            if let warning = checkoutWarning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(NFont.caption).foregroundStyle(TagColor.orange.fg).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var terminalPicker: some View {
        Menu {
            ForEach(coordinator.terminals) { t in
                Button { tasks.settings.terminal = t } label: { Text(t.name) }
            }
        } label: { menuLabel(coordinator.terminal.name) }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help(coordinator.terminal == .iTerm ? "iTerm2 is opened through AppleScript; macOS asks once for permission"
              : coordinator.terminal == .warp ? "Warp opens through a launch configuration in ~/.warp/launch_configurations" : "")
    }

    /// The command, exactly as it will run, so nothing about the launch is a surprise.
    @ViewBuilder private var preview: some View {
        if let cli, !trimmedPrompt.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Runs").font(.system(size: 11, weight: .medium)).foregroundStyle(N.text3)
                Text(AgentTaskScript.preview(cli, prompt: prompt))
                    .font(NFont.monoSmall).foregroundStyle(N.text2)
                    .lineLimit(3).truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
        }
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text(text).lineLimit(1).truncationMode(.middle).foregroundStyle(N.text)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(N.text2)
        }
        .font(NFont.small)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .frame(maxWidth: 400, alignment: .leading)
        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: N.radius, style: .continuous).strokeBorder(N.divider))
    }

    // MARK: Derived

    private var worktreePlan: AgentTaskGit.Worktree? {
        guard let repo, !trimmedPrompt.isEmpty else { return nil }
        return AgentTaskGit.plan(root: repo.root, prompt: trimmedPrompt, branches: branches)
    }

    private var branchForTemplates: String? {
        if useWorktree { return base.isEmpty ? nil : base }
        return GitCheckout.locate(checkout)?.branch
    }

    private var checkoutWarning: String? {
        guard let repo else { return nil }
        let changes = checkout == repo.root ? repo.changes : repo.worktrees.first { $0.path == checkout }?.changes
        guard let changes, !changes.isClean else { return nil }
        return "\(changes.summary) here. The agent will work alongside these changes."
    }

    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    // MARK: Actions

    private func setUp() {
        prompt = draft.prompt
        // An explicit checkout or base decides; otherwise whatever you chose last time.
        useWorktree = draft.checkout == nil && (draft.base != nil || tasks.settings.useWorktree)
        if let c = draft.checkout { checkout = c }
        if let b = draft.base { base = b }
        repoRoot = draft.repoRoot ?? repos.selected?.root ?? repoList.first?.root ?? ""
        pickAgent()
        repoChanged()
        promptFocused = true
    }

    private func pickAgent() {
        guard cli == nil || !available.contains(cli!) else { return }
        cli = tasks.settings.lastCLI.flatMap { available.contains($0) ? $0 : nil } ?? available.first
    }

    private func repoChanged() {
        error = nil
        guard let repo else { branches = []; return }
        if !checkouts.contains(where: { $0.path == checkout }) { checkout = repo.root }
        let root = repo.root, defaultBranch = repo.defaultBranch, wanted = base
        Task {
            var list = await Task.detached(priority: .userInitiated) { AgentTaskGit.localBranches(root, defaultBranch: defaultBranch) }.value
            guard root == repoRoot else { return }
            // A branch that only exists on the remote (a CI run's, say) starts from its remote-tracking ref.
            if !wanted.isEmpty, !list.isEmpty, !list.contains(wanted) {
                let remote = wanted.hasPrefix("origin/") ? wanted : "origin/\(wanted)"
                list.insert(remote, at: 0)
                base = remote
            }
            // If the branches couldn't be listed, the default branch is still the likely start; making the worktree
            // reports it if not.
            if list.isEmpty, let fallback = defaultBranch ?? repo.branch { list = [fallback] }
            branches = list
            if base.isEmpty || !list.contains(base) { base = list.first ?? "" }
        }
    }

    private func start() {
        guard let repo, let cli, canStart else { return }
        error = nil
        coordinator.launch(repo: repo, cli: cli, prompt: trimmedPrompt, worktreeBase: useWorktree ? base : nil, checkout: checkout) { failure in
            if let failure { error = failure } else { dismiss() }
        }
    }
}

private struct AgentChoiceStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? N.text : N.text2)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(selected ? N.selected : (configuration.isPressed ? N.pressed : N.bgSoft),
                        in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: N.radius, style: .continuous).strokeBorder(selected ? N.blue.opacity(0.6) : N.divider))
    }
}

// MARK: - Templates

/// Rename, rewrite or remove saved prompts. `{repo}` and `{branch}` fill in when one is used.
struct AgentTemplatesEditor: View {
    @ObservedObject var tasks: AgentTaskStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt templates").font(.system(size: 17, weight: .semibold)).foregroundStyle(N.text)
            Text("{repo} and {branch} are filled in when you use a template.").font(NFont.small).foregroundStyle(N.text2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($tasks.templates) { $template in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Title", text: $template.title).textFieldStyle(.plain).font(NFont.bodyMedium)
                                IconButton(symbol: "trash", help: "Delete template", tint: N.red) { tasks.deleteTemplate(template.id) }
                            }
                            TextEditor(text: $template.prompt)
                                .font(.system(size: 12.5))
                                .scrollContentBackground(.hidden)
                                .frame(height: 64)
                        }
                        .padding(10)
                        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
                    }
                }
            }
            .frame(height: 340)
            HStack {
                Button("Add template") { tasks.saveTemplate(title: "New template", prompt: "") }.buttonStyle(SecondaryButtonStyle())
                Button("Restore defaults") { tasks.resetTemplates() }.buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(N.bg)
    }
}

// MARK: - Sessions

/// "From Lookout" on a session row, for sessions started with the New agent task sheet.
struct LaunchedTaskTag: View {
    var session: AgentSession
    @ObservedObject private var tasks = AgentTaskStore.shared

    var body: some View {
        if let task = tasks.task(for: session) {
            Tag(text: "From Lookout", color: .blue, symbol: "paperplane")
                .help("Started from Lookout \(AgentFormat.ago(task.launchedAt)): \(task.summary)")
        }
    }
}

/// The inspector's account of a task started from Lookout: when, where, and the prompt it was given.
struct LaunchedTaskSection: View {
    var session: AgentSession
    @ObservedObject private var tasks = AgentTaskStore.shared

    var body: some View {
        if let task = tasks.task(for: session) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Started from Lookout").font(NFont.bodyMedium).foregroundStyle(N.text).padding(.bottom, 4)
                PropertyRow(symbol: "paperplane", label: "Launched") {
                    Text("\(AgentFormat.dateTime(task.launchedAt)) in \(task.terminal.name)")
                }
                PropertyRow(symbol: task.isWorktree ? "square.stack.3d.down.right" : "folder", label: task.isWorktree ? "New worktree" : "Checkout") {
                    Text(verbatim: (task.branch ?? "detached") + (task.baseBranch.map { " from \($0)" } ?? ""))
                }
                Text(task.prompt)
                    .font(NFont.small).foregroundStyle(N.text2)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
                    .padding(.top, 4)
            }
        }
    }
}
