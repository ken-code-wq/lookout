import Foundation

// Archetypes: a name for how someone works with agents, read off a profile by fixed threshold rules. Every match
// carries the numbers it rests on and a sentence saying so, and a period with too little activity gets no archetype
// rather than a guess. Rules are in `ProfileArchetypes.rules`; each qualifies at its threshold and reaches full
// strength further out, scaling linearly between. The primary archetype is the strongest qualifying habit; traits
// (which tool rather than how) lead only when no habit qualifies. Ties go to the order of `ProfileArchetype`.

public enum ProfileArchetype: String, CaseIterable, Codable, Identifiable, Sendable {
    // Habits, in tie-break order.
    case conductor, deepThinker, nightShift, earlyBird, weekendWarrior, marathoner, sprinter, architect, sommelier
    // Traits.
    case loyalist, cacheWhisperer
    // Defaults: enough data but nothing stands out; or too new to tell.
    case allRounder, gettingStarted

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .conductor: return "The Conductor"
        case .deepThinker: return "The Deep Thinker"
        case .nightShift: return "Night Shift"
        case .earlyBird: return "The Early Bird"
        case .weekendWarrior: return "Weekend Warrior"
        case .marathoner: return "The Marathoner"
        case .sprinter: return "The Sprinter"
        case .architect: return "The Architect"
        case .sommelier: return "The Sommelier"
        case .loyalist: return "The Loyalist"
        case .cacheWhisperer: return "The Cache Whisperer"
        case .allRounder: return "The All-Rounder"
        case .gettingStarted: return "Just Getting Started"
        }
    }

    public var tagline: String {
        switch self {
        case .conductor: return "Keeps a whole ensemble of agents playing at once."
        case .deepThinker: return "Turns the reasoning dial all the way up."
        case .nightShift: return "The best ideas show up after dark."
        case .earlyBird: return "Ships before the coffee cools."
        case .weekendWarrior: return "Saturdays are for side quests."
        case .marathoner: return "Long sessions, steady pace, big finishes."
        case .sprinter: return "In, done, next. Short, sharp bursts."
        case .architect: return "Keeps a skyline of projects rising at once."
        case .sommelier: return "Pairs the right model with every task."
        case .loyalist: return "Found the one and stuck with it."
        case .cacheWhisperer: return "Reuses context so well the bill barely notices."
        case .allRounder: return "A little of everything, nothing to excess."
        case .gettingStarted: return "Every streak starts with day one."
        }
    }

    /// Traits describe a tool rather than a way of working, and lead only when no habit qualifies.
    public var isTrait: Bool { self == .loyalist || self == .cacheWhisperer }
}

/// A number an archetype rests on.
public struct ProfileFact: Identifiable, Hashable, Sendable {
    /// Stable key, e.g. "parallelDays".
    public var id: String
    /// "Days with 3+ agents at once".
    public var label: String
    public var value: Double
    /// The value as shown: "12 of 30", "31%", "42m".
    public var text: String
}

/// A threshold rule. Strength runs from 0 at `threshold` to 1 at `full` (lower is stronger when `full` is below it).
public struct ArchetypeRule: Hashable, Sendable {
    public var archetype: ProfileArchetype
    public var threshold: Double
    public var full: Double
    /// The rule in words: "3+ agents at once on at least 25% of active days".
    public var summary: String

    public func strength(_ value: Double) -> Double? {
        let rising = full >= threshold
        guard rising ? value >= threshold : value <= threshold else { return nil }
        guard full != threshold else { return 1 }
        return min(max((value - threshold) / (full - threshold), 0), 1)
    }
}

public struct ArchetypeMatch: Identifiable, Hashable, Sendable {
    public var id: ProfileArchetype { archetype }
    public var archetype: ProfileArchetype
    /// 0 at the rule's threshold, 1 at full strength. Defaults score 0.
    public var strength: Double
    /// "3+ agents at once on 12 of 30 active days, up to 7 at once".
    public var sentence: String
    public var facts: [ProfileFact]
    /// The rule it passed, in words.
    public var rule: String
}

public struct ArchetypeResult: Hashable, Sendable {
    public var primary: ArchetypeMatch?
    /// The next strongest match, habit or trait.
    public var secondary: ArchetypeMatch?
    /// Every rule that qualified, strongest first.
    public var qualified: [ArchetypeMatch] = []
    /// Why habits couldn't be read, when the period had too little to go on. Set alongside "Just getting started".
    public var insufficientData: String?

