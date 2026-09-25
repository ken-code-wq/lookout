import Foundation

// Pure JSON -> window mappers for each provider. No I/O; exposed publicly as test seams.

private typealias J = AgentLimitJSON
private typealias F = AgentLimitFormat

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400

extension AgentLimitClients {
    // MARK: Claude

    /// Maps `GET api.anthropic.com/api/oauth/usage`. Prefers the `limits[]` list (which carries
    /// model-scoped weekly limits such as Fable) and falls back to the flat `five_hour` / `seven_day` fields.
    public static func claudeWindows(from data: Data, observedAt: Date, account: String = "") -> [AgentQuotaWindow] {
        guard let root = J.object(data) else { return [] }
        let source = "Anthropic usage API"
        func window(_ id: String, _ label: String, _ kind: AgentLimitKind, _ percent: Double, _ reset: Any?,
                    _ duration: TimeInterval?, detail: String = "") -> AgentQuotaWindow {
            AgentQuotaWindow(id: "claude-\(id)", agent: .claude, label: label, kind: kind,
                             usedPercent: F.clampPercent(percent), resetsAt: F.date(reset),
                             windowDuration: duration, detail: detail, observedAt: observedAt,
                             source: source, account: account)
        }

        var windows: [AgentQuotaWindow] = []
        if let limits = J.array(root["limits"]) {
            var seen: Set<String> = []
            for case let entry as [String: Any] in limits {
                guard let percent = J.double(entry["percent"]) else { continue }
                let kind = J.string(entry["kind"]) ?? ""
                switch kind {
                case "session":
                    guard seen.insert("session").inserted else { continue }
                    windows.append(window("session", "5-hour session", .session, percent, entry["resets_at"], 5 * hour))
                case "weekly_all":
                    guard seen.insert("weekly").inserted else { continue }
                    windows.append(window("weekly", "Weekly · all models", .weekly, percent, entry["resets_at"], 7 * day))
                case "weekly_scoped":
                    let model = J.dict(J.dict(entry["scope"])?["model"])
                    guard let name = J.string(model?["display_name"]) ?? J.string(model?["id"]) else { continue }
                    let slug = F.slug(name)
                    guard !slug.isEmpty, !slug.hasSuffix("all-models"), seen.insert("weekly-\(slug)").inserted else { continue }
                    windows.append(window("weekly-\(slug)", "Weekly · \(name)", .weeklyModel, percent, entry["resets_at"], 7 * day))
                default:
                    continue
                }
            }
        }
        if windows.isEmpty {
            let flat: [(String, String, String, AgentLimitKind, TimeInterval)] = [
                ("five_hour", "session", "5-hour session", .session, 5 * hour),
                ("seven_day", "weekly", "Weekly · all models", .weekly, 7 * day),
                ("seven_day_opus", "weekly-opus", "Weekly · Opus", .weeklyModel, 7 * day),
                ("seven_day_sonnet", "weekly-sonnet", "Weekly · Sonnet", .weeklyModel, 7 * day),
            ]
            for (key, id, label, kind, duration) in flat {
                guard let entry = J.dict(root[key]), let percent = J.double(entry["utilization"]) else { continue }
                windows.append(window(id, label, kind, percent, entry["resets_at"], duration))
            }
        }
        if let extra = claudeExtraUsage(root) {
            windows.append(window("extra-usage", "Extra usage", .monthly, extra.percent, nil, nil, detail: extra.detail))
        }
        return windows
    }

