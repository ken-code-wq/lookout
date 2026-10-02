import Foundation
import SwiftUI
import LocalObserverCore

/// Pieces that can appear in the menu bar title, left to right.
enum MenuBarItem: String, CaseIterable, Identifiable, Codable {
    case servers, agents, attention, limit, todayCost, todayTokens

    var id: String { rawValue }
    var title: String {
        switch self {
        case .servers: return "Server count"
        case .agents: return "Running agents"
        case .attention: return "Agents that need you"
        case .limit: return "Tightest plan limit"
        case .todayCost: return "Today's cost"
        case .todayTokens: return "Today's tokens"
        }
    }
    var detail: String {
        switch self {
        case .servers: return "Local servers that are listening"
        case .agents: return "Hidden while something needs you, if that item is on"
        case .attention: return "Sessions waiting for permission or an answer"
        case .limit: return "Highest used percentage across your plan windows"
        case .todayCost: return "Estimated at API prices when agents do not report cost"
        case .todayTokens: return "Processed tokens since midnight"
        }
    }
    var symbol: String {
        switch self {
        case .servers: return "server.rack"
        case .agents: return "sparkles"
        case .attention: return "hand.raised.fill"
        case .limit: return "gauge.with.dots.needle.33percent"
        case .todayCost: return "dollarsign.circle"
        case .todayTokens: return "number"
        }
    }
}

/// Sections of the menu bar popover. Order is user-defined.
enum MenuSection: String, CaseIterable, Identifiable, Codable {
    case today, usage, agents, limits, sound, servers, launchers, shelf

    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .usage: return "Usage chart"
        case .sound: return "Sound"
        case .agents: return "Agents"
        case .limits: return "Limits"
        case .servers: return "Servers"
        case .launchers: return "Launchers"
        case .shelf: return "Shelf"
        }
    }
    var symbol: String {
        switch self {
        case .today: return "calendar"
        case .usage: return "chart.bar.xaxis"
        case .sound: return "slider.horizontal.3"
        case .agents: return "sparkles"
        case .limits: return "gauge.with.dots.needle.33percent"
        case .servers: return "server.rack"
        case .launchers: return "play.square.stack"
        case .shelf: return "tray.full"
        }
    }
}

/// What sits beside the notch while it's closed.
enum NotchWing: String, CaseIterable, Identifiable {
    case none, agents, limit, todayCost, todayTokens, servers, nowPlaying

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Nothing"
        case .nowPlaying: return "Now playing"
        case .agents: return "Running agents"
        case .limit: return "Plan limits"
        case .todayCost: return "Today's cost"
        case .todayTokens: return "Today's tokens"
        case .servers: return "Server count"
        }
    }
}

/// Pages of the open notch.
enum NotchTab: String, CaseIterable, Identifiable {
    case agents, usage, limits, servers, shelf, media, sound

    var id: String { rawValue }
    var title: String {
        switch self {
        case .media: return "Media"
        case .sound: return "Sound"
        case .agents: return "Agents"
        case .usage: return "Usage"
        case .limits: return "Limits"
        case .servers: return "Servers"
        case .shelf: return "Shelf"
        }
    }
    var symbol: String {
        switch self {
        case .agents: return "sparkles"
        case .usage: return "chart.bar.fill"
        case .limits: return "gauge.with.dots.needle.67percent"
        case .servers: return "server.rack"
        case .media: return "music.note"
        case .sound: return "slider.horizontal.3"
        case .shelf: return "tray.full"
        }
    }
}

/// Which plan window stands for a provider when there's room for only one number.
enum LimitWindowChoice: String, CaseIterable, Identifiable {
    case shortest, weekly, tightest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .shortest: return "Shortest window"
        case .weekly: return "Weekly window"
        case .tightest: return "Most used window"
        }
    }
    var detail: String {
        switch self {
        case .shortest: return "5-hour session when the provider has one"
        case .weekly: return "The all-models weekly window"
        case .tightest: return "Whichever window is closest to running out"
        }
    }
}

/// What Agent Peek's "today" pill shows.
enum PeekTodayMetric: String, CaseIterable, Identifiable {
    case cost, tokens, requests, sessions, cacheHits

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cost: return "Cost"
        case .tokens: return "Tokens"
        case .requests: return "Requests"
        case .sessions: return "Sessions"
        case .cacheHits: return "Cache hit rate"
        }
    }
    var symbol: String {
        switch self {
        case .cost: return "dollarsign.circle"
        case .tokens: return "number"
        case .requests: return "arrow.up.arrow.down"
        case .sessions: return "rectangle.stack"
        case .cacheHits: return "bolt.horizontal.circle"
        }
    }
}