    public init(primary: ArchetypeMatch? = nil, secondary: ArchetypeMatch? = nil, qualified: [ArchetypeMatch] = [], insufficientData: String? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.qualified = qualified
        self.insufficientData = insufficientData
    }
}

public enum ProfileArchetypes {
    /// Below either, a period says too little about habits to name one.
    public static let minimumActiveDays = 3
    public static let minimumRequests = 50
    /// A history younger than this, or with fewer active days than the minimum, is just getting started.
    public static let newcomerDays = 14
    /// Conductor counts days with at least this many sessions working at the same moment, and needs a few of them.
    public static let conductorAtOnce = 3
    public static let conductorMinimumDays = 2
    /// Deep Thinker reads effort only when it's known for at least this share of requests.
    public static let effortCoverageNeeded = 0.5
    public static let deepEffortLevels: Set<String> = ["high", "xhigh", "max"]
    /// A model or project is in regular use at this share of requests.
    public static let regularShare = 0.05
    /// Session-length archetypes need this many sessions with more than one request.
    public static let marathonerMinimumSessions = 5
    public static let sprinterMinimumSessions = 10
    /// Weekend Warrior needs a period of at least a week with this many active weekend days.
    public static let weekendMinimumDays = 2

    /// Tuned on real multi-agent use: Claude Code alone serves ~98% of prompt tokens from cache, so caching only
    /// stands out near the top; parallel work, night hours and weekends are rarer and qualify lower.
    public static let rules: [ArchetypeRule] = [
        ArchetypeRule(archetype: .conductor, threshold: 0.25, full: 0.6,
                      summary: "\(conductorAtOnce)+ agents at once on at least 25% of active days"),
        ArchetypeRule(archetype: .deepThinker, threshold: 0.6, full: 0.95,
                      summary: "At least 60% of requests at high effort or above, with effort known for half of them"),
        ArchetypeRule(archetype: .nightShift, threshold: 0.25, full: 0.5, summary: "At least 25% of requests between 22:00 and 04:00"),
        ArchetypeRule(archetype: .earlyBird, threshold: 0.2, full: 0.4, summary: "At least 20% of requests between 05:00 and 09:00"),
        ArchetypeRule(archetype: .weekendWarrior, threshold: 0.35, full: 0.6, summary: "At least 35% of requests on weekends"),
        ArchetypeRule(archetype: .marathoner, threshold: 30 * 60, full: 90 * 60, summary: "A typical session runs 30 minutes or more"),
        ArchetypeRule(archetype: .sprinter, threshold: 5 * 60, full: 60, summary: "A typical session wraps in 5 minutes or less"),
        ArchetypeRule(archetype: .architect, threshold: 5, full: 10, summary: "5 or more projects each taking 5% of requests"),
        ArchetypeRule(archetype: .sommelier, threshold: 4, full: 8, summary: "4 or more models each handling 5% of requests"),
        ArchetypeRule(archetype: .loyalist, threshold: 0.85, full: 1, summary: "One agent handles at least 85% of requests"),
        ArchetypeRule(archetype: .cacheWhisperer, threshold: 0.95, full: 0.995, summary: "At least 95% of prompt tokens served from cache"),
    ]

    public static func rule(for archetype: ProfileArchetype) -> ArchetypeRule? { rules.first { $0.archetype == archetype } }

