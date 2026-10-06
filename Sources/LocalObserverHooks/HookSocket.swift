import Foundation
import Darwin

/// The Unix domain socket between `lookout-hook` and the app. One line each way: the helper sends an envelope, and
/// for a permission request the app answers with the JSON the helper prints, or hangs up to mean "no decision".
public enum HookSocket {
    /// `~/Library/Application Support/LocalObserver/hooks.sock`, next to the usage ledger. Resolved from the real home
    /// directory so the helper and the app agree whatever environment the agent runs hooks in.
    public static func defaultPath(home: String = realHome) -> String {
        home + "/Library/Application Support/LocalObserver/hooks.sock"
    }

    public static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    public enum Failure: LocalizedError, Equatable {
        case pathTooLong
        case inUse
        case system(String)

        public var errorDescription: String? {
            switch self {
            case .pathTooLong: return "The socket path is too long for macOS."
            case .inUse: return "Another copy of Lookout is already listening for agent hooks."
            case .system(let what): return what
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    static func connect(_ fd: Int32, _ path: String) -> Bool {
        guard var addr = try? address(path) else { return false }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    static func setTimeout(_ fd: Int32, _ option: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, pointer, left)
                if n < 0 { if errno == EINTR { continue }; return false }
                left -= n
                pointer = pointer.advanced(by: n)
            }
            return true
        }
    }

    /// Reads until a newline, end of stream, the receive timeout, or `limit` bytes. The newline isn't included.
    static func readLine(_ fd: Int32, limit: Int = 8 << 20) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        while data.count < limit {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            if let newline = buffer[..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[..<newline])
                break
            }
            data.append(contentsOf: buffer[..<n])
        }
        return data
    }
}

// MARK: - Client

/// The helper's side: never blocks the agent for longer than it's told to.
public enum HookClient {
    /// Sends one line. With `wait` above zero, waits up to that long for the answer line. Nil when the app isn't
    /// running, hangs up without an answer, or doesn't answer in time.
    public static func send(_ line: Data, to path: String = HookSocket.defaultPath(), wait: TimeInterval) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        HookSocket.noSigPipe(fd)
        HookSocket.setTimeout(fd, SO_SNDTIMEO, seconds: 2)
        guard HookSocket.connect(fd, path) else { return nil }
        guard HookSocket.writeAll(fd, line + Data([0x0A])) else { return nil }
        guard wait > 0 else { return nil }
        HookSocket.setTimeout(fd, SO_RCVTIMEO, seconds: wait)
        let reply = HookSocket.readLine(fd)
        return reply.isEmpty ? nil : reply
    }
}

// MARK: - Server

/// One accepted connection. Answer it exactly once with `reply`; until then the helper (and the agent) waits.
public final class HookConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var finished = false
    private var hangup: DispatchSourceRead?

    init(fd: Int32) { self.fd = fd }

    /// A connection to nobody, for demo data: answering it goes nowhere.
    public static func unconnected() -> HookConnection {
        let connection = HookConnection(fd: -1)
        connection.finished = true
        return connection
    }

    /// Writes the answer, if any, and hangs up. Nil hangs up without one: the agent asks in its own terminal.
    public func reply(_ data: Data?) {
        guard claim() else { return }
        if let data, !data.isEmpty { _ = HookSocket.writeAll(fd, data + Data([0x0A])) }
        close()
    }

    /// Calls `onClose` once if the helper goes away first: its hook timed out, or the agent was interrupted.
    public func watchForHangup(on queue: DispatchQueue, _ onClose: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            let n = recv(self.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            guard n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) else { return }
            if self.claim() { self.close(); onClose() }
        }
        lock.lock()
        let alreadyDone = finished
        if !alreadyDone { hangup = source }
        lock.unlock()
        if !alreadyDone { source.resume() }
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    private func close() {
        lock.lock()
        let source = hangup
        hangup = nil
        lock.unlock()
        if let source {
            let fd = self.fd
            source.setCancelHandler { Darwin.close(fd) }
            source.cancel()
        } else {
            Darwin.close(fd)
        }
    }
}

/// Listens on the socket and hands each envelope line to `handler` on a background queue.
public final class HookServer: @unchecked Sendable {
    public let path: String
    private let handler: @Sendable (Data, HookConnection) -> Void
    private let queue = DispatchQueue(label: "LocalObserver.hooks", attributes: .concurrent)
    private var listener: DispatchSourceRead?
    private var fd: Int32 = -1

    public init(path: String = HookSocket.defaultPath(), handler: @escaping @Sendable (Data, HookConnection) -> Void) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        guard listener == nil else { return }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var addr = try HookSocket.address(path)
        // A socket file that nothing answers on is left over from a crash; one that answers belongs to another copy.
        if FileManager.default.fileExists(atPath: path) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            let live = probe >= 0 && HookSocket.connect(probe, path)
            if probe >= 0 { Darwin.close(probe) }
            if live { throw HookSocket.Failure.inUse }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookSocket.Failure.system("Couldn't create the hook socket (\(errno)).") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw HookSocket.Failure.system("Couldn't open the hook socket (\(String(cString: strerror(code)))).")
        }
        // Only this user may talk to it: an answer here can approve a shell command.
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw HookSocket.Failure.system("Couldn't listen on the hook socket.")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        if fd >= 0 { unlink(path) }
        fd = -1
    }

    private func acceptAll() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            HookSocket.noSigPipe(client)
            // A helper that connects and then says nothing mustn't hold a thread for long.
            HookSocket.setTimeout(client, SO_RCVTIMEO, seconds: 3)
            HookSocket.setTimeout(client, SO_SNDTIMEO, seconds: 3)
            queue.async { [handler] in
                let line = HookSocket.readLine(client)
                let connection = HookConnection(fd: client)
                if line.isEmpty { connection.reply(nil); return }
                handler(line, connection)
            }
        }
    }
}
