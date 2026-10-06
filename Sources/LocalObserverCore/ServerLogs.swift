import Foundation

// MARK: - Log file framing

/// Which pipe a log line came out of. Lookout's own lines (launch header, exit status) are kept apart from the
/// server's so they can't be mistaken for its output.
public enum ServerLogStream: String, Codable, Sendable {
    case stdout, stderr, lookout
}

/// How a launcher's log file tells stdout, stderr and Lookout's notes apart. Both pipes append to the same file so
/// their order survives (and the server keeps logging while Lookout is quit); the launch script prefixes every
/// stderr line with an ASCII record separator, and Lookout's notes start with a group separator. Neither shows up
/// in normal program output.
public enum ServerLogFraming {
    public static let stderrMarker: Character = "\u{1E}"
    public static let lookoutMarker: Character = "\u{1D}"
    private static let exitPrefix = "exit "

    /// Wraps a shell body (cd, exports, the user's command) so its stderr is tagged line by line and its exit
    /// status lands at the end of the log. Expects stdout to already be the log file, opened for appending.
    /// The pipeline's first element is the user's command, so `pipestatus[1]` is its status, not the tagger's.
    /// MULTIOS is off for these redirections (else zsh tees stdout into the stderr pipe too) and back on inside.
    public static func wrap(_ body: String) -> String {
        """
        setopt no_multios
        exec 3>&1
        { setopt multios; \(body)
        } 2>&1 1>&3 3>&- | while IFS= read -r line || [[ -n $line ]]; do print -r -- $'\\x1e'"$line"; done
        ec=${pipestatus[1]}
        print -r -- $'\\x1d'"\(exitPrefix)$ec"
        exit $ec
        """
    }

    /// A note from Lookout itself, written straight into the log.
    public static func note(_ text: String) -> String { "\(lookoutMarker)\(text)\n" }

    /// The exit status from a Lookout exit note, if this is one.
    public static func exitCode(fromNote text: String) -> Int32? {
        guard text.hasPrefix(exitPrefix) else { return nil }
        return Int32(text.dropFirst(exitPrefix.count).trimmingCharacters(in: .whitespaces))
    }

    /// Splits one line of the file into its parts. A stderr line can land in the middle of a stdout line that had
    /// no newline yet; the text before the marker stays stdout. Carriage returns redraw a line in a terminal
    /// (progress bars), so only what follows the last one is kept.
    public static func records(in line: Substring) -> [ServerLogRecord] {
        var text = line
        if text.last == "\r" { text = text.dropLast() }
        if text.first == lookoutMarker {
            return [ServerLogRecord(stream: .lookout, text: String(text.dropFirst()))]
        }
        let parts = text.split(separator: stderrMarker, omittingEmptySubsequences: false)
        var records: [ServerLogRecord] = []
        for (i, part) in parts.enumerated() {
            if i == 0 && part.isEmpty && parts.count > 1 { continue }
            let visible = part.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            records.append(ServerLogRecord(stream: i == 0 ? .stdout : .stderr, text: visible))
        }
        return records
    }

    /// Log text with the stream markers and colour codes removed, for the request log and copying.
    public static func plainText(_ raw: String) -> String {
        ANSI.strip(raw).replacingOccurrences(of: String(stderrMarker), with: "")
            .replacingOccurrences(of: String(lookoutMarker), with: "")
    }
}

public struct ServerLogRecord: Equatable, Sendable {
    public var stream: ServerLogStream
    /// Still carries the program's ANSI codes.
    public var text: String
    public init(stream: ServerLogStream, text: String) {
        self.stream = stream
        self.text = text
    }
}

/// Turns bytes read from a log file into whole lines, holding a partial last line (and a UTF-8 sequence cut in
/// half) until the rest arrives.
public struct ServerLogDecoder: Sendable {
    private var pending = Data()
    public init() {}

