import AppKit
import LocalObserverShelf

/// Shelf rules that must hold: private clipboard writes are never read, content is classified the same way every
/// time, pruning spares pinned items, and a damaged history file loses only the damaged entries.
enum ShelfChecks {
    @MainActor
    static func run() {
        checkPrivateTypes()
        checkClassification()
        checkPruning()
        checkLoading()
        checkCaptureDropAndRelaunch()
    }

    /// The whole path on a private pasteboard: copies are recorded, private ones and paused ones aren't, copying an
    /// entry back doesn't duplicate it, a dropped file is copied in and survives its original, and everything is
    /// there again after a relaunch.
    @MainActor
    private static func checkCaptureDropAndRelaunch() {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("shelf-verify-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: directory) }
        let suite = "dev.localobserver.verify.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        defer { pasteboard.releaseGlobally() }
        let store = ShelfStore(directory: directory, defaults: UserDefaults(suiteName: suite)!, publishesWidget: false, pasteboard: pasteboard)
        store.start()

        pasteboard.clearContents()
        pasteboard.setString("first copy", forType: .string)
        precondition(wait { store.history.count == 1 }, "A copy should be recorded")

        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        spin(1)
        precondition(!store.history.contains { $0.text == "hunter2" }, "A concealed copy must not be recorded")

        store.isPaused = true
        pasteboard.clearContents()
        pasteboard.setString("while paused", forType: .string)
        spin(1)
        precondition(store.history.count == 1, "Nothing is recorded while paused")
        store.isPaused = false

        pasteboard.clearContents()
        pasteboard.setString("second copy", forType: .string)
        precondition(wait { store.history.count == 2 }, "Recording resumes")
        store.copy(store.history[1])
        spin(1)
        precondition(store.history.map(\.text) == ["first copy", "second copy"], "Copying an entry back moves it up without repeating it")
        precondition(pasteboard.string(forType: .string) == "first copy", "Copying an entry puts it on the clipboard")

        let original = fm.temporaryDirectory.appendingPathComponent("shelf-verify-\(UUID().uuidString).txt")
        try? Data("dropped".utf8).write(to: original)
        guard let provider = NSItemProvider(contentsOf: original) else { preconditionFailure("Could not make a file provider") }
        precondition(store.add(providers: [provider]), "A file drop should be accepted")
        precondition(wait { store.shelf.count == 1 }, "A dropped file should land on the shelf")
        let dropped = store.shelf[0]
        try? fm.removeItem(at: original)
        precondition(dropped.kind == .file && store.isStoredCopy(dropped) && !store.isMissing(dropped),
                     "The shelf keeps its own copy, which outlives the original")
        precondition(dropped.fileURL?.lastPathComponent == original.lastPathComponent, "The copy keeps the original's name")

        store.togglePin(dropped)
        store.saveNow()
        store.stop()
        let reopened = ShelfStore(directory: directory, defaults: UserDefaults(suiteName: suite)!, publishesWidget: false, pasteboard: pasteboard)
        precondition(reopened.history.map(\.text) == ["first copy", "second copy"], "History should survive a relaunch")
        precondition(reopened.shelf.map(\.id) == [dropped.id] && reopened.shelf[0].pinned, "The shelf and pins should survive a relaunch")

        let folder = directory.appendingPathComponent("blobs/\(dropped.id.uuidString)")
        precondition(fm.fileExists(atPath: folder.path), "Dropped files live in the item's own folder")
        reopened.remove(reopened.shelf[0])
        precondition(!fm.fileExists(atPath: folder.path), "Removing an item deletes its files")
    }

    /// Runs the main run loop, which also drives the store's main-actor tasks and the clipboard timer.
    @MainActor
    private static func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.05))) }
    }

    @MainActor
    private static func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }

    /// Writes to a private, uniquely named pasteboard so the user's clipboard is never touched.
    @MainActor
    private static func checkPrivateTypes() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.localobserver.verify.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        for marker in ShelfPasteboard.privateTypes {
            pasteboard.clearContents()
            pasteboard.setString("hunter2", forType: .string)
            pasteboard.setData(Data(), forType: marker)
            precondition(ShelfPasteboard.read(pasteboard).isEmpty, "Clipboard marked \(marker.rawValue) must not be recorded")
        }

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        precondition(ShelfPasteboard.read(pasteboard) == [.text("hello")], "Plain text should be recorded")

        // Finder writes the file, its name as text, and its icon as an image. The file wins.
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp") as NSURL])
        pasteboard.setString("tmp", forType: .string)
        precondition(ShelfPasteboard.read(pasteboard) == [.file(URL(fileURLWithPath: "/tmp"))], "Copied files should win over their name")

        pasteboard.clearContents()
        precondition(ShelfPasteboard.read(pasteboard).isEmpty, "An empty clipboard records nothing")
    }

    private static func checkClassification() {
        precondition(ShelfPasteboard.classify("https://example.com/docs") == .link(URL(string: "https://example.com/docs")!), "A web address is a link")
        precondition(ShelfPasteboard.classify("see https://example.com") == .text("see https://example.com"), "A sentence with a link is text")
        precondition(ShelfPasteboard.classify("#f60") == .color(hex: "#FF6600", original: "#f60"), "Short hex codes are colours")
        precondition(ShelfPasteboard.classify("123456") == .text("123456"), "Numbers without # are not colours")
        precondition(ShelfPasteboard.classify("  \n ") == nil, "Whitespace is not recorded")
        precondition(ShelfPasteboard.classify(String(repeating: "a", count: ShelfPasteboard.maxTextLength + 1)) == nil,
                     "Oversized text is skipped, not cut short")
    }

    @MainActor
    private static func checkPruning() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-ShelfStore.historyMaxAge - 60)
        let items = [
            ShelfItem(kind: .text, createdAt: now, text: "1"),
            ShelfItem(kind: .text, createdAt: now, pinned: true, text: "pinned"),
            ShelfItem(kind: .text, createdAt: now, text: "2"),
            ShelfItem(kind: .text, createdAt: now, text: "3"),
            ShelfItem(kind: .text, createdAt: old, pinned: true, text: "old pinned"),
            ShelfItem(kind: .text, createdAt: old, text: "old"),
        ]
        let (kept, dropped) = ShelfStore.pruned(items, limit: 2, maxAge: ShelfStore.historyMaxAge, now: now)
        precondition(kept.map(\.text) == ["1", "pinned", "2", "old pinned"], "Pruning keeps pinned items and the newest up to the limit")
        precondition(dropped.map(\.text) == ["3", "old"], "Pruning drops the oldest unpinned and anything past its age")
    }

    /// A history file with one entry that no longer decodes still loads the rest.
    @MainActor
    private static func checkLoading() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        let json = """
        {"version": 1,
         "shelf": [{"id": "\(UUID().uuidString)", "kind": "link", "createdAt": \(now), "pinned": true, "text": "https://example.com"}],
         "history": [
           {"id": "\(UUID().uuidString)", "kind": "text", "createdAt": \(now), "pinned": false, "text": "kept"},
           {"id": "not a uuid", "kind": "text", "createdAt": \(now), "pinned": false, "text": "damaged"},
           {"id": "\(UUID().uuidString)", "kind": "hologram", "createdAt": \(now), "pinned": false},
           {"id": "\(UUID().uuidString)", "kind": "color", "createdAt": \(now), "pinned": false, "text": "#fff", "colorHex": "#FFFFFF"}
         ]}
        """
        try? Data(json.utf8).write(to: directory.appendingPathComponent("history.json"))
        let defaults = UserDefaults(suiteName: "dev.localobserver.verify.\(UUID().uuidString)")!
        let store = ShelfStore(directory: directory, defaults: defaults, publishesWidget: false)
        precondition(store.shelf.count == 1 && store.shelf[0].pinned, "Shelf items should load")
        precondition(store.history.map(\.text) == ["kept", "#fff"], "Damaged history entries should be skipped, not fatal")
        precondition(store.historyLimit == 500 && !store.isPaused, "Defaults: 500 entries, recording on")
    }
}
