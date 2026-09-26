import Foundation

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case openCode = "opencode"
    case antigravity
    case copilot
    case cursor
    case pi

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .antigravity: return "Antigravity"
        case .copilot: return "GitHub Copilot"
        case .cursor: return "Cursor"
        case .pi: return "Pi"
        }
    }

    public var executableNames: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        case .openCode: return ["opencode"]
        case .antigravity: return ["agy", "antigravity"]
        case .copilot: return ["copilot"]
        case .cursor: return ["cursor-agent", "cursor"]
        case .pi: return ["pi"]
        }
    }

    public var dataDirectories: [String] {
        switch self {
        case .claude: return [".claude/projects"]
        case .codex: return [".codex/sessions"]
        case .openCode: return [".local/share/opencode", ".config/opencode"]
        case .antigravity: return [".gemini/antigravity", ".gemini/antigravity-cli"]
        case .copilot: return [".copilot/session-state"]
        case .cursor: return [".cursor"]
        case .pi: return [".pi/agent/sessions"]
        }
    }

    public var processMarkers: [String] {
        switch self {
        case .claude: return ["claude", "claude-code"]
        case .codex: return ["codex"]
        case .openCode: return ["opencode"]
        case .antigravity: return ["agy", "antigravity"]
        case .copilot: return ["copilot", "gh-copilot"]
        case .cursor: return ["cursor-agent", "cursor"]
        case .pi: return ["pi"]
        }
    }

    public var capabilities: AgentCapabilities {
        switch self {
        case .claude: return AgentCapabilities(sessions: true, tokens: true, cost: true, quota: true)
        case .codex: return AgentCapabilities(sessions: true, tokens: true, cost: false, quota: true)
        case .openCode: return AgentCapabilities(sessions: true, tokens: true, cost: false, quota: false)
        case .antigravity: return AgentCapabilities(sessions: true, tokens: true, cost: false, quota: true)
        case .copilot: return AgentCapabilities(sessions: true, tokens: true, cost: true, quota: true)
        case .cursor: return AgentCapabilities(sessions: true, tokens: false, cost: true, quota: false)
        case .pi: return AgentCapabilities(sessions: true, tokens: true, cost: true, quota: false)
        }
    }

    public var officialBrandURL: URL? {
        switch self {
        case .claude: return URL(string: "https://www.anthropic.com")
        case .codex: return URL(string: "https://openai.com/brand/")
        case .openCode: return URL(string: "https://opencode.ai/brand")
        case .antigravity: return URL(string: "https://antigravity.google/press")
        case .copilot: return URL(string: "https://brand.github.com/brand-identity/copilot")
        case .cursor: return URL(string: "https://cursor.com/brand")
        case .pi: return URL(string: "https://pi.dev/press-kit")
        }
    }

    public var iconResourceName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .openCode: return "opencode"
        case .antigravity: return "antigravity"
        case .copilot: return "copilot"
        case .cursor: return "cursor"
        case .pi: return "pi"
        }
    }
}

public struct AgentCapabilities: Codable, Hashable, Sendable {
    public var sessions: Bool
    public var tokens: Bool
    public var cost: Bool
    public var quota: Bool

    public init(sessions: Bool, tokens: Bool, cost: Bool, quota: Bool) {
        self.sessions = sessions
        self.tokens = tokens
        self.cost = cost
        self.quota = quota
    }
}

public enum AgentActivityState: String, Codable, CaseIterable, Sendable {
    case running
    case working
    case thinking
    case toolUse = "tool_use"
    case needsInput = "needs_input"
    case waiting
    case idle
    case failed
    case unknown

    public var title: String {
        switch self {
        case .running: return "Running"
        case .working: return "Working"
        case .thinking: return "Thinking"
        case .toolUse: return "Using tool"
        case .needsInput: return "Needs you"
        case .waiting: return "Your turn"
        case .idle: return "Idle"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }
}

public enum AgentSourceState: String, Codable, Sendable {
    case available
    case stale
    case unavailable
    case error
    case disabled
}

public enum AgentSourceKind: String, Codable, Sendable {
    case process
    case transcript
    case sessionAPI = "session_api"
    case quotaAPI = "quota_api"
    case installed = "installed"
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int64?
    public var uncachedInputTokens: Int64?
    public var cachedInputTokens: Int64?
    public var cacheCreationTokens: Int64?
    public var outputTokens: Int64?
    public var reasoningTokens: Int64?
    public var reportedTotalTokens: Int64?

