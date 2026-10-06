import Foundation
import Darwin

/// What a quick check found when it knocked on a service's port.
public enum ServiceLiveness: Hashable, Sendable {
    /// The service answered in its own protocol (Redis PONG, a Postgres handshake, a MySQL greeting).
    case responding(detail: String, ms: Int)
    /// It answered, but wants a password before it'll say more (Redis NOAUTH).
    case needsAuth(ms: Int)
    /// Something accepted the connection; it wasn't asked anything it would answer.
    case portOpen(ms: Int)
    /// Something accepted the connection but didn't answer like this service would.
    case unexpected(ms: Int)
    case refused
    case timedOut

    public var isAlive: Bool {
        switch self {
        case .responding, .needsAuth, .portOpen, .unexpected: return true
        case .refused, .timedOut: return false
        }
    }

    public var title: String {
        switch self {
        case .responding(let detail, _): return detail
        case .needsAuth: return "Responding, needs a password"
        case .portOpen: return "Port open"
        case .unexpected: return "Port open, unexpected reply"
        case .refused: return "Connection refused"
        case .timedOut: return "No answer"
        }
    }

    public var milliseconds: Int? {
        switch self {
        case .responding(_, let ms), .needsAuth(let ms), .portOpen(let ms), .unexpected(let ms): return ms
        case .refused, .timedOut: return nil
        }
    }
}

/// Cheap liveness checks. Each opens one TCP connection to localhost, says as little as possible, and closes it:
/// Redis gets a PING, Postgres an SSL request (answered with one byte, before any login), MySQL is read for the
/// greeting it sends unprompted. Everything else is a plain connect. Never sends credentials.
public enum ServiceProbe {
    /// Blocks for at most about `timeout` seconds; call off the main thread.
    public static func check(kind: ServiceKind?, port: Int, timeout: TimeInterval = 1.0) -> ServiceLiveness {
        let start = Date()
        guard let fd = connect(port: port, timeout: timeout) else {
            return Date().timeIntervalSince(start) >= timeout * 0.9 ? .timedOut : .refused
        }
        defer { close(fd) }
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        switch kind {
        case .redis?, .valkey?:
            guard send(fd, Array("PING\r\n".utf8)), let reply = receive(fd, max: 256, timeout: timeout) else { return .unexpected(ms: ms()) }
            return interpretRedis(reply, ms: ms())
        case .postgres?:
            // SSLRequest: length 8, code 80877103. The server answers a single 'S' or 'N'.
            let request: [UInt8] = [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F]
            guard send(fd, request), let reply = receive(fd, max: 1, timeout: timeout) else { return .unexpected(ms: ms()) }
            return interpretPostgres(reply, ms: ms())
        case .mysql?, .mariadb?:
            guard let reply = receive(fd, max: 512, timeout: timeout) else { return .unexpected(ms: ms()) }
            return interpretMySQL(reply, ms: ms())
        default:
            return .portOpen(ms: ms())
        }
    }

    // MARK: Replies

    public static func interpretRedis(_ reply: [UInt8], ms: Int) -> ServiceLiveness {
        let text = String(decoding: reply, as: UTF8.self)
        if text.hasPrefix("+PONG") { return .responding(detail: "Responding (PONG)", ms: ms) }
        if text.hasPrefix("-NOAUTH") || text.hasPrefix("-WRONGPASS") || text.contains("Authentication required") { return .needsAuth(ms: ms) }
        // Any other RESP error still means a Redis-speaking server is there (e.g. protected mode).
        if text.hasPrefix("-") { return .responding(detail: "Responding (\(text.dropFirst().prefix(40).trimmingCharacters(in: .whitespacesAndNewlines)))", ms: ms) }
        return .unexpected(ms: ms)
    }

    public static func interpretPostgres(_ reply: [UInt8], ms: Int) -> ServiceLiveness {
        switch reply.first {
        case UInt8(ascii: "S"): return .responding(detail: "Responding (accepts SSL)", ms: ms)
        case UInt8(ascii: "N"): return .responding(detail: "Responding", ms: ms)
        default: return .unexpected(ms: ms)
        }
    }

    /// The server's greeting: a 4-byte packet header, then protocol version 10 and a NUL-terminated version string.
    /// An error packet (0xFF) still means a MySQL server is there, just not letting this host in.
    public static func interpretMySQL(_ reply: [UInt8], ms: Int) -> ServiceLiveness {
        guard reply.count > 5 else { return .unexpected(ms: ms) }
        if reply[4] == 0xFF { return .responding(detail: "Responding (refused this host)", ms: ms) }
        guard reply[4] == 10 else { return .unexpected(ms: ms) }
        let version = reply[5...].prefix { $0 != 0 }
        let text = String(decoding: version, as: UTF8.self)
        return .responding(detail: text.isEmpty ? "Responding" : "Responding (\(text))", ms: ms)
    }

    // MARK: Sockets

    /// Non-blocking connect to 127.0.0.1, then ::1, each bounded by `timeout`.
    static func connect(port: Int, timeout: TimeInterval) -> Int32? {
        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var result: Int32
            if family == AF_INET {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
                inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
                result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var addr = sockaddr_in6()
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = in_port_t(UInt16(clamping: port).bigEndian)
                inet_pton(AF_INET6, "::1", &addr.sin6_addr)
                result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            if result != 0 && errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, Int32(timeout * 1000)) == 1 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    result = error == 0 ? 0 : -1
                }
            }
            if result == 0 { return fd }
            close(fd)
        }
        return nil
    }

    static func send(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, bytes.count, 0) } == bytes.count
    }

    static func receive(_ fd: Int32, max: Int, timeout: TimeInterval) -> [UInt8]? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: max)
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, max, 0) }
        return n > 0 ? Array(buffer.prefix(n)) : nil
    }
}