    /// Reads `profile` against the rules.
    public static func evaluate(_ profile: PersonalProfile, now: Date = .now) -> ArchetypeResult {
        let totals = profile.totals
        let requests = totals.tally.requests
        let memberDays = profile.firsts.memberSince.map { now.timeIntervalSince($0) / 86_400 } ?? 0
        let newcomer = profile.allTimeActiveDays < minimumActiveDays || memberDays < Double(newcomerDays)

        guard totals.activeDays >= minimumActiveDays, requests >= minimumRequests else {
            let need = "Archetypes need \(minimumActiveDays) active days and \(minimumRequests) requests"
            let have = "\(plural(totals.activeDays, "active day")) and \(plural(requests, "request"))"
            guard newcomer else {
                let reason = profile.isEmpty ? "No agent activity in this period." : "Not enough activity in this period: \(have). \(need)."
                return ArchetypeResult(insufficientData: reason)
            }
            var facts = [ProfileFact(id: "activeDays", label: "Active days so far", value: Double(profile.allTimeActiveDays),
                                     text: "\(profile.allTimeActiveDays)")]
            if profile.firsts.memberSince != nil {
                facts.append(ProfileFact(id: "memberDays", label: "Days since the first activity", value: memberDays.rounded(.down),
                                         text: "\(Int(memberDays))"))
            }
            let sentence = profile.allTimeActiveDays == 0 ? "No agent activity yet"
                : "\(plural(profile.allTimeActiveDays, "active day")) so far"
            let match = ArchetypeMatch(archetype: .gettingStarted, strength: 0, sentence: sentence, facts: facts,
                                       rule: "A history under \(newcomerDays) days old or with fewer than \(minimumActiveDays) active days")
            return ArchetypeResult(primary: match, insufficientData: "\(need); so far this period has \(have).")
        }

        let matches = rules.compactMap { match($0, profile) }
            .sorted { lhs, rhs in
                lhs.strength != rhs.strength ? lhs.strength > rhs.strength
                    : order(lhs.archetype) < order(rhs.archetype)
            }
        let primary = matches.first { !$0.archetype.isTrait } ?? matches.first ?? allRounder(profile)
        let secondary = matches.first { $0.archetype != primary.archetype }
        return ArchetypeResult(primary: primary, secondary: secondary, qualified: matches)
    }

    private static func order(_ archetype: ProfileArchetype) -> Int { ProfileArchetype.allCases.firstIndex(of: archetype) ?? .max }

