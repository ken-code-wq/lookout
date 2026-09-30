import Foundation
import SQLite3

/// Reads each coding agent's current plan-limit windows (percent used and reset time) from the
/// user's own signed-in account. Credentials are read on demand, used for one request, and never
/// logged, cached, or included in messages.
public enum AgentLimitClients {
    /// One report per agent in `enabledAgents`. Account reads (network, Keychain, subprocess) happen only
    /// for agents in `accountAgents`; other agents that support account limits get `.notConnected`.
    public static func read(enabledAgents: Set<AgentKind>, accountAgents: Set<AgentKind>, force: Bool) async -> [AgentLimitReport] {
        let ordered = AgentKind.allCases.filter { enabledAgents.contains($0) }
        await cache.forget(except: accountAgents.intersection(enabledAgents))
        return await withTaskGroup(of: (Int, AgentLimitReport).self) { group in
            for (index, agent) in ordered.enumerated() {
                group.addTask {
                    (index, await report(for: agent, connected: accountAgents.contains(agent), force: force))
                }
            }
            var reports: [(Int, AgentLimitReport)] = []
            for await item in group { reports.append(item) }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public static func supportsAccountLimits(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude, .codex, .copilot, .cursor, .antigravity: return true
        case .openCode, .pi, .qoder: return false
        }
    }

    public static func connectDescription(_ agent: AgentKind) -> String {
        switch agent {
        case .claude:
            return "Reads your Claude Code sign-in from the Keychain and asks Anthropic for your plan usage."
        case .codex:
            return "Asks the Codex app-server for your ChatGPT plan limits, falling back to your Codex sign-in in ~/.codex/auth.json."
        case .copilot:
            return "Uses your GitHub CLI or Copilot CLI sign-in to ask GitHub for your monthly premium request quota."
        case .cursor:
            return "Reads your Cursor sign-in from Cursor's local storage and asks Cursor for this billing cycle's usage."
        case .antigravity:
            return "Runs the agy usage report, which reads your Antigravity quota without sending a prompt."
        case .openCode, .pi:
            return "Uses the limits of the provider you sign in with."
        case .qoder:
            return "Qoder bills with plan credits, which it does not expose locally."
        }
    }

    // MARK: - Dispatch

    private static let cache = AgentLimitCache()

    static func minimumInterval(_ agent: AgentKind) -> TimeInterval {
        switch agent {
        case .claude: return 180
        case .codex: return 120
        case .copilot, .cursor: return 300
        case .antigravity: return 600
        case .openCode, .pi, .qoder: return .infinity
        }
    }

    private static func report(for agent: AgentKind, connected: Bool, force: Bool) async -> AgentLimitReport {
        guard supportsAccountLimits(agent) else {
            return AgentLimitReport(agent: agent, status: .unsupported, message: "Uses the limits of the provider you sign in with.")
        }
        guard connected else {
            return AgentLimitReport(agent: agent, status: .notConnected, message: connectDescription(agent))
        }
        return await cache.report(for: agent, force: force, interval: minimumInterval(agent)) {
            switch agent {
            case .claude: return await fetchClaude()
            case .codex: return await fetchCodex()
            case .copilot: return await fetchCopilot()
            case .cursor: return await fetchCursor()
            case .antigravity: return await fetchAntigravity()
            case .openCode, .pi, .qoder: return AgentLimitOutcome(AgentLimitReport(agent: agent, status: .unsupported))
            }
        }
    }

    static func failure(_ agent: AgentKind, _ message: String, source: String = "", transient: Bool = false,
                        retryAfter: Date? = nil) -> AgentLimitOutcome {
        AgentLimitOutcome(AgentLimitReport(agent: agent, status: .error, fetchedAt: Date(), source: source, message: message),
                          transient: transient, retryAfter: retryAfter)
    }

    // MARK: - Claude

    private static func fetchClaude() async -> AgentLimitOutcome {
        let source = "Anthropic usage API"
        let credentials = await AgentLimitProcess.background { () -> [String: Any]? in
            if let output = AgentLimitProcess.run("/usr/bin/security",
                                                  ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                                                  timeout: 8),
               output.status == 0,
               let object = AgentLimitJSON.firstObject(in: output.stdout) {
                return object
            }
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            return (try? Data(contentsOf: file)).flatMap(AgentLimitJSON.object)
        }
        guard let oauth = AgentLimitJSON.dict(credentials?["claudeAiOauth"]),
              let token = AgentLimitJSON.string(oauth["accessToken"])
        else {
            return failure(.claude, "Claude Code sign-in not found. Run claude and sign in with your Claude account.", source: source)
        }
        let plan = claudePlanLabel(subscriptionType: AgentLimitJSON.string(oauth["subscriptionType"]),
                                   rateLimitTier: AgentLimitJSON.string(oauth["rateLimitTier"]))
        if let expires = AgentLimitFormat.date(oauth["expiresAt"]), expires < Date() {
            return failure(.claude, "Claude Code sign-in expired. Run claude to refresh it.", source: source)
        }
        guard let response = await AgentLimitHTTP.get(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
                // Verified working; mirrors the Claude Code client this token belongs to.
                "User-Agent": "claude-code/2.1.0",
            ])
        else {
            return failure(.claude, "Could not reach Anthropic to read plan usage.", source: source, transient: true)
        }
        switch response.status {
        case 200:
            let now = Date()
            let windows = claudeWindows(from: response.data, observedAt: now)
            return AgentLimitOutcome(AgentLimitReport(
                agent: .claude, status: .connected, plan: plan, windows: windows, fetchedAt: now, source: source,
                message: windows.isEmpty ? "Anthropic returned no plan limits for this account." : ""))
        case 401:
            return failure(.claude, "Claude Code sign-in expired. Run claude to refresh it.", source: source)
        case 403:
            return failure(.claude, "This Claude sign-in cannot read plan usage. Sign in with a Pro or Max account.", source: source)
        case 429:
            let retry = response.retryAfter ?? Date().addingTimeInterval(300)
            return failure(.claude, "Anthropic is limiting usage checks. Trying again later.", source: source,
                           transient: true, retryAfter: retry)
        default:
            return failure(.claude, "Anthropic usage request failed (HTTP \(response.status)).", source: source, transient: true)
        }
    }

