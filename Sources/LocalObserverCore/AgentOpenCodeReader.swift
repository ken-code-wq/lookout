import Foundation

struct OpenCodeUsageRecord: Sendable {
    var messageID: String
    var sessionID: String
    var timestamp: Date
    var model: String
    var cwd: String
    var usage: TokenUsage
    var reportedCost: Double?
    var completed: Bool
}

/// Reads OpenCode's local store (`~/.local/share/opencode/opencode*.db`, plus pre-SQLite
/// `storage/message/**.json`), read-only, without talking to a running server.
enum AgentOpenCodeReader {
    private final class DatabaseCache: @unchecked Sendable {
        var records: [String: OpenCodeUsageRecord] = [:]
        var maxUpdated: [String: Int64] = [:]
        var legacy: [String: (stamp: AgentFileStamp, record: OpenCodeUsageRecord?)] = [:]
        var historyDays = 0
        let lock = NSLock()
    }

    private static let cache = DatabaseCache()

    static func read(historyDays: Int, now: Date = Date()) -> AgentArtifactResult {
        let cutoff = now.addingTimeInterval(-Double(historyDays) * 86_400)
        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)
        let root = dataRoot()
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if historyDays > cache.historyDays {
            // A longer window needs rows the incremental cursor already skipped.
            cache.records.removeAll()
            cache.maxUpdated.removeAll()
        }
        cache.historyDays = historyDays
        cache.records = cache.records.filter { $0.value.timestamp >= cutoff }

        var warnings: [String] = []
        var sessions: [String: SessionRow] = [:]
        var found = false
        let databases = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .sorted { $0 == "opencode.db" ? true : ($1 == "opencode.db" ? false : $0 < $1) }
        for name in databases {
            found = true
            let path = root.appendingPathComponent(name).path
            guard let database = AgentSQLiteDatabase(path: path) else {
                warnings.append("OpenCode database \(name) could not be opened")
                continue
            }
            let tables = database.tables()
            if tables.contains("session") {
                readSessions(database, cutoffMs: cutoffMs, into: &sessions)
            }
            for table in ["message", "session_message"] where tables.contains(table) {
                if !readMessages(database, table: table, key: "\(path)|\(table)", cutoffMs: cutoffMs) {
                    warnings.append("OpenCode \(table) history could not be read")
                }
            }
        }
        found = readLegacy(root: root, cutoff: cutoff) || found
        guard found else { return AgentArtifactResult() }

