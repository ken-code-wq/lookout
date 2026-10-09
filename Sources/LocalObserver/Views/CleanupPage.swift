import SwiftUI
import AppKit
import LocalObserverDisk

extension DiskCategory {
    var color: TagColor {
        switch self {
        case .artifacts: return .blue
        case .worktrees: return .purple
        case .caches: return .orange
        case .xcode: return .pink
        case .docker: return .green
        case .agents: return .brown
        }
    }
}

extension DiskSafety {
    var color: TagColor {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .keep: return .gray
        }
    }
}

/// What's filling the drive that Lookout can explain, and clearing the parts that come back on their own.
struct CleanupPage: View {
    @ObservedObject var store: DiskStore
    @State private var width: CGFloat = 900
    @State private var collapsed: Set<DiskCategory> = []
    @State private var confirming: [DiskItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(symbol: SidebarItem.cleanup.symbol, title: SidebarItem.cleanup.title, subtitle: AnyView(summary))
                DiskUsageCard(store: store)
                    .padding(.bottom, 18)
                toolbar
                    .padding(.bottom, 6)
                ForEach(DiskCategory.allCases) { category in
                    let list = store.items(in: category)
                    if !list.isEmpty { section(category, list) }
                }
                if store.items.isEmpty {
                    if store.isScanning {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Looking through your projects…").font(NFont.small).foregroundStyle(N.text2)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        EmptyStateView(symbol: "internaldrive", title: "Nothing measured yet",
                                       message: "Scan your repositories, launchers, caches and Docker to see what's taking space.") {
                            Button("Scan now") { DiskCoordinator.shared.scan() }.buttonStyle(PrimaryButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, width > 1100 ? 64 : (width > 800 ? 44 : 24))
            .padding(.bottom, store.selection.isEmpty ? 80 : 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .overlay(alignment: .bottom) { if !store.selection.isEmpty { selectionBar.transition(.move(edge: .bottom).combined(with: .opacity)) } }
        .animation(.snappy(duration: 0.22), value: store.selection.isEmpty)
        .onAppear {
            // A scan walks every project and runs du; reuse one from the last ten minutes.
            if store.lastScan.map({ Date().timeIntervalSince($0) > 600 }) ?? true { DiskCoordinator.shared.scan() }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } }),
                            titleVisibility: .visible) {
            Button("Clear \(DiskFormat.bytes(confirming.reduce(0) { $0 + ($1.bytes ?? 0) }))", role: .destructive) {
                store.clear(confirming)
                confirming = []
            }
            Button("Cancel", role: .cancel) { confirming = [] }
        } message: {
            Text(confirmMessage)
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            if let volume = store.volume {
                Label("\(DiskFormat.bytes(volume.available)) free of \(DiskFormat.bytes(volume.total))", systemImage: "internaldrive")
                    .foregroundStyle(store.isLowOnSpace ? TagColor.red.fg : N.text2)
            }
            if store.safeBytes > 0 {
                Label("\(DiskFormat.bytes(store.safeBytes)) safe to clear", systemImage: "checkmark.circle").foregroundStyle(TagColor.green.fg)
            }
            if store.freed > 0 {
                Label("\(DiskFormat.bytes(store.freed)) freed", systemImage: "sparkles").foregroundStyle(TagColor.blue.fg)
            }
            if store.isScanning {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Measuring \(store.measured) of \(store.items.count)").monospacedDigit()
                }
            } else {
                RelativeTimeText(date: store.lastScan)
            }
        }
        .font(NFont.small)
        .foregroundStyle(N.text2)
        .labelStyle(TightLabelStyle())
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            let suggested = store.suggested
            Button {
                store.selectSuggested()
            } label: {
                Label(suggested.isEmpty ? "Nothing stale to suggest"
                      : "Select suggested · \(suggested.count) · \(DiskFormat.bytes(suggested.reduce(0) { $0 + ($1.bytes ?? 0) }))",
                      systemImage: "wand.and.stars")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(suggested.isEmpty || store.isScanning)
            .help("Safe items untouched for \(store.settings.staleDays) days or more")
            Spacer()
            Picker("Sort", selection: $store.sort) {
                ForEach(DiskSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func section(_ category: DiskCategory, _ list: [DiskItem]) -> some View {
        let folded = collapsed.contains(category)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { if folded { collapsed.remove(category) } else { collapsed.insert(category) } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(N.text3)
                        .rotationEffect(.degrees(folded ? 0 : 90))
                    Image(systemName: category.symbol).font(.system(size: 12.5)).foregroundStyle(category.color.fg)
                    Text(category.rawValue).font(.system(size: 14, weight: .semibold)).foregroundStyle(N.text)
                    Text("\(list.count)").font(NFont.small).foregroundStyle(N.text3).monospacedDigit()
                    Spacer()
                    let clearable = list.filter(\.canClear)
                    if clearable.count > 1 {
                        let all = clearable.allSatisfy { store.selection.contains($0.id) }
                        Button(all ? "Deselect all" : "Select all") {
                            if all { store.selection.subtract(clearable.map(\.id)) } else { store.selection.formUnion(clearable.map(\.id)) }
                        }
                        .buttonStyle(GhostButtonStyle(tint: N.blue))
                    }
                    Text(DiskFormat.bytes(store.total(category))).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(N.text)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
            .padding(.bottom, 4)
            if !folded {
                Text(LocalizedStringKey(category.blurb)).font(NFont.caption).foregroundStyle(N.text2).padding(.leading, 18).padding(.bottom, 8)
                Rectangle().fill(N.divider).frame(height: 1)
                LazyVStack(spacing: 1) {
                    ForEach(list) { item in
                        DiskItemRow(store: store, item: item, staleDays: store.settings.staleDays) { confirming = [item] }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(store.selectedItems.count) selected").font(NFont.bodyMedium).foregroundStyle(N.text)
            Text(DiskFormat.bytes(store.selectedBytes)).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(N.text)
            Spacer(minLength: 12)
            Button("Deselect") { store.selection = [] }.buttonStyle(GhostButtonStyle())
            Button {
                confirming = store.selectedItems
            } label: {
                Label("Clear \(DiskFormat.bytes(store.selectedBytes))", systemImage: "trash")
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(store.selectedItems.isEmpty || !store.clearing.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .frame(maxWidth: 640)
        .background(N.bgRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(N.divider))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .padding(.bottom, 20)
        .padding(.horizontal, 24)
    }

    private var confirmTitle: String {
        confirming.count == 1 ? "Clear \(confirming[0].name)?" : "Clear \(confirming.count) items?"
    }

    private var confirmMessage: String {
        var lines: [String] = []
        let kinds = Set(confirming.map(\.kind.category))
        if kinds.contains(.artifacts) || kinds.contains(.caches) || kinds.contains(.xcode) {
            lines.append("Build output and caches are deleted, not moved to the Trash, so the space comes back now. They're recreated by the next install or build.")
        }
        if kinds.contains(.worktrees) {
            lines.append("Worktrees are removed with git worktree remove, which refuses if anything is uncommitted. Their branches stay.")
        }
        if kinds.contains(.docker) { lines.append("Docker prunes what no container is using.") }
        if confirming.contains(where: { $0.safety == .review }) {
            lines.append("Some of these are marked Review: \(confirming.filter { $0.safety == .review }.prefix(3).map { "\($0.project ?? $0.name) (\($0.note))" }.joined(separator: "; ")).")
        }
        return lines.joined(separator: "\n\n")
    }
}

/// Red filled button for the one destructive action on the page.
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(N.red.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// The drive as one bar: each category Lookout measured in its colour, the rest of what's used in grey, then free.
struct DiskUsageCard: View {
    @ObservedObject var store: DiskStore
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            if let volume = store.volume {
                if !compact {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(DiskFormat.bytes(volume.available)).font(.system(size: 26, weight: .bold)).monospacedDigit().foregroundStyle(N.text)
                        Text("free on \(volume.name)").font(NFont.body).foregroundStyle(N.text2)
                        if store.isLowOnSpace { Tag(text: "Low on space", color: .red, symbol: "exclamationmark.triangle") }
                        Spacer()
                        Text("\(Int((volume.usedFraction * 100).rounded()))% used").font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
                    }
                }
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        ForEach(segments(volume)) { segment in
                            Rectangle().fill(segment.color)
                                .frame(width: max(segment.bytes > 0 ? 2 : 0, geo.size.width * Double(segment.bytes) / Double(max(volume.total, 1))))
                                .help("\(segment.title): \(DiskFormat.bytes(segment.bytes))")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                    .background(N.hover)
                }
                .frame(height: compact ? 6 : 14)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 3 : 5, style: .continuous))
                if !compact {
                    FlowLayout(spacing: 16, lineSpacing: 8) {
                        ForEach(segments(volume)) { segment in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 10, height: 10)
                                Text(segment.title).font(NFont.small).foregroundStyle(N.text)
                                Text(DiskFormat.bytes(segment.bytes)).font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
                            }
                        }
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).strokeBorder(N.divider).frame(width: 10, height: 10)
                            Text("Free").font(NFont.small).foregroundStyle(N.text)
                            Text(DiskFormat.bytes(volume.available)).font(NFont.small).foregroundStyle(N.text2).monospacedDigit()
                        }
                    }
                }
            } else {
                Text("Reading the drive…").font(NFont.small).foregroundStyle(N.text2)
            }
        }
        .padding(compact ? 0 : 18)
        .background(compact ? Color.clear : N.bgSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private struct Segment: Identifiable {
        var id: String { title }
        var title: String
        var bytes: Int64
        var color: Color
    }

    private func segments(_ volume: DiskVolume) -> [Segment] {
        var list = DiskCategory.allCases.compactMap { c -> Segment? in
            let bytes = store.total(c)
            return bytes > 0 ? Segment(title: c.rawValue, bytes: bytes, color: c.color.fg) : nil
        }
        let known = list.reduce(0) { $0 + $1.bytes }
        list.append(Segment(title: "Everything else", bytes: max(0, volume.used - known), color: N.text3))
        return list
    }
}

struct DiskItemRow: View {
    @ObservedObject var store: DiskStore
    var item: DiskItem
    var staleDays: Int
    var clear: () -> Void
    @State private var hover = false

    var body: some View {
        let selected = store.selection.contains(item.id)
        let busy = store.clearing.contains(item.id)
        HStack(spacing: 10) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else if item.canClear {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? N.blue : N.text3)
                } else {
                    Image(systemName: "lock").font(.system(size: 11.5)).foregroundStyle(N.text3)
                        .help("Lookout won't clear this")
                }
            }
            .frame(width: 18)
            Image(systemName: item.kind.symbol).font(.system(size: 12.5)).foregroundStyle(item.kind.category.color.fg).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let project = item.project, item.kind.category == .artifacts || item.kind.category == .worktrees {
                        Text(project).font(NFont.bodyMedium).foregroundStyle(N.text).lineLimit(1)
                        if item.kind.category == .worktrees {
                            BranchTag(branch: item.name, worktree: true, maxWidth: 220)
                        } else {
                            Text(item.name).font(NFont.monoSmall).foregroundStyle(N.text2)
                        }
                    } else {
                        Text(item.name).font(NFont.bodyMedium).foregroundStyle(N.text).lineLimit(1)
                    }
                }
                Text(item.path.isEmpty ? item.note : "\(item.displayPath) · \(item.note)")
                    .font(NFont.caption).foregroundStyle(N.text2).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            if hover, !item.path.isEmpty {
                IconButton(symbol: "folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                }
                if item.canClear { IconButton(symbol: "trash", help: "Clear just this", tint: N.red, action: clear) }
            }
            Tag(text: item.safety.title, color: item.safety.color)
                .help(item.note)
            Text(item.lastUsed.map { RelativeTimeFormatter.short($0) } ?? "–")
                .font(NFont.small)
                .foregroundStyle(item.isStale(days: staleDays) && item.lastUsed != nil ? TagColor.orange.fg : N.text2)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
                .help(item.lastUsed.map { "Last used \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            Text(DiskFormat.bytes(item.bytes))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(item.bytes == nil ? N.text3 : N.text)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(selected ? N.selected : (hover ? N.hover : .clear), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.toggle(item) }
        .opacity(busy ? 0.6 : 1)
        .contextMenu {
            if !item.path.isEmpty {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                Button("Copy Path") { RepoActions.copy(item.path) }
            }
            if item.canClear {
                Divider()
                Button("Clear…", role: .destructive, action: clear)
            }
        }
    }
}

enum RelativeTimeFormatter {
    /// "3d", "5w", "4mo", "2y": compact enough for a column.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 3600 { return "\(max(1, s / 60))m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        if s < 86_400 * 14 { return "\(s / 86_400)d ago" }
        if s < 86_400 * 60 { return "\(s / (86_400 * 7))w ago" }
        if s < 86_400 * 365 { return "\(s / (86_400 * 30))mo ago" }
        return "\(s / (86_400 * 365))y ago"
    }
}

/// Settings › Disk: when to warn about space, what counts as stale, and extra folders to look in.
struct DiskSettingsPane: View {
    @ObservedObject var store: DiskStore = .shared

    var body: some View {
        SettingsPage(title: "Disk", message: "Cleanup looks inside your repositories, their worktrees and your launchers for build output, plus package caches, Xcode and Docker. Nothing is cleared until you confirm, and anything with unsaved work is never offered.") {
            SettingsHeader("Warnings", first: true)
            SettingsGroup {
                SettingsRow(title: "Warn when space runs low", detail: "A notification and a notch alert, once each time it drops below") {
                    Toggle("", isOn: $store.settings.notifyLowSpace).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Low means under", detail: store.volume.map { "\(DiskFormat.bytes($0.available)) free right now" } ?? "") {
                    Picker("", selection: $store.settings.lowSpaceGB) {
                        ForEach([5, 10, 20, 30, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .disabled(!store.settings.notifyLowSpace)
            }

            SettingsHeader("Suggestions")
            SettingsGroup {
                SettingsRow(title: "Suggest clearing after", detail: "Safe items untouched this long are picked by Select suggested") {
                    Picker("", selection: $store.settings.staleDays) {
                        ForEach([3, 7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            SettingsHeader("Also look in")
            SettingsGroup {
                if store.settings.extraRoots.isEmpty {
                    Text("Repositories and launchers are covered already. Add other project folders here.")
                        .font(NFont.small).foregroundStyle(N.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                }
                ForEach(Array(store.settings.extraRoots.enumerated()), id: \.element) { index, root in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(N.text2).frame(width: 20)
                        Text((root as NSString).abbreviatingWithTildeInPath).font(NFont.body).foregroundStyle(N.text)
                        Spacer()
                        IconButton(symbol: "minus.circle", help: "Stop looking here") {
                            store.settings.extraRoots.removeAll { $0 == root }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: 44)
                }
            }
            Button("Add Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                panel.prompt = "Add"
                guard panel.runModal() == .OK else { return }
                for url in panel.urls where !store.settings.extraRoots.contains(url.path) { store.settings.extraRoots.append(url.path) }
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 8)
        }
    }
}
