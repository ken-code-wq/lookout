import Foundation
import AppKit
import LocalObserverCore

/// Output of the servers Lookout launched, tailed from their log files into a bounded buffer per launcher.
/// The file is the source of truth (the server keeps writing to it while Lookout is quit), so a restart of the app
/// picks the recent output back up. Running launchers are always tailed, slowly, for crash excerpts and error
/// spikes; an open logs panel tails its launcher every second.
@MainActor
final class ServerLogStore: ObservableObject {
    static let shared = ServerLogStore()

    /// Lines kept in memory per launcher.
    nonisolated static let capacity = 3_000
    /// Past this the log is rotated: the current file becomes `.1.log` (replacing the older one) and starts over.
    nonisolated static let fileCap: UInt64 = 2 * 1024 * 1024
    /// How much of an existing file to read when a launcher is first shown.
    nonisolated static let backfillBytes: UInt64 = 256 * 1024
    /// Most read in one go; a server that writes faster than this skips ahead rather than stalling the app.
    nonisolated static let maxReadBytes: UInt64 = 512 * 1024

    private struct Feed: Sendable {
        var path: String
        var rotatedPath: String
        var parser = ServerLogParser()
        var lines = RingBuffer<ServerLogLine>(capacity: ServerLogStore.capacity)
        var offset: UInt64 = 0
        var loaded = false
        var busy = false
        /// The status in the last exit note read, for runs that ended while nobody was waiting on them.
        var lastExitCode: Int32?
    }

    /// Bumped whenever a launcher's lines change, so views redraw.
    @Published private(set) var revisions: [UUID: Int] = [:]
    private var feeds: [UUID: Feed] = [:]
    private var watchers: [UUID: Int] = [:]
    /// Launchers the supervisor wants followed even with no panel open.
    private var background: Set<UUID> = []
    private var timer: Timer?
    private var timerFast = false
    private var isDemo = false

    // MARK: Reading

    func lines(for id: UUID) -> [ServerLogLine] { feeds[id]?.lines.elements ?? [] }

    /// Lines dropped from the front of the buffer since it was last cleared.
    func droppedCount(for id: UUID) -> Int { feeds[id]?.lines.dropped ?? 0 }

    func lastExitCode(for id: UUID) -> Int32? { feeds[id]?.lastExitCode }

    /// A panel is showing this launcher: follow it closely.
    func watch(_ launcher: ManagedServer) {
        watchers[launcher.id, default: 0] += 1
        ensureFeed(launcher)
        tick(launcher.id)
        scheduleTimer()
    }

    func unwatch(_ id: UUID) {
        watchers[id] = max((watchers[id] ?? 1) - 1, 0)
        if watchers[id] == 0 { watchers[id] = nil }
        scheduleTimer()
    }

    /// Launchers to keep tailing in the background (the ones meant to be running).
    func follow(_ list: [ManagedServer]) {
        for launcher in list {
            ensureFeed(launcher)
        }
        background = Set(list.map(\.id))
        scheduleTimer()
    }

    /// Reads whatever is new right now, for a crash excerpt that includes the last words.
    func catchUp(_ launcher: ManagedServer) async {
        ensureFeed(launcher)
        for _ in 0..<20 where feeds[launcher.id]?.busy == true { try? await Task.sleep(for: .milliseconds(50)) }
        await read(launcher.id, flushPartial: true)
    }

    // MARK: Actions

    /// Empties the panel and the log file (and its rotated copy).
    func clear(_ launcher: ManagedServer) {
        let path = ProcessManager.logURL(for: launcher).path
        if let handle = FileHandle(forWritingAtPath: path) {
            try? handle.truncate(atOffset: 0)
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: ProcessManager.rotatedLogURL(for: launcher))
        guard var feed = feeds[launcher.id] else { return }
        feed.lines.removeAll()
        feed.parser.reset()
        feed.offset = 0
        feed.lastExitCode = nil
        feeds[launcher.id] = feed
        bump(launcher.id)
    }

