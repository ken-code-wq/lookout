import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LaunchersPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: "play.square.stack", title: "Launchers", subtitle: AnyView(
                Text("Saved start commands. Drag to reorder, or drop a project folder anywhere to add one.")
                    .font(NFont.small).foregroundStyle(N.text2)
            ))
            .padding(.horizontal, 44)

            HStack {
                Text("\(state.managed.count) saved · \(state.managed.filter { state.isRunning($0) }.count) running")
                    .font(NFont.small).foregroundStyle(N.text2)
                Spacer()
                Button("New launcher") { state.draft = LauncherDraft() }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 44)
            .padding(.bottom, 8)
            Rectangle().fill(N.divider).frame(height: 1).padding(.horizontal, 44)
            let groups = LauncherGroup.groups(state.managed)
            let clashes = launcherPortClashes(state.managed)
            if !groups.isEmpty || !clashes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups) { group in
                        let running = group.launchers.filter { state.isRunning($0) }.count
                        HStack(spacing: 10) {
                            FolderIconView(folder: group.root, name: group.name, size: 18)
                            Text(group.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                            Text("\(group.launchers.count) launchers · \(running) running").font(NFont.small).foregroundStyle(N.text2)
                            Spacer()
                            if running < group.launchers.count {
                                Button { state.startAll(group) } label: { Label("Start all", systemImage: "play.fill") }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                            if running > 0 {
                                Button { state.stopAll(group) } label: { Label("Stop all", systemImage: "stop.fill") }
                                    .buttonStyle(SecondaryButtonStyle(tint: N.red))
                            }
                        }
                        .help(group.launchers.map(\.name).joined(separator: ", "))
                    }
                    ForEach(clashes.keys.sorted(), id: \.self) { port in
                        Label("\(clashes[port]!.map(\.name).joined(separator: " and ")) both use port \(port); only one can run at a time.",
                              systemImage: "exclamationmark.triangle")
                            .font(NFont.small).foregroundStyle(TagColor.orange.fg)
                    }
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 10)
            }

            if state.managed.isEmpty {
                EmptyStateView(symbol: "folder.badge.plus", title: "No launchers yet",
                               message: "A launcher remembers a folder and its start command, so you can bring a server up with one click — from here or the menu bar.") {
                    Button("Choose a folder…") { chooseFolder() }.buttonStyle(PrimaryButtonStyle())
                }
                Spacer()
            } else {
                List {
                    ForEach(state.managed) { launcher in
                        LauncherRow(state: state, launcher: launcher)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 36, bottom: 1, trailing: 36))
                    }
                    .onMove { state.moveLaunchers(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { state.draftLauncher(folder: url.path) }
    }
}

private struct LauncherRow: View {
    @ObservedObject var state: AppState
    var launcher: ManagedServer
    @State private var hover = false