    private static func claudeExtraUsage(_ root: [String: Any]) -> (percent: Double, detail: String)? {
        if let spend = J.dict(root["spend"]), J.bool(spend["enabled"]) == true {
            func amount(_ value: Any?) -> Double? {
                guard let money = J.dict(value), let minor = J.double(money["amount_minor"]) else { return nil }
                return minor / pow(10, J.double(money["exponent"]) ?? 2)
            }
            let used = amount(spend["used"]) ?? 0
            let limit = amount(spend["limit"]) ?? amount(spend["cap"])
            let percent = J.double(spend["percent"]) ?? limit.map { $0 > 0 ? used / $0 * 100 : 0 } ?? 0
            let detail = limit.map { "\(F.dollars(used)) of \(F.dollars($0)) used" } ?? "\(F.dollars(used)) used"
            return (percent, detail)
        }
        if let extra = J.dict(root["extra_usage"]), J.bool(extra["is_enabled"]) == true {
            // Anthropic reports these in minor units (cents).
            let used = (J.double(extra["used_credits"]) ?? 0) / 100
            let limit = J.double(extra["monthly_limit"]).map { $0 / 100 }
            let percent = J.double(extra["utilization"]) ?? limit.map { $0 > 0 ? used / $0 * 100 : 0 } ?? 0
            let detail = limit.map { "\(F.dollars(used)) of \(F.dollars($0)) used" } ?? "\(F.dollars(used)) used"
            return (percent, detail)
        }
        return nil
    }

    /// "max" + "default_claude_max_5x" -> "Max 5x".
    static func claudePlanLabel(subscriptionType: String?, rateLimitTier: String?) -> String {
        let tier = (rateLimitTier ?? "").lowercased()
        if let range = tier.range(of: #"(\d+)x"#, options: .regularExpression) {
            let base = F.humanize(subscriptionType ?? "max")
            return "\(base) \(tier[range])"
        }
        return subscriptionType.map(F.humanize) ?? ""
    }

    // MARK: Codex

    /// Maps the `account/rateLimits/read` result from `codex app-server` (either the full JSON-RPC
    /// message or just its `result`).
    public static func codexAppServerWindows(from data: Data, observedAt: Date) -> [AgentQuotaWindow] {
        codexAppServer(from: data, observedAt: observedAt).windows
    }

    static func codexAppServer(from data: Data, observedAt: Date) -> CodexParse {
        guard let message = J.object(data) else { return CodexParse() }
        let result = J.dict(message["result"]) ?? message
        let source = "Codex app-server"
        guard let main = J.dict(result["rateLimits"]) else { return CodexParse() }
        var parse = CodexParse()
        parse.plan = codexPlanLabel(J.string(main["planType"]))
        let mainID = J.string(main["limitId"]) ?? "codex"
        parse.windows = codexSnapshotWindows(main, bucket: nil, source: source, observedAt: observedAt,
                                             percentKey: "usedPercent", minutesKey: "windowDurationMins",
                                             secondsKey: nil, resetKey: "resetsAt")
        if let byID = J.dict(result["rateLimitsByLimitId"]) {
            for key in byID.keys.sorted() where key != mainID {
                guard let snapshot = J.dict(byID[key]) else { continue }
                let name = J.string(snapshot["limitName"]) ?? F.humanize(key)
                parse.windows += codexSnapshotWindows(snapshot, bucket: name, source: source, observedAt: observedAt,
                                                      percentKey: "usedPercent", minutesKey: "windowDurationMins",
                                                      secondsKey: nil, resetKey: "resetsAt")
            }
        }
        parse.message = codexMessage(credits: J.dict(main["credits"]), unlimitedKey: "unlimited",
                                     hasKey: "hasCredits", reached: J.string(main["rateLimitReachedType"]))
        return parse
    }

    /// Maps `GET chatgpt.com/backend-api/wham/usage`.
    public static func codexWhamWindows(from data: Data, observedAt: Date) -> [AgentQuotaWindow] {
        codexWham(from: data, observedAt: observedAt).windows
    }

