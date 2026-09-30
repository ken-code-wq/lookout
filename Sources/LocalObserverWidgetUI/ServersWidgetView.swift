import SwiftUI
import AppKit
import WidgetKit
import LocalObserverCore

/// Local servers by port. In medium and large each row opens the server in the browser.
public struct ServersWidgetView: View {
    var snapshot: WidgetSnapshot?
    var now: Date
    var family: WidgetFamily

    public init(snapshot: WidgetSnapshot?, now: Date, family: WidgetFamily) {
        self.snapshot = snapshot
        self.now = now
        self.family = family
    }

    public var body: some View {
        Group {
            if let snapshot {
                content(snapshot)
            } else {
                WidgetEmpty(symbol: "server.rack", title: "Open Lookout",
                            detail: family == .systemSmall ? nil : "Listening servers appear here once the app has scanned ports.")
            }
        }
        .widgetURL(WidgetLink.servers)
    }

    @ViewBuilder private func content(_ snapshot: WidgetSnapshot) -> some View {
        let servers = snapshot.servers
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            ServersHeadline(servers: servers, compact: family == .systemSmall)
            if servers.isEmpty {
                WidgetEmpty(symbol: "powerplug", title: "Nothing listening",
                            detail: family == .systemSmall ? nil : "Start a dev server and it shows up here with its port.")
            } else {
                switch family {
                case .systemSmall:
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(servers.prefix(4)) { ServerRow(server: $0, compact: true) }
                    }
                case .systemMedium:
                    let shown = Array(servers.prefix(6))
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                        ForEach(0..<(shown.count + 1) / 2, id: \.self) { row in
                            GridRow {
                                linked(shown[row * 2])
                                if row * 2 + 1 < shown.count { linked(shown[row * 2 + 1]) } else { Color.clear.frame(height: 1) }
                            }
                        }
                    }
                default:
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(servers.prefix(10)) { linked($0, detailed: true) }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    FreshnessNote(generatedAt: snapshot.generatedAt, now: now)
                    Spacer(minLength: 0)
                    let hidden = servers.count - (family == .systemSmall ? 4 : family == .systemMedium ? 6 : 10)
                    if hidden > 0, family != .systemSmall {
                        Text("\(hidden) more").font(WFont.micro).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func linked(_ server: WidgetSnapshot.Server, detailed: Bool = false) -> some View {
        Group {
            if let url = URL(string: server.url) {
                RowLink(destination: url) { ServerRow(server: server, detailed: detailed, now: now) }
            } else {
                ServerRow(server: server, detailed: detailed, now: now)
            }
        }
    }
}

struct ServersHeadline: View {
    var servers: [WidgetSnapshot.Server]
    /// Small widgets show just the symbol and count; the symbol already says failing or warning.
    var compact = false

    var body: some View {
        // 5xx and errors are failures; a 4xx at "/" often just means the server has no index page.
        let failing = servers.filter { $0.health == .failing }.count
        let warning = servers.filter { $0.health == .warning }.count
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(servers.isEmpty ? "Servers" : "\(servers.count) \(servers.count == 1 ? "server" : "servers")")
                .font(WFont.title)
                .monospacedDigit()
            Spacer(minLength: 4)
            if failing > 0 {
                Label(compact ? "\(failing)" : "\(failing) failing", systemImage: WidgetSnapshot.Server.Health.failing.symbol)
                    .labelStyle(TightLabel())
                    .font(WFont.captionMedium)
                    .foregroundStyle(WTheme.danger)
            } else if warning > 0 {
                Label(compact ? "\(warning)" : "\(warning) \(warning == 1 ? "warning" : "warnings")", systemImage: WidgetSnapshot.Server.Health.warning.symbol)
                    .labelStyle(TightLabel())
                    .font(WFont.captionMedium)
                    .foregroundStyle(WTheme.attention)
            }
        }
        .lineLimit(1)
    }
}

/// The favicon or app icon the Servers page shows; the same letter tile while none has been found.
struct ServerIcon: View {
    var server: WidgetSnapshot.Server
    var size: CGFloat = 16

