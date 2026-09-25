import Foundation

/// Antigravity keeps each conversation in `conversations/<id>.db`; usage metadata is protobuf
/// in the `gen_metadata` and `steps` tables, independent of conversation text. Field numbers
/// follow T3 Code's `antigravityUsageReader.ts`.
enum AgentAntigravityReader {
    struct UsageCandidate: Sendable {
        var keys: [String]
        var sessionID: String
        var timestamp: Date
        var timestampQuality: Int
        var model: String
        var uncached: Int64
        var cached: Int64
        var cacheCreation: Int64
        var output: Int64
        var reasoning: Int64
        var fallbackKey: String
        var databasePath: String
    }

    private final class Cache: @unchecked Sendable {
        var databases: [String: (stamp: AgentFileStamp, candidates: [UsageCandidate])] = [:]
        let lock = NSLock()
    }

    private static let cache = Cache()

    static func read(historyDays: Int, now: Date = Date()) -> AgentArtifactResult {
        let cutoff = now.addingTimeInterval(-Double(historyDays) * 86_400)
        let roots = AgentDiscovery.dataURLs(for: .antigravity)
        var result = AgentArtifactResult()
        var candidates: [UsageCandidate] = []
        var databases: [(url: URL, modifiedAt: Date, root: URL)] = []
        var failed = 0
        cache.lock.lock()
        var live: Set<String> = []
        for root in roots {
            let directory = root.appendingPathComponent("conversations", isDirectory: true)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".db") }.sorted()
            for name in names {
                let url = directory.appendingPathComponent(name)
                guard let stamp = combinedStamp(url), stamp.modifiedAt >= cutoff else { continue }
                live.insert(url.path)
                databases.append((url, stamp.modifiedAt, root))
                if let cached = cache.databases[url.path], cached.stamp == stamp {
                    candidates.append(contentsOf: cached.candidates)
                    continue
                }
                if let parsed = readDatabase(url, fallback: stamp.modifiedAt) {
                    cache.databases[url.path] = (stamp, parsed)
                    candidates.append(contentsOf: parsed)
                } else {
                    failed += 1
                    if let cached = cache.databases[url.path] { candidates.append(contentsOf: cached.candidates) }
                }
            }
        }
        cache.databases = cache.databases.filter { live.contains($0.key) }
        cache.lock.unlock()
        guard !databases.isEmpty else { return result }
        if failed > 0 { result.warnings.append("Antigravity could not read \(failed) conversation databases") }

        let summaries = Dictionary(roots.flatMap { readSummaries($0) }, uniquingKeysWith: { lhs, rhs in lhs.updated > rhs.updated ? lhs : rhs })
        let merged = mergeAliases(candidates)
        let names = AgentProjectNames()
        var eventsBySession: [String: [AgentUsageEvent]] = [:]
        for candidate in merged where candidate.timestamp >= cutoff {
            let summary = summaries[candidate.sessionID]
            let projectPath = summary?.workspace ?? ""
            let event = AgentUsageFactory.event(
                id: "antigravity|\(candidate.keys.first ?? candidate.fallbackKey)",
                agent: .antigravity,
                sessionID: candidate.sessionID,
                projectPath: projectPath,
                projectName: names.name(for: projectPath),
                model: candidate.model,
                observedAt: candidate.timestamp,
                usage: TokenUsage(
                    uncachedInputTokens: candidate.uncached,
                    cachedInputTokens: candidate.cached,
                    cacheCreationTokens: candidate.cacheCreation,
                    outputTokens: candidate.output,
                    reasoningTokens: candidate.reasoning
                ),
                reportedCost: nil,
                sourcePath: candidate.databasePath
            )
            result.usageEvents.append(event)
            eventsBySession[candidate.sessionID, default: []].append(event)
        }
        for database in databases {
            let sessionID = database.url.deletingPathExtension().lastPathComponent
            let summary = summaries[sessionID]
            let projectPath = summary?.workspace ?? ""
            let projectName = names.name(for: projectPath)
            let events = eventsBySession[sessionID] ?? []
            let title = [summary?.title ?? "", summary?.preview ?? ""].first { !$0.isEmpty }.map { ClaudeText.titled($0) }
            let updated = max(summary?.updated ?? database.modifiedAt, database.modifiedAt)
            var session = AgentSession(
                id: "antigravity|session|\(sessionID)",
                agent: .antigravity,
                sessionID: sessionID,
                title: title ?? projectName,
                process: nil,
                projectPath: projectPath,
                projectName: projectName,
                model: events.max { $0.observedAt < $1.observedAt }?.model ?? "",
                account: "",
                branch: "",
                state: activityState(status: summary?.status ?? "", modifiedAt: updated, now: now),
                startedAt: events.map(\.observedAt).min() ?? database.modifiedAt,
                updatedAt: updated,
                sourcePath: database.url.path,
                sourceKind: .transcript,
                usage: nil,
                cost: nil,
                requests: nil
            )
            AgentUsageFactory.apply(events, to: &session)
            result.sessions.append(session)
        }
        return result
    }

    /// The database file's mtime lags while writes sit in the WAL, so both count.
    private static func combinedStamp(_ url: URL) -> AgentFileStamp? {
        guard var stamp = AgentFileScanner.stamp(for: url) else { return nil }
        if let wal = AgentFileScanner.stamp(for: URL(fileURLWithPath: url.path + "-wal")) {
            stamp.size += wal.size
            stamp.modifiedAt = max(stamp.modifiedAt, wal.modifiedAt)
        }
        return stamp
    }

    static func activityState(status: String, modifiedAt: Date, now: Date) -> AgentActivityState {
        let age = now.timeIntervalSince(modifiedAt)
        let upper = status.uppercased()
        if upper.contains("RUNNING") || upper.contains("BUSY") { return age < 30 * 60 ? .working : .idle }
        if upper.contains("WAITING") || upper.contains("INPUT") || upper.contains("APPROVAL") { return age < 30 * 60 ? .needsInput : .idle }
        if upper.contains("ERROR") || upper.contains("FAILED") { return age < 30 * 60 ? .failed : .idle }
        return age < 10 ? .working : .idle
    }

    // MARK: - Conversation summaries

    private struct Summary {
        var title: String
        var preview: String
        var workspace: String
        var status: String
        var updated: Date
    }

    private static func readSummaries(_ root: URL) -> [(String, Summary)] {
        let path = root.appendingPathComponent("conversation_summaries.db").path
        guard FileManager.default.fileExists(atPath: path), let database = AgentSQLiteDatabase(path: path),
              database.tables().contains("conversation_summaries") else { return [] }
        var rows: [(String, Summary)] = []
        database.query("SELECT conversation_id, title, preview, workspace_uris, status, last_modified_time FROM conversation_summaries") { row in
            guard let id = row.text(0) else { return }
            var workspace = ""
            if let uris = row.text(3), let data = uris.data(using: .utf8),
               let list = (try? JSONSerialization.jsonObject(with: data)) as? [String], let first = list.first {
                workspace = URL(string: first)?.path ?? first.replacingOccurrences(of: "file://", with: "")
                if URL(string: first) == nil, let decoded = workspace.removingPercentEncoding { workspace = decoded }
            }
            rows.append((id, Summary(
                title: row.text(1) ?? "",
                preview: row.text(2) ?? "",
                workspace: workspace,
                status: row.text(4) ?? "",
                updated: row.text(5).flatMap { AgentJSON.date($0) } ?? .distantPast
            )))
        }
        return rows
    }

    // MARK: - Usage metadata

    private static func readDatabase(_ url: URL, fallback: Date) -> [UsageCandidate]? {
        guard let database = AgentSQLiteDatabase(path: url.path) else { return nil }
        let tables = database.tables()
        guard tables.contains("gen_metadata") || tables.contains("steps") else { return [] }
        let sessionID = url.deletingPathExtension().lastPathComponent
        struct Entry { var idx: Int64; var metadata: Metadata }
        func load(_ sql: String, step: Bool) -> [Entry]? {
            var entries: [Entry] = []
            var valid = true
            let ok = database.query(sql) { row in
                guard let idx = row.int64(0), let blob = row.blob(1), let metadata = try? Metadata(blob, step: step) else {
                    valid = false
                    return
                }
                entries.append(Entry(idx: idx, metadata: metadata))
            }
            return ok && valid ? entries : nil
        }
        let generations = tables.contains("gen_metadata") ? load("SELECT idx, data FROM gen_metadata ORDER BY idx", step: false) : []
        let steps = tables.contains("steps") ? load("SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx", step: true) : []
        guard let generations, let steps else { return nil }
        var trajectoryTimestamp: Date?
        if tables.contains("trajectory_metadata_blob") {
            database.query("SELECT data FROM trajectory_metadata_blob") { row in
                if trajectoryTimestamp == nil, let blob = row.blob(0), let fields = try? ProtoFields(blob) {
                    trajectoryTimestamp = (try? fields.nested(2)).flatMap { $0.timestamp }
                }
            }
        }
        let generationModels = Dictionary(generations.map { ($0.idx, $0.metadata.model) }, uniquingKeysWith: { first, _ in first })
        var candidates: [UsageCandidate] = []
        for (source, entries) in [("step", steps), ("generation", generations)] {
            for (index, entry) in entries.enumerated() {
                for (usageIndex, usage) in entry.metadata.usages.enumerated() {
                    let output = max(usage.number(3), usage.number(9) + usage.number(10))
                    let uncached = usage.number(2)
                    let cached = usage.number(5)
                    let cacheCreation = usage.number(4)
                    guard uncached + cached + cacheCreation + output > 0 else { continue }
                    let keys = [11, 12, 7].compactMap { key -> String? in
                        let id = usage.text(key)
                        return id.isEmpty ? nil : "\(key):\(id)"
                    }
                    let modelID = usage.number(1)
                    var model = modelIDs[modelID] ?? entry.metadata.model
                    if model.isEmpty, source == "step" { model = generationModels[entry.idx] ?? "" }
                    if model.isEmpty { model = modelName("", id: modelID) }
                    if model.isEmpty { model = "antigravity-unknown" }
                    let quality = entry.metadata.timestamp != nil ? 2 : (trajectoryTimestamp != nil ? 1 : 0)
                    candidates.append(UsageCandidate(
                        keys: keys,
                        sessionID: sessionID,
                        timestamp: entry.metadata.timestamp ?? trajectoryTimestamp ?? fallback,
                        timestampQuality: quality,
                        model: model,
                        uncached: uncached,
                        cached: cached,
                        cacheCreation: cacheCreation,
                        output: output,
                        reasoning: min(output, usage.number(9)),
                        fallbackKey: "\(sessionID):\(source):\(index):\(usageIndex)",
                        databasePath: url.path
                    ))
                }
            }
        }
        return candidates
    }

    /// The same generation shows up in `steps` and `gen_metadata` (and across copied stores)
    /// under overlapping ids. Candidates sharing any id collapse into one, keeping the largest counts.
    static func mergeAliases(_ candidates: [UsageCandidate]) -> [UsageCandidate] {
        var merged: [UsageCandidate] = []
        var owner: [String: Int] = [:]
        for candidate in candidates {
            guard let index = candidate.keys.lazy.compactMap({ owner[$0] }).first else {
                for key in candidate.keys { owner[key] = merged.count }
                merged.append(candidate)
                continue
            }
            var target = merged[index]
            target.uncached = max(target.uncached, candidate.uncached)
            target.cached = max(target.cached, candidate.cached)
            target.cacheCreation = max(target.cacheCreation, candidate.cacheCreation)
            target.output = max(target.output, candidate.output)
            target.reasoning = max(target.reasoning, candidate.reasoning)
            if target.model == "antigravity-unknown" { target.model = candidate.model }
            if candidate.timestampQuality > target.timestampQuality ||
                (candidate.timestampQuality == target.timestampQuality && candidate.timestamp < target.timestamp) {
                target.timestamp = candidate.timestamp
                target.timestampQuality = candidate.timestampQuality
            }
            for key in candidate.keys where owner[key] == nil { owner[key] = index }
            for key in candidate.keys where !target.keys.contains(key) { target.keys.append(key) }
            merged[index] = target
        }
        return merged
    }

    private struct Metadata {
        var model: String
        var timestamp: Date?
        var usages: [ProtoFields]

        init(_ bytes: Data, step: Bool) throws {
            let root = try ProtoFields(bytes)
            if !step, root.bytes(1) == nil { throw ProtoFields.DecodeError.invalid }
            let data = step ? root : try root.nested(1)
            let modelFields = step ? try data.nested(24) : data
            var usages: [ProtoFields] = []
            if let usage = data.bytes(step ? 9 : 4) { usages.append(try ProtoFields(usage)) }
            for retry in data.allBytes(step ? 28 : 17) {
                if let usage = try ProtoFields(retry).bytes(2) { usages.append(try ProtoFields(usage)) }
            }
            let name = modelFields.text(step ? 12 : 19).isEmpty ? modelFields.text(step ? 8 : 21) : modelFields.text(step ? 12 : 19)
            model = AgentAntigravityReader.modelName(name, id: modelFields.number(step ? 1 : 3))
            if step {
                let completed = try data.nested(8).timestamp
                timestamp = completed != nil ? completed : try data.nested(1).timestamp
            } else {
                timestamp = try data.nested(9).nested(4).timestamp
            }
            self.usages = usages
        }
    }

    static let modelIDs: [Int64: String] = [
        246: "gemini-2.5-pro", 312: "gemini-2.5-flash", 313: "gemini-2.5-flash-thinking",
        329: "gemini-2.5-flash-thinking", 330: "gemini-2.5-flash-lite", 281: "claude-sonnet-4",
        282: "claude-sonnet-4", 290: "claude-opus-4", 291: "claude-opus-4", 333: "claude-sonnet-4-5",
        334: "claude-sonnet-4-5", 340: "claude-haiku-4-5", 341: "claude-haiku-4-5", 1026: "claude-opus-4-6",
        1035: "claude-sonnet-4-6", 1016: "gemini-3.1-pro", 1036: "gemini-3.1-pro", 1037: "gemini-3.1-pro",
        1018: "gemini-3-flash-preview", 1084: "gemini-3-flash-preview", 1047: "gemini-3-flash-preview"
    ]

    /// "Claude Sonnet 4.5 (Thinking)" → "claude-sonnet-4-5"; "Gemini 3.1 Pro (High)" → "gemini-3.1-pro".
    static func modelName(_ name: String, id: Int64) -> String {
        guard !name.isEmpty else { return modelIDs[id] ?? (id > 0 ? "antigravity-model-\(id)" : "") }
        var normalized = name.lowercased()
        if let range = normalized.range(of: "\\s*\\([^)]*\\)\\s*$", options: .regularExpression) { normalized.removeSubrange(range) }
        normalized = normalized.replacingOccurrences(of: " ", with: "-")
        if normalized.hasPrefix("claude-") { return AgentPricing.normalize(normalized) }
        return normalized
    }
}