    public init(
        inputTokens: Int64? = nil,
        uncachedInputTokens: Int64? = nil,
        cachedInputTokens: Int64? = nil,
        cacheCreationTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        reasoningTokens: Int64? = nil,
        reportedTotalTokens: Int64? = nil
    ) {
        self.inputTokens = inputTokens
        self.uncachedInputTokens = uncachedInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.reportedTotalTokens = reportedTotalTokens
    }

    public var derivedUncachedInputTokens: Int64? {
        if let inputTokens {
            let derived = max(0, inputTokens - (cachedInputTokens ?? 0) - (cacheCreationTokens ?? 0))
            if uncachedInputTokens == nil || uncachedInputTokens == 0 { return derived }
        }
        return uncachedInputTokens
    }

    public var processedTokens: Int64? {
        let componentTotal: Int64?
        if let inputTokens {
            componentTotal = inputTokens + (outputTokens ?? 0)
        } else {
            let values = [uncachedInputTokens, cachedInputTokens, cacheCreationTokens, outputTokens].compactMap { $0 }
            componentTotal = values.isEmpty ? nil : values.reduce(0, +)
        }
        guard let componentTotal else { return reportedTotalTokens }
        return componentTotal + (reportedTotalTokens ?? 0)
    }

    public func normalized() -> TokenUsage {
        var value = self
        if inputTokens != nil || uncachedInputTokens != nil {
            value.reportedTotalTokens = nil
        }
        return value
    }

    public var isEmpty: Bool {
        inputTokens == nil && uncachedInputTokens == nil && cachedInputTokens == nil &&
            cacheCreationTokens == nil && outputTokens == nil && reasoningTokens == nil &&
            reportedTotalTokens == nil
    }

    public static let zero = TokenUsage(
        inputTokens: 0,
        uncachedInputTokens: 0,
        cachedInputTokens: 0,
        cacheCreationTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        reportedTotalTokens: 0
    )

    public func adding(_ other: TokenUsage) -> TokenUsage {
        func add(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
            guard let lhs else { return rhs }
            guard let rhs else { return lhs }
            return lhs + rhs
        }
        return TokenUsage(
            inputTokens: add(inputTokens, other.inputTokens),
            uncachedInputTokens: add(uncachedInputTokens, other.uncachedInputTokens),
            cachedInputTokens: add(cachedInputTokens, other.cachedInputTokens),
            cacheCreationTokens: add(cacheCreationTokens, other.cacheCreationTokens),
            outputTokens: add(outputTokens, other.outputTokens),
            reasoningTokens: add(reasoningTokens, other.reasoningTokens),
            reportedTotalTokens: add(reportedTotalTokens, other.reportedTotalTokens)
        )
    }
}

public struct AgentProcess: Identifiable, Hashable, Sendable {
    public var id: String { "\(pid)-\(Int(startedAt.timeIntervalSince1970))" }
    public var pid: Int32
    public var parentPID: Int32
    public var processName: String
    public var executablePath: String
    public var workingDirectory: String
    public var startedAt: Date
    public var terminal: String
    /// The GUI app hosting this agent (terminal, editor, desktop app), found by walking parent processes.
    public var host: AgentHostApp?

    public init(
        pid: Int32,
        parentPID: Int32,
        processName: String,
        executablePath: String,
        workingDirectory: String,
        startedAt: Date,
        terminal: String,
        host: AgentHostApp? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.processName = processName
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.terminal = terminal
        self.host = host
    }
}

public struct AgentHostApp: Hashable, Sendable {
    public var pid: Int32
    public var name: String
    public var bundlePath: String

