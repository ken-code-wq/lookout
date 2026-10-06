import Foundation
import LocalObserverCore

/// Launcher logs: stream framing (through a real zsh), colour codes, level guesses, filtering, exit statuses,
/// restart backoff and error spikes.
enum ServerLogChecks {
    static func run() {
        checkFramingThroughShell()
        checkDecoder()
        checkANSI()
        checkLevels()
        checkParserAndQuery()
        checkRingBuffer()
        checkExits()
        checkBackoff()
        checkSpikes()
    }

    /// Runs the launch wrapper for real: stdout and stderr land in one file, told apart, followed by the exit note.
    private static func checkFramingThroughShell() {
        let path = NSTemporaryDirectory() + "server-log-check-\(UUID().uuidString).log"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Opened for appending, like a real launch, so both pipes write at the end.
        let fd = open(path, O_WRONLY | O_APPEND)
        precondition(fd >= 0, "Temp log")
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-f", "-c", ServerLogFraming.wrap("echo ready; echo 'boom' >&2; printf 'no newline' >&2; exit 3")]
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        try? out.close()
        precondition(proc.terminationStatus == 3, "The wrapper keeps the command's status: \(proc.terminationStatus)")
        var decoder = ServerLogDecoder()
        let records = decoder.feed((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()) + decoder.flush()
        let expected = [ServerLogRecord(stream: .stdout, text: "ready"), ServerLogRecord(stream: .stderr, text: "boom"),
                        ServerLogRecord(stream: .stderr, text: "no newline"), ServerLogRecord(stream: .lookout, text: "exit 3")]
        precondition(records == expected, "Framed log: \(records)")
        precondition(ServerLogFraming.exitCode(fromNote: "exit 3") == 3 && ServerLogFraming.exitCode(fromNote: "started") == nil, "Exit note")
    }

    private static func checkDecoder() {
        var decoder = ServerLogDecoder()
        precondition(decoder.feed(Data("par".utf8)).isEmpty, "Partial lines wait for their newline")
        let first = decoder.feed(Data("tial\n\u{1E}warn\n".utf8))
        precondition(first == [ServerLogRecord(stream: .stdout, text: "partial"), ServerLogRecord(stream: .stderr, text: "warn")], "Lines: \(first)")
        // A UTF-8 character split across two reads.
        let bytes = Array("é\n".utf8)
        precondition(decoder.feed(Data(bytes[..<1])).isEmpty, "Half a character waits")
        precondition(decoder.feed(Data(bytes[1...])) == [ServerLogRecord(stream: .stdout, text: "é")], "UTF-8 across reads")
        let mixed = ServerLogFraming.records(in: "compiling…\u{1E}Error: x")
        precondition(mixed == [ServerLogRecord(stream: .stdout, text: "compiling…"), ServerLogRecord(stream: .stderr, text: "Error: x")],
                     "stderr inside an unfinished stdout line: \(mixed)")
        precondition(ServerLogFraming.records(in: "10%\r50%\rdone\r") == [ServerLogRecord(stream: .stdout, text: "done")], "Carriage returns redraw")
        precondition(ServerLogFraming.records(in: "\u{1D}Started") == [ServerLogRecord(stream: .lookout, text: "Started")], "Lookout notes")
        precondition(ServerLogFraming.plainText("\u{1E}\u{1B}[31mred\u{1B}[0m") == "red", "Plain text drops markers and colour")
    }

    private static func checkANSI() {
        let (spans, end) = ANSI.parse("\u{1B}[1;31mError\u{1B}[0m: \u{1B}[38;5;208mport\u{1B}[39m \u{1B}[38;2;10;20;30mrgb")
        precondition(spans.map(\.text) == ["Error", ": ", "port", " ", "rgb"], "Spans: \(spans.map(\.text))")
        precondition(spans[0].style.bold && spans[0].style.foreground == .standard(1), "Bold red")
        precondition(spans[1].style.isPlain, "Reset")
        precondition(spans[2].style.foreground == .palette(208) && spans[3].style.foreground == nil, "256 colours and default fg")
        precondition(spans[4].style.foreground == .rgb(10, 20, 30) && end.foreground == .rgb(10, 20, 30), "Truecolour, carried to the end")
        // Colon sub-parameters, bright colours, and styles that carry over to the next line.
        let colon = ANSI.parse("\u{1B}[38:2::1:2:3mx\u{1B}[92my", initial: ANSIStyle())
        precondition(colon.spans[0].style.foreground == .rgb(1, 2, 3) && colon.spans[1].style.foreground == .standard(10), "Colon form and bright")
        var underlined = ANSIStyle(); underlined.underline = true
        let carried = ANSI.parse("still\u{1B}[24m off", initial: underlined)
        precondition(carried.spans[0].style.underline && !carried.spans[1].style.underline, "Style carried from the last line")
        // Everything that isn't colour goes: cursor moves, clears, titles, hyperlinks, a cut-off sequence.
        let noisy = "\u{1B}[2K\u{1B}[1G\u{1B}]0;title\u{07}\u{1B}]8;;https://x.dev\u{1B}\\link\u{1B}]8;;\u{1B}\\ done\u{1B}[3"
        precondition(ANSI.strip(noisy) == "link done", "Stripped: \(ANSI.strip(noisy).debugDescription)")
        precondition(ANSI.strip("plain\ttext") == "plain\ttext", "Tabs stay")
    }

    private static func checkLevels() {
        let cases: [(String, ServerLogLevel)] = [
            ("TypeError: Cannot read properties of undefined", .error),
            ("npm ERR! code ELIFECYCLE", .error),
            ("[error] connection lost", .error),
            ("time=… level=error msg=\"db down\"", .error),
            ("Error: listen EADDRINUSE: address already in use :::3000", .error),
            ("ERROR:    Exception in ASGI application", .error),
            ("panic: runtime error: index out of range", .error),
            ("(node:123) [DEP0040] DeprecationWarning: punycode is deprecated", .warn),
            ("WARN  [vite] Port 5173 is in use", .warn),
            ("warning: unused variable `x`", .warn),
            (" GET /api/users 500 in 23ms", .error),
            (" GET /favicon.ico 404 in 2ms", .warn),
            (" GET /error-page 200 in 4ms", .info),
            ("Found 0 errors. Watching for file changes.", .info),
            ("✓ Compiled with no warnings", .info),
            ("  ➜  Local:   http://localhost:5173/", .info),
            ("ready - started server on 0.0.0.0:3000", .info),
        ]
        for (line, level) in cases {
            precondition(ServerLogClassifier.level(of: line) == level, "Level of \(line.debugDescription): \(ServerLogClassifier.level(of: line))")
        }
        precondition(ServerLogClassifier.level(of: "    at Object.<anonymous> (/app/server.js:4:9)", previous: .error) == .error, "JS stack frames stay errors")
        precondition(ServerLogClassifier.level(of: "  File \"app.py\", line 3, in <module>", previous: .error) == .error, "Python frames stay errors")
        precondition(ServerLogClassifier.level(of: "    at Object.<anonymous> (/app/server.js:4:9)", previous: .info) == .info, "A lone frame isn't an error")
        precondition(ServerLogClassifier.level(of: "\u{1B}[31mERROR\u{1B}[0m boom") == .error, "Coloured markers count")
    }

    private static func checkParserAndQuery() {
        var parser = ServerLogParser()
        let text = "\u{1D}Started · npm run dev\nready\n\u{1E}\u{1B}[31mTypeError: x\n\u{1E}    at f (a.js:1:1)\n\u{1E}warning: slow\n\u{1D}exit 1\n"
        let lines = parser.consume(Data(text.utf8))
        precondition(lines.map(\.id) == [0, 1, 2, 3, 4, 5], "Ids count up")
        precondition(lines.map(\.stream) == [.lookout, .stdout, .stderr, .stderr, .stderr, .lookout], "Streams")
        precondition(lines.map(\.level) == [.info, .info, .error, .error, .warn, .info], "Levels: \(lines.map(\.level))")
        precondition(lines[2].text == "TypeError: x" && lines[2].spans[0].style.foreground == .standard(1), "Coloured text kept as spans")
        precondition(lines[5].exitCode == 1 && lines[5].text == "Exited with status 1", "Exit note read")

        precondition(lines.filter(ServerLogQuery(minimumLevel: .error).matches).map(\.id) == [0, 2, 3, 5], "Errors only (plus Lookout notes)")
        precondition(lines.filter(ServerLogQuery(minimumLevel: .warn).matches).map(\.id) == [0, 2, 3, 4, 5], "Warnings and errors")
        precondition(lines.filter(ServerLogQuery(stream: .stdout).matches).map(\.id) == [0, 1, 5], "stdout only")
        precondition(lines.filter(ServerLogQuery(text: "typeerror").matches).map(\.id) == [2], "Search is case-insensitive, notes hidden")
        precondition(!ServerLogQuery().isNarrowed && ServerLogQuery(text: "x").isNarrowed, "Narrowed")

        let more = parser.consume(Data("tail".utf8)) + parser.finish()
        precondition(more.map(\.text) == ["tail"] && more[0].id == 6, "Unfinished last line on finish")
    }

    private static func checkRingBuffer() {
        var ring = RingBuffer<Int>(capacity: 3)
        ring.append(contentsOf: 1...5)
        precondition(ring.elements == [3, 4, 5] && ring.dropped == 2 && ring.count == 3, "Ring keeps the newest: \(ring.elements)")
        ring.append(6)
        precondition(ring.elements == [4, 5, 6] && ring.suffix(2) == [5, 6], "Ring wraps")
        ring.removeAll()
        precondition(ring.isEmpty && ring.dropped == 0, "Ring clears")
    }

    private static func checkExits() {
        precondition(ServerExitStatus(waitStatus: 1 << 8) == .exited(1), "Exit code from wait status")
        precondition(ServerExitStatus(waitStatus: 9) == .signaled(9), "Signal from wait status")
        precondition(ServerExitStatus.exited(137).summary == "killed by SIGKILL (status 137)", "Shell-reported signal")
        precondition(ServerExitStatus.signaled(11).summary == "killed by SIGSEGV" && ServerExitStatus.exited(2).summary == "exit code 2", "Summaries")
        precondition(ServerExitClassifier.verdict(.exited(1), stopRequested: true) == .stopped, "A stop you asked for isn't a crash")
        precondition(ServerExitClassifier.verdict(.signaled(15), stopRequested: false) == .crashed, "Killed from elsewhere")
        precondition(ServerExitClassifier.verdict(.exited(0), stopRequested: false) == .exitedEarly, "Clean exit while meant to run")
        precondition(ServerExitClassifier.verdict(nil, stopRequested: false) == .crashed, "Gone, status unknown")
    }

    private static func checkBackoff() {
        let policy = RestartPolicy(delays: [2, 8, 30], stableAfter: 120)
        precondition(policy.decide(attempts: 0, ranFor: 5) == .restart(after: 2, attempt: 1), "First retry")
        precondition(policy.decide(attempts: 2, ranFor: 5) == .restart(after: 30, attempt: 3), "Backs off")
        precondition(policy.decide(attempts: 3, ranFor: 5) == .giveUp(attempts: 3), "Gives up after the last try")
        precondition(policy.decide(attempts: 3, ranFor: 600) == .restart(after: 2, attempt: 1), "A long run resets the count")
    }

    private static func checkSpikes() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var spikes = ErrorSpikeWindow(window: 60, threshold: 10)
        spikes.record(4, at: t0)
        spikes.record(5, at: t0.addingTimeInterval(20))
        precondition(!spikes.isSpiking(now: t0.addingTimeInterval(20)), "9 errors is under the threshold")
        spikes.record(1, at: t0.addingTimeInterval(30))
        precondition(spikes.isSpiking(now: t0.addingTimeInterval(30)) && spikes.count(now: t0.addingTimeInterval(30)) == 10, "10 in a minute spikes")
        precondition(!spikes.isSpiking(now: t0.addingTimeInterval(70)), "The first burst ages out")
        precondition(spikes.count(now: t0.addingTimeInterval(91)) == 0, "All aged out")
    }
}
