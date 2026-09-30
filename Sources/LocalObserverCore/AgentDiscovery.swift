import Foundation

public enum AgentDiscovery {
    struct ProcessRecord {
        var process: AgentProcess
        var arguments: String
    }

    static func parseProcessRecords(_ text: String, now: Date = .now) -> [ProcessRecord] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count >= 6,
                  let pid = Int32(parts[0]),
                  let parentPID = Int32(parts[1]) else { return nil }
            let elapsed = parseElapsed(String(parts[2]))
            let processName = String(parts[4])
            let arguments = String(parts[5])
            let argumentPath = arguments.split(separator: " ").first.map(String.init) ?? ""
            let executablePath = processName.hasPrefix("/")
                ? processName
                : (argumentPath.hasPrefix("/") ? argumentPath : (argumentPath.isEmpty ? processName : argumentPath))
            return ProcessRecord(
                process: AgentProcess(
                    pid: pid,
                    parentPID: parentPID,
                    processName: processName,
                    executablePath: executablePath,
                    workingDirectory: "",
                    startedAt: now.addingTimeInterval(-elapsed),
                    terminal: String(parts[3])
                ),
                arguments: arguments
            )
        }
    }

    public static func parseProcessTable(_ text: String, now: Date = .now) -> [AgentProcess] {
        parseProcessRecords(text, now: now).map(\.process)
    }

    static func parseElapsed(_ value: String) -> TimeInterval {
        var days = 0
        var rest = Substring(value)
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let components = rest.split(separator: ":").compactMap { Double($0) }
        var seconds = 0.0
        for component in components { seconds = seconds * 60 + component }
        return TimeInterval(days * 86_400) + seconds
    }

    public static func classify(processName: String, arguments: String) -> AgentKind? {
        func base(_ path: String) -> String {
            var name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if name.hasSuffix(".exe") { name.removeLast(4) }
            return name
        }
        let name = base(processName)
        let argumentName = arguments.split(separator: " ").first.map { base(String($0)) } ?? ""
        let path = (processName + " " + arguments).lowercased()
        // Background infrastructure, not sessions.
        if path.contains("--managed-daemon") || path.contains("pid-update-loop") { return nil }
        for agent in AgentKind.allCases {
            for marker in agent.processMarkers where name == marker || argumentName == marker {
                return agent
            }
        }
        if let app = appAgent(processName: processName) { return app }
        if path.contains("/@anthropic-ai/claude-code/") { return .claude }
        if path.contains("/@openai/codex") && (name == "node" || name == "codex") { return .codex }
        if path.contains("/opencode") && name.contains("opencode") { return .openCode }
        if path.contains("@github/copilot") || path.contains("github-copilot") { return .copilot }
        if path.contains("cursor-agent") { return .cursor }
        if path.contains("/.pi/") && (name == "pi" || arguments.contains(" pi ")) { return .pi }
        return nil
    }

    /// Desktop apps count only through their main executable, never their helpers.
    static func appAgent(processName: String) -> AgentKind? {
        let apps: [(String, AgentKind)] = [
            ("/Antigravity.app/Contents/MacOS/", .antigravity),
            ("/Antigravity IDE.app/Contents/MacOS/", .antigravity),
            ("/Cursor.app/Contents/MacOS/", .cursor),
            ("/Qoder.app/Contents/MacOS/", .qoder)
        ]
        for (marker, agent) in apps {
            guard let range = processName.range(of: marker) else { continue }
            let executable = processName[range.upperBound...]
            if !executable.contains("/") && !executable.lowercased().contains("helper") { return agent }
        }
        return nil
    }

    public static func isDesktopApp(_ processName: String) -> Bool { appAgent(processName: processName) != nil }

    /// Every GUI app currently hosting a process, as host detection sees them. Used by verification.
    public static func currentHostApps(now: Date = .now) -> [AgentHostApp] {
        let table = processTable(now: now)
        return table.keys.compactMap { hostApp(for: $0, in: table) }
    }

    /// Full-path process table. `comm` keeps the whole executable path (spaces included), which host detection needs.
    static func processTable(now: Date) -> [Int32: ProcessRecord] {
        let commText = runTool("/bin/ps", ["-axo", "pid=,ppid=,etime=,tty=,comm="])
        let argsText = runTool("/bin/ps", ["-axo", "pid=,args="])
        var arguments: [Int32: String] = [:]
        for line in argsText.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            arguments[pid] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        var table: [Int32: ProcessRecord] = [:]
        for line in commText.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]), let parentPID = Int32(parts[1]) else { continue }
            // ps pads columns; the final split keeps that padding, which broke host paths ("   /Applications/…").
            let comm = parts[4].trimmingCharacters(in: .whitespaces)
            table[pid] = ProcessRecord(
                process: AgentProcess(
                    pid: pid,
                    parentPID: parentPID,
                    processName: comm,
                    executablePath: comm,
                    workingDirectory: "",
                    startedAt: now.addingTimeInterval(-parseElapsed(String(parts[2]))),
                    terminal: String(parts[3])
                ),
                arguments: arguments[pid] ?? comm
            )
        }
        return table
    }

    /// Walks up the parent chain to the first `.app` bundle: the terminal, editor, or desktop app hosting the agent.
    static func hostApp(for pid: Int32, in table: [Int32: ProcessRecord]) -> AgentHostApp? {
        var current: Int32? = pid
        var hops = 0
        while let id = current, id > 1, hops < 24, let record = table[id] {
            let path = record.process.processName
            if let range = path.range(of: ".app/") {
                let bundle = String(path[..<range.lowerBound]) + ".app"
                let name = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
                return AgentHostApp(pid: id, name: name, bundlePath: bundle)
            }
            current = record.process.parentPID
            hops += 1
        }
        return nil
    }

    /// Agent processes worth listing: classified, enabled, not spawned by us, and not a child of another process of the same agent.
    static func agentProcesses(in table: [Int32: ProcessRecord], enabledAgents: Set<AgentKind>) -> [(AgentKind, AgentProcess)] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var kinds: [Int32: AgentKind] = [:]
        for (pid, record) in table {
            if let agent = classify(processName: record.process.processName, arguments: record.arguments) {
                kinds[pid] = agent
            }
        }
        return kinds.compactMap { pid, agent -> (AgentKind, AgentProcess)? in
            guard enabledAgents.contains(agent), let record = table[pid] else { return nil }
            if record.process.parentPID == ownPID { return nil }
            var parent = record.process.parentPID
            var hops = 0
            while parent > 1, hops < 24, let ancestor = table[parent] {
                if kinds[parent] == agent { return nil }
                parent = ancestor.process.parentPID
                hops += 1
            }
            var process = record.process
            process.host = hostApp(for: pid, in: table)
            return (agent, process)
        }
    }

    public static func scan(enabledAgents: Set<AgentKind>, historyDays: Int) async -> AgentSnapshot {
        let discoveredAt = Date()
        let system = await background {
            let table = processTable(now: discoveredAt)
            let classified = agentProcesses(in: table, enabledAgents: enabledAgents)
            let directories = workingDirectories(pids: Set(classified.map { $0.1.pid }))
            return classified.map { agent, process in
                var enriched = process
                enriched.workingDirectory = directories[process.pid] ?? ""
                return (agent, enriched)
            }
        }

        async let artifactReads = readArtifacts(enabledAgents: enabledAgents, historyDays: historyDays)
        async let openCodeRead = AgentProviderClients.readOpenCode(enabledAgents: enabledAgents, historyDays: historyDays)
        let results = await (artifactReads, openCodeRead)

        var historicalSessions = results.0.sessions
        var usageEvents = results.0.usageEvents
        var quotas = results.0.quotaWindows
        var warnings = results.0.warnings
        if let openCode = results.1 {
            historicalSessions.append(contentsOf: openCode.sessions)
            usageEvents.append(contentsOf: openCode.usageEvents)
            quotas.append(contentsOf: openCode.quotaWindows)
            warnings.append(contentsOf: openCode.warnings)
        }

        usageEvents = deduplicate(usageEvents)
        let sessionsByID = Dictionary(grouping: historicalSessions, by: \.id)
        historicalSessions = sessionsByID.values.compactMap { $0.max { $0.updatedAt < $1.updatedAt } }
            .sorted { $0.updatedAt > $1.updatedAt }
        let quotasByID = Dictionary(grouping: quotas, by: \.id)
        quotas = quotasByID.values.compactMap { $0.max { $0.observedAt < $1.observedAt } }
            .sorted { lhs, rhs in
                if lhs.agent != rhs.agent { return lhs.agent.name < rhs.agent.name }
                return lhs.usedPercent > rhs.usedPercent
            }

        let runningSessions = pairRunning(system, with: historicalSessions, now: discoveredAt)

        let enabled = enabledAgents.isEmpty ? Set(AgentKind.allCases) : enabledAgents
        let integrations = AgentKind.allCases.map { agent in
            integration(
                agent: agent,
                enabled: enabled.contains(agent),
                installedPath: installedPath(for: agent),
                runningSessions: runningSessions,
                historicalSessions: historicalSessions,
                usageEvents: usageEvents,
                warnings: warnings
            )
        }

        return AgentSnapshot(
            discoveredAt: discoveredAt,
            processes: runningSessions.sorted { $0.agent.name < $1.agent.name },
            sessions: historicalSessions,
            usageEvents: usageEvents.sorted { $0.observedAt > $1.observedAt },
            limitReports: limitReports(quotas),
            integrations: integrations,
            warnings: Array(Set(warnings)).sorted()
        )
    }

    /// Pairs each running process with the transcript it is most likely writing: same agent and folder,
    /// newest first, each transcript used once. Unpaired processes still appear, just without usage.
    static func pairRunning(_ processes: [(AgentKind, AgentProcess)], with sessions: [AgentSession], now: Date) -> [AgentSession] {
        var claimed = Set<String>()
        let ordered = processes.sorted { $0.1.startedAt > $1.1.startedAt }
        return ordered.map { agent, process in
            let projectPath = process.workingDirectory
            let name = projectName(for: projectPath)
            let isApp = isDesktopApp(process.processName)
            let match = isApp ? nil : sessions
                .filter { session in
                    session.agent == agent && !claimed.contains(session.id) &&
                        !session.projectPath.isEmpty && session.projectPath == projectPath &&
                        session.updatedAt >= process.startedAt.addingTimeInterval(-120)
                }
                .max { $0.updatedAt < $1.updatedAt }
            if let match { claimed.insert(match.id) }
            let state: AgentActivityState
            switch match?.state {
            case .needsInput?: state = .needsInput
            case .failed?: state = .failed
            case .working?, .thinking?, .toolUse?: state = .working
            case .idle?, .waiting?: state = .waiting
            default:
                // No transcript yet: fresh session, or an app window with nothing to report.
                state = isApp ? .idle : .running
            }
            return AgentSession(
                id: "\(agent.rawValue)-process-\(process.id)",
                agent: agent,
                sessionID: match?.sessionID ?? process.id,
                title: match?.title ?? (isApp ? "\(agent.name) app" : name),
                process: process,
                projectPath: projectPath,
                projectName: name,
                model: match?.model ?? "",
                account: match?.account ?? "",
                branch: match?.branch ?? "",
                state: state,
                startedAt: process.startedAt,
                updatedAt: match?.updatedAt ?? process.startedAt,
                sourcePath: match?.sourcePath ?? "",
                sourceKind: .process,
                usage: match?.usage,
                cost: match?.cost,
                requests: match?.requests,
                costIsEstimated: match?.costIsEstimated ?? false,
                contextTokens: match?.contextTokens
            )
        }
    }

    /// Groups locally recovered quota windows into per-agent reports.
    static func limitReports(_ windows: [AgentQuotaWindow]) -> [AgentLimitReport] {
        Dictionary(grouping: windows, by: \.agent).map { agent, windows in
            AgentLimitReport(
                agent: agent,
                status: .local,
                windows: windows.sorted { $0.kind.sortOrder < $1.kind.sortOrder },
                fetchedAt: windows.map(\.observedAt).max(),
                source: windows.first?.source ?? "Local session artifact"
            )
        }
        .sorted { $0.agent.name < $1.agent.name }
    }

    public static func runTool(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func readArtifacts(enabledAgents: Set<AgentKind>, historyDays: Int) async -> AgentArtifactResult {
        await withTaskGroup(of: AgentArtifactResult.self) { group in
            for agent in AgentKind.allCases where enabledAgents.contains(agent) {
                group.addTask {
                    await AgentArtifactReader.read(agent: agent, historyDays: historyDays)
                }
            }
            var combined = AgentArtifactResult()
            for await result in group {
                combined.sessions.append(contentsOf: result.sessions)
                combined.usageEvents.append(contentsOf: result.usageEvents)
                combined.quotaWindows.append(contentsOf: result.quotaWindows)
                combined.warnings.append(contentsOf: result.warnings)
            }
            return combined
        }
    }

    private static func workingDirectories(pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let text = runTool("/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd", "-Fn"])
        var result: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in text.split(separator: "\n") {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            if first == "p" {
                pid = Int32(value) ?? 0
            } else if first == "n", pid != 0, result[pid] == nil {
                result[pid] = value
            }
        }
        return result
    }

    private final class InstalledPaths: @unchecked Sendable {
        var paths: [AgentKind: (path: String, checkedAt: Date)] = [:]
        let lock = NSLock()
    }
    private static let installedPaths = InstalledPaths()

    /// Where the agent is installed. Looking it up spawns `which` per executable name, so the answer is kept for
    /// five minutes instead of being asked again on every refresh.
    private static func installedPath(for agent: AgentKind) -> String {
        installedPaths.lock.lock()
        if let cached = installedPaths.paths[agent], Date().timeIntervalSince(cached.checkedAt) < 300 {
            installedPaths.lock.unlock()
            return cached.path
        }
        installedPaths.lock.unlock()
        let path = lookUpInstalledPath(for: agent)
        installedPaths.lock.lock()
        installedPaths.paths[agent] = (path, Date())
        installedPaths.lock.unlock()
        return path
    }

    private static func lookUpInstalledPath(for agent: AgentKind) -> String {
        for name in agent.executableNames {
            let path = runTool("/usr/bin/which", [name])
                .split(separator: "\n")
                .first
                .map(String.init) ?? ""
            if !path.isEmpty { return path }
        }
        let desktopPaths: [AgentKind: [String]] = [
            .antigravity: ["/Applications/Antigravity.app", "\(NSHomeDirectory())/Applications/Antigravity.app"],
            .cursor: ["/Applications/Cursor.app", "\(NSHomeDirectory())/Applications/Cursor.app"],
            .copilot: ["/Applications/GitHub Copilot.app", "\(NSHomeDirectory())/Applications/GitHub Copilot.app"],
            .qoder: ["/Applications/Qoder.app", "\(NSHomeDirectory())/Applications/Qoder.app"]
        ]
        if let path = desktopPaths[agent]?.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return path
        }
        return dataURLs(for: agent).first.map(\.path) ?? ""
    }

    static func dataURLs(for agent: AgentKind) -> [URL] {
        agent.dataDirectories.map { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent($0) }
    }

    static func projectName(for path: String) -> String {
        guard !path.isEmpty, path != NSHomeDirectory(), path != "/" else { return "Unknown workspace" }
        let markers = [
            "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Package.swift",
            "docker-compose.yml", "compose.yaml", ".git"
        ]
        var directory = URL(fileURLWithPath: path)
        for _ in 0..<6 {
            if markers.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                return directory.lastPathComponent
            }
            let parent = directory.deletingLastPathComponent().path
            if parent == directory.path || parent.isEmpty || parent == NSHomeDirectory() || parent == "/" { break }
            directory = URL(fileURLWithPath: parent)
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func deduplicate(_ events: [AgentUsageEvent]) -> [AgentUsageEvent] {
        let grouped = Dictionary(grouping: events, by: \.id)
        return grouped.values.compactMap { $0.max { lhs, rhs in
            lhs.observedAt < rhs.observedAt
        } }
    }

    private static func integration(
        agent: AgentKind,
        enabled: Bool,
        installedPath: String,
        runningSessions: [AgentSession],
        historicalSessions: [AgentSession],
        usageEvents: [AgentUsageEvent],
        warnings: [String]
    ) -> AgentIntegration {
        let running = runningSessions.filter { $0.agent == agent }
        let sessions = historicalSessions.filter { $0.agent == agent }
        let events = usageEvents.filter { $0.agent == agent }
        let dataAvailable = dataURLs(for: agent).contains { FileManager.default.fileExists(atPath: $0.path) }
        let isInstalled = !installedPath.isEmpty || dataAvailable
        let sourceState: AgentSourceState
        let message: String
        if !enabled {
            sourceState = .disabled
            message = "Disabled in Agent settings"
        } else if !isInstalled && running.isEmpty {
            sourceState = .unavailable
            message = "No local installation or session data found"
        } else if !running.isEmpty {
            sourceState = .available
            let warning = warnings.first { $0.lowercased().contains(agent.name.lowercased()) }
            message = warning ?? (events.isEmpty
                ? "Process discovery is active; usage data is not available yet"
                : "Reading local agent artifacts")
        } else if let warning = warnings.first(where: { $0.lowercased().contains(agent.name.lowercased()) }) {
            sourceState = .error
            message = warning
        } else if !events.isEmpty || !sessions.isEmpty {
            sourceState = .available
            message = "Reading local agent artifacts"
        } else {
            sourceState = .stale
            message = "Installed, but no recent session activity was found"
        }
        let updated = ([running.map(\.updatedAt), sessions.map(\.updatedAt), events.map(\.observedAt)].flatMap { $0 }).max()
        return AgentIntegration(
            agent: agent,
            isInstalled: isInstalled,
            installedPath: installedPath,
            runningProcessCount: running.count,
            sessionCount: sessions.count,
            usageEventCount: events.count,
            sourceState: sourceState,
            message: message,
            lastUpdated: updated
        )
    }
}