/// How Agent Peek draws each plan window: a pie-style ring with the percentage inside, or a slim line.
enum PeekLimitStyle: String, CaseIterable, Identifiable {
    case pie, line

    var id: String { rawValue }
    var title: String { self == .pie ? "Pie" : "Line" }
    var symbol: String { self == .pie ? "chart.pie" : "chart.bar.fill" }
}

/// Agent Peek's footprint. Discrete modes rather than free resizing, like the notch's modes: each one decides
/// what it leaves out instead of squeezing the same content narrower.
enum PeekSize: String, CaseIterable, Identifiable, Codable {
    case large, medium, small

    var id: String { rawValue }
    var title: String {
        switch self {
        case .large: "Large"
        case .medium: "Medium"
        case .small: "Small"
        }
    }
    /// The letter on the header's size button.
    var letter: String {
        switch self {
        case .large: "L"
        case .medium: "M"
        case .small: "S"
        }
    }
    var width: CGFloat {
        switch self {
        case .large: 320
        case .medium: 260
        case .small: 200
        }
    }
    var next: PeekSize {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

enum KeepAwakeMode: String, CaseIterable, Identifiable {
    case off, whileWorking, always

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .whileWorking: return "While agents work"
        case .always: return "Always"
        }
    }
}

enum DockBadge: String, CaseIterable, Identifiable {
    case none = "None"
    case attention = "Agents that need you"
    case agents = "Running agents"
    case limit = "Tightest limit %"
    case servers = "Server count"
    var id: String { rawValue }
}

enum DockIconStyle: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case peek = "Agent Peek"
    var id: String { rawValue }
}

