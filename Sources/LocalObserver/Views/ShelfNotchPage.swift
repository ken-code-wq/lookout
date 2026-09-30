import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverShelf

/// The notch's Shelf tab: what you dropped, as a grid, and what you copied, as a searchable list.
struct ShelfNotchPage: View {
    @ObservedObject var store: ShelfStore
    var close: () -> Void
    @ObservedObject private var presentation = ShelfPresentation.shared
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var section: ShelfPresentation.Section { presentation.section }
    private var shelfItems: [ShelfItem] { ShelfStore.arranged(store.shelf, query: query) }
    private var historyItems: [ShelfItem] { ShelfStore.arranged(store.history, query: query) }
    private var shownItems: [ShelfItem] { section == .shelf ? shelfItems : historyItems }
    private var motion: Animation? { reduceMotion ? nil : .snappy(duration: 0.22) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            NotchCard {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if section == .shelf { shelfGrid(now: context.date) } else { historyList(now: context.date) }
                }
            }
        }
        .animation(motion, value: store.shelf.map(\.id))
        .animation(motion, value: store.history.map(\.id))
        .onAppear(perform: takeFocusIfAsked)
        .onChange(of: presentation.focusRequest) { _, _ in takeFocusIfAsked() }
        .onChange(of: presentation.section) { _, _ in selection = nil }
        .onChange(of: query) { _, _ in selection = nil }
    }

    private func takeFocusIfAsked() {
        guard presentation.wantsFocus else { return }
        presentation.wantsFocus = false
        DispatchQueue.main.async { searchFocused = true }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ShelfPresentation.Section.allCases) { option in
                    let selected = option == section
                    // While searching, how many match in each half, so a hit in the other one isn't missed.
                    let count = query.isEmpty
                        ? (option == .shelf ? store.shelf.count : store.history.count)
                        : (option == .shelf ? shelfItems.count : historyItems.count)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { presentation.section = option }
                    } label: {
                        HStack(spacing: 5) {
                            Text(option.title).font(.system(size: 11.5, weight: .semibold))
                            Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(NotchColor.text3)
                        }
                        .foregroundStyle(selected ? NotchColor.text : NotchColor.text2)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(selected ? Color.white.opacity(0.16) : .clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(option == .shelf ? "What you dragged in" : "What you copied")
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.07), in: Capsule())
            if section == .clipboard && store.isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchColor.orange)
                    .help("Clipboard history is paused. Resume it from the menu on the right.")
            }
            Spacer(minLength: 8)
            searchField
            moreMenu
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(NotchColor.text3)
            TextField("", text: $query, prompt: Text(section == .shelf ? "Search shelf" : "Search clipboard").foregroundColor(NotchColor.text3))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(NotchColor.text)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.return) {
                    guard let item = shownItems.first(where: { $0.id == selection }) ?? shownItems.first else { return .ignored }
                    store.copy(item)
                    close()
                    return .handled
                }
                .onKeyPress(.escape) {
                    if query.isEmpty { close() } else { query = "" }
                    return .handled
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(NotchColor.text3)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 190, height: 26)
        .background(Color.white.opacity(searchFocused ? 0.12 : 0.07), in: Capsule())
        .help("↑ ↓ to choose, Return to copy, Esc to close")
    }

    private var moreMenu: some View {
        Menu {
            Toggle("Pause clipboard history", isOn: $store.isPaused)
            Divider()
            Button("Clear shelf") { store.clearShelf() }
                .disabled(!store.shelf.contains { !$0.pinned })
            Button("Clear clipboard history") { store.clearHistory() }
                .disabled(!store.history.contains { !$0.pinned })
            Divider()
            Button("Shelf settings…") {
                close()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchColor.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 24)
        .help("Pinned items stay when clearing")
    }

    private func moveSelection(_ step: Int) {
        let items = shownItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : items.count)
        selection = items[min(max(current + step, 0), items.count - 1)].id
    }

    // MARK: Shelf

    @ViewBuilder private func shelfGrid(now: Date) -> some View {
        let items = shelfItems
        if items.isEmpty {
            if query.isEmpty {
                ShelfEmptyNote(symbol: "tray", title: "Nothing on the shelf yet",
                               detail: "Drag files, images, links, or text onto the notch to keep them here.")
            } else {
                ShelfEmptyNote(symbol: "magnifyingglass", title: "No matches", detail: "Nothing on the shelf matches “\(query)”.")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 82, maximum: 110), spacing: 6)], spacing: 6) {
                        ForEach(items) { item in
                            ShelfTile(item: item, store: store, now: now, selected: item.id == selection)
                                .id(item.id)
                                .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }

    // MARK: Clipboard

    @ViewBuilder private func historyList(now: Date) -> some View {
        let items = historyItems
        if items.isEmpty {
            if !query.isEmpty {
                ShelfEmptyNote(symbol: "magnifyingglass", title: "No matches", detail: "Nothing you copied matches “\(query)”.")
            } else if store.isPaused {
                ShelfEmptyNote(symbol: "pause.circle", title: "Clipboard history is paused",
                               detail: "Nothing you copy is recorded until you resume it.") {
                    Button("Resume") { store.isPaused = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(NotchColor.text)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
            } else {
                ShelfEmptyNote(symbol: "doc.on.clipboard", title: "Nothing copied yet",
                               detail: "Text, links, images, and files you copy show up here. Passwords never do.")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(items) { item in
                            ShelfHistoryRow(item: item, store: store, now: now, selected: item.id == selection) { close() }
                                .id(item.id)
                                .transition(reduceMotion ? .identity : .opacity)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }
}

/// "Nothing here yet" and one line on what will appear, in the notch's quiet type.
private struct ShelfEmptyNote<Accessory: View>: View {
    var symbol: String
    var title: String
    var detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(NotchColor.text3).padding(.bottom, 2)
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(NotchColor.text2)
            Text(detail).font(.system(size: 11)).foregroundStyle(NotchColor.text3).multilineTextAlignment(.center)
            accessory.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension ShelfEmptyNote where Accessory == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// A shelf item as a tile. Click copies it, double-click opens it, drag takes it into another app.
private struct ShelfTile: View {
    var item: ShelfItem
    @ObservedObject var store: ShelfStore
    var now: Date
    var selected: Bool
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        let missing = store.isMissing(item)
        VStack(spacing: 4) {
            ShelfThumb(item: item, side: 44, missing: missing)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .overlay(alignment: .topTrailing) {
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8.5, weight: .bold)).foregroundStyle(NotchColor.orange)
                            .padding(3)
                            .opacity(hover ? 0 : 1)
                    }
                }
            Text(item.title.isEmpty ? item.kindTitle : item.title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(NotchColor.text)
                .lineLimit(1)
                // A file's extension is worth keeping; a sentence reads better from its start.
                .truncationMode(item.kind == .file ? .middle : .tail)
            Text(copied ? "Copied" : missing ? "Missing" : AgentFormat.ago(item.createdAt, now: now))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(copied ? NotchColor.green : NotchColor.text3)
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 6)
        .background(hover || selected ? NotchColor.cardHover : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .top) {
            if hover {
                ShelfItemActions(item: item, store: store, inHistory: false, tone: NotchColor.text2) { flashCopied() }
                    .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(.top, 3)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 }
        .onDrag { item.itemProvider() }
        .onTapGesture(count: 2) { store.open(item) }
        .onTapGesture {
            store.copy(item)
            flashCopied()
        }
        .contextMenu { ShelfItemMenu(item: item, store: store) }
        .help(help(missing: missing))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Copies it. Drag to move it into another app.")
    }

    private func help(missing: Bool) -> String {
        var lines = [item.kind == .text ? String((item.text ?? "").prefix(300)) : item.title]
        if missing { lines.append("The file has moved or been deleted.") }
        else if item.kind == .file, !store.isStoredCopy(item) { lines.append("Kept as a link to the original, which is large or on another disk.") }
        lines.append("Click to copy, double-click to open, or drag it out.")
        return lines.joined(separator: "\n")
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// One clipboard entry: preview on the left, age and source app on the right, actions on hover.
private struct ShelfHistoryRow: View {
    var item: ShelfItem
    @ObservedObject var store: ShelfStore
    var now: Date
    var selected: Bool
    var close: () -> Void
    @State private var hover = false

    var body: some View {
        let missing = store.isMissing(item)
        HStack(spacing: 9) {
            ShelfThumb(item: item, side: 26, missing: missing)
            VStack(alignment: .leading, spacing: 1) {
                if item.kind == .link {
                    Text(item.domain ?? item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(NotchColor.text).lineLimit(1)
                    Text(item.preview).font(.system(size: 10.5)).foregroundStyle(NotchColor.text3).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(item.preview.isEmpty ? item.kindTitle : item.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(missing ? NotchColor.text3 : NotchColor.text)
                        .lineLimit(item.kind == .text ? 2 : 1)
                        .truncationMode(item.kind == .file ? .middle : .tail)
                    if item.kind != .text {
                        Text(missing ? "Missing" : item.kindTitle).font(.system(size: 10.5)).foregroundStyle(NotchColor.text3)
                    }
                }
            }
            Spacer(minLength: 6)
            if hover {
                ShelfItemActions(item: item, store: store, inHistory: true, tone: NotchColor.text2)
            } else {
                HStack(spacing: 6) {
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(NotchColor.orange)
                    }
                    Text(AgentFormat.ago(item.createdAt, now: now).replacingOccurrences(of: " ago", with: ""))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(NotchColor.text3)
                    if let app = item.sourceApp, let icon = SourceApps.icon(app) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            .help(SourceApps.name(app).map { "Copied in \($0)" } ?? "")
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 40)
        .background(hover || selected ? NotchColor.cardHover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onDrag { item.itemProvider() }
        .onTapGesture {
            store.copy(item)
            close()
        }
        .contextMenu { ShelfItemMenu(item: item, store: store) }
        .help("Click to copy it again. Drag it into another app.")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