    public mutating func feed(_ data: Data) -> [ServerLogRecord] {
        pending.append(data)
        guard let lastNewline = pending.lastIndex(of: 0x0A) else { return [] }
        let complete = pending[pending.startIndex...lastNewline]
        pending = Data(pending[pending.index(after: lastNewline)...])
        let text = String(decoding: complete, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            .flatMap(ServerLogFraming.records(in:))
    }

    /// Whatever is left without a newline (a prompt, or a line still being written).
    public mutating func flush() -> [ServerLogRecord] {
        defer { pending = Data() }
        guard !pending.isEmpty else { return [] }
        return ServerLogFraming.records(in: Substring(String(decoding: pending, as: UTF8.self)))
    }

    public mutating func reset() { pending = Data() }
}

// MARK: - ANSI colours

/// A terminal colour: one of the 16 named ones (0–7 normal, 8–15 bright), the 256-colour palette, or 24-bit.
public enum ANSIColor: Hashable, Sendable {
    case standard(UInt8)
    case palette(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct ANSIStyle: Hashable, Sendable {
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var strikethrough = false

    public init() {}
    public var isPlain: Bool { self == ANSIStyle() }
}

public struct ANSISpan: Hashable, Sendable {
    public var text: String
    public var style: ANSIStyle
    public init(text: String, style: ANSIStyle) {
        self.text = text
        self.style = style
    }
}

/// Reads SGR colour codes into styled spans and drops every other escape sequence (cursor moves, line clears,
/// window titles, hyperlinks), which only make sense in a live terminal.
public enum ANSI {
    /// Styles carry over from line to line like they do in a terminal: pass the previous line's `end` as `initial`.
    public static func parse(_ text: String, initial: ANSIStyle = ANSIStyle()) -> (spans: [ANSISpan], end: ANSIStyle) {
        var spans: [ANSISpan] = []
        var style = initial
        var current = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var i = 0

        func flush() {
            guard !current.isEmpty else { return }
            let piece = String(current)
            if let last = spans.last, last.style == style { spans[spans.count - 1].text += piece }
            else { spans.append(ANSISpan(text: piece, style: style)) }
            current = String.UnicodeScalarView()
        }

        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1B}" || c == "\u{9B}" {
                let isCSI = c == "\u{9B}" || (i + 1 < scalars.count && scalars[i + 1] == "[")
                if isCSI {
                    var j = i + (c == "\u{9B}" ? 1 : 2)
                    var params = ""
                    while j < scalars.count, (0x20...0x3F).contains(scalars[j].value) {
                        params.unicodeScalars.append(scalars[j]); j += 1
                    }
                    guard j < scalars.count else { break }    // cut off mid-sequence: drop the rest
                    if scalars[j] == "m" {
                        flush()
                        apply(params, to: &style)
                    }
                    i = j + 1
                } else if i + 1 < scalars.count, scalars[i + 1] == "]" {
                    // OSC (titles, hyperlinks): runs to BEL or ESC \.
                    var j = i + 2
                    while j < scalars.count, scalars[j] != "\u{07}", !(scalars[j] == "\u{1B}" && j + 1 < scalars.count && scalars[j + 1] == "\\") { j += 1 }
                    i = j < scalars.count && scalars[j] == "\u{1B}" ? j + 2 : j + 1
                } else {
                    i += 2    // two-character escapes (ESC 7, ESC =, …)
                }
                continue
            }
            if c.value < 0x20 && c != "\t" || c.value == 0x7F { i += 1; continue }
            current.append(c)
            i += 1
        }
        flush()
        return (spans, style)
    }

    public static func strip(_ text: String) -> String {
        guard text.contains("\u{1B}") || text.contains("\u{9B}") else { return text }
        return parse(text).spans.map(\.text).joined()
    }

    private static func apply(_ params: String, to style: inout ANSIStyle) {
        // Colons separate sub-parameters (38:2::r:g:b); semicolons separate codes (38;2;r;g;b).
        let groups = params.isEmpty ? [""] : params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var k = 0
        func number(_ s: String) -> Int { Int(s) ?? 0 }
        while k < groups.count {
            let group = groups[k]
            if group.contains(":") {
                let sub = group.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                if let code = sub.first, code == 38 || code == 48, sub.count >= 3 {
                    var color: ANSIColor?
                    if sub[1] == 5 { color = .palette(UInt8(clamping: sub[2])) }
                    else if sub[1] == 2 {
                        let rgb = sub.count >= 6 ? Array(sub.suffix(3)) : Array(sub.dropFirst(2))
                        if rgb.count == 3 { color = .rgb(UInt8(clamping: rgb[0]), UInt8(clamping: rgb[1]), UInt8(clamping: rgb[2])) }
                    }
                    if code == 38 { style.foreground = color } else { style.background = color }
                } else if let code = sub.first {
                    applySimple(code == 4 && sub.count > 1 && sub[1] == 0 ? 24 : code, to: &style)
                }
                k += 1
                continue
            }
            let code = number(group)
            if code == 38 || code == 48, k + 1 < groups.count {
                var color: ANSIColor?
                let mode = number(groups[k + 1])
                if mode == 5, k + 2 < groups.count {
                    color = .palette(UInt8(clamping: number(groups[k + 2])))
                    k += 3
                } else if mode == 2, k + 4 < groups.count {
                    color = .rgb(UInt8(clamping: number(groups[k + 2])), UInt8(clamping: number(groups[k + 3])),
                                 UInt8(clamping: number(groups[k + 4])))
                    k += 5
                } else {
                    k = groups.count    // malformed: ignore the rest, like terminals do
                }
                if code == 38 { style.foreground = color } else { style.background = color }
                continue
            }
            applySimple(code, to: &style)
            k += 1
        }
    }

