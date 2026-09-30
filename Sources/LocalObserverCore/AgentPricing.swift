import Foundation

/// API-equivalent model pricing, used to estimate cost when an agent does not report it.
///
/// Rates are a snapshot of LiteLLM's `model_prices_and_context_window.json` (the table
/// T3 Code and ccusage price against), taken 2026-09-25, plus family fallbacks. Tiered
/// variants (`above_200k`, flex, priority, batch) are ignored: transcripts do not record
/// which tier served a request, so everything is priced at the base tier.
public enum AgentPricing {
    /// Model ids repeat across every event of every session; the normalization regexes are
    /// far more expensive than the dictionary they pay into.
    private static let memoLock = NSLock()
    private static var priceMemo: [String: ModelRate?] = [:]
    private static var normalizeMemo: [String: String] = [:]

    /// USD per million tokens.
    public struct ModelRate: Hashable, Sendable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite: Double
        /// Multiple of all rates billed for a fast-mode request (Claude `usage.speed == "fast"`).
        public var fastMultiplier: Double

        public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, fastMultiplier: Double = 1) {
            self.input = input
            self.output = output
            // A model without published cache rates is priced as plain input, not as free.
            self.cacheRead = cacheRead ?? input
            self.cacheWrite = cacheWrite ?? input
            self.fastMultiplier = fastMultiplier
        }
    }

    /// Rate for a model id as written by an agent, or nil when the model is unpriced.
    public static func price(model: String) -> ModelRate? {
        memoLock.lock()
        if let hit = priceMemo[model] {
            memoLock.unlock()
            return hit
        }
        memoLock.unlock()
        let rate = computePrice(model: model)
        memoLock.lock()
        if priceMemo.count > 512 { priceMemo.removeAll() }
        priceMemo[model] = rate
        memoLock.unlock()
        return rate
    }

    private static func computePrice(model: String) -> ModelRate? {
        let key = normalize(model)
        guard !key.isEmpty, !unpriceable.contains(key) else { return nil }
        if isFreeModel(model) { return ModelRate(input: 0, output: 0, cacheRead: 0, cacheWrite: 0) }
        if let rate = table[key] { return rate }
        let undated = stripDateSuffix(key)
        if let rate = table[undated] { return rate }
        // Unknown variant of a known model (e.g. gpt-5.5-codex → gpt-5.5): trim trailing segments.
        // Claude ids are versioned by dash, so trimming would land on an older generation; use family rates.
        var trimmed = undated.hasPrefix("claude") ? "" : undated
        while let dash = trimmed.lastIndex(of: "-"), trimmed.distance(from: trimmed.startIndex, to: dash) > 3 {
            trimmed = String(trimmed[..<dash])
            if let rate = table[trimmed] { return rate }
        }
        for (prefix, rate) in familyFallbacks where undated.hasPrefix(prefix) {
            return rate
        }
        return nil
    }

    /// Estimated cost in USD, or nil when the model is unpriced.
    /// `usage` must carry uncached input explicitly or an `inputTokens` that includes cache.
    public static func cost(usage: TokenUsage, model: String, fast: Bool = false) -> Double? {
        guard let rate = price(model: model) else { return nil }
        let uncached = Double(usage.derivedUncachedInputTokens ?? 0)
        let cached = Double(usage.cachedInputTokens ?? 0)
        let written = Double(usage.cacheCreationTokens ?? 0)
        let output = Double(usage.outputTokens ?? 0)
        let standard = uncached * rate.input + cached * rate.cacheRead + written * rate.cacheWrite + output * rate.output
        return standard / 1_000_000 * (fast ? rate.fastMultiplier : 1)
    }

    /// What cached input would have cost at the full input rate, minus what it cost. Nil when unpriced.
    public static func cacheSavings(usage: TokenUsage, model: String, fast: Bool = false) -> Double? {
        guard let rate = price(model: model) else { return nil }
        let cached = Double(usage.cachedInputTokens ?? 0)
        return cached * (rate.input - rate.cacheRead) / 1_000_000 * (fast ? rate.fastMultiplier : 1)
    }

    /// Lowercases, drops provider prefixes (`anthropic/`, `openai/`, `vercel/anthropic/`),
    /// bracketed variants (`[1m]`), `:free`/`-free` tags, and dotted Claude versions (`claude-haiku-4.5`).
    public static func normalize(_ model: String) -> String {
        memoLock.lock()
        if let hit = normalizeMemo[model] {
            memoLock.unlock()
            return hit
        }
        memoLock.unlock()
        let key = computeNormalize(model)
        memoLock.lock()
        if normalizeMemo.count > 512 { normalizeMemo.removeAll() }
        normalizeMemo[model] = key
        memoLock.unlock()
        return key
    }

    private static func computeNormalize(_ model: String) -> String {
        var key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let bracket = key.firstIndex(of: "[") { key = String(key[..<bracket]) }
        if let slash = key.lastIndex(of: "/") { key = String(key[key.index(after: slash)...]) }
        if let colon = key.firstIndex(of: ":") { key = String(key[..<colon]) }
        if key.hasPrefix("anthropic.") { key.removeFirst("anthropic.".count) }
        if key.hasPrefix("claude") {
            key = key.replacingOccurrences(of: ".", with: "-")
            // Older naming puts the version before the family: claude-3-5-sonnet → keep; claude-4-sonnet → claude-sonnet-4.
            for family in ["opus", "sonnet", "haiku", "fable"] {
                let pattern = "^claude-([0-9]+(?:-[0-9]+)?)-\(family)"
                if let range = key.range(of: pattern, options: .regularExpression) {
                    let version = key[range].dropFirst("claude-".count).dropLast(family.count + 1)
                    if let major = version.split(separator: "-").first, let number = Int(major), number >= 4 {
                        key.replaceSubrange(range, with: "claude-\(family)-\(version)")
                    }
                }
            }
            if key.hasSuffix("-thinking") { key.removeLast("-thinking".count) }
        }
        return key
    }

    static func isFreeModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        return lower.hasSuffix(":free") || lower.hasSuffix("-free")
    }

    private static func stripDateSuffix(_ key: String) -> String {
        // claude-haiku-4-5-20251001, gpt-5.2-2025-12-11, gpt-4o-2024-08-06
        if let range = key.range(of: "-20[0-9]{2}-?[0-9]{2}-?[0-9]{2}$", options: .regularExpression) {
            return String(key[..<range.lowerBound])
        }
        if key.hasSuffix("-latest") { return String(key.dropLast("-latest".count)) }
        return key
    }

    /// Locally generated messages and bare family names are never priced.
    private static let unpriceable: Set<String> = ["<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable", "default", "auto"]

    private static func rate(_ input: Double, _ output: Double, _ cacheRead: Double?, _ cacheWrite: Double? = nil, fast: Double = 1) -> ModelRate {
        ModelRate(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, fastMultiplier: fast)
    }

    static let table: [String: ModelRate] = [
        // Anthropic (LiteLLM)
        "claude-opus-5-5": rate(4, 20, 0.2, 5, fast: 2),
        "claude-opus-5": rate(5, 25, 0.5, 6.25, fast: 2),
        "claude-opus-4-8": rate(5, 25, 0.5, 6.25, fast: 2),
        "claude-opus-4-7": rate(5, 25, 0.5, 6.25),
        "claude-opus-4-6": rate(5, 25, 0.5, 6.25),
        "claude-opus-4-5": rate(5, 25, 0.5, 6.25),
        "claude-sonnet-5": rate(2, 10, 0.2, 2.5),
        "claude-sonnet-4-6": rate(3, 15, 0.3, 3.75),
        "claude-sonnet-4-5": rate(3, 15, 0.3, 3.75),
        "claude-haiku-4-5": rate(1, 5, 0.1, 1.25),
        "claude-fable-5-1": rate(10, 50, 0.25, 12.5),
        "claude-fable-5": rate(10, 50, 1, 12.5),
        // Anthropic, older generations (Anthropic list prices; no longer in LiteLLM's base keys)
        "claude-opus-4-1": rate(15, 75, 1.5, 18.75),
        "claude-opus-4": rate(15, 75, 1.5, 18.75),
        "claude-sonnet-4": rate(3, 15, 0.3, 3.75),
        "claude-3-7-sonnet": rate(3, 15, 0.3, 3.75),
        "claude-3-5-sonnet": rate(3, 15, 0.3, 3.75),
        "claude-3-5-haiku": rate(0.8, 4, 0.08, 1),
        "claude-3-opus": rate(15, 75, 1.5, 18.75),
        "claude-3-haiku": rate(0.25, 1.25, 0.03, 0.3),
        // OpenAI (LiteLLM)
        "gpt-5.6": rate(4, 20, 0.4, 5),
        "gpt-5.6-sol": rate(4, 20, 0.4, 5),
        "gpt-5.6-terra": rate(2, 12, 0.2, 2.5),
        "gpt-5.6-luna": rate(0.2, 1.2, 0.02, 0.25),
        "gpt-5.6-cyber": rate(12.5, 75, 1.25, 15.625),
        "gpt-5.5": rate(5, 30, 0.5),
        "gpt-5.5-pro": rate(30, 180, nil),
        "gpt-5.5-cyber": rate(12.5, 75, 1.25),
        "gpt-5.4": rate(2.5, 15, 0.25),
        "gpt-5.4-pro": rate(30, 180, nil),
        "gpt-5.4-mini": rate(0.75, 4.5, 0.075),
        "gpt-5.4-nano": rate(0.2, 1.25, 0.02),
        "gpt-5.3-codex": rate(1.75, 14, 0.175),
        "gpt-5.2": rate(1.75, 14, 0.175),
        "gpt-5.2-codex": rate(1.75, 14, 0.175),
        "gpt-5.2-pro": rate(21, 168, nil),
        "gpt-5.1": rate(1.25, 10, 0.125),
        "gpt-5.1-codex": rate(1.25, 10, 0.125),
        "gpt-5.1-codex-max": rate(1.25, 10, 0.125),
        "gpt-5.1-codex-mini": rate(0.25, 2, 0.025),
        "gpt-5": rate(1.25, 10, 0.125),
        "gpt-5-codex": rate(1.25, 10, 0.125),
        "gpt-5-pro": rate(15, 120, nil),
        "gpt-5-mini": rate(0.25, 2, 0.025),
        "gpt-5-nano": rate(0.05, 0.4, 0.005),
        "gpt-4.1": rate(2, 8, 0.5),
        "gpt-4.1-mini": rate(0.4, 1.6, 0.1),
        "gpt-4.1-nano": rate(0.1, 0.4, 0.025),
        "gpt-4o": rate(2.5, 10, 1.25),
        "gpt-4o-mini": rate(0.15, 0.6, 0.075),
        "o3": rate(2, 8, 0.5),
        "o3-mini": rate(1.1, 4.4, 0.55),
        "o4-mini": rate(1.1, 4.4, 0.275),
        "o1": rate(15, 60, 7.5),
        // Google (LiteLLM)
        "gemini-3.8-flash": rate(0.75, 3.75, 0.075),
        "gemini-3.7-flash": rate(0.75, 3.75, 0.075),
        "gemini-3.6-flash": rate(0.75, 3.75, 0.075),
        "gemini-3.5-flash": rate(1.5, 9, 0.15),
        "gemini-3.5-flash-lite": rate(0.3, 2.5, 0.03),
        "gemini-3.1-flash-lite": rate(0.25, 1.5, 0.025),
        "gemini-3.1-pro": rate(2, 12, 0.2),
        "gemini-3.1-pro-preview": rate(2, 12, 0.2),
        "gemini-3-pro": rate(2, 12, 0.2),
        "gemini-3-pro-preview": rate(2, 12, 0.2),
        "gemini-3-flash": rate(0.5, 3, 0.05),
        "gemini-3-flash-preview": rate(0.5, 3, 0.05),
        "gemini-2.5-pro": rate(1.25, 10, 0.125),
        "gemini-2.5-flash": rate(0.3, 2.5, 0.03),
        "gemini-2.5-flash-thinking": rate(0.3, 2.5, 0.03),
        "gemini-2.5-flash-lite": rate(0.1, 0.4, 0.01)
    ]

    /// Checked in order after exact and undated lookups miss. Longest prefixes first.
    static let familyFallbacks: [(String, ModelRate)] = [
        ("claude-opus-", rate(5, 25, 0.5, 6.25)),
        ("claude-sonnet-", rate(3, 15, 0.3, 3.75)),
        ("claude-haiku-", rate(1, 5, 0.1, 1.25)),
        ("claude-fable-", rate(10, 50, 1, 12.5)),
        ("gpt-5-mini", rate(0.25, 2, 0.025)),
        ("gpt-5-nano", rate(0.05, 0.4, 0.005)),
        ("gpt-5", rate(1.25, 10, 0.125))
    ]
}