    var body: some View {
        let live = state.server(for: launcher)
        let running = state.isRunning(launcher)
        HStack(spacing: 12) {
            FolderIconView(folder: launcher.workingDirectory, name: launcher.name, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(launcher.name).font(NFont.bodyMedium).foregroundStyle(N.text)
                    if let live {
                        Tag(text: ":\(live.port)", mono: true)
                        StatusTag(server: live)
                    } else if running {
                        Tag(text: "Starting…", color: .yellow)
                    }
                    LauncherHealthTag(launcher: launcher)
                }
                HStack(spacing: 6) {
                    Text(launcher.command).font(NFont.monoSmall).foregroundStyle(N.text2)
                    Text("·").foregroundStyle(N.text3)
                    Text(launcher.workingDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(NFont.caption).foregroundStyle(N.text3).truncationMode(.middle)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 12)

            HStack(spacing: 4) {
                if running {
                    if let live, live.isResponding {
                        IconButton(symbol: "arrow.up.right.square", help: "Open in browser") { state.open(live) }
                    }
                    IconButton(symbol: "arrow.clockwise", help: "Restart") { state.restart(launcher) }
                    Button { state.stop(launcher) } label: {
                        Label("Stop", systemImage: "stop.fill").labelStyle(TightLabelStyle())
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: N.red))
                } else {
                    Button { state.start(launcher) } label: {
                        Label("Start", systemImage: "play.fill").labelStyle(TightLabelStyle())
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                LauncherLogsButton(state: state, launcher: launcher)
                Menu {
                    LauncherMenu(state: state, launcher: launcher)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 20, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(N.text2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture(count: 2) { state.edit(launcher) }
        .contextMenu { LauncherMenu(state: state, launcher: launcher) }
    }
}

// MARK: - New / edit sheet

struct LauncherSheet: View {
    @ObservedObject var state: AppState
    @State var draft: LauncherDraft
    @Environment(\.dismiss) private var dismiss
    @State private var dropTargeted = false
    @FocusState private var focus: Field?

    enum Field { case name, command, port }

    private var suggestions: [CommandSuggester.Suggestion] { CommandSuggester.suggestions(for: draft.folder) }
    private var folderError: String? {
        guard !draft.folder.isEmpty else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: draft.folder, isDirectory: &isDir) && isDir.boolValue ? nil : "This folder doesn’t exist."
    }
    private var portError: String? {
        guard !draft.port.isEmpty else { return nil }
        guard let p = Int(draft.port), (1...65535).contains(p) else { return "Use a number between 1 and 65535." }
        if let owner = state.servers.first(where: { $0.port == p && $0.managedID != draft.editingID }) {
            return "Already used by \(owner.projectName)."
        }
        return nil
    }
    private var canSave: Bool {
        !draft.command.trimmingCharacters(in: .whitespaces).isEmpty && folderError == nil && (portError == nil || !draft.startNow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.editingID == nil ? "New server" : "Edit launcher")
                .font(NFont.title).foregroundStyle(N.text)
            Text("Pick a project folder and the command that starts it.")
                .font(NFont.small).foregroundStyle(N.text2)
                .padding(.top, 4)

            folderPicker.padding(.top, 18)

            VStack(alignment: .leading, spacing: 14) {
                field("Name", error: nil) {
                    TextField("my-app", text: $draft.name).focused($focus, equals: .name)
                }
                field("Command", error: nil) {
                    TextField("npm run dev", text: $draft.command)
                        .font(NFont.mono)
                        .focused($focus, equals: .command)
                }
                if !suggestions.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(N.text3)
                        ForEach(suggestions) { s in
                            Button { draft.command = s.command } label: {
                                Text(s.command).font(NFont.monoSmall)
                            }
                            .buttonStyle(ChipStyle(active: draft.command == s.command))
                        }
                    }
                    .padding(.top, -6)
                }
                field("Port", hint: "Optional — exported as $PORT", error: portError) {
                    TextField("3000", text: $draft.port).font(NFont.mono).focused($focus, equals: .port)
                }
            }
            .padding(.top, 18)

            Toggle("Start it now", isOn: $draft.startNow)
                .toggleStyle(.checkbox)
                .font(NFont.small)
                .foregroundStyle(N.text)
                .padding(.top, 16)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(draft.startNow ? "Save & start" : "Save") {
                    state.save(draft)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.top, 22)
        }
        .padding(24)
        .frame(width: 500)
        .background(N.bg)
        .onAppear { focus = draft.folder.isEmpty ? nil : (draft.command.isEmpty ? .command : .name) }
    }

    private var folderPicker: some View {
        Button(action: chooseFolder) {
            HStack(spacing: 12) {
                if draft.folder.isEmpty {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 18)).foregroundStyle(dropTargeted ? N.blue : N.text2)
                        .frame(width: 32, height: 32)
                } else {
                    FolderIconView(folder: draft.folder, name: draft.name.isEmpty ? draft.folder : draft.name, size: 32)
                        .id(draft.folder)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.folder.isEmpty ? "Drop a project folder, or click to choose" :
                            draft.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(NFont.small).foregroundStyle(N.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(folderError ?? CommandSuggester.projectKind(draft.folder) ?? (draft.folder.isEmpty ? "Optional — commands run from your home folder otherwise" : "Folder"))
                        .font(NFont.caption).foregroundStyle(folderError == nil ? N.text2 : N.red)
                }
                Spacer()
                if !draft.folder.isEmpty {
                    Text("Change").font(NFont.small).foregroundStyle(N.text2)
                }
            }
            .padding(12)
            .background(dropTargeted ? N.blue.opacity(0.06) : N.bgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(dropTargeted ? N.blue : N.divider, style: StrokeStyle(lineWidth: 1, dash: draft.folder.isEmpty ? [5, 4] : []))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.hasDirectoryPath) else { return false }
            use(folder: url.path)
            return true
        } isTargeted: { t in withAnimation(.easeOut(duration: 0.12)) { dropTargeted = t } }
    }

    private func field<F: View>(_ label: String, hint: String? = nil, error: String?, @ViewBuilder _ content: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2)
                if let hint { Text(hint).font(NFont.caption).foregroundStyle(N.text3) }
            }
            content()
                .textFieldStyle(.plain)
                .font(NFont.body)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: N.radius, style: .continuous)
                    .strokeBorder(error == nil ? N.divider : N.red.opacity(0.6)))
            if let error { Text(error).font(NFont.caption).foregroundStyle(N.red) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { use(folder: url.path) }
    }

    private func use(folder: String) {
        let previousName = (draft.folder as NSString).lastPathComponent
        let previousSuggestions = suggestions.map(\.command)
        draft.folder = folder
        if draft.name.isEmpty || draft.name == previousName { draft.name = (folder as NSString).lastPathComponent }
        // Only replace the command if the user hasn't typed their own.
        if draft.command.isEmpty || previousSuggestions.contains(draft.command) {
            draft.command = CommandSuggester.suggestions(for: folder).first?.command ?? draft.command
        }
    }
}

private struct ChipStyle: ButtonStyle {
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? N.blue : N.text2)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(active ? N.selected : (configuration.isPressed ? N.pressed : N.hover),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