/// Just enough protobuf wire-format decoding for Antigravity's metadata blobs.
struct ProtoFields: Sendable {
    enum DecodeError: Error { case invalid }
    enum Value: Sendable {
        case varint(UInt64)
        case bytes(Data)
    }

    private(set) var values: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 64 {
                guard offset < bytes.count else { throw DecodeError.invalid }
                let byte = bytes[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            throw DecodeError.invalid
        }
        while offset < bytes.count {
            let tag = try varint()
            let number = Int(tag >> 3)
            let wire = tag & 7
            guard number > 0 else { throw DecodeError.invalid }
            switch wire {
            case 0:
                values[number, default: []].append(.varint(try varint()))
            case 1, 5:
                let length = wire == 1 ? 8 : 4
                guard length <= bytes.count - offset else { throw DecodeError.invalid }
                offset += length
            case 2:
                let raw = try varint()
                guard raw <= UInt64(bytes.count - offset) else { throw DecodeError.invalid }
                let length = Int(raw)
                values[number, default: []].append(.bytes(Data(bytes[offset..<(offset + length)])))
                offset += length
            default:
                throw DecodeError.invalid
            }
        }
    }

    func number(_ field: Int) -> Int64 {
        if case .varint(let value)? = values[field]?.first { return Int64(clamping: value) }
        return 0
    }

    func bytes(_ field: Int) -> Data? {
        if case .bytes(let data)? = values[field]?.first { return data }
        return nil
    }

    func allBytes(_ field: Int) -> [Data] {
        (values[field] ?? []).compactMap { if case .bytes(let data) = $0 { return data } else { return nil } }
    }

    func text(_ field: Int) -> String {
        guard let data = bytes(field), let string = String(data: data, encoding: .utf8) else { return "" }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Missing fields decode as empty messages, matching protobuf defaults.
    func nested(_ field: Int) throws -> ProtoFields {
        guard let data = bytes(field) else { return try ProtoFields(Data()) }
        return try ProtoFields(data)
    }

    /// google.protobuf.Timestamp: seconds (1) and nanos (2).
    var timestamp: Date? {
        let seconds = number(1)
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(number(2)) / 1_000_000_000)
    }
}