/// App-level display preferences for the menu bar, Dock, and floating Peek panel. Persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var menuBarItems: [MenuBarItem] { didSet { save(menuBarItems.map(\.rawValue), Keys.menuBarItems) } }
    @Published var menuSections: [MenuSection] { didSet { save(menuSections.map(\.rawValue), Keys.menuSections) } }
    @Published var hiddenSections: Set<MenuSection> { didSet { save(hiddenSections.map(\.rawValue), Keys.hiddenSections) } }
    @Published var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) } }
    @Published var dockBadge: DockBadge { didSet { defaults.set(dockBadge.rawValue, forKey: Keys.dockBadge) } }
    @Published var dockIconStyle: DockIconStyle { didSet { defaults.set(dockIconStyle.rawValue, forKey: Keys.dockIconStyle) } }
    @Published var peekOnAllSpaces: Bool { didSet { defaults.set(peekOnAllSpaces, forKey: Keys.peekOnAllSpaces) } }
    @Published var peekShowsLimits: Bool { didSet { defaults.set(peekShowsLimits, forKey: Keys.peekShowsLimits) } }
    /// Whether Agent Peek lists running agents at all. Off leaves just the limits.
    @Published var peekShowsAgents: Bool { didSet { defaults.set(peekShowsAgents, forKey: Keys.peekShowsAgents) } }
    @Published var peekLimitStyle: PeekLimitStyle { didSet { defaults.set(peekLimitStyle.rawValue, forKey: Keys.peekLimitStyle) } }
    /// False until the user has answered Peek's "what should it show?" prompt (or dismissed it).
    @Published var peekSetupDone: Bool { didSet { defaults.set(peekSetupDone, forKey: Keys.peekSetupDone) } }
    /// Agent Peek's outer glass: the see-through Liquid Glass variant, or frosted.
    @Published var peekTodayMetric: PeekTodayMetric { didSet { defaults.set(peekTodayMetric.rawValue, forKey: Keys.peekTodayMetric) } }
    @Published var peekClearGlass: Bool { didSet { defaults.set(peekClearGlass, forKey: Keys.peekClearGlass) } }
    @Published var peekSize: PeekSize { didSet { defaults.set(peekSize.rawValue, forKey: Keys.peekSize) } }
    /// Providers whose 5-hour window Small Peek shows, in this order. Empty means every provider that has one.
    @Published var peekSmallProviders: [AgentKind] { didSet { save(peekSmallProviders.map(\.rawValue), Keys.peekSmallProviders) } }
    @Published var peekVisible: Bool { didSet { defaults.set(peekVisible, forKey: Keys.peekVisible) } }
    /// Groups folded shut in the menu bar panel, by key ("agents", "limits", "projects", "apps", …).
    @Published var collapsedMenuGroups: Set<String> { didSet { save(Array(collapsedMenuGroups), Keys.collapsedMenuGroups) } }
    /// Sections folded shut in Agent Peek ("agents", "limits").
    @Published var collapsedPeekGroups: Set<String> { didSet { save(Array(collapsedPeekGroups), Keys.collapsedPeekGroups) } }
    /// Providers whose sessions and limits Agent Peek leaves out.
    @Published var peekHiddenAgents: Set<AgentKind> { didSet { save(peekHiddenAgents.map(\.rawValue), Keys.peekHiddenAgents) } }
    // Notch
    @Published var notchEnabled: Bool { didSet { defaults.set(notchEnabled, forKey: Keys.notchEnabled) } }
    @Published var notchLeft: NotchWing { didSet { defaults.set(notchLeft.rawValue, forKey: Keys.notchLeft) } }
    @Published var notchRight: NotchWing { didSet { defaults.set(notchRight.rawValue, forKey: Keys.notchRight) } }
    @Published var notchHoverToOpen: Bool { didSet { defaults.set(notchHoverToOpen, forKey: Keys.notchHoverToOpen) } }
    /// Briefly drops down when an agent needs you or finishes.
    @Published var notchAlerts: Bool { didSet { defaults.set(notchAlerts, forKey: Keys.notchAlerts) } }
    @Published var notchFinishedAlerts: Bool { didSet { defaults.set(notchFinishedAlerts, forKey: Keys.notchFinishedAlerts) } }
    /// Draws a notch-shaped pill on displays that don't have a camera notch.
    @Published var notchOnPlainDisplays: Bool { didSet { defaults.set(notchOnPlainDisplays, forKey: Keys.notchOnPlainDisplays) } }
    @Published var notchHaptics: Bool { didSet { defaults.set(notchHaptics, forKey: Keys.notchHaptics) } }
    @Published var notchTab: NotchTab { didSet { defaults.set(notchTab.rawValue, forKey: Keys.notchTab) } }

    /// Providers shown in the notch limit ring and the menu bar limit item, in this order. Empty means "whichever is tightest".
    @Published var limitProviders: [AgentKind] { didSet { save(limitProviders.map(\.rawValue), Keys.limitProviders) } }
    @Published var limitWindowChoice: LimitWindowChoice { didSet { defaults.set(limitWindowChoice.rawValue, forKey: Keys.limitWindowChoice) } }
    /// Volume and brightness changes drop down from the notch.
    /// Scales the closed wings, the open panel, and the virtual notch on displays without one. 0.8...1.3.
    @Published var notchWidth: Double { didSet { defaults.set(notchWidth, forKey: Keys.notchWidth) } }
    /// Brightness applied by software dimming on external displays that don't answer DDC. 1 is untouched.
    @Published var externalBrightness: Double { didSet { defaults.set(externalBrightness, forKey: Keys.externalBrightness) } }
    @Published var notchHUD: Bool { didSet { defaults.set(notchHUD, forKey: Keys.notchHUD) } }
    @Published var keepAwake: KeepAwakeMode { didSet { defaults.set(keepAwake.rawValue, forKey: Keys.keepAwake) } }

    // Notifications that complement the per-agent ones in AgentSettings.
    @Published var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: Keys.notifyFinished) } }
    @Published var notifyPace: Bool { didSet { defaults.set(notifyPace, forKey: Keys.notifyPace) } }
    /// A limit you used up (95%+) is available again: notification plus a notch drop-down at the reset time.
    @Published var notifyReset: Bool { didSet { defaults.set(notifyReset, forKey: Keys.notifyReset) } }

    /// System-wide shortcut that shows or hides Agent Peek. Nil turns it off.
    @Published var peekHotKey: HotKey? { didSet { saveHotKey(peekHotKey, Keys.peekHotKey) } }
    /// System-wide shortcut that opens the menu bar panel. Nil turns it off.
    @Published var menuBarHotKey: HotKey? { didSet { saveHotKey(menuBarHotKey, Keys.menuBarHotKey) } }
    /// System-wide shortcut that opens the notch. Nil turns it off.
    @Published var notchHotKey: HotKey? { didSet { saveHotKey(notchHotKey, Keys.notchHotKey) } }
    /// System-wide shortcut that opens clipboard history in the notch. Nil turns it off.
    @Published var shelfHotKey: HotKey? { didSet { saveHotKey(shelfHotKey, Keys.shelfHotKey) } }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let menuBarItems = "LocalObserver.menuBarItems"
        static let menuSections = "LocalObserver.menuSections"
        static let hiddenSections = "LocalObserver.hiddenSections"
        static let showDockIcon = "LocalObserver.showDockIcon"
        static let dockBadge = "LocalObserver.dockBadge"
        static let dockIconStyle = "LocalObserver.dockIconStyle"
        static let peekOnAllSpaces = "LocalObserver.peekOnAllSpaces"
        static let peekShowsLimits = "LocalObserver.peekShowsLimits"
        static let peekShowsAgents = "LocalObserver.peekShowsAgents"
        static let peekLimitStyle = "LocalObserver.peekLimitStyle"
        static let peekSetupDone = "LocalObserver.peekSetupDone"
        static let peekVisible = "LocalObserver.peekVisible"
        static let peekClearGlass = "LocalObserver.peekClearGlass"
        static let peekTodayMetric = "LocalObserver.peekTodayMetric"
        static let peekSize = "LocalObserver.peekSize"
        static let peekSmallProviders = "LocalObserver.peekSmallProviders"
        static let collapsedMenuGroups = "LocalObserver.collapsedMenuGroups"
        static let collapsedPeekGroups = "LocalObserver.collapsedPeekGroups"
        static let peekHiddenAgents = "LocalObserver.peekHiddenAgents"
        static let peekHotKey = "LocalObserver.peekHotKey"
        static let menuBarHotKey = "LocalObserver.menuBarHotKey"
        static let notchHotKey = "LocalObserver.notchHotKey"
        static let shelfHotKey = "LocalObserver.shelfHotKey"
        static let notchEnabled = "LocalObserver.notchEnabled"
        static let notchLeft = "LocalObserver.notchLeft"
        static let notchRight = "LocalObserver.notchRight"
        static let notchHoverToOpen = "LocalObserver.notchHoverToOpen"
        static let notchAlerts = "LocalObserver.notchAlerts"
        static let notchFinishedAlerts = "LocalObserver.notchFinishedAlerts"
        static let notchOnPlainDisplays = "LocalObserver.notchOnPlainDisplays"
        static let notchHaptics = "LocalObserver.notchHaptics"
        static let notchTab = "LocalObserver.notchTab"
        static let notifyFinished = "LocalObserver.notifyFinished"
        static let notifyPace = "LocalObserver.notifyPace"
        static let notifyReset = "LocalObserver.notifyReset"
        static let limitProviders = "LocalObserver.limitProviders"
        static let limitWindowChoice = "LocalObserver.limitWindowChoice"
        static let notchHUD = "LocalObserver.notchHUD"
        static let notchWidth = "LocalObserver.notchWidth"
        static let externalBrightness = "LocalObserver.externalBrightness"
        static let keepAwake = "LocalObserver.keepAwake"
    }

    private init() {
        let items = (defaults.stringArray(forKey: Keys.menuBarItems) ?? ["servers", "agents", "attention"])
        menuBarItems = items.compactMap(MenuBarItem.init(rawValue:))
        var sections = (defaults.stringArray(forKey: Keys.menuSections) ?? []).compactMap(MenuSection.init(rawValue:))
        // Sections added in later versions slot in after the one before them in the default order.
        for (index, section) in MenuSection.allCases.enumerated() where !sections.contains(section) {
            let previous = index > 0 ? MenuSection.allCases[index - 1] : nil
            let at = previous.flatMap { sections.firstIndex(of: $0) }.map { $0 + 1 } ?? sections.endIndex
            sections.insert(section, at: at)
        }
        menuSections = sections
        hiddenSections = Set((defaults.stringArray(forKey: Keys.hiddenSections) ?? []).compactMap(MenuSection.init(rawValue:)))
        showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? true
        dockBadge = DockBadge(rawValue: defaults.string(forKey: Keys.dockBadge) ?? "") ?? .attention
        dockIconStyle = DockIconStyle(rawValue: defaults.string(forKey: Keys.dockIconStyle) ?? "") ?? .standard
        peekOnAllSpaces = defaults.object(forKey: Keys.peekOnAllSpaces) as? Bool ?? true
        peekShowsLimits = defaults.object(forKey: Keys.peekShowsLimits) as? Bool ?? true
        peekShowsAgents = defaults.object(forKey: Keys.peekShowsAgents) as? Bool ?? true
        peekLimitStyle = PeekLimitStyle(rawValue: defaults.string(forKey: Keys.peekLimitStyle) ?? "") ?? .pie
        peekSetupDone = defaults.bool(forKey: Keys.peekSetupDone)
        peekVisible = defaults.bool(forKey: Keys.peekVisible)
        peekClearGlass = defaults.object(forKey: Keys.peekClearGlass) as? Bool ?? true
        peekTodayMetric = PeekTodayMetric(rawValue: defaults.string(forKey: Keys.peekTodayMetric) ?? "") ?? .cost
        peekSize = PeekSize(rawValue: defaults.string(forKey: Keys.peekSize) ?? "") ?? .large
        peekSmallProviders = (defaults.stringArray(forKey: Keys.peekSmallProviders) ?? []).compactMap(AgentKind.init(rawValue:))
        collapsedMenuGroups = Set(defaults.stringArray(forKey: Keys.collapsedMenuGroups) ?? [])
        collapsedPeekGroups = Set(defaults.stringArray(forKey: Keys.collapsedPeekGroups) ?? [])
        peekHiddenAgents = Set((defaults.stringArray(forKey: Keys.peekHiddenAgents) ?? []).compactMap(AgentKind.init(rawValue:)))
        notchEnabled = defaults.object(forKey: Keys.notchEnabled) as? Bool ?? true
        notchLeft = NotchWing(rawValue: defaults.string(forKey: Keys.notchLeft) ?? "") ?? .agents
        notchRight = NotchWing(rawValue: defaults.string(forKey: Keys.notchRight) ?? "") ?? .limit
        notchHoverToOpen = defaults.object(forKey: Keys.notchHoverToOpen) as? Bool ?? true
        notchAlerts = defaults.object(forKey: Keys.notchAlerts) as? Bool ?? true
        notchFinishedAlerts = defaults.object(forKey: Keys.notchFinishedAlerts) as? Bool ?? true
        notchOnPlainDisplays = defaults.object(forKey: Keys.notchOnPlainDisplays) as? Bool ?? true
        notchHaptics = defaults.object(forKey: Keys.notchHaptics) as? Bool ?? true
        notchTab = NotchTab(rawValue: defaults.string(forKey: Keys.notchTab) ?? "") ?? .agents
        notifyFinished = defaults.bool(forKey: Keys.notifyFinished)
        notifyPace = defaults.bool(forKey: Keys.notifyPace)
        notifyReset = defaults.object(forKey: Keys.notifyReset) as? Bool ?? true
        limitProviders = (defaults.stringArray(forKey: Keys.limitProviders) ?? []).compactMap(AgentKind.init(rawValue:))
        limitWindowChoice = LimitWindowChoice(rawValue: defaults.string(forKey: Keys.limitWindowChoice) ?? "") ?? .shortest
        notchHUD = defaults.object(forKey: Keys.notchHUD) as? Bool ?? true
        notchWidth = min(max(defaults.object(forKey: Keys.notchWidth) as? Double ?? 1, 0.8), 1.3)
        externalBrightness = min(max(defaults.object(forKey: Keys.externalBrightness) as? Double ?? 1, 0.2), 1)
        keepAwake = KeepAwakeMode(rawValue: defaults.string(forKey: Keys.keepAwake) ?? "") ?? .off
        peekHotKey = Self.loadHotKey(defaults, Keys.peekHotKey, default: HotKeyAction.peek.defaultKey)
        menuBarHotKey = Self.loadHotKey(defaults, Keys.menuBarHotKey, default: HotKeyAction.menuBar.defaultKey)
        notchHotKey = Self.loadHotKey(defaults, Keys.notchHotKey, default: HotKeyAction.notch.defaultKey)
        shelfHotKey = Self.loadHotKey(defaults, Keys.shelfHotKey, default: HotKeyAction.shelf.defaultKey)
    }

    func hotKey(for action: HotKeyAction) -> HotKey? {
        switch action {
        case .peek: return peekHotKey
        case .menuBar: return menuBarHotKey
        case .notch: return notchHotKey
        case .shelf: return shelfHotKey
        }
    }

    func setHotKey(_ key: HotKey?, for action: HotKeyAction) {
        switch action {
        case .peek: peekHotKey = key
        case .menuBar: menuBarHotKey = key
        case .notch: notchHotKey = key
        case .shelf: shelfHotKey = key
        }
    }

    /// A cleared shortcut is stored as empty data, so it stays off instead of reverting to the default.
    private func saveHotKey(_ key: HotKey?, _ name: String) {
        defaults.set(key.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: name)
    }

    private static func loadHotKey(_ defaults: UserDefaults, _ name: String, default fallback: HotKey) -> HotKey? {
        guard defaults.object(forKey: name) != nil else { return fallback }
        return defaults.data(forKey: name).flatMap { try? JSONDecoder().decode(HotKey.self, from: $0) }
    }

    func isCollapsed(menu key: String) -> Bool { collapsedMenuGroups.contains(key) }
    func toggleCollapsed(menu key: String) {
        if collapsedMenuGroups.contains(key) { collapsedMenuGroups.remove(key) } else { collapsedMenuGroups.insert(key) }
    }
    func isCollapsed(peek key: String) -> Bool { collapsedPeekGroups.contains(key) }
    func toggleCollapsed(peek key: String) {
        if collapsedPeekGroups.contains(key) { collapsedPeekGroups.remove(key) } else { collapsedPeekGroups.insert(key) }
    }
    func toggleLimitProvider(_ agent: AgentKind) {
        if let i = limitProviders.firstIndex(of: agent) { limitProviders.remove(at: i) } else { limitProviders.append(agent) }
    }

    /// The window that represents `agent` under the chosen rule.
    func primaryWindow(for agent: AgentKind, in windows: [AgentQuotaWindow]) -> AgentQuotaWindow? {
        let own = windows.filter { $0.agent == agent }
        switch limitWindowChoice {
        case .tightest:
            return own.max { $0.usedPercent < $1.usedPercent }
        case .shortest:
            return own.first { $0.kind == .session } ?? own.first { $0.kind == .daily } ?? own.first { $0.kind == .weekly }
                ?? own.first { $0.kind == .weeklyModel } ?? own.first { $0.kind == .monthly } ?? own.max { $0.usedPercent < $1.usedPercent }
        case .weekly:
            return own.first { $0.kind == .weekly } ?? own.first { $0.kind == .weeklyModel } ?? own.max { $0.usedPercent < $1.usedPercent }
        }
    }

    /// One window per chosen provider; when none are chosen, the single tightest window overall.
    func glanceWindows(from windows: [AgentQuotaWindow]) -> [AgentQuotaWindow] {
        if limitProviders.isEmpty {
            return windows.max { $0.usedPercent < $1.usedPercent }.map { [$0] } ?? []
        }
        return limitProviders.compactMap { primaryWindow(for: $0, in: windows) }
    }

    func toggleSmallPeekProvider(_ agent: AgentKind) {
        if let i = peekSmallProviders.firstIndex(of: agent) { peekSmallProviders.remove(at: i) } else { peekSmallProviders.append(agent) }
    }

    func setPeekHidden(_ agent: AgentKind, _ hidden: Bool) {
        if hidden { peekHiddenAgents.insert(agent) } else { peekHiddenAgents.remove(agent) }
    }

    func toggle(_ item: MenuBarItem, on: Bool) {
        if on {
            guard !menuBarItems.contains(item) else { return }
            // Keep the canonical order so the title doesn't shuffle as items are toggled.
            menuBarItems = MenuBarItem.allCases.filter { menuBarItems.contains($0) || $0 == item }
        } else {
            menuBarItems.removeAll { $0 == item }
        }
    }

    func move(_ section: MenuSection, by delta: Int) {
        guard let i = menuSections.firstIndex(of: section) else { return }
        let j = i + delta
        guard menuSections.indices.contains(j) else { return }
        menuSections.swapAt(i, j)
    }

    func isVisible(_ section: MenuSection) -> Bool { !hiddenSections.contains(section) }

    func setVisible(_ section: MenuSection, _ visible: Bool) {
        if visible { hiddenSections.remove(section) } else { hiddenSections.insert(section) }
    }

    private func save(_ value: [String], _ key: String) { defaults.set(value, forKey: key) }
}
