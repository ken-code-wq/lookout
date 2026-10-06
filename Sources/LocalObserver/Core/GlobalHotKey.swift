import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key plus modifiers, stored as a Carbon virtual key code so it survives keyboard layout changes.
struct HotKey: Codable, Hashable, Identifiable {
    var keyCode: UInt32
    var modifiers: UInt

    var id: String { "\(modifiers)-\(keyCode)" }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(HotKey.relevant).rawValue
    }

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(HotKey.relevant) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// Menu-style order: ⌃⌥⇧⌘.
    var modifierSymbols: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    var keyName: String { HotKey.names[Int(keyCode)] ?? "Key \(keyCode)" }
    var display: String { modifierSymbols + keyName }

    /// Function keys work alone; everything else needs ⌘, ⌃, or ⌥ so typing isn't hijacked.
    var isUsable: Bool {
        HotKey.functionKeys.contains(Int(keyCode)) || !flags.intersection([.command, .control, .option]).isEmpty
    }

    /// Shown next to the menu command. Nil for keys SwiftUI can't express as a single character.
    var keyboardShortcut: KeyboardShortcut? {
        guard keyName.count == 1, let char = keyName.lowercased().first else { return nil }
        var m: SwiftUI.EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.shift) { m.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(char), modifiers: m)
    }

    static let letters: [(Int, String)] = [
        (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
        (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
        (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
        (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
        (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
        (kVK_ANSI_Z, "Z"),
    ]
    static let digits: [(Int, String)] = [
        (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
        (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
    ]
    static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    ]
    private static let names: [Int: String] = {
        var map = Dictionary(uniqueKeysWithValues: letters + digits)
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (i, code) in fKeys.enumerated() { map[code] = "F\(i + 1)" }
        let extra: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
        map.merge(extra) { a, _ in a }
        return map
    }()
    /// Reverse lookup for parsing NSUserKeyEquivalents strings like "@~p".
    static func keyCode(for character: String) -> UInt32? {
        let upper = character.uppercased()
        return names.first { $0.value == upper }.map { UInt32($0.key) }
    }
}

/// Why a shortcut can't (or shouldn't) be used.
enum HotKeyConflict: Equatable {
    case macOS
    case otherApp
    case appShortcut(String)
    case localObserver(String)

    var message: String {
        switch self {
        case .macOS: return "Used by a macOS shortcut (System Settings › Keyboard › Keyboard Shortcuts)"
        case .otherApp: return "Already taken by another app's global shortcut"
        case .appShortcut(let title): return "Assigned to “\(title)” in System Settings › App Shortcuts"
        case .localObserver(let title): return "Lookout already uses it for \(title)"
        }
    }
}

/// Things a system-wide shortcut can do.
enum HotKeyAction: UInt32, CaseIterable, Identifiable {
    case peek = 1
    case menuBar = 2
    case notch = 3
    case shelf = 4
    case approvals = 5

    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .peek: return "Toggle Agent Peek"
        case .menuBar: return "Open the menu bar panel"
        case .notch: return "Open the notch"
        case .shelf: return "Open clipboard history"
        case .approvals: return "Answer the oldest agent request"
        }
    }
    var defaultKey: HotKey {
        switch self {
        case .peek: return HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: [.control, .option, .command])
        case .menuBar: return HotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: [.control, .option, .command])
        case .notch: return HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: [.control, .option, .command])
        // V for paste. Opens the history with its search focused; Return copies the match.
        case .shelf: return HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: [.control, .option, .command])
        // A for approve. Opens the oldest permission request with ⏎ (allow) and ⎋ (deny) ready.
        case .approvals: return HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: [.control, .option, .command])
        }
    }
    /// Letters that hint at the action, offered first by the finder.
    var preferredLetters: [String] {
        switch self {
        case .peek: return ["P", "A", "K", "G"]
        case .menuBar: return ["L", "M", "O", "B"]
        case .notch: return ["N", "D", "I", "T"]
        case .shelf: return ["V", "C", "H", "S"]
        case .approvals: return ["A", "Y", "R", "E"]
        }
    }

    @MainActor func perform() {
        switch self {
        case .peek: LiveSurfaces.shared.togglePeek()
        case .menuBar: LiveSurfaces.shared.toggleMenuBarPanel()
        case .notch: NotchController.shared.toggle()
        case .shelf: NotchController.shared.toggleClipboardHistory()
        case .approvals: ApprovalCenter.shared.openOldest()
        }
    }
}

