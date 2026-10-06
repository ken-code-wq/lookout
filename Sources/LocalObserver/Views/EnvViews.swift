import SwiftUI
import AppKit
import LocalObserverEnv

/// A project's env files in an inspector: every key with where it comes from and its effective value (masked; a
/// reveal shows only its shape), keys the template expects that nothing sets, and files git could leak.
/// Read-only: Lookout never edits an env file.
struct EnvSection: View {
    var folder: String
    @ObservedObject var store: EnvStore = .shared
    @State private var revealed: Set<String> = []
    @State private var showAll = false
    @State private var copied: String?

    init(folder: String) { self.folder = folder }

    /// The folder a server was started from: its project root when one was found.
    init(server: ServerEntry) {
        let path = server.projectRoot.isEmpty ? server.workingDirectory : server.projectRoot
        folder = path == "/" || path == NSHomeDirectory() ? "" : path
    }

    var body: some View {
        Group {
            if let report = store.report(folder), !report.isEmpty {
                content(report).padding(.top, 20)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .onAppear { store.load(folder) }
        .onChange(of: folder) { _, new in store.load(new) }
    }

    private func content(_ report: EnvReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(report)
            if !report.missing.isEmpty { missing(report) }
            ForEach(report.warnings.filter { $0.kind != .parse }) { warning($0) }
            files(report)
            keys(report)
            ForEach(report.warnings.filter { $0.kind == .parse }) { warning($0) }
            Text(precedenceNote(report)).font(NFont.caption).foregroundStyle(N.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Header

    private func header(_ report: EnvReport) -> some View {
        HStack(spacing: 8) {
            Text("Environment").font(.system(size: 12, weight: .medium)).foregroundStyle(N.text2).fixedSize()
            EnvMissingBadge(folder: folder, store: store)
            if let copied { Text(copied).font(NFont.caption).foregroundStyle(TagColor.green.fg).transition(.opacity) }
            Spacer()
            Menu {
                Picker("Mode", selection: $store.mode) {
                    ForEach(EnvResolver.modes(in: report.files), id: \.self) { Text($0).tag($0) }
                }
                Picker("Order", selection: $store.convention) {
                    ForEach(EnvConvention.allCases) { Text("\($0.rawValue) order").tag($0) }
                }
            } label: {
                Text(report.mode).font(NFont.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which mode's files load, and which framework's precedence to follow")
            IconButton(symbol: revealed.isEmpty ? "eye" : "eye.slash",
                       help: revealed.isEmpty ? "Show every value's shape (never the value)" : "Hide values", size: 22) {
                revealed = revealed.isEmpty ? Set(report.keys.map(\.key)) : []
            }
            IconButton(symbol: "arrow.clockwise", help: "Read the files again", size: 22) { store.load(folder, age: 0) }
        }
    }

    // MARK: Missing and warnings

    private func missing(_ report: EnvReport) -> some View {
        let template = report.files.first { $0.role.isTemplate }?.name ?? ".env.example"
        return VStack(alignment: .leading, spacing: 6) {
            Label(report.hasRealFiles
                  ? "\(report.missing.count) key\(report.missing.count == 1 ? "" : "s") from \(template) \(report.missing.count == 1 ? "isn't" : "aren't") set in any env file"
                  : "No env file yet: none of the \(report.missing.count) keys in \(template) are set",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(TagColor.orange.fg)
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(report.missing) { key in
                    Button { copy(key.key, "Copied \(key.key)") } label: {
                        Text(key.key).font(NFont.monoSmall).foregroundStyle(N.text)
                            .padding(.horizontal, 6).frame(height: 20)
                            .background(N.bg, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Copy the key name")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TagColor.orange.bg, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
    }

    private func warning(_ w: EnvWarning) -> some View {
        let tone: TagColor = w.kind == .tracked ? .red : (w.kind == .parse ? .gray : .orange)
        let symbol = switch w.kind {
        case .tracked: "exclamationmark.octagon.fill"
        case .notIgnored: "eye.trianglebadge.exclamationmark"
        case .secretInTemplate: "key.fill"
        case .parse: "text.badge.xmark"
        }
        return Label(w.message, systemImage: symbol)
            .font(NFont.caption)
            .foregroundStyle(w.kind == .parse ? N.text2 : tone.fg)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Files

    private func files(_ report: EnvReport) -> some View {
        let order = report.convention.order(mode: report.mode)
        return FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(report.files) { file in
                let rank = order.firstIndex(of: file.role)
                Button { ProcessManager.openInEditor(path: file.path) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: file.role.isTemplate ? "doc.text" : (rank != nil ? "doc.fill" : "doc"))
                            .font(.system(size: 10))
                        Text(file.name).font(NFont.monoSmall)
                        Text("\(file.parsed.keys.count)").font(NFont.caption).foregroundStyle(N.text3)
                        if file.gitWarning == .tracked { Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 9.5)).foregroundStyle(TagColor.red.fg) }
                        else if file.gitWarning == .notIgnored { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(TagColor.orange.fg) }
                    }
                    .foregroundStyle(rank != nil || file.role.isTemplate ? N.text : N.text3)
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(N.bgSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(fileHelp(file, rank: rank))
            }
        }
    }

    private func fileHelp(_ file: EnvFileInfo, rank: Int?) -> String {
        var parts = ["Open \(file.name) in your editor"]
        if file.role.isTemplate { parts.append("Template: lists the keys the project expects") }
        else if let rank { parts.append("Loads in \(file.role == .base ? "every mode" : "this mode"), precedence \(rank + 1)") }
        else { parts.append("Doesn't load in this mode") }
        switch file.tracked {
        case true?: parts.append("Committed to git")
        case false?: parts.append(file.ignored == true ? "Ignored by git" : "Not ignored by git")
        case nil: parts.append("Not in a git repository")
        }
        return parts.joined(separator: ". ")
    }

    // MARK: Keys

    private func keys(_ report: EnvReport) -> some View {
        let list = report.keys
        let shown = showAll ? list : Array(list.prefix(14))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { key in keyRow(key, report: report) }
            if list.count > shown.count {
                Button("Show all \(list.count) keys") { showAll = true }.buttonStyle(GhostButtonStyle(tint: N.blue)).padding(.top, 4)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(N.bgSoft, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
    }

    private func keyRow(_ key: EnvKey, report: EnvReport) -> some View {
        let isRevealed = revealed.contains(key.key)
        let value = key.effective?.entry.value
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(key.key).font(NFont.monoSmall).foregroundStyle(key.status == .missing ? TagColor.orange.fg : N.text)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    statusTag(key, report: report)
                }
                HStack(spacing: 5) {
                    if let source = key.effective {
                        Text(source.file).foregroundStyle(N.text2)
                        if key.sources.count > 1 {
                            Text("overrides \(key.sources.dropFirst().map(\.file).joined(separator: ", "))").foregroundStyle(N.text3).lineLimit(1)
                        }
                    } else if !key.inactiveFiles.isEmpty {
                        Text("only in \(key.inactiveFiles.joined(separator: ", "))").foregroundStyle(N.text3)
                    }
                    if let refs = key.effective?.entry.references, !refs.isEmpty {
                        Text("uses \(refs.map { "${\($0)}" }.joined(separator: " "))").foregroundStyle(N.text3).lineLimit(1)
                            .help("Interpolated by dotenv-expand when the app loads; shown, not expanded")
                    }
                }
                .font(NFont.caption)
            }
            Spacer(minLength: 6)
            if let value {
                Text(isRevealed ? EnvMask.shape(value) : EnvMask.hidden)
                    .font(NFont.monoSmall).foregroundStyle(N.text2).lineLimit(1)
                    .help(isRevealed ? "Shape only: the prefix and length. Copy value puts the real value on the clipboard." : "Hidden")
                IconButton(symbol: isRevealed ? "eye.slash" : "eye", help: isRevealed ? "Hide" : "Show shape", size: 20) {
                    if isRevealed { revealed.remove(key.key) } else { revealed.insert(key.key) }
                }
            }
            Menu {
                Button("Copy Key Name") { copy(key.key, "Copied \(key.key)") }
                if let value { Button("Copy Value") { copy(value, "Copied value of \(key.key)") } }
                if let source = key.effective, let file = report.files.first(where: { $0.name == source.file }) {
                    Button("Open \(file.name)") { ProcessManager.openInEditor(path: file.path) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(N.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Copy Key Name") { copy(key.key, "Copied \(key.key)") }
            if let value { Button("Copy Value") { copy(value, "Copied value of \(key.key)") } }
        }
    }

    @ViewBuilder private func statusTag(_ key: EnvKey, report: EnvReport) -> some View {
        switch key.status {
        case .missing: Tag(text: "Missing", color: .orange, symbol: "exclamationmark.triangle")
        case .empty: Tag(text: "Empty", color: .gray)
        case .otherModeOnly: Tag(text: "Not in \(report.mode)", color: .gray)
        case .set: EmptyView()
        }
        if key.isExtra { Tag(text: "Not in template", color: .gray).help("Set here, but the template doesn't list it") }
        if key.dependsOnConvention {
            Tag(text: "Order-dependent", color: .yellow, symbol: "arrow.up.arrow.down")
                .help("Set in both .env.local and .env.\(report.mode): Next.js and Vite pick different ones")
        }
    }

    private func precedenceNote(_ report: EnvReport) -> String {
        let order = report.convention.order(mode: report.mode).map { role -> String in
            switch role {
            case .base: return ".env"
            case .local: return ".env.local"
            case .mode(let m): return ".env.\(m)"
            case .modeLocal(let m): return ".env.\(m).local"
            default: return ""
            }
        }
        return "\(report.convention.rawValue) order for \(report.mode): \(order.joined(separator: " › ")). Variables already set in the shell win over every file."
    }

    private func copy(_ text: String, _ note: String) {
        RepoActions.copy(text)
        withAnimation(.easeOut(duration: 0.15)) { copied = note }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation(.easeOut(duration: 0.2)) { if copied == note { copied = nil } } }
    }
}

/// "3 env keys missing": template keys nothing sets. Shows nothing when there are none.
struct EnvMissingBadge: View {
    var folder: String
    @ObservedObject var store: EnvStore = .shared
    /// "3 env keys missing" on its own; "3 missing" next to the Environment heading.
    var standalone = false

    var body: some View {
        let n = store.missingCount(folder)
        Group {
            if n > 0 {
                Tag(text: standalone ? "\(n) env key\(n == 1 ? "" : "s") missing" : "\(n) missing", color: .orange,
                    symbol: "exclamationmark.triangle")
                    .help("\(n) key\(n == 1 ? "" : "s") in the env template \(n == 1 ? "isn't" : "aren't") set in any env file")
            }
        }
        .onAppear { store.load(folder) }
    }
}