    public init(pid: Int32, name: String, bundlePath: String) {
        self.pid = pid
        self.name = name
        self.bundlePath = bundlePath
    }
}

public struct AgentSession: Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var sessionID: String
    public var title: String
    public var process: AgentProcess?
    public var projectPath: String
    public var projectName: String
    public var model: String
    public var account: String
    public var branch: String
    public var state: AgentActivityState
    public var startedAt: Date
    public var updatedAt: Date
    public var sourcePath: String
    public var sourceKind: AgentSourceKind
    public var usage: TokenUsage?
    public var cost: Double?
    public var requests: Int?
    /// True when `cost` was computed from the bundled price table rather than reported by the agent.
    public var costIsEstimated: Bool
    /// Tokens in the most recent request's prompt (input + cache), i.e. current context size.
    public var contextTokens: Int64?

    public init(
        id: String,
        agent: AgentKind,
        sessionID: String,
        title: String,
        process: AgentProcess?,
        projectPath: String,
        projectName: String,
        model: String,
        account: String,
        branch: String,
        state: AgentActivityState,
        startedAt: Date,
        updatedAt: Date,
        sourcePath: String,
        sourceKind: AgentSourceKind,
        usage: TokenUsage?,
        cost: Double?,
        requests: Int?,
        costIsEstimated: Bool = false,
        contextTokens: Int64? = nil
    ) {
        self.id = id
        self.agent = agent
        self.sessionID = sessionID
        self.title = title
        self.process = process
        self.projectPath = projectPath
        self.projectName = projectName
        self.model = model
        self.account = account
        self.branch = branch
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.sourcePath = sourcePath
        self.sourceKind = sourceKind
        self.usage = usage
        self.cost = cost
        self.requests = requests
        self.costIsEstimated = costIsEstimated
        self.contextTokens = contextTokens
    }

    public var needsAttention: Bool { state == .needsInput || state == .failed }
}

public struct AgentUsageEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var sessionID: String
    public var projectPath: String
    public var projectName: String
    public var model: String
    public var observedAt: Date
    public var usage: TokenUsage
    public var cost: Double?
    public var requests: Int?
    public var sourcePath: String
    public var sourceKind: AgentSourceKind
    /// True when `cost` came from the bundled price table rather than the agent's own report.
    public var costIsEstimated: Bool
    /// Dollars saved by cache reads versus paying the full input rate. Nil when the model is unpriced.
    public var cacheSavings: Double?

    public init(
        id: String,
        agent: AgentKind,
        sessionID: String,
        projectPath: String,
        projectName: String,
        model: String,
        observedAt: Date,
        usage: TokenUsage,
        cost: Double?,
        requests: Int?,
        sourcePath: String,
        sourceKind: AgentSourceKind,
        costIsEstimated: Bool = false,
        cacheSavings: Double? = nil
    ) {
        self.id = id
        self.agent = agent
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.projectName = projectName
        self.model = model
        self.observedAt = observedAt
        self.usage = usage
        self.cost = cost
        self.requests = requests
        self.sourcePath = sourcePath
        self.sourceKind = sourceKind
        self.costIsEstimated = costIsEstimated
        self.cacheSavings = cacheSavings
    }
}

public enum AgentLimitKind: String, Codable, Sendable {
    /// Rolling short window, e.g. Claude's and Codex's 5-hour session.
    case session
    /// Weekly window across all models.
    case weekly
    /// Weekly window scoped to one model family (e.g. Claude Fable, Opus).
    case weeklyModel
    case daily
    case monthly
    /// Per-model quota without a documented window (e.g. Antigravity model quota).
    case model
    case other

    public var sortOrder: Int {
        switch self {
        case .session: return 0
        case .weekly: return 1
        case .weeklyModel: return 2
        case .daily: return 3
        case .monthly: return 4
        case .model: return 5
        case .other: return 6
        }
    }
}

