import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalObserverShelf

/// Settings › Shelf: clipboard recording, how much history to keep, apps to skip, and clearing.
struct ShelfSettingsPane: View {
    @ObservedObject var store: ShelfStore = .shared
    @ObservedObject private var prefs = Preferences.shared
    @State private var confirmHistory = false
    @State private var confirmShelf = false

    var body: some View {
        SettingsPage(title: "Shelf", message: "Park files, images, links, and text while you move between apps, and find anything you copied earlier. It all stays on this Mac, in Application Support › LocalObserver › Shelf.") {
            SettingsHeader("Clipboard history", first: true)
            SettingsGroup {
                SettingsRow(title: "Record what you copy", detail: "Passwords, and anything an app marks as private, are never recorded") {
                    Toggle("Record what you copy", isOn: Binding(get: { !store.isPaused }, set: { store.isPaused = !$0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Keep up to", detail: "Entries older than 30 days go too. Pinned entries always stay.") {
                    Picker("Keep up to", selection: $store.historyLimit) {
                        ForEach(ShelfStore.historyLimits, id: \.self) { Text("\($0) items").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if let key = prefs.shelfHotKey {
                SettingsFootnote("Press \(key.display) anywhere to search it. Change the shortcut in Menu Bar & Notch.")
            }

            SettingsHeader("Skip these apps")
            SettingsGroup {
                if store.excludedApps.isEmpty {
                    Text("None. Copies from every app are recorded.")
                        .font(NFont.small).foregroundStyle(N.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                } else {
                    ForEach(Array(store.excludedApps.enumerated()), id: \.element) { index, bundleID in
                        if index > 0 { SettingsDivider() }
                        HStack(spacing: 10) {
                            if let icon = SourceApps.icon(bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundStyle(N.text3)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(SourceApps.name(bundleID) ?? bundleID).font(NFont.body).foregroundStyle(N.text)
                                Text(bundleID).font(NFont.caption).foregroundStyle(N.text3)
                            }
                            Spacer(minLength: 12)
                            IconButton(symbol: "minus.circle", help: "Record copies from this app again") {
                                store.excludedApps.removeAll { $0 == bundleID }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minHeight: 52)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Add App…", action: chooseApp).buttonStyle(SecondaryButtonStyle())
                Text("Nothing copied while one of these apps is in front is recorded.")
                    .font(NFont.caption).foregroundStyle(N.text3)
            }
            .padding(.top, 8)

            SettingsHeader("Stored")
            SettingsGroup {
                SettingsRow(title: "Clipboard history", detail: summary(store.history, noun: "entry", plural: "entries")) {
                    Button("Clear…") { confirmHistory = true }.buttonStyle(SecondaryButtonStyle(tint: TagColor.red.fg))
                        .disabled(!store.history.contains { !$0.pinned })
                }
                SettingsDivider()
                SettingsRow(title: "Shelf", detail: summary(store.shelf, noun: "item", plural: "items")) {
                    Button("Clear…") { confirmShelf = true }.buttonStyle(SecondaryButtonStyle(tint: TagColor.red.fg))
                        .disabled(!store.shelf.contains { !$0.pinned })
                }
            }
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmHistory) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
        } message: {
            Text("Pinned entries stay. This can't be undone.")
        }
        .confirmationDialog("Clear the shelf?", isPresented: $confirmShelf) {
            Button("Clear Shelf", role: .destructive) { store.clearShelf() }
        } message: {
            Text("Pinned items stay. Copies the shelf made of dropped files are deleted; your originals aren't touched.")
        }
    }

    private func summary(_ items: [ShelfItem], noun: String, plural: String) -> String {
        let pinned = items.filter(\.pinned).count
        let count = "\(items.count) \(items.count == 1 ? noun : plural)"
        return pinned > 0 ? "\(count), \(pinned) pinned" : count
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Skip copies from"
        panel.prompt = "Skip"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !store.excludedApps.contains(id) else { continue }
            store.excludedApps.append(id)
        }
    }
}