    var body: some View {
        let corner = max(3, size * 0.22)
        Group {
            if let name = server.icon,
               let image = NSImage(contentsOf: WidgetSnapshot.iconsDirectory.appendingPathComponent(name)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: corner * 0.6, style: .continuous))
            } else {
                let tone = MonogramTone.hashed(server.name)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tone.bg)
                    .overlay {
                        if let letter = server.name.first(where: { $0.isLetter || $0.isNumber }) {
                            Text(String(letter).uppercased())
                                .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                                .foregroundStyle(tone.fg)
                        } else {
                            Image(systemName: server.symbol).font(.system(size: size * 0.5)).foregroundStyle(tone.fg)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The app's hashed tag colours (TagColor.hashed), so a project gets the same tile here as on the Servers page.
private enum MonogramTone {
    private static let palette: [(bg: Color, fg: Color)] = [
        (Color(light: 0xF4EEEE, dark: 0x4A3228), Color(light: 0x9F6B53, dark: 0xBA856F)),
        (Color(light: 0xFBECDD, dark: 0x5C3B23), Color(light: 0xD9730D, dark: 0xC77D48)),
        (Color(light: 0xFBF3DB, dark: 0x564328), Color(light: 0xCB912F, dark: 0xCA9849)),
        (Color(light: 0xEDF3EC, dark: 0x243D30), Color(light: 0x448361, dark: 0x529E72)),
        (Color(light: 0xE7F3F8, dark: 0x143A4E), Color(light: 0x337EA9, dark: 0x379AD3)),
        (Color(light: 0xF6F3F9, dark: 0x3C2D49), Color(light: 0x9065B0, dark: 0x9D68D3)),
        (Color(light: 0xFAF1F5, dark: 0x4E2C3C), Color(light: 0xC14C8A, dark: 0xD15796)),
        (Color(light: 0xFDEBEC, dark: 0x522E2A), Color(light: 0xD44C47, dark: 0xDF5452))
    ]

    static func hashed(_ s: String) -> (bg: Color, fg: Color) {
        let sum = s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

/// Icon, then port in mono, because the port is what you type into the browser.
struct ServerRow: View {
    var server: WidgetSnapshot.Server
    var compact = false
    var detailed = false
    var now: Date = .now

    var body: some View {
        if compact || detailed { line } else { stacked }
    }

    /// Medium's two-column grid: port and name on top, status underneath at the full column width.
    private var stacked: some View {
        HStack(alignment: .top, spacing: 7) {
            ServerIcon(server: server, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(":\(String(server.port))").font(WFont.port).fixedSize()
                    Text(server.name).font(WFont.body).lineLimit(1)
                }
                statusText.font(WFont.micro)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Port \(server.port), \(server.name), \(server.status)")
    }

    private var line: some View {
        HStack(spacing: compact ? 6 : 8) {
            ServerIcon(server: server, size: compact ? 14 : 16)
            Text(":\(String(server.port))")
                .font(WFont.port)
                .fixedSize()
                .frame(minWidth: compact ? 0 : 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(server.name).font(compact ? WFont.caption : WFont.body).lineLimit(1)
                if !compact, !detailed {
                    statusText.font(WFont.micro)
                }
            }
            Spacer(minLength: 4)
            if compact {
                Image(systemName: server.health.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(server.health.tone)
                    .widgetAccentable()
            } else if detailed {
                if server.uptime > 0 {
                    Text(AgentFormat.duration(server.uptime))
                        .font(WFont.micro)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                statusText.font(WFont.caption).fixedSize()
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Port \(server.port), \(server.name), \(server.status)")
    }

    private var statusText: some View {
        Label(server.status, systemImage: server.health.symbol)
            .labelStyle(TightLabel())
            .foregroundStyle(server.health.tone)
            .lineLimit(1)
            .monospacedDigit()
    }
}