public struct AgentQuotaWindow: Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var label: String
    public var kind: AgentLimitKind
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Full length of the window. With `resetsAt` this gives the pace marker.
    public var windowDuration: TimeInterval?
    /// Optional absolute amounts, e.g. "412 of 1,500 requests".
    public var detail: String
    public var observedAt: Date
    public var source: String
    public var account: String

    public init(
        id: String,
        agent: AgentKind,
        label: String,
        kind: AgentLimitKind = .other,
        usedPercent: Double,
        resetsAt: Date?,
        windowDuration: TimeInterval? = nil,
        detail: String = "",
        observedAt: Date,
        source: String,
        account: String
    ) {
        self.id = id
        self.agent = agent
        self.label = label
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
        self.detail = detail
        self.observedAt = observedAt
        self.source = source
        self.account = account
    }

    /// Share of the window that has elapsed (0...1), when both reset time and duration are known.
    public func elapsedFraction(now: Date = .now) -> Double? {
        guard let resetsAt, let windowDuration, windowDuration > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(max(1 - remaining / windowDuration, 0), 1)
    }
}

public enum AgentLimitStatus: String, Codable, Sendable {
    /// Live data from the provider account.
    case connected
    /// Windows recovered from the agent's own local logs (may lag behind the provider).
    case local
    /// The provider exposes limits, but reading them needs the user's opt-in.
    case notConnected
    /// The provider exposes limits, but the account was not found or the request failed.
    case error
    /// The agent has no plan limits of its own (it bills through another provider).
    case unsupported
}

public struct AgentLimitReport: Identifiable, Hashable, Sendable {
    public var id: AgentKind { agent }
    public var agent: AgentKind
    public var status: AgentLimitStatus
    public var plan: String
    public var account: String
    public var windows: [AgentQuotaWindow]
    public var fetchedAt: Date?
    public var source: String
    public var message: String

    public init(
        agent: AgentKind,
        status: AgentLimitStatus,
        plan: String = "",
        account: String = "",
        windows: [AgentQuotaWindow] = [],
        fetchedAt: Date? = nil,
        source: String = "",
        message: String = ""
    ) {
        self.agent = agent
        self.status = status
        self.plan = plan
        self.account = account
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.source = source
        self.message = message
    }
}

public struct AgentIntegration: Identifiable, Hashable, Sendable {
    public var id: AgentKind { agent }
    public var agent: AgentKind
    public var isInstalled: Bool
    public var installedPath: String
    public var runningProcessCount: Int
    public var sessionCount: Int
    public var usageEventCount: Int
    public var sourceState: AgentSourceState
    public var message: String
    public var lastUpdated: Date?

    public init(
        agent: AgentKind,
        isInstalled: Bool,
        installedPath: String,
        runningProcessCount: Int,
        sessionCount: Int,
        usageEventCount: Int,
        sourceState: AgentSourceState,
        message: String,
        lastUpdated: Date?
    ) {
        self.agent = agent
        self.isInstalled = isInstalled
        self.installedPath = installedPath
        self.runningProcessCount = runningProcessCount
        self.sessionCount = sessionCount
        self.usageEventCount = usageEventCount
        self.sourceState = sourceState
        self.message = message
        self.lastUpdated = lastUpdated
    }
}

public struct AgentSnapshot: Sendable {
    public var discoveredAt: Date
    public var processes: [AgentSession]
    public var sessions: [AgentSession]
    public var usageEvents: [AgentUsageEvent]
    public var limitReports: [AgentLimitReport]
    public var integrations: [AgentIntegration]
    public var warnings: [String]

    public init(
        discoveredAt: Date,
        processes: [AgentSession],
        sessions: [AgentSession],
        usageEvents: [AgentUsageEvent],
        limitReports: [AgentLimitReport],
        integrations: [AgentIntegration],
        warnings: [String]
    ) {
        self.discoveredAt = discoveredAt
        self.processes = processes
        self.sessions = sessions
        self.usageEvents = usageEvents
        self.limitReports = limitReports
        self.integrations = integrations
        self.warnings = warnings
    }

    public var quotaWindows: [AgentQuotaWindow] { limitReports.flatMap(\.windows) }
}

public struct AgentSettings: Codable, Hashable, Sendable {
    public var enabledAgents: Set<AgentKind>
    public var historyDays: Int
    public var autoRefresh: Bool
    /// False until the user has confirmed which agents to watch.
    public var hasCompletedSetup: Bool
    /// Agents whose plan limits may be read from the signed-in provider account (network, opt-in).
    public var accountLimitAgents: Set<AgentKind>
    public var notifyNeedsInput: Bool
    /// Notify once a limit window crosses this percentage. Nil disables limit notifications.
    public var limitAlertPercent: Int?

