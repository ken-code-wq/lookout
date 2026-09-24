import Foundation

/// Discovers listening TCP sockets via lsof, enriches with ps + cwd + project guess + HTTP probe.
enum PortScanner {

    struct RawSocket: Hashable {
        var pid: Int32
        var processName: String
        var address: String
        var port: Int
    }

    struct ProcInfo {
        var pgid: Int32 = 0
        var cpu: Double = 0
        var rssKB: Int = 0
        var uptime: TimeInterval = 0
        var args: String = ""
    }

    /// Ports that speak a non-HTTP protocol. Probing them with GET only spams their logs.
    static let nonHTTPPorts: Set<Int> = [22, 25, 53, 111, 445, 548, 631, 1433, 1521, 2181, 3306, 5432,
                                         5672, 6379, 7000, 9042, 9092, 11211, 15672, 27017, 27018, 33060]

    static func scan() async -> [ServerEntry] {
        let raws = await background { parseLsofFieldOutput(runTool("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pcn"])) }

        // One row per pid+port. Wildcard/loopback v4+v6 pairs collapse into a single entry.
        var byKey: [String: RawSocket] = [:]
        for r in raws {
            let wildcard = ["*", "0.0.0.0", "::"].contains(r.address)
            let loopback = ["127.0.0.1", "::1", "localhost"].contains(r.address)
            let addr = wildcard ? "*" : (loopback ? "127.0.0.1" : r.address)
            let key = "\(r.pid)-\(r.port)"
            if let existing = byKey[key], existing.address == "*" { continue }
            byKey[key] = RawSocket(pid: r.pid, processName: r.processName, address: addr, port: r.port)
        }
        let sockets = byKey.values.sorted { $0.port < $1.port }
        let pids = Set(sockets.map(\.pid))

        async let psInfo = background { runPs(pids: pids) }
        async let cwds = background { runCwds(pids: pids) }
        let (info, dirs) = await (psInfo, cwds)

        var entries: [ServerEntry] = sockets.map { sock in
            let p = info[sock.pid] ?? ProcInfo()
            let cmd = p.args.isEmpty ? sock.processName : p.args
            let cwd = dirs[sock.pid] ?? ""
            let guess = guessProject(cwd: cwd, command: cmd, process: sock.processName)
            return ServerEntry(
                pid: sock.pid, pgid: p.pgid, processName: sock.processName, command: cmd,
                port: sock.port, bindAddress: sock.address, workingDirectory: cwd,
                projectRoot: guess.root, projectName: guess.name, projectType: guess.type,
                cpu: p.cpu, rssKB: p.rssKB, uptime: p.uptime
            )
        }

