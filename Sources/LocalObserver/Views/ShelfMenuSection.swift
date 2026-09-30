import SwiftUI
import AppKit
import LocalObserverCore
import LocalObserverShelf

/// The menu bar panel's Shelf rows: recent items, then ways into the full shelf in the notch.
struct ShelfMenuContent: View {
    @ObservedObject var store: ShelfStore
    /// Closes the menu bar panel before the notch opens, so the two don't stack.
    var dismiss: () -> Void

    private static let rowLimit = 4

    var body: some View {
        let items = ShelfStore.arranged(store.shelf)
        VStack(alignment: .leading, spacing: 1) {
            if items.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "tray").font(.system(size: 13)).foregroundStyle(.tertiary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Nothing on the shelf yet").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        Text("Drag files, links, or text here or onto the notch.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 1) {
                        ForEach(items.prefix(Self.rowLimit)) { ShelfMenuRow(item: $0, store: store, now: context.date) }
                    }
                }
            }
            HStack(spacing: 2) {
                if NotchController.shared.isAvailable {
                    ShelfMenuLink(title: items.count > Self.rowLimit ? "All \(items.count)" : "Open Shelf", symbol: "tray.full") {
                        open(.shelf)
                    }
                    ShelfMenuLink(title: "Clipboard history", symbol: "doc.on.clipboard") { open(.clipboard) }
                }
                Spacer(minLength: 6)
                if store.shelf.contains(where: { !$0.pinned }) {
                    ShelfMenuLink(title: "Clear shelf", symbol: "xmark.bin") { store.clearShelf() }
                        .help("Removes everything except pinned items")
                }
            }
            .padding(.top, 2)
        }
    }

    private func open(_ section: ShelfPresentation.Section) {
        dismiss()
        NotchController.shared.openShelf(section, focusSearch: section == .clipboard)
    }
}

private struct ShelfMenuRow: View {
    var item: ShelfItem
    @ObservedObject var store: ShelfStore
    var now: Date
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        let missing = store.isMissing(item)
        HStack(spacing: 9) {
            ShelfThumb(item: item, side: 22, missing: missing)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title.isEmpty ? item.kindTitle : item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(item.kind == .file ? .middle : .tail)
                Text(copied ? "Copied" : missing ? "Missing" : subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(copied ? AnyShapeStyle(N.green) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            Spacer(minLength: 6)
            if hover {
                ShelfItemActions(item: item, store: store, inHistory: false) { flashCopied() }
                    .transition(.opacity)
            } else if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onDrag { item.itemProvider() }
        .onTapGesture {
            store.copy(item)
            flashCopied()
        }
        .contextMenu { ShelfItemMenu(item: item, store: store) }
        .help("Click to copy. Drag it into another app.")
    }

    /// "File · 4m ago"; just the age when the title already says what it is ("Image").
    private var subtitle: String {
        let ago = AgentFormat.ago(item.createdAt, now: now)
        return item.title == item.kindTitle ? ago : "\(item.kindTitle) · \(ago)"
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

private struct ShelfMenuLink: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5))
                .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