    public init(
        enabledAgents: Set<AgentKind> = Set(AgentKind.allCases),
        historyDays: Int = 90,
        autoRefresh: Bool = true,
        hasCompletedSetup: Bool = false,
        accountLimitAgents: Set<AgentKind> = [],
        notifyNeedsInput: Bool = false,
        limitAlertPercent: Int? = nil
    ) {
        self.enabledAgents = enabledAgents
        self.historyDays = historyDays
        self.autoRefresh = autoRefresh
        self.hasCompletedSetup = hasCompletedSetup
        self.accountLimitAgents = accountLimitAgents
        self.notifyNeedsInput = notifyNeedsInput
        self.limitAlertPercent = limitAlertPercent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentSettings()
        enabledAgents = try c.decodeIfPresent(Set<AgentKind>.self, forKey: .enabledAgents) ?? defaults.enabledAgents
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays) ?? defaults.historyDays
        autoRefresh = try c.decodeIfPresent(Bool.self, forKey: .autoRefresh) ?? defaults.autoRefresh
        hasCompletedSetup = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? false
        accountLimitAgents = try c.decodeIfPresent(Set<AgentKind>.self, forKey: .accountLimitAgents) ?? []
        notifyNeedsInput = try c.decodeIfPresent(Bool.self, forKey: .notifyNeedsInput) ?? false
        limitAlertPercent = try c.decodeIfPresent(Int.self, forKey: .limitAlertPercent)
    }
}

public enum AgentDateRange: Int, CaseIterable, Identifiable, Sendable {
    case today = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case oneYear = 365

    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .oneYear: return "1 year"
        }
    }

    /// Phrase used in sentences: "in the last 7 days".
    public var phrase: String {
        switch self {
        case .today: return "today"
        default: return "in the last \(title)"
        }
    }

    public func start(now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(rawValue - 1), to: today) ?? today
    }
}

public enum AgentMetricKind: String, CaseIterable, Identifiable, Sendable {
    case tokens = "Tokens"
    case cost = "Cost"
    case requests = "Requests"

    public var id: String { rawValue }
}

public enum AgentUsageGrouping: String, CaseIterable, Identifiable, Sendable {
    case agent = "Agent"
    case model = "Model"
    case project = "Project"

    public var id: String { rawValue }
}

public struct AgentUsageFilter: Hashable, Sendable {
    public var range: AgentDateRange = .thirtyDays
    /// Empty means every enabled agent.
    public var agents: Set<AgentKind> = []
    /// Empty means every project.
    public var projects: Set<String> = []
    /// Empty means every model.
    public var models: Set<String> = []
    public var metric: AgentMetricKind = .tokens
    public var grouping: AgentUsageGrouping = .model

    public init() {}

    public var isNarrowed: Bool { !agents.isEmpty || !projects.isEmpty || !models.isEmpty }
}

/// Token, cost, and request totals for any slice of usage events.
public struct AgentUsageTotals: Hashable, Sendable {
    public var tokens = TokenUsage.zero
    public var processed: Int64 = 0
    public var uncachedInput: Int64 = 0
    public var cost: Double = 0
    public var pricedEvents = 0
    public var estimatedCostEvents = 0
    public var cacheSavings: Double = 0
    public var requests = 0
    public var events = 0
    public var sessions = 0

    public init() {}

    public var hasCost: Bool { pricedEvents > 0 }
    public var costIsEstimated: Bool { estimatedCostEvents > 0 }
    /// Share of prompt tokens served from cache.
    public var cacheHitRate: Double? {
        let read = tokens.cachedInputTokens ?? 0
        let prompt = read + (tokens.cacheCreationTokens ?? 0) + uncachedInput
        return prompt > 0 ? Double(read) / Double(prompt) : nil
    }

    public func value(for metric: AgentMetricKind) -> Double {
        switch metric {
        case .tokens: return Double(processed)
        case .cost: return cost
        case .requests: return Double(requests)
        }
    }