    static func codexWham(from data: Data, observedAt: Date) -> CodexParse {
        guard let root = J.object(data) else { return CodexParse() }
        let source = "ChatGPT usage API"
        var parse = CodexParse()
        parse.plan = codexPlanLabel(J.string(root["plan_type"]))
        func windows(_ rateLimit: [String: Any]?, bucket: String?) -> [AgentQuotaWindow] {
            guard let rateLimit else { return [] }
            let snapshot: [String: Any] = [
                "primary": rateLimit["primary_window"] ?? NSNull(),
                "secondary": rateLimit["secondary_window"] ?? NSNull(),
            ]
            return codexSnapshotWindows(snapshot, bucket: bucket, source: source, observedAt: observedAt,
                                        percentKey: "used_percent", minutesKey: nil,
                                        secondsKey: "limit_window_seconds", resetKey: "reset_at")
        }
        parse.windows = windows(J.dict(root["rate_limit"]), bucket: nil)
        if let additional = J.array(root["additional_rate_limits"]) {
            for case let entry as [String: Any] in additional {
                let name = J.string(entry["limit_name"]) ?? J.string(entry["metered_feature"]).map(F.humanize) ?? "Extra limit"
                parse.windows += windows(J.dict(entry["rate_limit"]), bucket: name)
            }
        }
        let reached = J.bool(J.dict(root["rate_limit"])?["limit_reached"]) == true ? "limit_reached" : nil
        parse.message = codexMessage(credits: J.dict(root["credits"]), unlimitedKey: "unlimited",
                                     hasKey: "has_credits", reached: reached)
        return parse
    }

    struct CodexParse {
        var windows: [AgentQuotaWindow] = []
        var plan = ""
        var message = ""
    }

    private static func codexSnapshotWindows(
        _ snapshot: [String: Any], bucket: String?, source: String, observedAt: Date,
        percentKey: String, minutesKey: String?, secondsKey: String?, resetKey: String
    ) -> [AgentQuotaWindow] {
        var result: [AgentQuotaWindow] = []
        for slot in ["primary", "secondary"] {
            guard let window = J.dict(snapshot[slot]), let percent = J.double(window[percentKey]) else { continue }
            var duration: TimeInterval?
            if let minutesKey, let minutes = J.double(window[minutesKey]) { duration = minutes * 60 }
            if let secondsKey, let seconds = J.double(window[secondsKey]) { duration = seconds }
            let (kind, name) = codexClassify(duration, isExtraBucket: bucket != nil)
            let label = bucket.map { "\($0) · \(name)" } ?? name
            let idBase = bucket.map { "codex-\(F.slug($0))" } ?? "codex"
            var id = "\(idBase)-\(kind.rawValue)"
            if result.contains(where: { $0.id == id }) { id += "-\(slot)" }
            result.append(AgentQuotaWindow(
                id: id, agent: .codex, label: label, kind: kind,
                usedPercent: F.clampPercent(percent), resetsAt: F.date(window[resetKey]),
                windowDuration: duration, observedAt: observedAt, source: source, account: ""))
        }
        return result
    }

    private static func codexClassify(_ duration: TimeInterval?, isExtraBucket: Bool) -> (AgentLimitKind, String) {
        guard let duration, duration > 0 else { return (.other, isExtraBucket ? "Limit" : "Usage limit") }
        if duration <= 6 * hour {
            let hours = Int((duration / hour).rounded())
            return (.session, isExtraBucket ? "\(hours)-hour" : "\(hours)-hour session")
        }
        if duration >= 6 * day, duration <= 8 * day { return (isExtraBucket ? .weeklyModel : .weekly, "Weekly") }
        if duration >= 27 * day, duration <= 32 * day { return (.monthly, "Monthly") }
        if duration >= 20 * hour, duration <= 28 * hour { return (.daily, "Daily") }
        if duration < 2 * day { return (.other, "\(Int((duration / hour).rounded()))-hour window") }
        return (.other, "\(Int((duration / day).rounded()))-day window")
    }