    // MARK: - Codex

    private static func fetchCodex() async -> AgentLimitOutcome {
        let now = Date()
        if let executable = AgentLimitProcess.executable(named: "codex"),
           let data = await AgentLimitProcess.background({ AgentLimitCodexAppServer.readRateLimits(executable: executable) }) {
            let parse = codexAppServer(from: data, observedAt: now)
            if !parse.windows.isEmpty {
                return AgentLimitOutcome(AgentLimitReport(
                    agent: .codex, status: .connected, plan: parse.plan, windows: parse.windows, fetchedAt: now,
                    source: "Codex app-server", message: parse.message))
            }
        }
        return await fetchCodexWham()
    }

    private static func fetchCodexWham() async -> AgentLimitOutcome {
        let source = "ChatGPT usage API"
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let auth = await AgentLimitProcess.background {
            (try? Data(contentsOf: home.appendingPathComponent("auth.json"))).flatMap(AgentLimitJSON.object)
        }
        guard let auth else {
            return failure(.codex, "Codex sign-in not found. Run codex and sign in with ChatGPT.", source: source)
        }
        guard let tokens = AgentLimitJSON.dict(auth["tokens"]), let token = AgentLimitJSON.string(tokens["access_token"]) else {
            return failure(.codex, "Codex is signed in with an API key, which has no plan limits.", source: source)
        }
        var headers = ["Authorization": "Bearer \(token)"]
        if let account = AgentLimitJSON.string(tokens["account_id"]) { headers["ChatGPT-Account-Id"] = account }
        guard let response = await AgentLimitHTTP.get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers) else {
            return failure(.codex, "Could not reach ChatGPT to read Codex limits.", source: source, transient: true)
        }
        switch response.status {
        case 200:
            let now = Date()
            let parse = codexWham(from: response.data, observedAt: now)
            return AgentLimitOutcome(AgentLimitReport(
                agent: .codex, status: .connected, plan: parse.plan, windows: parse.windows, fetchedAt: now, source: source,
                message: parse.windows.isEmpty ? "ChatGPT returned no Codex limits for this account." : parse.message))
        case 401, 403:
            return failure(.codex, "Codex sign-in expired. Run codex to refresh it.", source: source)
        case 429:
            return failure(.codex, "ChatGPT is limiting usage checks. Trying again later.", source: source, transient: true,
                           retryAfter: response.retryAfter ?? Date().addingTimeInterval(300))
        default:
            return failure(.codex, "ChatGPT usage request failed (HTTP \(response.status)).", source: source, transient: true)
        }
    }

    // MARK: - Copilot

    private static func fetchCopilot() async -> AgentLimitOutcome {
        let source = "GitHub Copilot API"
        let token = await AgentLimitProcess.background { () -> String? in
            if let gh = AgentLimitProcess.executable(named: "gh"),
               let output = AgentLimitProcess.run(gh, ["auth", "token", "--hostname", "github.com"], timeout: 6),
               output.status == 0,
               let token = String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                return token
            }
            if let output = AgentLimitProcess.run("/usr/bin/security", ["find-generic-password", "-s", "copilot-cli", "-w"], timeout: 8),
               output.status == 0,
               var token = String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                let prefix = "go-keyring-base64:"
                if token.hasPrefix(prefix),
                   let decoded = Data(base64Encoded: String(token.dropFirst(prefix.count))).flatMap({ String(data: $0, encoding: .utf8) }) {
                    token = decoded
                }
                return token
            }
            return nil
        }
        guard let token else {
            return failure(.copilot, "GitHub sign-in not found. Run gh auth login or sign in to the Copilot CLI.", source: source)
        }
        guard let response = await AgentLimitHTTP.get(
            URL(string: "https://api.github.com/copilot_internal/user")!,
            headers: ["Authorization": "token \(token)", "X-GitHub-Api-Version": "2025-04-01"])
        else {
            return failure(.copilot, "Could not reach GitHub to read Copilot quota.", source: source, transient: true)
        }
        switch response.status {
        case 200:
            let now = Date()
            let parse = copilot(from: response.data, observedAt: now)
            return AgentLimitOutcome(AgentLimitReport(
                agent: .copilot, status: .connected, plan: parse.plan, account: parse.account, windows: parse.windows,
                fetchedAt: now, source: source,
                message: parse.windows.isEmpty && parse.message.isEmpty ? "GitHub returned no Copilot quota for this account." : parse.message))
        case 401:
            return failure(.copilot, "GitHub sign-in expired. Run gh auth login to refresh it.", source: source)
        case 403, 404:
            return failure(.copilot, "This GitHub account has no Copilot plan.", source: source)
        case 429:
            return failure(.copilot, "GitHub is limiting usage checks. Trying again later.", source: source, transient: true,
                           retryAfter: response.retryAfter ?? Date().addingTimeInterval(300))
        default:
            return failure(.copilot, "GitHub Copilot request failed (HTTP \(response.status)).", source: source, transient: true)
        }
    }

    // MARK: - Cursor

    private static func fetchCursor() async -> AgentLimitOutcome {
        let source = "Cursor usage API"
        let stored = await AgentLimitProcess.background { AgentLimitCursorStore.read() }
        guard let stored, let token = stored.accessToken else {
            return failure(.cursor, "Cursor sign-in not found. Open Cursor and sign in.", source: source)
        }
        guard let claims = AgentLimitCursorStore.jwtClaims(token),
              let subject = AgentLimitJSON.string(claims["sub"]),
              let userID = subject.split(separator: "|").last.map(String.init),
              !userID.isEmpty,
              userID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) })
        else {
            return failure(.cursor, "Cursor sign-in could not be read. Open Cursor and sign in again.", source: source)
        }
        if let exp = AgentLimitJSON.double(claims["exp"]), Date(timeIntervalSince1970: exp) < Date() {
            return failure(.cursor, "Cursor sign-in expired. Open Cursor to refresh it.", source: source)
        }
        guard let response = await AgentLimitHTTP.get(
            URL(string: "https://cursor.com/api/usage-summary")!,
            headers: ["Cookie": "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"])
        else {
            return failure(.cursor, "Could not reach Cursor to read usage.", source: source, transient: true)
        }
        switch response.status {
        case 200:
            let now = Date()
            let account = stored.email ?? ""
            let parse = cursor(from: response.data, observedAt: now, account: account)
            let plan = parse.plan.isEmpty ? (stored.membership.map(AgentLimitFormat.humanize) ?? "") : parse.plan
            return AgentLimitOutcome(AgentLimitReport(
                agent: .cursor, status: .connected, plan: plan, account: account, windows: parse.windows, fetchedAt: now,
                source: source, message: parse.windows.isEmpty ? "Cursor returned no usage limits for this plan." : ""))
        case 401, 403:
            return failure(.cursor, "Cursor sign-in expired. Open Cursor to refresh it.", source: source)
        case 429:
            return failure(.cursor, "Cursor is limiting usage checks. Trying again later.", source: source, transient: true,
                           retryAfter: response.retryAfter ?? Date().addingTimeInterval(300))
        default:
            return failure(.cursor, "Cursor usage request failed (HTTP \(response.status)).", source: source, transient: true)
        }
    }

    // MARK: - Antigravity

    private static func fetchAntigravity() async -> AgentLimitOutcome {
        let source = "agy usage report"
        let override = ProcessInfo.processInfo.environment["ANTIGRAVITY_CLI_PATH"]
        guard let executable = override.flatMap({ FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil })
            ?? AgentLimitProcess.executable(named: "agy")
        else {
            return failure(.antigravity, "Install the Antigravity CLI (agy) and sign in to read quota.", source: source)
        }
        let output = await AgentLimitProcess.background { () -> AgentLimitProcess.Output? in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("local-observer-agy-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            return AgentLimitProcess.run(executable, ["-p", "/usage", "--output-format", "json"],
                                         currentDirectory: directory, timeout: 90)
        }
        guard let output else {
            return failure(.antigravity, "The agy usage report could not be started.", source: source, transient: true)
        }
        if output.timedOut {
            return failure(.antigravity, "The agy usage report timed out.", source: source, transient: true)
        }
        let now = Date()
        let windows = antigravityWindows(from: output.stdout, observedAt: now)
        guard !windows.isEmpty else {
            let status = AgentLimitJSON.firstObject(in: output.stdout).flatMap { AgentLimitJSON.string($0["status"]) }
            let message = status == nil || status == "SUCCESS"
                ? "agy returned no quota. Run agy and sign in, then try again."
                : "agy could not read quota. Run agy and sign in, then try again."
            return failure(.antigravity, message, source: source)
        }
        return AgentLimitOutcome(AgentLimitReport(
            agent: .antigravity, status: .connected, windows: windows, fetchedAt: now, source: source))
    }
}