    mutating func add(_ event: AgentUsageEvent) {
        let usage = event.usage.normalized()
        tokens = tokens.adding(usage)
        processed += usage.processedTokens ?? 0
        uncachedInput += usage.derivedUncachedInputTokens ?? 0
        if let value = event.cost {
            cost += value
            pricedEvents += 1
            if event.costIsEstimated { estimatedCostEvents += 1 }
        }
        cacheSavings += event.cacheSavings ?? 0
        requests += event.requests ?? 1
        events += 1
    }
}

public struct AgentUsageRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// The agent this row belongs to; nil when a row spans several (e.g. a project used by two agents).
    public var agent: AgentKind?
    public var agents: Set<AgentKind>
    public var totals: AgentUsageTotals
    /// Share of the selected metric across all rows, 0...1.
    public var share: Double
}

public struct AgentUsageBucket: Identifiable, Hashable, Sendable {
    public var id: String { "\(date.timeIntervalSince1970)-\(agent.rawValue)" }
    public var date: Date
    public var agent: AgentKind
    public var value: Double
}

public struct AgentUsageReport: Sendable {
    public var filter: AgentUsageFilter
    public var totals = AgentUsageTotals()
    public var byAgent: [AgentUsageRow] = []
    public var rows: [AgentUsageRow] = []
    /// Stacked series for the chart: one bucket per (day or hour, agent), zero-filled.
    public var buckets: [AgentUsageBucket] = []
    public var bucketDates: [Date] = []
    public var isHourly = false
    public var busiest: (date: Date, value: Double)?
    public var activeBuckets = 0
    public var availableProjects: [String] = []
    public var availableModels: [String] = []
    public var hasAnyEvents = false

    public init(filter: AgentUsageFilter) { self.filter = filter }

    public var average: Double {
        activeBuckets > 0 ? totals.value(for: filter.metric) / Double(activeBuckets) : 0
    }

    public var metricHasData: Bool {
        switch filter.metric {
        case .tokens: return totals.processed > 0
        case .cost: return totals.hasCost
        case .requests: return totals.requests > 0
        }
    }
}

/// Coarse state buckets the Activity page groups running sessions into.
public enum AgentActivityBucket: String, CaseIterable, Identifiable, Sendable {
    case needsYou = "Needs you"
    case working = "Working"
    case yourTurn = "Your turn"
    case idle = "Idle"

    public var id: String { rawValue }

    public init(_ session: AgentSession) {
        if session.needsAttention { self = .needsYou; return }
        switch session.state {
        case .running, .working, .thinking, .toolUse: self = .working
        case .waiting: self = .yourTurn
        default: self = .idle
        }
    }
}

/// Filters for the Activity page. Empty sets mean "everything".
public struct AgentActivityFilter: Hashable, Sendable {
    public var agents: Set<AgentKind> = []
    public var buckets: Set<AgentActivityBucket> = []
    public var projects: Set<String> = []
    public var models: Set<String> = []
    /// Only recent sessions updated inside this window; nil keeps the whole history.
    public var recentRange: AgentDateRange? = nil
    /// Only recent sessions that used at least this many tokens.
    public var minTokens: Int64 = 0

    public init() {}

    public var isNarrowed: Bool {
        !agents.isEmpty || !buckets.isEmpty || !projects.isEmpty || !models.isEmpty || recentRange != nil || minTokens > 0
    }

    /// Filters shared by running and recent sessions.
    public func matches(_ session: AgentSession) -> Bool {
        (agents.isEmpty || agents.contains(session.agent))
            && (projects.isEmpty || projects.contains(session.projectName))
            && (models.isEmpty || models.contains(session.model))
    }

    public func matchesRunning(_ session: AgentSession) -> Bool {
        matches(session) && (buckets.isEmpty || buckets.contains(AgentActivityBucket(session)))
    }

    public func matchesRecent(_ session: AgentSession, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard matches(session) else { return false }
        if let recentRange, session.updatedAt < recentRange.start(now: now, calendar: calendar) { return false }
        if minTokens > 0, (session.usage?.processedTokens ?? 0) < minTokens { return false }
        return true
    }
}