    private static func codexPlanLabel(_ raw: String?) -> String {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return "" }
        switch raw {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        default: return F.humanize(raw)
        }
    }

    private static func codexMessage(credits: [String: Any]?, unlimitedKey: String, hasKey: String, reached: String?) -> String {
        var parts: [String] = []
        if let reached, reached != "null" { parts.append("Limit reached.") }
        if let credits {
            if J.bool(credits[unlimitedKey]) == true {
                parts.append("Unlimited credits.")
            } else if J.bool(credits[hasKey]) == true, let balance = J.string(credits["balance"]) {
                parts.append("Credits balance: \(balance).")
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: Copilot

    /// Maps `GET api.github.com/copilot_internal/user`.
    public static func copilotWindows(from data: Data, observedAt: Date) -> [AgentQuotaWindow] {
        copilot(from: data, observedAt: observedAt).windows
    }

    static func copilot(from data: Data, observedAt: Date) -> (windows: [AgentQuotaWindow], plan: String, account: String, message: String) {
        guard let root = J.object(data) else { return ([], "", "", "") }
        let account = J.string(root["login"]) ?? ""
        let plan = copilotPlanLabel(plan: J.string(root["copilot_plan"]), sku: J.string(root["access_type_sku"]))
        let reset = F.date(root["quota_reset_date_utc"]) ?? F.date(root["quota_reset_date"])
        var duration: TimeInterval?
        if let reset {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            if let start = calendar.date(byAdding: .month, value: -1, to: reset) { duration = reset.timeIntervalSince(start) }
        }
        let snapshots = J.dict(root["quota_snapshots"]) ?? [:]
        var windows: [AgentQuotaWindow] = []
        var unlimited: [String] = []
        let known: [(String, String)] = [("premium_interactions", "Premium requests"), ("chat", "Chat"), ("completions", "Completions")]
        let ordered = known.map(\.0) + snapshots.keys.sorted().filter { key in !known.contains { $0.0 == key } }
        for key in ordered {
            guard let snapshot = J.dict(snapshots[key]) else { continue }
            let label = known.first { $0.0 == key }?.1 ?? F.humanize(key)
            if J.bool(snapshot["unlimited"]) == true {
                unlimited.append(label.lowercased())
                continue
            }
            guard let remainingPercent = J.double(snapshot["percent_remaining"]) else { continue }
            var detail = ""
            if let entitlement = J.double(snapshot["entitlement"]), entitlement > 0 {
                let remaining = J.double(snapshot["quota_remaining"]) ?? J.double(snapshot["remaining"]) ?? 0
                let used = max(entitlement - remaining, 0).rounded()
                detail = "\(F.count(used)) of \(F.count(entitlement)) used"
                if let overage = J.double(snapshot["overage_count"]), overage > 0 { detail += ", \(F.count(overage)) over" }
            }
            windows.append(AgentQuotaWindow(
                id: "copilot-\(F.slug(key))", agent: .copilot, label: label, kind: .monthly,
                usedPercent: F.clampPercent(100 - remainingPercent), resetsAt: reset, windowDuration: duration,
                detail: detail, observedAt: observedAt, source: "GitHub Copilot API", account: account))
        }
        var message = ""
        if !unlimited.isEmpty {
            let list = unlimited.joined(separator: " and ")
            message = list.prefix(1).uppercased() + list.dropFirst() + " unlimited."
        }
        return (windows, plan, account, message)
    }

    private static func copilotPlanLabel(plan: String?, sku: String?) -> String {
        let sku = (sku ?? "").lowercased()
        if sku.contains("free_limited") { return "Free" }
        if sku.contains("educational") { return "Education" }
        if sku.contains("pro_plus") || sku.contains("proplus") { return "Pro+" }
        if sku.contains("pro") { return "Pro" }
        switch (plan ?? "").lowercased() {
        case "individual": return "Individual"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "": return ""
        default: return F.humanize(plan ?? "")
        }
    }

    // MARK: Cursor

    /// Maps `GET cursor.com/api/usage-summary`. Amounts are in cents; percent fields are already 0-100.
    public static func cursorWindows(from data: Data, observedAt: Date, account: String = "") -> [AgentQuotaWindow] {
        cursor(from: data, observedAt: observedAt, account: account).windows
    }

    static func cursor(from data: Data, observedAt: Date, account: String) -> (windows: [AgentQuotaWindow], plan: String) {
        guard let root = J.object(data) else { return ([], "") }
        let start = F.date(root["billingCycleStart"])
        let end = F.date(root["billingCycleEnd"])
        let duration = start.flatMap { s in end.map { $0.timeIntervalSince(s) } }.flatMap { $0 > 0 ? $0 : nil }
        let plan = J.string(root["membershipType"]).map(F.humanize) ?? ""
        let individual = J.dict(root["individualUsage"])
        let team = J.dict(root["teamUsage"])
        var windows: [AgentQuotaWindow] = []

        func add(_ id: String, _ label: String, _ meter: [String: Any]?, percentKey: String? = nil) {
            guard let meter, J.bool(meter["enabled"]) != false else { return }
            let used = J.double(meter["used"]) ?? 0
            guard let limit = J.double(meter["limit"]), limit > 0 else { return }
            let percent = percentKey.flatMap { J.double(meter[$0]) } ?? used / limit * 100
            windows.append(AgentQuotaWindow(
                id: "cursor-\(id)", agent: .cursor, label: label, kind: .monthly,
                usedPercent: F.clampPercent(percent), resetsAt: end, windowDuration: duration,
                detail: "\(F.dollars(used / 100)) of \(F.dollars(limit / 100)) used",
                observedAt: observedAt, source: "Cursor usage API", account: account))
        }

        if let planMeter = J.dict(individual?["plan"]) {
            add("included", "Included usage", planMeter, percentKey: "totalPercentUsed")
        } else if let overall = J.dict(individual?["overall"]) {
            add("included", "Included usage", overall)
        } else {
            add("team-pool", "Team pool", J.dict(team?["pooled"]))
        }
        add("on-demand", "On-demand", J.dict(individual?["onDemand"]))
        if individual?["onDemand"] == nil { add("team-on-demand", "Team on-demand", J.dict(team?["onDemand"])) }
        return (windows, plan)
    }

    // MARK: Antigravity

    /// Maps `agy -p /usage --output-format json`.
    public static func antigravityWindows(from data: Data, observedAt: Date) -> [AgentQuotaWindow] {
        guard let root = J.firstObject(in: data) else { return [] }
        let payload = J.dict(J.dict(root["command"])?["data"]) ?? J.dict(root["summary"]) ?? root
        var windows: [AgentQuotaWindow] = []
        for case let group as [String: Any] in J.array(payload["groups"]) ?? [] {
            let groupName = antigravityGroupName(J.string(J.value(group, "name", "displayName")) ?? "Quota")
            for case let bucket as [String: Any] in J.array(group["buckets"]) ?? [] {
                guard J.bool(bucket["disabled"]) != true,
                      let remaining = J.double(J.value(bucket, "remaining_fraction", "remainingFraction"))
                else { continue }
                let id = J.string(J.value(bucket, "id", "bucketId")) ?? ""
                let windowName = (J.string(bucket["window"]) ?? id).lowercased()
                let kind: AgentLimitKind
                let suffix: String
                let duration: TimeInterval?
                if windowName.contains("5h") || windowName.contains("five") || windowName.hasSuffix("session") {
                    (kind, suffix, duration) = (.session, "5-hour", 5 * hour)
                } else if windowName.contains("week") {
                    (kind, suffix, duration) = (.weekly, "Weekly", 7 * day)
                } else {
                    (kind, suffix, duration) = (.model, J.string(J.value(bucket, "name", "displayName")) ?? "Quota", nil)
                }
                let slugID = id.isEmpty ? "\(F.slug(groupName))-\(F.slug(suffix))" : F.slug(id)
                windows.append(AgentQuotaWindow(
                    id: "antigravity-\(slugID)", agent: .antigravity, label: "\(groupName) · \(suffix)", kind: kind,
                    usedPercent: F.clampPercent((1 - remaining) * 100),
                    resetsAt: F.date(J.value(bucket, "reset_time", "resetTime")), windowDuration: duration,
                    observedAt: observedAt, source: "agy usage report", account: ""))
            }
        }
        return windows
    }

    /// "Gemini Models" -> "Gemini", "Claude and GPT models" -> "Claude & GPT".
    static func antigravityGroupName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(" models") { name = String(name.dropLast(" models".count)) }
        return name.replacingOccurrences(of: " and ", with: " & ")
    }
}
