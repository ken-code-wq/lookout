import Foundation

// Small, self-contained helpers for the plan-limit clients: JSON access, date parsing,
// executable lookup, subprocesses with timeouts, and HTTP. Nothing here logs or persists
// request data, so credentials passed through stay in local variables only.

// MARK: - JSON

enum AgentLimitJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Parses the first JSON object found in `data`, tolerating leading or trailing noise.
    static func firstObject(in data: Data) -> [String: Any]? {
        if let direct = object(data) { return direct }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end
        else { return nil }
        return object(Data(text[start...end].utf8))
    }

    static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func array(_ value: Any?) -> [Any]? { value as? [Any] }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber where !(value is Bool):
            return number.stringValue
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let result = number.doubleValue
            return result.isFinite ? result : nil
        case let text as String:
            return Double(text.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if let text = value as? String { return ["true", "1", "yes"].contains(text.lowercased()) }
        return nil
    }

    /// First non-nil value among `keys`, so callers can accept snake_case and camelCase.
    static func value(_ object: [String: Any]?, _ keys: String...) -> Any? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key], !(value is NSNull) { return value }
        }
        return nil
    }
}

// MARK: - Dates and formatting

enum AgentLimitFormat {
    /// Accepts ISO-8601 strings with any number of fractional digits, date-only strings,
    /// and Unix timestamps in seconds or milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let number = AgentLimitJSON.double(value), !(value is String) {
            guard number > 0 else { return nil }
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        guard let text = AgentLimitJSON.string(value) else { return nil }
        if let number = Double(text), number > 0 {
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        if text.count == 10 {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: text)
        }
        var base = text
        var fraction = 0.0
        if let tIndex = text.firstIndex(of: "T"),
           let dot = text[tIndex...].firstIndex(of: ".") {
            let digitsStart = text.index(after: dot)
            let digitsEnd = text[digitsStart...].firstIndex(where: { !$0.isNumber }) ?? text.endIndex
            let digits = String(text[digitsStart..<digitsEnd])
            fraction = Double("0." + digits) ?? 0
            base = String(text[..<dot]) + String(text[digitsEnd...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: base).map { $0.addingTimeInterval(fraction) }
    }

    static func dollars(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }

    static func count(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    /// "pro_plus" -> "Pro plus", "max" -> "Max".
    static func humanize(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.lowercased() }
        guard let first = words.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    static func slug(_ value: String) -> String {
        var result = ""
        var lastDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                result.append("-")
                lastDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - Executables and subprocesses

enum AgentLimitProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var timedOut: Bool
    }

    /// Finds an executable by name in PATH plus the usual install locations GUI apps miss.
    static func executable(named name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        directories += [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
            "\(home)/.volta/bin", "\(home)/.vite-plus/bin", "\(home)/.cargo/bin",
            "\(home)/Library/pnpm", "\(home)/.antigravity/bin",
        ]
        var seen: Set<String> = []
        for directory in directories where seen.insert(directory).inserted {
            let path = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a process with stdin closed and stderr discarded. Terminates it at `timeout`.
    /// Blocking: call from a background context.
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval
    ) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let buffer = AgentLimitLockedData()
        let eof = DispatchSemaphore(value: 0)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.signal()
            } else {
                buffer.append(chunk, limit: 4 * 1024 * 1024)
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            stop(process, exited: exited)
        }
        _ = eof.wait(timeout: .now() + 1)
        stdout.fileHandleForReading.readabilityHandler = nil
        return Output(status: process.terminationReason == .exit ? process.terminationStatus : -1,
                      stdout: buffer.data, timedOut: timedOut)
    }

    static func stop(_ process: Process, exited: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if exited.wait(timeout: .now() + 1.5) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
    }

    static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}

final class AgentLimitLockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data, limit: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < limit else { return }
        storage.append(chunk)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - HTTP

enum AgentLimitHTTP {
    struct Response: Sendable {
        var status: Int
        var data: Data
        var retryAfter: Date?
    }

    static let userAgent = "LocalObserver/1.0"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Returns nil on transport failure. Error text never includes request headers.
    static func get(_ url: URL, headers: [String: String]) async -> Response? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return Response(status: http.statusCode, data: data, retryAfter: retryAfter(http))
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) {
            return Date().addingTimeInterval(max(seconds, 0))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