    private static func applySimple(_ code: Int, to style: inout ANSIStyle) {
        switch code {
        case 0: style = ANSIStyle()
        case 1: style.bold = true
        case 2: style.dim = true
        case 3: style.italic = true
        case 4, 21: style.underline = true
        case 7: style.inverse = true
        case 9: style.strikethrough = true
        case 22: style.bold = false; style.dim = false
        case 23: style.italic = false
        case 24: style.underline = false
        case 27: style.inverse = false
        case 29: style.strikethrough = false
        case 30...37: style.foreground = .standard(UInt8(code - 30))
        case 39: style.foreground = nil
        case 40...47: style.background = .standard(UInt8(code - 40))
        case 49: style.background = nil
        case 90...97: style.foreground = .standard(UInt8(code - 90 + 8))
        case 100...107: style.background = .standard(UInt8(code - 100 + 8))
        default: break
        }
    }
}

// MARK: - Levels

public enum ServerLogLevel: Int, Comparable, Codable, CaseIterable, Sendable {
    case info, warn, error
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Guesses a line's severity from its words. Dev servers rarely agree on a format, so this looks for the usual
/// markers (`ERROR`, `[warn]`, `level=error`, `TypeError:`, a 5xx access line), ignores the all-clear phrasing
/// ("0 errors", "no warnings"), and keeps stack frames with the error above them. stderr alone isn't treated as
/// an error: plenty of tools log everything there.
public enum ServerLogClassifier {
    private static let allClear = try! NSRegularExpression(pattern:
        #"(?i)\b(0|no|zero|without)\s+(errors?|warnings?|failures?|failed|problems?)\b|\b(errors?|warnings?)\s*[:=]\s*0\b"#)
    private static let error = try! NSRegularExpression(pattern:
        #"(?i)(\bERR!|\b(error|errors|fatal|panic|panicked|exception|traceback|uncaught|unhandled|failed|failure|crash(ed)?|segmentation fault|critical)\b|\[(error|err|fatal|crit|critical)\]|\blevel[=:]\s*"?(error|fatal|critical)|^E\d{4} |\b[A-Z]\w*(Error|Exception)\b|\bE(ADDRINUSE|CONNREFUSED|ACCES|NOENT)\b|✖|✘)"#)
    private static let warn = try! NSRegularExpression(pattern:
        #"(?i)(\b(warn|warning|warnings|deprecated|deprecation)\b|\[(warn|warning)\]|\blevel[=:]\s*"?warn|⚠)"#)
    /// Stack frames and the lines that hang off an error: JS `at …`, Python `File "…", line n`, Go frames, carets.
    private static let continuation = try! NSRegularExpression(pattern:
        #"^(\s+at\s|\s+File ".*", line \d+|\s+\S+\.go:\d+|goroutine \d+|\s+\.\.\. \d+ more|\s*\^+\s*$|\s{4,}\S|\s*\|\s|\s*\d+\s*\|)"#)

    public static func level(of text: String, previous: ServerLogLevel? = nil) -> ServerLogLevel {
        let plain = ANSI.strip(text)
        if plain.trimmingCharacters(in: .whitespaces).isEmpty { return previous == .error ? .error : .info }
        let range = NSRange(plain.startIndex..., in: plain)
        if previous == .error, continuation.firstMatch(in: plain, range: range) != nil { return .error }

        if let status = ServerRequest.parse(plain).first?.status {
            if status >= 500 { return .error }
            if status >= 400 { return .warn }
            return .info
        }
        let scrubbed = allClear.stringByReplacingMatches(in: plain, range: range, withTemplate: "")
        let scrubbedRange = NSRange(scrubbed.startIndex..., in: scrubbed)
        if error.firstMatch(in: scrubbed, range: scrubbedRange) != nil { return .error }
        if warn.firstMatch(in: scrubbed, range: scrubbedRange) != nil { return .warn }
        return .info
    }
}

// MARK: - Parsed lines

/// One displayable line: which stream, how severe, its styled text, and its plain text for search and copy.
public struct ServerLogLine: Identifiable, Equatable, Sendable {
    public var id: Int
    public var stream: ServerLogStream
    public var level: ServerLogLevel
    public var spans: [ANSISpan]
    public var text: String
    /// Set on Lookout's exit note: the status the command exited with.
    public var exitCode: Int32?

    public init(id: Int, stream: ServerLogStream, level: ServerLogLevel, spans: [ANSISpan], text: String, exitCode: Int32? = nil) {
        self.id = id
        self.stream = stream
        self.level = level
        self.spans = spans
        self.text = text
        self.exitCode = exitCode
    }
}

/// Bytes in, display lines out. Keeps what has to carry over between reads: a partial line, the colour in effect
/// on each stream, and the last level (so a stack trace stays an error).
public struct ServerLogParser: Sendable {
    private var decoder = ServerLogDecoder()
    private var styles: [ServerLogStream: ANSIStyle] = [:]
    private var previousLevel: ServerLogLevel?
    public private(set) var nextID = 0

    public init(firstID: Int = 0) { nextID = firstID }

    public mutating func consume(_ data: Data) -> [ServerLogLine] { lines(decoder.feed(data)) }

    public mutating func finish() -> [ServerLogLine] { lines(decoder.flush()) }

    /// After the file is truncated or rotated, start clean (ids keep counting so views can tell lines apart).
    public mutating func reset() {
        decoder.reset()
        styles = [:]
        previousLevel = nil
    }

    private mutating func lines(_ records: [ServerLogRecord]) -> [ServerLogLine] {
        records.map { record in
            defer { nextID += 1 }
            if record.stream == .lookout {
                let code = ServerLogFraming.exitCode(fromNote: record.text)
                let text = code.map { "Exited with status \($0)" } ?? ANSI.strip(record.text)
                return ServerLogLine(id: nextID, stream: .lookout, level: .info,
                                     spans: [ANSISpan(text: text, style: ANSIStyle())], text: text, exitCode: code)
            }
            let (spans, end) = ANSI.parse(record.text, initial: styles[record.stream] ?? ANSIStyle())
            styles[record.stream] = end
            let text = spans.map(\.text).joined()
            let level = ServerLogClassifier.level(of: text, previous: previousLevel)
            previousLevel = level
            return ServerLogLine(id: nextID, stream: record.stream, level: level, spans: spans, text: text)
        }
    }
}

/// Fixed-capacity buffer that forgets its oldest elements first.
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0
    /// How many elements have been pushed out since the last `removeAll`.
    public private(set) var dropped = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(min(capacity, 1024))
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity { storage.append(element); return }
        storage[head] = element
        head = (head + 1) % capacity
        dropped += 1
    }

    public mutating func append<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        for element in elements { append(element) }
    }

    /// Oldest first.
    public var elements: [Element] { head == 0 ? storage : Array(storage[head...] + storage[..<head]) }

    public func suffix(_ n: Int) -> [Element] { Array(elements.suffix(n)) }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        dropped = 0
    }
}

// MARK: - Filtering

public struct ServerLogQuery: Equatable, Sendable {
    public var text = ""
    /// Lines below this level are hidden.
    public var minimumLevel: ServerLogLevel = .info
    /// Nil shows both pipes.
    public var stream: ServerLogStream?