/// Registers Local Observer's system-wide shortcuts with Carbon, which works without Accessibility permission.
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var registered: [HotKeyAction: HotKey] = [:]
    private var handlerInstalled = false
    private static let signature: OSType = 0x4C4F_4250 // "LOBP"

    func register(_ action: HotKeyAction, _ key: HotKey?) {
        unregister(action)
        installHandler()
        guard let key else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.carbonModifiers, EventHotKeyID(signature: Self.signature, id: action.rawValue),
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref { refs[action] = ref; registered[action] = key }
    }

    /// Pauses every shortcut while a recorder listens, so pressing one records it instead of running it.
    func suspend() { HotKeyAction.allCases.forEach(unregister) }
    func resume() { HotKeyAction.allCases.forEach { register($0, Preferences.shared.hotKey(for: $0)) } }

    private func unregister(_ action: HotKeyAction) {
        if let ref = refs[action] { UnregisterEventHotKey(ref) }
        refs[action] = nil
        registered[action] = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == GlobalHotKeys.signature, let action = HotKeyAction(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in action.perform() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    // MARK: Conflict detection

    /// Checks macOS's own shortcuts, user App Shortcuts, other apps' registered global shortcuts, and this app's menus
    /// and other global shortcuts.
    func conflict(for key: HotKey, action: HotKeyAction) -> HotKeyConflict? {
        if let title = ownShortcuts(except: action)[key] { return .localObserver(title) }
        if key == Preferences.shared.hotKey(for: action) && registered[action] == key { return nil }
        if Self.systemShortcuts().contains(key) { return .macOS }
        if let title = Self.userAppShortcuts()[key] { return .appShortcut(title) }
        if !Self.canRegister(key) { return .otherApp }
        return nil
    }

    /// Free combinations, easiest-to-press first: ⌃⌥⌘ and ⌃⌥ plus a letter, then ⌥⇧⌘ and ⌃⇧, then F-keys.
    func suggestions(for action: HotKeyAction, limit: Int = 12) -> [HotKey] {
        let groups: [NSEvent.ModifierFlags] = [[.control, .option, .command], [.control, .option], [.option, .shift, .command], [.control, .shift]]
        let preferred = action.preferredLetters
        let letters = HotKey.letters.sorted { a, b in
            let ia = preferred.firstIndex(of: a.1) ?? 99, ib = preferred.firstIndex(of: b.1) ?? 99
            return ia != ib ? ia < ib : a.1 < b.1
        }
        let system = Self.systemShortcuts()
        let appShortcuts = Self.userAppShortcuts()
        let own = ownShortcuts(except: action)
        var result: [HotKey] = []
        let candidates = groups.flatMap { mods in letters.map { HotKey(keyCode: UInt32($0.0), modifiers: mods) } }
            + [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19].map { HotKey(keyCode: UInt32($0), modifiers: []) }
        for key in candidates where result.count < limit {
            guard own[key] == nil else { continue }
            if key == registered[action] { result.append(key); continue }
            guard !system.contains(key), appShortcuts[key] == nil, Self.canRegister(key) else { continue }
            result.append(key)
        }
        return result
    }

    /// Menu shortcuts plus the other global shortcuts, so one action can't steal another's keys.
    private func ownShortcuts(except action: HotKeyAction) -> [HotKey: String] {
        var map = Self.menuShortcuts
        for other in HotKeyAction.allCases where other != action {
            if let key = Preferences.shared.hotKey(for: other) { map[key] = other.title }
        }
        return map
    }

    /// Shortcuts from this app's own menus, so a global hotkey doesn't shadow them.
    private static let menuShortcuts: [HotKey: String] = {
        func key(_ code: Int, _ mods: NSEvent.ModifierFlags) -> HotKey { HotKey(keyCode: UInt32(code), modifiers: mods) }
        return [
            key(kVK_ANSI_1, [.command, .option]): "Activity",
            key(kVK_ANSI_2, [.command, .option]): "Usage",
            key(kVK_ANSI_3, [.command, .option]): "Limits",
            key(kVK_ANSI_R, [.command, .shift]): "Refresh Agents",
            key(kVK_ANSI_R, [.command]): "Refresh",
            key(kVK_ANSI_J, [.command]): "Jump to Session",
            key(kVK_ANSI_N, [.command]): "New Server",
            key(kVK_ANSI_O, [.command]): "Open in Browser",
        ]
    }()

    /// Probe by registering and immediately releasing. Carbon rejects combinations another process owns.
    private static func canRegister(_ key: HotKey) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.carbonModifiers, EventHotKeyID(signature: signature, id: 99),
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    /// Enabled shortcuts from System Settings › Keyboard (Spotlight, Mission Control, screenshots, input sources…).
    private static func systemShortcuts() -> Set<HotKey> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var result: Set<HotKey> = []
        for entry in entries {
            guard (entry["kHISymbolicHotKeyEnabled"] as? Bool) ?? false,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value,
                  let carbon = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.intValue else { continue }
            var flags: NSEvent.ModifierFlags = []
            if carbon & cmdKey != 0 { flags.insert(.command) }
            if carbon & optionKey != 0 { flags.insert(.option) }
            if carbon & controlKey != 0 { flags.insert(.control) }
            if carbon & shiftKey != 0 { flags.insert(.shift) }
            result.insert(HotKey(keyCode: code, modifiers: flags))
        }
        return result
    }

    /// Menu shortcuts the user assigned for all apps in System Settings › Keyboard › App Shortcuts.
    private static func userAppShortcuts() -> [HotKey: String] {
        guard let map = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSUserKeyEquivalents"] as? [String: String]
        else { return [:] }
        var result: [HotKey: String] = [:]
        for (title, equivalent) in map {
            var flags: NSEvent.ModifierFlags = []
            var rest = Substring(equivalent)
            while let c = rest.first, "@~^$".contains(c) {
                switch c {
                case "@": flags.insert(.command)
                case "~": flags.insert(.option)
                case "^": flags.insert(.control)
                default: flags.insert(.shift)
                }
                rest = rest.dropFirst()
            }
            if let code = HotKey.keyCode(for: String(rest)) { result[HotKey(keyCode: code, modifiers: flags)] = title }
        }
        return result
    }
}
