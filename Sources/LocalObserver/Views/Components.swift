import SwiftUI
import AppKit

// MARK: - Tags

struct Tag: View {
    var text: String
    var color: TagColor = .gray
    var symbol: String? = nil
    var mono = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            Text(text).font(mono ? NFont.monoSmall : .system(size: 12))
        }
        .lineLimit(1)
        .foregroundStyle(color.fg)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(color.bg, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .fixedSize()
    }
}

struct StatusTag: View {
    var server: ServerEntry
    var stopping = false

    var body: some View {
        if stopping {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Stopping").font(.system(size: 12))
            }
            .foregroundStyle(TagColor.gray.fg)
            .padding(.horizontal, 6).frame(height: 20)
            .background(TagColor.gray.bg, in: RoundedRectangle(cornerRadius: 3))
        } else {
            let s = server.statusTag
            HStack(spacing: 5) {
                Circle().fill(s.color.fg).frame(width: 6, height: 6)
                Text(s.text).font(.system(size: 12)).monospacedDigit()
            }
            .foregroundStyle(s.color.fg)
            .padding(.horizontal, 6).frame(height: 20)
            .background(s.color.bg, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .fixedSize()
            .contentTransition(.numericText())
        }
    }
}

// MARK: - Icons

/// A project's favicon, or a Notion-style monogram tile while none is found.
struct FaviconView: View {
    var server: ServerEntry
    var size: CGFloat = 20
    @State private var image: NSImage?

    init(server: ServerEntry, size: CGFloat = 20) {
        self.server = server
        self.size = size
        _image = State(initialValue: IconStore.shared.cached(server.iconKey))
    }

    var body: some View {
        IconTile(image: image, name: server.projectName, fallbackSymbol: server.projectType.symbol, size: size)
            .task(id: "\(server.iconKey)|\(server.isResponding)") {
                if let img = await IconStore.shared.icon(for: server), img !== image {
                    withAnimation(.easeOut(duration: 0.2)) { image = img }
                }
            }
    }
}

struct FolderIconView: View {
    var folder: String
    var name: String
    var size: CGFloat = 20
    @State private var image: NSImage?

    init(folder: String, name: String, size: CGFloat = 20) {
        self.folder = folder
        self.name = name
        self.size = size
        _image = State(initialValue: IconStore.shared.cached(folder))
    }

    var body: some View {
        IconTile(image: image, name: name, fallbackSymbol: "folder", size: size)
            .task(id: folder) {
                if let img = await IconStore.shared.icon(forFolder: folder) {
                    withAnimation(.easeOut(duration: 0.2)) { image = img }
                }
            }
    }
}

private struct IconTile: View {
    var image: NSImage?
    var name: String
    var fallbackSymbol: String
    var size: CGFloat

    var body: some View {
        let corner = max(3, size * 0.22)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: corner * 0.6, style: .continuous))
            } else {
                let color = TagColor.hashed(name)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(color.bg)
                    .overlay {
                        if let letter = name.first(where: { $0.isLetter || $0.isNumber }) {
                            Text(String(letter).uppercased())
                                .font(.system(size: size * 0.52, weight: .semibold, design: .rounded))
                                .foregroundStyle(color.fg)
                        } else {
                            Image(systemName: fallbackSymbol)
                                .font(.system(size: size * 0.45, weight: .medium))
                                .foregroundStyle(color.fg)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(N.blue.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = N.text
    func makeBody(configuration: Configuration) -> some View {
        HoverSurface(pressed: configuration.isPressed, bordered: true) {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(height: 28)
        }
    }
}

/// Borderless button that shows a soft fill on hover — Notion's default affordance.
struct GhostButtonStyle: ButtonStyle {
    var tint: Color = N.text2
    func makeBody(configuration: Configuration) -> some View {
        HoverSurface(pressed: configuration.isPressed, bordered: false) {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .frame(height: 26)
        }
    }
}

private struct HoverSurface<Content: View>: View {
    var pressed: Bool
    var bordered: Bool
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        content
            .background(pressed ? N.pressed : (hover ? N.hover : (bordered ? N.bg : .clear)),
                        in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: N.radius, style: .continuous).strokeBorder(N.divider)
                }
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var tint: Color = N.text2
    var size: CGFloat = 26
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: size - 14, height: size)
        }
        .buttonStyle(GhostButtonStyle(tint: tint))
        .help(help)
    }
}

/// Two-step destructive button: first click arms it, second click confirms. Disarms itself after a moment.
struct ArmedStopButton: View {
    var compact = true
    var action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed { armed = false; action() } else {
                withAnimation(.snappy(duration: 0.2)) { armed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.snappy(duration: 0.2)) { armed = false }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: armed ? "stop.fill" : "stop")
                    .font(.system(size: 11, weight: .semibold))
                if armed || !compact { Text(armed ? "Stop?" : "Stop").font(.system(size: 12, weight: .medium)) }
            }
            .foregroundStyle(armed ? Color.white : N.red)
            .padding(.horizontal, armed || !compact ? 8 : 7)
            .frame(height: 26)
            .background(armed ? N.red : Color.clear, in: RoundedRectangle(cornerRadius: N.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(armed ? "Click again to stop" : "Stop server")
    }
}

// MARK: - Layout pieces

struct PageHeader: View {
    var symbol: String
    var title: String
    var subtitle: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(N.text2)
                .frame(height: 40, alignment: .bottomLeading)
            Text(title).font(NFont.pageTitle).foregroundStyle(N.text)
            subtitle
        }
        .padding(.top, 28)
        .padding(.bottom, 14)
    }
}

/// Notion property row: grey label with icon on the left, value on the right.
struct PropertyRow<Value: View>: View {
    var symbol: String
    var label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11.5)).frame(width: 14)
                Text(label).font(NFont.small)
            }
            .foregroundStyle(N.text2)
            .frame(width: 104, alignment: .leading)
            value
                .font(NFont.small)
                .foregroundStyle(N.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 28)
    }
}

struct EmptyStateView<Actions: View>: View {
    var symbol: String
    var title: String
    var message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(N.text3)
                .padding(.bottom, 4)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(N.text)
            Text(message).font(NFont.small).foregroundStyle(N.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: 8) { actions }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

struct ToastView: View {
    var toast: Toast
    var onAction: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconColor)
            Text(toast.message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
            if let title = toast.actionTitle {
                Button(title, action: onAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(light: 0x6CB4FF, dark: 0x6CB4FF))
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: 40)
        .background(N.toast, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var iconColor: Color {
        switch toast.tone {
        case .neutral: return .white.opacity(0.7)
        case .success: return Color(light: 0x6BCB9B, dark: 0x6BCB9B)
        case .danger: return Color(light: 0xFF8A80, dark: 0xFF8A80)
        }
    }
}

/// "Updated 3s ago", ticking once a second without redrawing anything else.
struct RelativeTimeText: View {
    var date: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(now: context.date)).monospacedDigit()
        }
    }
    private func label(now: Date) -> String {
        guard let date else { return "Scanning…" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        return s < 2 ? "Updated just now" : "Updated \(s)s ago"
    }
}