    func reveal(_ launcher: ManagedServer) {
        let url = ProcessManager.logURL(for: launcher)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(ProcessManager.logDirectory)
        }
    }

    // MARK: Tailing

    private func ensureFeed(_ launcher: ManagedServer) {
        let path = ProcessManager.logURL(for: launcher).path
        // A rename moves the log to a new file name; start over from that one.
        if let feed = feeds[launcher.id], feed.path == path { return }
        guard !isDemo else { return }
        feeds[launcher.id] = Feed(path: path, rotatedPath: ProcessManager.rotatedLogURL(for: launcher).path)
    }

    private func scheduleTimer() {
        let fast = !watchers.isEmpty
        let needed = !isDemo && (fast || !background.isEmpty)
        if !needed { timer?.invalidate(); timer = nil; return }
        if timer != nil && timerFast == fast { return }
        timer?.invalidate()
        timerFast = fast
        let interval: TimeInterval = fast ? 1 : 3
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in ServerLogStore.shared.tickAll() }
        }
        timer.tolerance = interval / 3
        self.timer = timer
    }

    private func tickAll() {
        for id in Set(watchers.keys).union(background) { tick(id) }
    }

    private func tick(_ id: UUID) {
        Task { await read(id, flushPartial: false) }
    }

    private func read(_ id: UUID, flushPartial: Bool) async {
        guard !isDemo, var feed = feeds[id], !feed.busy else { return }
        feed.busy = true
        feeds[id] = feed
        let snapshot = feed
        let result = await Task.detached(priority: .utility) {
            Self.readChunk(snapshot, flushPartial: flushPartial)
        }.value
        guard var current = feeds[id], current.path == snapshot.path else { return }
        current.busy = false
        current.offset = result.offset
        current.parser = result.parser
        current.loaded = true
        if result.restarted { current.lines.removeAll() }
        current.lines.append(contentsOf: result.lines)
        if let code = result.lines.last(where: { $0.exitCode != nil })?.exitCode { current.lastExitCode = code }
        feeds[id] = current
        guard !result.lines.isEmpty || result.restarted else { return }
        bump(id)
        // Backfilled history isn't news; only lines written since count toward a spike.
        if snapshot.loaded {
            let errors = result.lines.filter { $0.level == .error && $0.stream != .lookout }.count
            ServerSupervisor.shared.noteErrors(id, count: errors)
        }
    }

    private struct Chunk: Sendable {
        var lines: [ServerLogLine]
        var parser: ServerLogParser
        var offset: UInt64
        /// The file was replaced or emptied under us: what's buffered no longer matches it.
        var restarted: Bool
    }

    /// Reads from the feed's offset to the end of the file, parses it, and rotates the file if it grew past its cap.
    private nonisolated static func readChunk(_ feed: Feed, flushPartial: Bool) -> Chunk {
        var parser = feed.parser
        guard let handle = FileHandle(forReadingAtPath: feed.path) else {
            return Chunk(lines: [], parser: parser, offset: 0, restarted: false)
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var start = feed.offset
        var restarted = false
        var skipPartial = false
        if !feed.loaded {
            if size > backfillBytes { start = size - backfillBytes; skipPartial = true }
        } else if size < feed.offset {
            // Truncated (cleared, or rotated by someone else): read it from the top.
            start = 0
            restarted = true
            parser.reset()
        }
        if size - start > maxReadBytes {
            start = size - maxReadBytes
            skipPartial = true
            parser.reset()
        }
        try? handle.seek(toOffset: start)
        var data = (try? handle.read(upToCount: Int(size - start))) ?? Data()
        // Starting mid-file: the first line is a fragment.
        if skipPartial, let newline = data.firstIndex(of: 0x0A) { data = Data(data[data.index(after: newline)...]) }
        var lines = parser.consume(data)
        if flushPartial { lines += parser.finish() }
        var offset = size

        if size > fileCap {
            // Copy, then truncate in place: the server holds the file open for appending and keeps writing to it.
            try? FileManager.default.removeItem(atPath: feed.rotatedPath)
            try? FileManager.default.copyItem(atPath: feed.path, toPath: feed.rotatedPath)
            if let writer = FileHandle(forWritingAtPath: feed.path) {
                try? writer.truncate(atOffset: 0)
                try? writer.close()
                offset = 0
            }
        }
        return Chunk(lines: lines, parser: parser, offset: offset, restarted: restarted)
    }

    private func bump(_ id: UUID) { revisions[id, default: 0] += 1 }

    #if DEBUG
    /// Snapshot harness: shows these lines for a launcher without reading any file.
    func loadDemo(_ id: UUID, text: String) {
        isDemo = true
        timer?.invalidate()
        timer = nil
        var feed = Feed(path: "", rotatedPath: "")
        let lines = feed.parser.consume(Data(text.utf8))
        feed.lines.append(contentsOf: lines)
        feed.loaded = true
        feeds[id] = feed
        bump(id)
    }
    #endif
}