// MARK: - Cache

struct AgentLimitOutcome: Sendable {
    var report: AgentLimitReport
    /// Network or rate-limit failures that should keep showing the last good windows.
    var transient: Bool
    var retryAfter: Date?

    init(_ report: AgentLimitReport, transient: Bool = false, retryAfter: Date? = nil) {
        self.report = report
        self.transient = transient
        self.retryAfter = retryAfter
    }
}

actor AgentLimitCache {
    private struct Entry {
        var report: AgentLimitReport
        var fetchedAt: Date
        var blockedUntil: Date?
        var lastGood: AgentLimitReport?
    }

    private var entries: [AgentKind: Entry] = [:]
    private var inFlight: [AgentKind: Task<AgentLimitOutcome, Never>] = [:]

    /// Drops cached reports for agents the user disconnected.
    func forget(except connected: Set<AgentKind>) {
        for agent in entries.keys where !connected.contains(agent) { entries[agent] = nil }
    }

    func report(
        for agent: AgentKind,
        force: Bool,
        interval: TimeInterval,
        fetch: @escaping @Sendable () async -> AgentLimitOutcome
    ) async -> AgentLimitReport {
        let now = Date()
        if let entry = entries[agent] {
            if let blocked = entry.blockedUntil, blocked > now { return entry.report }
            if !force, now.timeIntervalSince(entry.fetchedAt) < interval { return entry.report }
        }
        let task: Task<AgentLimitOutcome, Never>
        if let existing = inFlight[agent] {
            task = existing
        } else {
            task = Task.detached(priority: .utility) { await fetch() }
            inFlight[agent] = task
        }
        let outcome = await task.value
        if inFlight[agent] == task {
            inFlight[agent] = nil
            store(outcome, for: agent)
        }
        return entries[agent]?.report ?? outcome.report
    }

    private func store(_ outcome: AgentLimitOutcome, for agent: AgentKind) {
        let previousGood = entries[agent]?.lastGood
        var report = outcome.report
        var lastGood = previousGood
        if report.status == .connected {
            lastGood = report
        } else if outcome.transient, var kept = previousGood {
            kept.message = report.message
            report = kept
        }
        entries[agent] = Entry(report: report, fetchedAt: Date(), blockedUntil: outcome.retryAfter, lastGood: lastGood)
    }
}

