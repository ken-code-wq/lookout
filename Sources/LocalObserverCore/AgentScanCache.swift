import Foundation

/// Identity of a file's contents as far as re-parsing is concerned.
struct AgentFileStamp: Hashable, Sendable {
    var size: UInt64
    var modifiedAt: Date
    var inode: UInt64
}

struct AgentScannedFile: Sendable {
    var url: URL
    var stamp: AgentFileStamp
}

/// Per-file parse state that can resume where the previous pass stopped. Transcripts are
/// append-only, so a file that only grew is parsed from `offset` onward.
protocol AgentLineScanState: Sendable {
    /// Byte offset just past the last complete line consumed.
    var offset: UInt64 { get set }
    /// Index of the next line, stable across resumed passes.
    var lineIndex: Int { get set }
    mutating func consume(line: UnsafeRawBufferPointer, index: Int)
}

/// Process-lifetime cache of parsed transcript files, keyed by path.
final class AgentFileCache<State: Sendable>: @unchecked Sendable {
    private var entries: [String: (stamp: AgentFileStamp, state: State)] = [:]
    private let lock = NSLock()

    func entry(for path: String) -> (stamp: AgentFileStamp, state: State)? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]
    }

    func store(_ state: State, stamp: AgentFileStamp, for path: String) {
        lock.lock()
        entries[path] = (stamp, state)
        lock.unlock()
    }

    /// Drops files that fell out of the history window or were deleted.
    func retain(only paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

enum AgentFileScanner {
    /// Largest single file parsed at all.
    static let maxFileBytes: UInt64 = 512 * 1_024 * 1_024
    /// New bytes parsed per refresh per agent. The rest is picked up on following refreshes.
    static let refreshByteBudget: UInt64 = 768 * 1_024 * 1_024

    static func stamp(for url: URL) -> AgentFileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return AgentFileStamp(size: size, modifiedAt: modified, inode: inode)
    }

    /// Regular files under `roots` modified since `cutoff`, newest first.
    static func files(in roots: [URL], since cutoff: Date, skipHidden: Bool = true, matching accept: (URL) -> Bool) -> [AgentScannedFile] {
        var result: [AgentScannedFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            let options: FileManager.DirectoryEnumerationOptions = skipHidden ? [.skipsPackageDescendants, .skipsHiddenFiles] : [.skipsPackageDescendants]
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else { continue }
            for case let url as URL in enumerator {
                guard accept(url) else { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= cutoff,
                      let stamp = stamp(for: url) else { continue }
                result.append(AgentScannedFile(url: url, stamp: stamp))
            }
        }
        return result.sorted { $0.stamp.modifiedAt > $1.stamp.modifiedAt }
    }

    struct Outcome<State> {
        var states: [(file: AgentScannedFile, state: State)] = []
        var deferredFiles = 0
        var oversizedFiles = 0
        var unreadableFiles = 0
    }

    /// Parses `files` through `cache`, reusing unchanged results and resuming grown files.
    static func scan<State: AgentLineScanState>(
        files: [AgentScannedFile],
        cache: AgentFileCache<State>,
        fresh: (AgentScannedFile) -> State
    ) -> Outcome<State> {
        var outcome = Outcome<State>()
        var budget = refreshByteBudget
        for file in files {
            let path = file.url.path
            let cached = cache.entry(for: path)
            if let cached, cached.stamp == file.stamp {
                outcome.states.append((file, cached.state))
                continue
            }
            guard file.stamp.size <= maxFileBytes else {
                outcome.oversizedFiles += 1
                continue
            }
            var state: State
            if let cached, cached.stamp.inode == file.stamp.inode, file.stamp.size >= cached.state.offset,
               file.stamp.size >= cached.stamp.size {
                state = cached.state
            } else {
                state = fresh(file)
            }
            let pending = file.stamp.size - min(state.offset, file.stamp.size)
            guard pending <= budget else {
                outcome.deferredFiles += 1
                // Show what we had last time rather than nothing.
                if let cached { outcome.states.append((file, cached.state)) }
                continue
            }
            budget -= pending
            do {
                try readLines(url: file.url, state: &state)
                cache.store(state, stamp: file.stamp, for: path)
                outcome.states.append((file, state))
            } catch {
                outcome.unreadableFiles += 1
            }
        }
        cache.retain(only: Set(files.map(\.url.path)))
        return outcome
    }

    /// Feeds complete newline-terminated lines from `state.offset` to `state`. A trailing
    /// partial line (a write in progress) is left for the next pass.
    static func readLines<State: AgentLineScanState>(url: URL, state: inout State) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)
        let chunkSize = 4 * 1_024 * 1_024
        var carry = Data()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            var buffer: Data
            if carry.isEmpty {
                buffer = chunk
            } else {
                buffer = carry
                buffer.append(chunk)
            }
            let consumed = buffer.withUnsafeBytes { raw -> Int in
                var start = 0
                let count = raw.count
                guard let base = raw.baseAddress else { return 0 }
                while start < count {
                    guard let newline = memchr(base + start, 0x0A, count - start) else { break }
                    let end = base.distance(to: UnsafeRawPointer(newline))
                    if end > start {
                        state.consume(line: UnsafeRawBufferPointer(rebasing: raw[start..<end]), index: state.lineIndex)
                    }
                    state.lineIndex += 1
                    start = end + 1
                }
                return start
            }
            state.offset += UInt64(consumed)
            carry = consumed < buffer.count ? buffer.subdata(in: consumed..<buffer.count) : Data()
        }
    }
}

/// Memoizes `AgentDiscovery.projectName(for:)`, which walks the filesystem.
final class AgentProjectNames: @unchecked Sendable {
    private var names: [String: String] = [:]
    private let lock = NSLock()

    func name(for path: String) -> String {
        lock.lock()
        if let name = names[path] {
            lock.unlock()
            return name
        }
        lock.unlock()
        let name = AgentDiscovery.projectName(for: path)
        lock.lock()
        names[path] = name
        lock.unlock()
        return name
    }
}