    /// One rule against one profile; nil when it doesn't qualify or its preconditions aren't met.
    private static func match(_ rule: ArchetypeRule, _ profile: PersonalProfile) -> ArchetypeMatch? {
        let totals = profile.totals
        let rhythm = profile.rhythm
        func make(_ value: Double, _ sentence: String, _ facts: [ProfileFact]) -> ArchetypeMatch? {
            rule.strength(value).map { ArchetypeMatch(archetype: rule.archetype, strength: $0, sentence: sentence, facts: facts, rule: rule.summary) }
        }
        switch rule.archetype {
        case .conductor:
            let days = profile.days(withAtLeast: conductorAtOnce)
            guard days >= conductorMinimumDays, totals.activeDays > 0 else { return nil }
            let share = Double(days) / Double(totals.activeDays)
            let peak = profile.records.peakConcurrent?.sessions ?? conductorAtOnce
            return make(share, "\(conductorAtOnce)+ agents at once on \(days) of \(totals.activeDays) active days, up to \(peak) at once", [
                ProfileFact(id: "parallelDays", label: "Days with \(conductorAtOnce)+ agents at once", value: Double(days), text: "\(days) of \(totals.activeDays)"),
                ProfileFact(id: "parallelShare", label: "Share of active days", value: share, text: percent(share)),
                ProfileFact(id: "peakConcurrent", label: "Most at once", value: Double(peak), text: "\(peak)"),
            ])
        case .deepThinker:
            let effort = profile.effort
            guard effort.coverage >= effortCoverageNeeded, let high = effort.highShare else { return nil }
            return make(high, "\(percent(high)) of requests at high effort or above, where effort is known (\(percent(effort.coverage)) of requests)", [
                ProfileFact(id: "highEffortShare", label: "Requests at high effort or above", value: high, text: percent(high)),
                ProfileFact(id: "effortCoverage", label: "Requests with known effort", value: effort.coverage, text: percent(effort.coverage)),
            ])
        case .nightShift:
            return make(rhythm.nightShare, "\(percent(rhythm.nightShare)) of requests between 22:00 and 04:00", [
                ProfileFact(id: "nightShare", label: "Requests between 22:00 and 04:00", value: rhythm.nightShare, text: percent(rhythm.nightShare)),
            ])
        case .earlyBird:
            return make(rhythm.earlyShare, "\(percent(rhythm.earlyShare)) of requests between 05:00 and 09:00", [
                ProfileFact(id: "earlyShare", label: "Requests between 05:00 and 09:00", value: rhythm.earlyShare, text: percent(rhythm.earlyShare)),
            ])
        case .weekendWarrior:
            guard profile.coveredDays >= 7, rhythm.weekendDays >= weekendMinimumDays else { return nil }
            return make(rhythm.weekendShare, "\(percent(rhythm.weekendShare)) of requests on weekends, across \(plural(rhythm.weekendDays, "weekend day"))", [
                ProfileFact(id: "weekendShare", label: "Requests on weekends", value: rhythm.weekendShare, text: percent(rhythm.weekendShare)),
                ProfileFact(id: "weekendDays", label: "Active weekend days", value: Double(rhythm.weekendDays), text: "\(rhythm.weekendDays)"),
            ])
        case .marathoner, .sprinter:
            let minimum = rule.archetype == .marathoner ? marathonerMinimumSessions : sprinterMinimumSessions
            guard let median = totals.medianSessionSeconds, totals.measuredSessions >= minimum else { return nil }
            let sentence = rule.archetype == .marathoner
                ? "A typical session runs \(AgentFormat.duration(median)) of active work"
                : "A typical session wraps in \(AgentFormat.duration(median))"
            return make(median, sentence, [
                ProfileFact(id: "medianSession", label: "Typical session", value: median, text: AgentFormat.duration(median)),
                ProfileFact(id: "measuredSessions", label: "Sessions measured", value: Double(totals.measuredSessions), text: "\(totals.measuredSessions)"),
            ])
        case .architect:
            let regular = profile.projects.filter { $0.share >= regularShare && !$0.id.isEmpty && $0.id != "Unknown workspace" }
            return make(Double(regular.count), "\(regular.count) projects each took 5% or more of requests", [
                ProfileFact(id: "regularProjects", label: "Projects with 5% of requests or more", value: Double(regular.count), text: "\(regular.count)"),
                ProfileFact(id: "projects", label: "Projects touched", value: Double(profile.projects.count), text: "\(profile.projects.count)"),
            ])
        case .sommelier:
            let regular = profile.models.filter { $0.share >= regularShare && !$0.id.isEmpty }
            return make(Double(regular.count), "\(regular.count) models each handled 5% or more of requests", [
                ProfileFact(id: "regularModels", label: "Models with 5% of requests or more", value: Double(regular.count), text: "\(regular.count)"),
                ProfileFact(id: "models", label: "Models used", value: Double(profile.models.count), text: "\(profile.models.count)"),
            ])
        case .loyalist:
            guard let top = profile.providers.first else { return nil }
            return make(top.share, "\(top.title) handled \(percent(top.share)) of requests", [
                ProfileFact(id: "topProviderShare", label: "\(top.title)'s share of requests", value: top.share, text: percent(top.share)),
                ProfileFact(id: "providers", label: "Agents used", value: Double(profile.providers.count), text: "\(profile.providers.count)"),
            ])
        case .cacheWhisperer:
            guard let rate = totals.cacheHitRate else { return nil }
            var facts = [ProfileFact(id: "cacheHitRate", label: "Prompt tokens served from cache", value: rate, text: percent(rate, digits: 1))]
            if totals.cacheSavings > 0 {
                facts.append(ProfileFact(id: "cacheSavings", label: "Saved by caching", value: totals.cacheSavings, text: AgentFormat.cost(totals.cacheSavings, estimated: true)))
            }
            return make(rate, "\(percent(rate, digits: 1)) of prompt tokens served from cache", facts)
        case .allRounder, .gettingStarted:
            return nil
        }
    }

    /// Enough to go on, and nothing stands out: say so with the numbers that came closest.
    private static func allRounder(_ profile: PersonalProfile) -> ArchetypeMatch {
        var facts: [ProfileFact] = []
        if let top = profile.providers.first {
            facts.append(ProfileFact(id: "topProviderShare", label: "\(top.title)'s share of requests", value: top.share, text: percent(top.share)))
        }
        if let median = profile.totals.medianSessionSeconds {
            facts.append(ProfileFact(id: "medianSession", label: "Typical session", value: median, text: AgentFormat.duration(median)))
        }
        facts.append(ProfileFact(id: "nightShare", label: "Requests between 22:00 and 04:00", value: profile.rhythm.nightShare, text: percent(profile.rhythm.nightShare)))
        return ArchetypeMatch(archetype: .allRounder, strength: 0, sentence: "No single habit stands out", facts: facts,
                              rule: "Enough activity to read, and no rule above its threshold")
    }

    /// Locale-free so sentences read the same everywhere: "31%", "96.5%".
    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        let scaled = fraction * 100
        if digits == 0 { return "\(Int(scaled.rounded()))%" }
        let factor = pow(10, Double(digits))
        let rounded = (scaled * factor).rounded() / factor
        return rounded == rounded.rounded() ? "\(Int(rounded))%" : "\(rounded)%"
    }

    static func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
}
