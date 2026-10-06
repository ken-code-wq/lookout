import SwiftUI
import AppKit

extension Color {
    /// Adapts to light/dark appearance.
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

/// Notion design tokens: warm neutrals, one blue accent, muted tag colours.
enum N {
    static let bg = Color(light: 0xFFFFFF, dark: 0x191919)
    static let bgSoft = Color(light: 0xF7F7F5, dark: 0x202020)
    static let bgRaised = Color(light: 0xFFFFFF, dark: 0x252525)
    static let text = Color(light: 0x37352F, dark: 0xFFFFFF, darkAlpha: 0.81)
    static let text2 = Color(light: 0x787774, dark: 0x9B9B9B)
    static let text3 = Color(light: 0x37352F, dark: 0xFFFFFF, lightAlpha: 0.35, darkAlpha: 0.28)
    static let divider = Color(light: 0x37352F, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.094)
    static let hover = Color(light: 0x37352F, dark: 0xFFFFFF, lightAlpha: 0.055, darkAlpha: 0.055)
    static let pressed = Color(light: 0x37352F, dark: 0xFFFFFF, lightAlpha: 0.1, darkAlpha: 0.09)
    static let selected = Color(light: 0x2383E2, dark: 0x2383E2, lightAlpha: 0.1, darkAlpha: 0.2)
    static let blue = Color(light: 0x2383E2, dark: 0x2383E2)
    static let red = Color(light: 0xEB5757, dark: 0xE06C6C)
    static let green = Color(light: 0x4DAB9A, dark: 0x4DAB9A)
    static let toast = Color(light: 0x2F2F2D, dark: 0x3A3A3A)

    static let radius: CGFloat = 6
    static let rowHeight: CGFloat = 36
}

enum NFont {
    static let pageTitle = Font.system(size: 30, weight: .bold)
    static let title = Font.system(size: 22, weight: .bold)
    static let body = Font.system(size: 14)
    static let bodyMedium = Font.system(size: 14, weight: .medium)
    static let small = Font.system(size: 12.5)
    static let caption = Font.system(size: 11.5)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let monoSmall = Font.system(size: 11.5, design: .monospaced)
}

/// Notion's select-tag palette.
enum TagColor: CaseIterable {
    case gray, brown, orange, yellow, green, blue, purple, pink, red

    var bg: Color {
        switch self {
        case .gray: return Color(light: 0xF1F1EF, dark: 0x373737)
        case .brown: return Color(light: 0xF4EEEE, dark: 0x4A3228)
        case .orange: return Color(light: 0xFBECDD, dark: 0x5C3B23)
        case .yellow: return Color(light: 0xFBF3DB, dark: 0x564328)
        case .green: return Color(light: 0xEDF3EC, dark: 0x243D30)
        case .blue: return Color(light: 0xE7F3F8, dark: 0x143A4E)
        case .purple: return Color(light: 0xF6F3F9, dark: 0x3C2D49)
        case .pink: return Color(light: 0xFAF1F5, dark: 0x4E2C3C)
        case .red: return Color(light: 0xFDEBEC, dark: 0x522E2A)
        }
    }

    var fg: Color {
        switch self {
        case .gray: return Color(light: 0x787774, dark: 0x9B9B9B)
        case .brown: return Color(light: 0x9F6B53, dark: 0xBA856F)
        case .orange: return Color(light: 0xD9730D, dark: 0xC77D48)
        case .yellow: return Color(light: 0xCB912F, dark: 0xCA9849)
        case .green: return Color(light: 0x448361, dark: 0x529E72)
        case .blue: return Color(light: 0x337EA9, dark: 0x379AD3)
        case .purple: return Color(light: 0x9065B0, dark: 0x9D68D3)
        case .pink: return Color(light: 0xC14C8A, dark: 0xD15796)
        case .red: return Color(light: 0xD44C47, dark: 0xDF5452)
        }
    }

    /// Deterministic colour for a name, so a project keeps its colour across launches.
    static func hashed(_ s: String) -> TagColor {
        let palette: [TagColor] = [.brown, .orange, .yellow, .green, .blue, .purple, .pink, .red]
        let sum = s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

extension ProjectType {
    var tag: TagColor {
        switch self {
        case .node: return .green
        case .python: return .yellow
        case .docker: return .blue
        case .database: return .purple
        case .ruby: return .red
        case .go: return .blue
        case .rust: return .orange
        case .xcode: return .purple
        case .staticSite: return .brown
        case .app: return .gray
        case .other, .system: return .gray
        }
    }
}

extension ServerEntry {
    var statusTag: (text: String, color: TagColor) {
        switch httpState {
        case .online:
            if statusCode >= 500 { return ("\(statusCode)", .red) }
            if statusCode >= 400 { return ("\(statusCode)", .orange) }
            return ("Live · \(latencyMs)ms", .green)
        case .authRequired: return ("Auth · \(statusCode)", .orange)
        case .offline: return ("TCP only", .gray)
        case .error: return ("Error", .red)
        case .unknown: return ("Checking", .gray)
        }
    }
}