        let records = cache.records.values.filter { $0.timestamp >= cutoff }
        let names = AgentProjectNames()
        var result = AgentArtifactResult(warnings: warnings)
        var eventsBySession: [String: [AgentUsageEvent]] = [:]
        var latestBySession: [String: OpenCodeUsageRecord] = [:]
        for record in records {
            let session = sessions[record.sessionID]
            let projectPath = session?.directory ?? record.cwd
            let event = AgentUsageFactory.event(
                id: "opencode|\(record.messageID)",
                agent: .openCode,
                sessionID: record.sessionID,
                projectPath: projectPath,
                projectName: names.name(for: projectPath),
                model: record.model,
                observedAt: record.timestamp,
                usage: record.usage,
                reportedCost: record.reportedCost,
                sourcePath: root.path
            )
            result.usageEvents.append(event)
            eventsBySession[record.sessionID, default: []].append(event)
            if record.timestamp > latestBySession[record.sessionID]?.timestamp ?? .distantPast {
                latestBySession[record.sessionID] = record
            }
        }
        for row in sessions.values {
            let projectName = names.name(for: row.directory)
            let latest = latestBySession[row.id]
            let age = now.timeIntervalSince(row.updated)
            let state: AgentActivityState
            if let latest, !latest.completed, age < 120 {
                state = age < 10 ? .working : .thinking
            } else {
                state = age < 10 ? .working : .idle
            }
            var session = AgentSession(
                id: "opencode|session|\(row.id)",
                agent: .openCode,
                sessionID: row.id,
                title: row.title.isEmpty ? projectName : ClaudeText.titled(row.title),
                process: nil,
                projectPath: row.directory,
                projectName: projectName,
                model: latest?.model ?? "",
                account: "",
                branch: "",
                state: state,
                startedAt: row.created,
                updatedAt: row.updated,
                sourcePath: root.path,
                sourceKind: .transcript,
                usage: nil,
                cost: nil,
                requests: nil,
                contextTokens: latest.map { ($0.usage.uncachedInputTokens ?? 0) + ($0.usage.cachedInputTokens ?? 0) + ($0.usage.cacheCreationTokens ?? 0) }
            )
            AgentUsageFactory.apply(eventsBySession[row.id] ?? [], to: &session)
            result.sessions.append(session)
        }
        return result
    }

    private static func dataRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return AgentDiscovery.dataURLs(for: .openCode)[0]
    }

    private struct SessionRow {
        var id: String
        var directory: String
        var title: String
        var created: Date
        var updated: Date
    }

    private static func readSessions(_ database: AgentSQLiteDatabase, cutoffMs: Int64, into sessions: inout [String: SessionRow]) {
        let columns = database.columns(of: "session")
        guard columns.isSuperset(of: ["id", "time_updated"]) else { return }
        let directory = columns.contains("directory") ? "directory" : "''"
        let title = columns.contains("title") ? "title" : "''"
        let created = columns.contains("time_created") ? "time_created" : "time_updated"
        database.query(
            "SELECT id, \(directory), \(title), \(created), time_updated FROM session WHERE time_updated >= ?",
            [.int(cutoffMs)]
        ) { row in
            guard let id = row.text(0) else { return }
            let updated = Date(timeIntervalSince1970: Double(row.int64(4) ?? 0) / 1000)
            sessions[id] = SessionRow(
                id: id,
                directory: row.text(1) ?? "",
                title: row.text(2) ?? "",
                created: Date(timeIntervalSince1970: Double(row.int64(3) ?? 0) / 1000),
                updated: updated
            )
        }
    }

    /// Incremental by `time_updated`: only rows changed since the previous pass are parsed.
    private static func readMessages(_ database: AgentSQLiteDatabase, table: String, key: String, cutoffMs: Int64) -> Bool {
        let columns = database.columns(of: table)
        guard columns.isSuperset(of: ["id", "data"]) else { return false }
        let sessionColumn = columns.contains("session_id") ? "session_id" : "''"
        let createdColumn = columns.contains("time_created") ? "time_created" : "NULL"
        let updatedColumn = columns.contains("time_updated") ? "time_updated" : "NULL"
        var predicates = ["instr(data, '\"assistant\"') > 0"]
        var bindings: [AgentSQLiteDatabase.Binding] = []
        if table == "session_message", columns.contains("type") { predicates.append("type = 'assistant'") }
        if createdColumn != "NULL" {
            predicates.append("\(createdColumn) >= ?")
            bindings.append(.int(cutoffMs))
        }
        let since = cache.maxUpdated[key] ?? -1
        if updatedColumn != "NULL" {
            predicates.append("\(updatedColumn) > ?")
            bindings.append(.int(since))
        }
        var newest = since
        let ok = database.query(
            "SELECT id, \(sessionColumn), \(createdColumn), \(updatedColumn), data FROM \(table) WHERE \(predicates.joined(separator: " AND "))",
            bindings
        ) { row in
            guard let id = row.text(0), let data = row.text(4), let object = AgentJSON.parseObject(data) else { return }
            if let updated = row.int64(3) { newest = max(newest, updated) }
            let createdMs = row.int64(2)
            if let record = parseMessage(object, id: id, sessionID: row.text(1), createdMs: createdMs) {
                cache.records[id] = record
            }
        }
        if ok { cache.maxUpdated[key] = newest }
        return ok
    }

    /// OpenCode keeps uncached input, cache reads/writes, output and reasoning as separate counts.
    static func parseMessage(_ message: [String: Any], id: String, sessionID: String?, createdMs: Int64?) -> OpenCodeUsageRecord? {
        if let role = AgentJSON.string(message, ["role"]), role != "assistant" { return nil }
        guard let tokens = AgentJSON.object(message, ["tokens"]) else { return nil }
        let cache = AgentJSON.object(tokens, ["cache"]) ?? [:]
        let modelObject = AgentJSON.object(message, ["model"]) ?? [:]
        let model = AgentJSON.string(modelObject, ["id", "modelID"]) ?? AgentJSON.string(message, ["modelID"]) ?? ""
        let provider = AgentJSON.string(modelObject, ["providerID"]) ?? AgentJSON.string(message, ["providerID"]) ?? ""
        let timestamp = AgentJSON.path(message, ["time", "created"]).flatMap(AgentJSON.date)
            ?? createdMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        guard !model.isEmpty, let timestamp else { return nil }
        let reasoning = max(0, AgentJSON.int64(tokens, ["reasoning"]) ?? 0)
        let usage = TokenUsage(
            uncachedInputTokens: max(0, AgentJSON.int64(tokens, ["input"]) ?? 0),
            cachedInputTokens: max(0, AgentJSON.int64(cache, ["read"]) ?? 0),
            cacheCreationTokens: max(0, AgentJSON.int64(cache, ["write"]) ?? 0),
            outputTokens: max(0, AgentJSON.int64(tokens, ["output"]) ?? 0) + reasoning,
            reasoningTokens: reasoning
        )
        guard (usage.processedTokens ?? 0) > 0 else { return nil }
        let cost = AgentJSON.double(message, ["cost"])
        return OpenCodeUsageRecord(
            messageID: id,
            sessionID: sessionID ?? AgentJSON.string(message, ["sessionID"]) ?? "",
            timestamp: timestamp,
            model: provider.isEmpty ? model : "\(provider)/\(model)",
            cwd: AgentJSON.path(message, ["path", "cwd"]) as? String ?? "",
            usage: usage,
            // OpenCode writes 0 for models it cannot price, including subscription models.
            reportedCost: cost.flatMap { $0 > 0 ? $0 : nil },
            completed: AgentJSON.path(message, ["time", "completed"]) != nil
        )
    }

    /// Pre-SQLite installs: one JSON file per message. Database rows win over their migrated copies.
    private static func readLegacy(root: URL, cutoff: Date) -> Bool {
        let directory = root.appendingPathComponent("storage/message", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        let files = AgentFileScanner.files(in: [directory], since: cutoff) { $0.pathExtension == "json" }
        var live: Set<String> = []
        for file in files {
            let id = file.url.deletingPathExtension().lastPathComponent
            live.insert(file.url.path)
            if let cached = cache.legacy[file.url.path], cached.stamp == file.stamp {
                if let record = cached.record, cache.records[id] == nil { cache.records[id] = record }
                continue
            }
            let record = (try? Data(contentsOf: file.url))
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                .flatMap { parseMessage($0, id: id, sessionID: nil, createdMs: nil) }
            cache.legacy[file.url.path] = (file.stamp, record)
            if let record, cache.records[id] == nil { cache.records[id] = record }
        }
        cache.legacy = cache.legacy.filter { live.contains($0.key) }
        return !files.isEmpty
    }
}
