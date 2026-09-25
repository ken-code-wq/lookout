import Foundation

enum AgentProviderClients {
    static func readCodexQuotas(isEnabled: Bool) async -> (windows: [AgentQuotaWindow], warnings: [String]) {
        guard isEnabled else { return ([], []) }
        return await AgentDiscovery.background {
            guard let executable = installedExecutable(named: "codex") else { return ([], []) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["app-server"]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let initialize: [String: Any] = [
                    "method": "initialize",
                    "id": 0,
                    "params": ["clientInfo": ["name": "local_observer", "title": "Local Observer", "version": "1.0"]]
                ]
                input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: initialize))
                input.fileHandleForWriting.write(Data("\n".utf8))
                Thread.sleep(forTimeInterval: 0.45)
                guard process.isRunning else {
                    return ([], ["Codex rate limits could not be read from app-server"])
                }
                let initialized: [String: Any] = ["method": "initialized", "params": [:]]
                let request: [String: Any] = ["method": "account/rateLimits/read", "id": 1]
                input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: initialized))
                input.fileHandleForWriting.write(Data("\n".utf8))
                input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request))
                input.fileHandleForWriting.write(Data("\n".utf8))
                Thread.sleep(forTimeInterval: 0.9)
                if process.isRunning { process.terminate() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let windows = parseCodexQuotaOutput(data)
                return (windows, windows.isEmpty ? ["Codex rate limits were not present in the current account response"] : [])
            } catch {
                if process.isRunning { process.terminate() }
                return ([], ["Codex rate limits could not be read from app-server"])
            }
        }
    }

    /// OpenCode history from its local SQLite store; no running server is needed.
    static func readOpenCode(enabledAgents: Set<AgentKind>, historyDays: Int) async -> AgentArtifactResult? {
        guard enabledAgents.contains(.openCode) else { return nil }
        return await AgentDiscovery.background {
            AgentOpenCodeReader.read(historyDays: historyDays)
        }
    }

    private static func parseCodexQuotaOutput(_ data: Data) -> [AgentQuotaWindow] {
        let rows = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        var result: [AgentQuotaWindow] = []
        for row in rows {
            guard let object = AgentJSON.object(row),
                  AgentJSON.int(object, ["id"]) == 1,
                  let payload = AgentJSON.object(object, ["result"]) else { continue }
            let observedAt = Date()
            if let buckets = AgentJSON.object(payload, ["rateLimitsByLimitId"]) {
                for (bucketID, value) in buckets {
                    guard let bucket = AgentJSON.object(value) else { continue }
                    appendCodexBucket(bucket, label: AgentJSON.string(bucket, ["limitName"]) ?? bucketID, observedAt: observedAt, windows: &result)
                }
            } else if let limits = AgentJSON.object(payload, ["rateLimits"]) {
                appendCodexBucket(limits, label: AgentJSON.string(limits, ["limitName"]) ?? "Codex", observedAt: observedAt, windows: &result)
            }
        }
        return result
    }

    private static func appendCodexBucket(
        _ object: [String: Any],
        label: String,
        observedAt: Date,
        windows: inout [AgentQuotaWindow]
    ) {
        if let primary = AgentJSON.object(object, ["primary"]) {
            appendCodexWindow(primary, label: "\(label) primary", observedAt: observedAt, windows: &windows)
        }
        if let secondary = AgentJSON.object(object, ["secondary"]) {
            appendCodexWindow(secondary, label: "\(label) secondary", observedAt: observedAt, windows: &windows)
        }
        if AgentJSON.object(object, ["primary"]) == nil, AgentJSON.object(object, ["secondary"]) == nil {
            appendCodexWindow(object, label: label, observedAt: observedAt, windows: &windows)
        }
    }

    private static func appendCodexWindow(
        _ object: [String: Any],
        label: String,
        observedAt: Date,
        windows: inout [AgentQuotaWindow]
    ) {
        guard let used = AgentJSON.double(object, ["usedPercent", "used_percent", "usedPercentage"]) else { return }
        let minutes = AgentJSON.int(object, ["windowDurationMins", "window_duration_mins"])
        let displayLabel = minutes.map { "\(label) · \($0)m" } ?? label
        windows.append(AgentQuotaWindow(
            id: "codex|\(displayLabel)",
            agent: .codex,
            label: displayLabel,
            usedPercent: min(max(used, 0), 100),
            resetsAt: AgentJSON.date(object, ["resetsAt", "resets_at"]),
            observedAt: observedAt,
            source: "Codex app-server",
            account: ""
        ))
    }

    private static func installedExecutable(named name: String) -> String? {
        AgentDiscovery.runTool("/usr/bin/which", [name])
            .split(separator: "\n")
            .first
            .map(String.init)
    }
}