    public init(text: String = "", minimumLevel: ServerLogLevel = .info, stream: ServerLogStream? = nil) {
        self.text = text
        self.minimumLevel = minimumLevel
        self.stream = stream
    }

    public var isNarrowed: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty || minimumLevel > .info || stream != nil }

    /// Lookout's own notes (start, exit) always show unless you're searching, so you can see where runs begin and end.
    public func matches(_ line: ServerLogLine) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespaces)
        if line.stream == .lookout { return needle.isEmpty }
        if line.level < minimumLevel { return false }
        if let stream, line.stream != stream { return false }
        return needle.isEmpty || line.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

// MARK: - Crashes

/// How a launched command ended, from a `waitpid` status or the exit note in its log.
public enum ServerExitStatus: Equatable, Codable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    /// Decodes a raw `waitpid` status (the WIFEXITED / WTERMSIG macros, which Swift can't import).
    public init(waitStatus: Int32) {
        let signal = waitStatus & 0x7F
        self = signal == 0 ? .exited((waitStatus >> 8) & 0xFF) : .signaled(signal)
    }

    /// A shell reports a child killed by signal n as 128 + n.
    public var signal: Int32? {
        switch self {
        case .signaled(let s): return s
        case .exited(let code): return code > 128 && code <= 128 + 31 ? code - 128 : nil
        }
    }

    public var isSuccess: Bool { self == .exited(0) }

    public var summary: String {
        if let signal {
            let name = Self.signalNames[signal].map { "SIG\($0)" } ?? "signal \(signal)"
            if case .exited(let code) = self { return "killed by \(name) (status \(code))" }
            return "killed by \(name)"
        }
        if case .exited(let code) = self { return "exit code \(code)" }
        return "unknown"
    }

    private static let signalNames: [Int32: String] = [1: "HUP", 2: "INT", 3: "QUIT", 4: "ILL", 6: "ABRT", 9: "KILL", 10: "BUS",
                                                      11: "SEGV", 13: "PIPE", 14: "ALRM", 15: "TERM"]
}

