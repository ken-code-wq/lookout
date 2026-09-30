import SwiftUI
import AppKit
import WidgetKit
import LocalObserverCore

/// Widget tokens. Widgets sit on the wallpaper and are often shown desaturated behind windows, so hierarchy comes
/// from the system's primary/secondary/tertiary styles and every status carries a symbol and a word, not just a hue.
enum WTheme {
    static let background = Color(light: 0xFCFCFB, dark: 0x1E1E1D)
    /// Hairline between sections. Cheaper and calmer than nesting cards inside the widget's own card.
    static let rule = Color(light: 0x37352F, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09)
    static let track = Color(light: 0x37352F, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.1)

    // Semantic tones, from the app's tag palette so a "Needs you" reads the same everywhere.
    static let attention = Color(light: 0xD9730D, dark: 0xE8913F)
    static let danger = Color(light: 0xD44C47, dark: 0xE5625E)
    static let live = Color(light: 0x448361, dark: 0x5DB07F)
    static let turn = Color(light: 0x337EA9, dark: 0x4BA3D9)

    static let spacing: CGFloat = 10
}

enum WFont {
    /// Figures are SF Rounded, like the notch ring, so a number reads as a measurement rather than a label.
    static func figure(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12)
    static let bodyMedium = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 10)
    static let port = Font.system(size: 12, weight: .semibold, design: .monospaced)
}

extension Color {
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension AgentKind {
    /// Provider colour, readable on both widget backgrounds. Codex is ChatGPT white on dark, ink on light.
    var widgetColor: Color {
        switch self {
        case .claude: return Color(light: 0xC96442, dark: 0xD97857)
        case .codex: return Color(light: 0x5F5E5A, dark: 0xE4E4E2)
        case .openCode: return Color(light: 0x6B6E76, dark: 0x9EA3B0)
        case .antigravity: return Color(light: 0x3478F6, dark: 0x4F8CFF)
        case .copilot: return Color(light: 0x8A5CF0, dark: 0xA370F7)
        case .cursor: return Color(light: 0x2E9E9E, dark: 0x5EC7C7)
        case .pi: return Color(light: 0x3E9E4A, dark: 0x7DE587)
        }
    }

    var widgetShortName: String {
        switch self {
        case .claude: return "Claude"
        case .copilot: return "Copilot"
        default: return name
        }
    }
}

extension AgentActivityState {
    /// Where the state sits in the queue a developer works through: things waiting on them first.
    var widgetRank: Int {
        switch self {
        case .needsInput: return 0
        case .failed: return 1
        case .waiting: return 2
        case .running, .working, .thinking, .toolUse: return 3
        case .idle, .unknown: return 4
        }
    }

    var widgetSymbol: String {
        switch self {
        case .needsInput: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .waiting: return "arrowshape.turn.up.left.fill"
        case .running, .working, .thinking, .toolUse: return "bolt.fill"
        case .idle, .unknown: return "moon.fill"
        }
    }

    var widgetTone: Color {
        switch self {
        case .needsInput: return WTheme.attention
        case .failed: return WTheme.danger
        case .waiting: return WTheme.turn
        case .running, .working, .thinking, .toolUse: return WTheme.live
        case .idle, .unknown: return .secondary
        }
    }
}

extension WidgetSnapshot.Server.Health {
    var tone: Color {
        switch self {
        case .live: return WTheme.live
        case .warning: return WTheme.attention
        case .failing: return WTheme.danger
        case .quiet: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .live: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failing: return "xmark.octagon.fill"
        case .quiet: return "circle.dashed"
        }
    }
}

// MARK: - Deep links

/// `localobserver://` routes the app handles (see LocalObserverApp's URL handling).
public enum WidgetLink {
    public static let scheme = "localobserver"
    public static let activity = URL(string: "\(scheme)://activity")!
    public static let usage = URL(string: "\(scheme)://usage")!
    public static let limits = URL(string: "\(scheme)://limits")!
    public static let servers = URL(string: "\(scheme)://servers")!
    public static let shelf = URL(string: "\(scheme)://shelf")!

    public static func session(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "session"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? activity
    }
}

/// The widget's own surface. The system swaps it out for its tinted and clear desktop styles.
public struct WidgetBackground: View {
    public init() {}
    public var body: some View { WTheme.background }
}