        let probes = await withTaskGroup(of: (String, ProbeResult).self) { group in
            for e in entries {
                group.addTask { (e.id, await probe(e)) }
            }
            var out: [String: ProbeResult] = [:]
            for await (id, res) in group { out[id] = res }
            return out
        }
        for i in entries.indices {
            guard let p = probes[entries[i].id] else { continue }
            entries[i].httpState = p.state
            entries[i].statusCode = p.code
            entries[i].latencyMs = p.latencyMs
            entries[i].pageTitle = p.title
            entries[i].iconHref = p.iconHref
        }
        return entries
    }

    // MARK: - process helpers

    private static func background<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: work()) }
        }
    }

    /// Reads stdout before waitUntilExit — waiting first deadlocks once output exceeds the pipe buffer.
    static func runTool(_ executable: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    static func parseLsofFieldOutput(_ text: String) -> [RawSocket] {
        var out: [RawSocket] = []
        var pid: Int32 = 0
        var procName = ""
        for line in text.split(separator: "\n") {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p": pid = Int32(value) ?? 0
            case "c": procName = value
            case "n":
                // forms: *:5000, 127.0.0.1:3000, [::1]:3000
                guard let colon = value.range(of: ":", options: .backwards),
                      let port = Int(value[colon.upperBound...]) else { continue }
                let host = value[..<colon.lowerBound].replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                out.append(RawSocket(pid: pid, processName: procName, address: host.isEmpty ? "*" : host, port: port))
            default: break
            }
        }
        return out
    }

    private static func runPs(pids: Set<Int32>) -> [Int32: ProcInfo] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let text = runTool("/bin/ps", ["-o", "pid=,pgid=,pcpu=,rss=,etime=,args=", "-p", list])
        var result: [Int32: ProcInfo] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count >= 5, let pid = Int32(parts[0]) else { continue }
            result[pid] = ProcInfo(
                pgid: Int32(parts[1]) ?? 0,
                cpu: Double(parts[2]) ?? 0,
                rssKB: Int(parts[3]) ?? 0,
                uptime: parseEtime(String(parts[4])),
                args: parts.count > 5 ? String(parts[5]) : ""
            )
        }
        return result
    }

    /// `[[dd-]hh:]mm:ss` → seconds.
    static func parseEtime(_ s: String) -> TimeInterval {
        var days = 0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let comps = rest.split(separator: ":").compactMap { Int($0) }
        var secs = 0
        for c in comps { secs = secs * 60 + c }
        return TimeInterval(days * 86_400 + secs)
    }

    /// Single batched `lsof -p pid1,pid2,… -d cwd -Fn` instead of one spawn per pid.
    private static func runCwds(pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let text = runTool("/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd", "-Fn"])
        var out: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in text.split(separator: "\n") {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            if first == "p" { pid = Int32(value) ?? 0 }
            else if first == "n", pid != 0, out[pid] == nil { out[pid] = value }
        }
        return out
    }

    // MARK: - project guess

    struct ProjectGuess { var name: String; var type: ProjectType; var root: String }

    private static let markers: [(String, ProjectType)] = [
        ("package.json", .node), ("deno.json", .node), ("bun.lockb", .node),
        ("pyproject.toml", .python), ("requirements.txt", .python), ("manage.py", .python), ("Pipfile", .python),
        ("Cargo.toml", .rust), ("go.mod", .go), ("Gemfile", .ruby),
        ("docker-compose.yml", .docker), ("compose.yaml", .docker), ("Dockerfile", .docker),
        ("Package.swift", .xcode), ("index.html", .staticSite),
    ]

    static func guessProject(cwd: String, command: String, process: String) -> ProjectGuess {
        let combined = (command + " " + process).lowercased()

        if combined.contains("com.docker") || process.lowercased().hasPrefix("docker") || combined.contains("vpnkit") {
            return ProjectGuess(name: "Docker", type: .docker, root: "")
        }
        if combined.contains("ngrok") { return ProjectGuess(name: "ngrok tunnel", type: .other, root: "") }

        let fm = FileManager.default
        let home = NSHomeDirectory()
        let usefulCwd = !cwd.isEmpty && cwd != "/" && cwd != home
        // Helpers inside an app bundle (VS Code, Chrome, Raycast…) — not a project, name it after the app.
        if !usefulCwd, command.contains(".app/") {
            return ProjectGuess(name: prettyProcess(process, command: command), type: .app, root: "")
        }
        if usefulCwd {
            var dir = cwd
            for _ in 0..<5 {
                for (file, type) in markers where fm.fileExists(atPath: dir + "/" + file) {
                    return ProjectGuess(name: (dir as NSString).lastPathComponent, type: type, root: dir)
                }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir || parent.isEmpty || parent == home || parent == "/" { break }
                dir = parent
            }
        }

        let type = command.contains(".app/") ? .app : typeFromCommand(combined)
        let name = usefulCwd ? (cwd as NSString).lastPathComponent : prettyProcess(process, command: command)
        return ProjectGuess(name: name, type: type, root: usefulCwd ? cwd : "")
    }

    private static func typeFromCommand(_ c: String) -> ProjectType {
        if ["node", "next", "vite", "npm", "bun", "deno", "pnpm", "yarn"].contains(where: c.contains) { return .node }
        if ["python", "uvicorn", "gunicorn", "flask", "django"].contains(where: c.contains) { return .python }
        if ["ruby", "rails", "puma", "jekyll"].contains(where: c.contains) { return .ruby }
        if c.contains("/system/") || c.contains("/usr/libexec/") { return .system }
        return .other
    }

    private static func prettyProcess(_ process: String, command: String) -> String {
        // "/Applications/Figma.app/Contents/…" → "Figma"
        if let r = command.range(of: ".app/") {
            let appPath = command[..<r.lowerBound]
            return (String(appPath) as NSString).lastPathComponent
        }
        return process.isEmpty ? "Unknown" : process
    }

    // MARK: - HTTP probe

    struct ProbeResult {
        var state: HttpState
        var code: Int = 0
        var latencyMs: Int = 0
        var title: String = ""
        var iconHref: String = ""
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        config.connectionProxyDictionary = [:] // never route localhost through a proxy
        return URLSession(configuration: config)
    }()

    private static func probe(_ entry: ServerEntry) async -> ProbeResult {
        if nonHTTPPorts.contains(entry.port) { return ProbeResult(state: .offline) }
        guard let url = URL(string: entry.urlString) else { return ProbeResult(state: .unknown) }
        var req = URLRequest(url: url)
        req.setValue("text/html,*/*", forHTTPHeaderField: "Accept")
        req.setValue("LocalObserver/1.0", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = resp as? HTTPURLResponse else { return ProbeResult(state: .online, latencyMs: ms) }

            var head = Data()
            let isHTML = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html")
            if isHTML {
                for try await byte in bytes {
                    head.append(byte)
                    if head.count >= 48_000 { break }
                }
            }
            bytes.task.cancel()
            let html = String(decoding: head, as: UTF8.self)
            let state: HttpState = (http.statusCode == 401 || http.statusCode == 403) ? .authRequired : .online
            return ProbeResult(state: state, code: http.statusCode, latencyMs: ms,
                               title: extractTitle(html), iconHref: extractIconHref(html))
        } catch {
            return ProbeResult(state: .offline, latencyMs: Int(Date().timeIntervalSince(start) * 1000))
        }
    }

    static func extractTitle(_ html: String) -> String {
        guard let r = html.range(of: "<title", options: .caseInsensitive),
              let close = html.range(of: ">", range: r.upperBound..<html.endIndex),
              let e = html.range(of: "</title>", options: .caseInsensitive, range: close.upperBound..<html.endIndex) else { return "" }
        let t = html[close.upperBound..<e.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
        return t.count > 80 ? String(t.prefix(80)) + "…" : t
    }

    /// First `<link rel="icon" | "shortcut icon" | "apple-touch-icon" href="…">`.
    static func extractIconHref(_ html: String) -> String {
        var search = html.startIndex..<html.endIndex
        while let r = html.range(of: "<link", options: .caseInsensitive, range: search) {
            guard let end = html.range(of: ">", range: r.upperBound..<html.endIndex) else { break }
            let tag = String(html[r.upperBound..<end.lowerBound])
            let lower = tag.lowercased()
            if let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"), !lower.contains("mask-icon"),
               let href = attribute("href", in: tag), !href.isEmpty {
                return href
            }
            search = end.upperBound..<html.endIndex
        }
        return ""
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: name + "=", options: .caseInsensitive) else { return nil }
        let rest = tag[r.upperBound...]
        guard let q = rest.first else { return nil }
        if q == "\"" || q == "'" {
            let body = rest.dropFirst()
            guard let close = body.firstIndex(of: q) else { return nil }
            return String(body[..<close])
        }
        return String(rest.prefix { !$0.isWhitespace && $0 != ">" })
    }
}
