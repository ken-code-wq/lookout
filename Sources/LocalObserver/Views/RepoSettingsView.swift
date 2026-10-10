import SwiftUI
import AppKit
import LocalObserverRepos

/// Settings › Repos: where to look for repositories, GitHub, and which pull request changes to hear about.
struct RepoSettingsPane: View {
    @ObservedObject var store: RepoStore = .shared

    var body: some View {
        SettingsPage(title: "Repos", message: "Lookout finds git repositories in your code folders and reads their state with git, read-only. Pull requests and checks come from the GitHub CLI's sign-in; your token never passes through Lookout.") {
            SettingsHeader("Code folders", first: true)
            SettingsGroup {
                let roots = store.settings.effectiveRoots
                if roots.isEmpty {
                    Text("No folders yet. Add the ones where you keep code.")
                        .font(NFont.small).foregroundStyle(N.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                }
                ForEach(Array(roots.enumerated()), id: \.element) { index, root in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(N.text2).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((root as NSString).lastPathComponent).font(NFont.body).foregroundStyle(N.text)
                            Text((root as NSString).abbreviatingWithTildeInPath).font(NFont.caption).foregroundStyle(N.text3)
                        }
                        Spacer(minLength: 12)
                        let count = store.repos.filter { $0.root.hasPrefix(root + "/") || $0.root == root }.count
                        Tag(text: "\(count) repo\(count == 1 ? "" : "s")", color: count > 0 ? .blue : .gray)
                        IconButton(symbol: "minus.circle", help: "Stop looking here") {
                            store.settings.roots = roots.filter { $0 != root }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: 52)
                }
            }
            HStack(spacing: 8) {
                Button("Add Folder…", action: addFolder).buttonStyle(SecondaryButtonStyle())
                if store.settings.roots != nil {
                    Button("Use Defaults") { store.settings.roots = nil }.buttonStyle(GhostButtonStyle())
                }
                Spacer()
                Picker("Depth", selection: $store.settings.depth) {
                    ForEach(1...6, id: \.self) { Text("\($0) level\($0 == 1 ? "" : "s") deep").tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("How many folders down to look for repositories under each code folder")
            }
            .padding(.top, 8)
            SettingsFootnote("Worktrees are found through their repository, wherever they live (T3 Code, Qoder, Codex…).")

            SettingsHeader("GitHub")
            SettingsGroup {
                SettingsRow(title: "Pull requests and checks", detail: gitHubDetail) {
                    Toggle("Pull requests and checks", isOn: $store.settings.gitHubEnabled).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsHeader("Notify me when")
            SettingsGroup {
                SettingsRow(title: "Checks fail on my pull request", detail: "Opens the failing checks when clicked") {
                    Toggle("", isOn: $store.settings.notifyChecksFailed).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Checks pass on my pull request", detail: "Only after they were running, not on every refresh") {
                    Toggle("", isOn: $store.settings.notifyChecksPassed).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "My pull request is reviewed", detail: "Approved, or changes requested") {
                    Toggle("", isOn: $store.settings.notifyApproved).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Someone asks for my review", detail: "Once per pull request") {
                    Toggle("", isOn: $store.settings.notifyReviewRequested).toggleStyle(.switch).labelsHidden()
                }
            }
            .disabled(!store.settings.gitHubEnabled)

            SettingsHeader("Forgotten work")
            SettingsGroup {
                SettingsRow(title: "Untouched for", detail: "Uncommitted or unpushed work this old shows under Forgotten") {
                    Picker("Untouched for", selection: $store.settings.forgottenDays) {
                        ForEach([3, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            if !store.settings.hidden.isEmpty {
                SettingsHeader("Hidden repositories")
                SettingsGroup {
                    ForEach(Array(store.settings.hidden.enumerated()), id: \.element) { index, root in
                        if index > 0 { SettingsDivider() }
                        HStack {
                            Text((root as NSString).abbreviatingWithTildeInPath).font(NFont.small).foregroundStyle(N.text)
                            Spacer()
                            Button("Show") { store.settings.hidden.removeAll { $0 == root } }.buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(minHeight: 44)
                    }
                }
            }
        }
    }

    private var gitHubDetail: String {
        switch store.gitHub {
        case .ok(let login): return "Signed in as \(login) through the GitHub CLI"
        case .missingCLI: return "Install the GitHub CLI (brew install gh), then run gh auth login"
        case .signedOut: return "Run gh auth login in a terminal to sign in"
        case .error(let message): return message
        case .off: return "Off. Repositories still show their local state."
        case .unknown: return "Checking the GitHub CLI…"
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders that contain your repositories"
        guard panel.runModal() == .OK else { return }
        var roots = store.settings.effectiveRoots
        for url in panel.urls where !roots.contains(url.path) { roots.append(url.path) }
        store.settings.roots = roots
    }
}