// MARK: - Codex app-server

/// Minimal JSON-RPC client for `codex app-server` over stdio: initialize, then `account/rateLimits/read`.
/// The child process is always terminated before returning.
final class AgentLimitCodexAppServer: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: Data] = [:]
    private var closed = false

    static func readRateLimits(executable: String, timeout: TimeInterval = 4) -> Data? {
        let client = AgentLimitCodexAppServer()
        return client.run(executable: executable, timeout: timeout)
    }

    private func run(executable: String, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exited.signal()
            self.markClosed()
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.markClosed()
            } else {
                self.consume(chunk)
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            AgentLimitProcess.stop(process, exited: exited)
            process.terminationHandler = nil
        }
        do { try process.run() } catch { return nil }

        func send(_ object: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            data.append(0x0A)
            do { try input.fileHandleForWriting.write(contentsOf: data) } catch { return false }
            return true
        }
        guard send([
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": ["clientInfo": ["name": "local_observer", "title": "Local Observer", "version": "1.0"]],
        ]) else { return nil }
        guard wait(for: 0, timeout: timeout) != nil else { return nil }
        guard send(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()]),
              send(["jsonrpc": "2.0", "id": 1, "method": "account/rateLimits/read"])
        else { return nil }
        guard let response = wait(for: 1, timeout: timeout),
              let object = AgentLimitJSON.object(response),
              object["result"] != nil
        else { return nil }
        return response
    }

    private func consume(_ chunk: Data) {
        condition.lock()
        defer { condition.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = AgentLimitJSON.object(Data(line)),
                  let id = AgentLimitJSON.double(object["id"]),
                  object["method"] == nil
            else { continue }
            responses[Int(id)] = Data(line)
        }
        if buffer.count > 8 * 1024 * 1024 { buffer.removeAll() }
        condition.broadcast()
    }

    private func markClosed() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    private func wait(for id: Int, timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil, !closed {
            if !condition.wait(until: deadline) { break }
        }
        return responses[id]
    }
}

// MARK: - Cursor local storage

enum AgentLimitCursorStore {
    struct Stored {
        var accessToken: String?
        var email: String?
        var membership: String?
    }

    static var databasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
    }

    /// Reads Cursor's sign-in values read-only. Returns nil when Cursor is not installed.
    static func read() -> Stored? {
        let path = databasePath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1500)
        func value(_ key: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            let result = String(cString: text).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
            return result.isEmpty ? nil : result
        }
        return Stored(accessToken: value("cursorAuth/accessToken"),
                      email: value("cursorAuth/cachedEmail"),
                      membership: value("cursorAuth/stripeMembershipType"))
    }

    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        return Data(base64Encoded: payload).flatMap(AgentLimitJSON.object)
    }
}
