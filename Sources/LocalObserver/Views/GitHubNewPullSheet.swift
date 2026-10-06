import SwiftUI
import LocalObserverRepos

/// Open a pull request without leaving Lookout: pick base and head, see the commits it would bring, write a title
/// and description (filled in from those commits), optionally as a draft.
struct GHNewPullSheet: View {
    @ObservedObject var store: GitHubStore
    @ObservedObject var repos: RepoStore
    var draft: GitHubStore.PullDraft
    @Environment(\.dismiss) private var dismiss

    @State private var base = ""
    @State private var head = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var isDraft = false
    @State private var comparison: GHComparison?
    @State private var comparing = false
    @State private var edited = false

    private var branches: [String] { store.branches[draft.slug]?.map(\.name) ?? [] }
    private var busy: Bool { store.working.contains("new-pull:\(draft.slug)") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(GH.open)
                Text("Open a pull request").font(.system(size: 17, weight: .semibold))
                Text(draft.slug).font(NFont.small).foregroundStyle(N.text2)
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(N.text2)
                picker("base", $base)
                Image(systemName: "arrow.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(N.text3)
                picker("compare", $head)
                Spacer()
                if comparing { ProgressView().controlSize(.small) }
            }
            if let c = comparison {
                HStack(spacing: 6) {
                    Image(systemName: c.aheadBy > 0 ? "checkmark" : "exclamationmark.triangle")
                        .foregroundStyle(c.aheadBy > 0 ? GH.open : GH.attention)
                    Text(c.aheadBy > 0 ? "\(c.aheadBy) commit\(c.aheadBy == 1 ? "" : "s"), \(c.files) file\(c.files == 1 ? "" : "s") changed"
                         : "\(head) has nothing \(base) doesn't already have.")
                        .font(NFont.small).foregroundStyle(N.text2)
                }
            }
            TextField("Title", text: $title, onEditingChanged: { if $0 { edited = true } })
                .textFieldStyle(.roundedBorder).font(.system(size: 14))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $bodyText).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6)
                if bodyText.isEmpty {
                    Text("Describe the change… Markdown works.").font(.system(size: 13)).foregroundStyle(N.text3)
                        .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
            .frame(minHeight: 160)
            .background(GH.canvasSubtle, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
            HStack {
                Toggle("Create as draft", isOn: $isDraft).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(isDraft ? "Create draft pull request" : "Create pull request") {
                    store.createPull(draft.slug, base: base, head: head, title: title, body: bodyText, draft: isDraft) { ok in
                        if ok { dismiss() }
                    }
                }
                .buttonStyle(GHPrimaryButtonStyle())
                .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty || base == head || head.isEmpty || comparison?.aheadBy == 0)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: setUp)
        .onChange(of: branches) { _, _ in setUp() }
        .task(id: "\(base)…\(head)") { await compare() }
    }

    private func picker(_ label: String, _ selection: Binding<String>) -> some View {
        Menu {
            ForEach(branches, id: \.self) { name in Button(name) { selection.wrappedValue = name } }
        } label: {
            HStack(spacing: 4) {
                Text("\(label):").foregroundStyle(N.text2)
                Text(selection.wrappedValue.isEmpty ? "choose" : selection.wrappedValue).fontWeight(.semibold).foregroundStyle(N.text)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(N.text2)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10).frame(height: 28)
            .background(GH.canvasSubtle, in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(GH.border))
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
    }

    /// Base: the default branch. Head: the one asked for, else the branch checked out here, else the newest other branch.
    private func setUp() {
        store.loadBranches(draft.slug)
        if base.isEmpty { base = store.defaultBranch(draft.slug) }
        guard head.isEmpty else { return }
        if let h = draft.head { head = h; return }
        if let local = repos.localRepo(slug: draft.slug), let b = local.branch, b != base { head = b; return }
        head = store.branches[draft.slug]?.first { !$0.isDefault && $0.pull?.state.isOpen != true }?.name ?? ""
    }

    private func compare() async {
        guard !base.isEmpty, !head.isEmpty, base != head else { comparison = nil; return }
        comparing = true
        let slug = draft.slug, b = base, h = head
        let result = await Task.detached(priority: .userInitiated) { GitHubAPI.compare(slug, base: b, head: h) }.value
        comparing = false
        guard case .success(let c) = result else { comparison = nil; return }
        comparison = c
        // Fill in until the user starts writing their own.
        if !edited {
            title = c.suggestedTitle(head: h)
            bodyText = c.suggestedBody
        }
    }
}