public enum ServerExitVerdict: Equatable, Sendable {
    /// You (or Lookout) asked it to stop.
    case stopped
    /// It ended by itself with a clean status, while it was meant to keep serving.
    case exitedEarly
    /// It ended by itself with a failure or a signal.
    case crashed
}

public enum ServerExitClassifier {
    public static func verdict(_ status: ServerExitStatus?, stopRequested: Bool) -> ServerExitVerdict {
        if stopRequested { return .stopped }
        guard let status else { return .crashed }    // gone, status unknown: still unexpected
        return status.isSuccess ? .exitedEarly : .crashed
    }
}

/// Auto-restart with backoff: a few tries, waiting longer each time. A run that stayed up past `stableAfter`
/// counts as recovered, so the next crash starts the count again.
public struct RestartPolicy: Equatable, Sendable {
    public var delays: [TimeInterval]
    public var stableAfter: TimeInterval

    public init(delays: [TimeInterval] = [2, 8, 30], stableAfter: TimeInterval = 120) {
        self.delays = delays
        self.stableAfter = stableAfter
    }

    public var maxAttempts: Int { delays.count }

    public enum Decision: Equatable, Sendable {
        case restart(after: TimeInterval, attempt: Int)
        case giveUp(attempts: Int)
    }

    /// `attempts` is how many automatic restarts already happened in this run of crashes; `ranFor` is how long
    /// the run that just crashed stayed up.
    public func decide(attempts: Int, ranFor: TimeInterval) -> Decision {
        let used = ranFor >= stableAfter ? 0 : attempts
        guard used < delays.count else { return .giveUp(attempts: used) }
        return .restart(after: delays[used], attempt: used + 1)
    }
}

// MARK: - Error spikes

/// Counts error lines in a sliding window, to flag a server that starts throwing (a broken route hit in a loop,
/// a database gone away) without alerting on the odd one.
public struct ErrorSpikeWindow: Equatable, Sendable {
    public var window: TimeInterval
    public var threshold: Int
    private var events: [(at: Date, count: Int)] = []

    public init(window: TimeInterval = 60, threshold: Int = 10) {
        self.window = window
        self.threshold = threshold
    }

    public mutating func record(_ count: Int, at date: Date) {
        guard count > 0 else { return }
        events.append((date, count))
        prune(now: date)
    }

    public mutating func prune(now: Date) {
        events.removeAll { now.timeIntervalSince($0.at) > window }
    }

    public func count(now: Date) -> Int {
        events.filter { now.timeIntervalSince($0.at) <= window }.reduce(0) { $0 + $1.count }
    }

    public func isSpiking(now: Date) -> Bool { count(now: now) >= threshold }

    public mutating func reset() { events.removeAll() }

    public static func == (a: Self, b: Self) -> Bool {
        a.window == b.window && a.threshold == b.threshold && a.events.map(\.at) == b.events.map(\.at)
            && a.events.map(\.count) == b.events.map(\.count)
    }
}
