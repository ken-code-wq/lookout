import SwiftUI
import AppKit
import LocalObserverRepos

/// GitHub's Primer colours, light and dark, for the screens that mirror github.com. Text and backgrounds stay on
/// Lookout's own tokens; these are the accents GitHub uses to mean something (open, merged, closed, diff lines).
enum GH {
    static let link = Color(light: 0x0969DA, dark: 0x4493F8)
    static let open = Color(light: 0x1A7F37, dark: 0x3FB950)
    static let openButton = Color(light: 0x1F883D, dark: 0x238636)
    static let merged = Color(light: 0x8250DF, dark: 0xAB7DF8)
    static let closed = Color(light: 0xD1242F, dark: 0xF85149)
    static let draft = Color(light: 0x59636E, dark: 0x9198A1)
    static let attention = Color(light: 0x9A6700, dark: 0xD29922)
    static let border = Color(light: 0xD1D9E0, dark: 0x3D444D)
    static let borderMuted = Color(light: 0xD1D9E0, dark: 0x3D444D, lightAlpha: 0.7, darkAlpha: 0.7)
    static let canvasSubtle = Color(light: 0xF6F8FA, dark: 0x151B23)
    static let tabUnderline = Color(light: 0xFD8C73, dark: 0xF78166)
    static let branchBg = Color(light: 0xDDF4FF, dark: 0x388BFD, lightAlpha: 1, darkAlpha: 0.15)
    static let authorHeader = Color(light: 0xDDF4FF, dark: 0x388BFD, lightAlpha: 1, darkAlpha: 0.1)
    static let authorBorder = Color(light: 0x54AEFF, dark: 0x388BFD, lightAlpha: 0.4, darkAlpha: 0.4)
    static let counterBg = Color(light: 0x818B98, dark: 0x656C76, lightAlpha: 0.2, darkAlpha: 0.2)
    static let addBg = Color(light: 0xDAFBE1, dark: 0x2EA043, lightAlpha: 1, darkAlpha: 0.15)
    static let addNumBg = Color(light: 0xACEEBB, dark: 0x3FB950, lightAlpha: 1, darkAlpha: 0.3)
    static let delBg = Color(light: 0xFFEBE9, dark: 0xF85149, lightAlpha: 1, darkAlpha: 0.15)
    static let delNumBg = Color(light: 0xFFCECB, dark: 0xF85149, lightAlpha: 1, darkAlpha: 0.3)
    static let hunkBg = Color(light: 0xDDF4FF, dark: 0x388BFD, lightAlpha: 1, darkAlpha: 0.1)
    static let neutralBox = Color(light: 0xAFB8C1, dark: 0x3D444D)

    static let radius: CGFloat = 6

    /// `#rrggbb` or `rrggbb` as a colour; GitHub's language and label colours come this way.
    static func hex(_ string: String?) -> Color? {
        guard var s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Whether text on this label colour should be dark, by perceived brightness.
    static func isLight(_ string: String) -> Bool {
        guard let v = UInt32(string.replacingOccurrences(of: "#", with: ""), radix: 16) else { return true }
        let r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 150
    }
}

// MARK: - Pull request state

extension GHPullState {
    var color: Color {
        switch self {
        case .open: return GH.openButton
        case .draft: return GH.draft
        case .merged: return GH.merged
        case .closed: return GH.closed
        }
    }
    /// The icon colour in lists, a shade lighter than the filled badge in dark mode.
    var tint: Color {
        switch self {
        case .open: return GH.open
        case .draft: return GH.draft
        case .merged: return GH.merged
        case .closed: return GH.closed
        }
    }
    var symbol: String {
        switch self {
        case .open: return "arrow.triangle.pull"
        case .draft: return "circle.dashed"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }
}

/// The filled "⇄ Open" / "Merged" / "Closed" / "Draft" pill beside a pull request title.
struct GHStateBadge: View {
    var state: GHPullState
    var large = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol).font(.system(size: large ? 12 : 10, weight: .semibold))
            Text(state.title).font(.system(size: large ? 13.5 : 11.5, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, large ? 12 : 8)
        .frame(height: large ? 30 : 22)
        .background(state.color, in: Capsule())
        .fixedSize()
    }
}

/// Outlined "Public" / "Private" / "Public archive" pill beside a repository name.
struct GHVisibilityBadge: View {
    var text: String
    var tint: Color = N.text2

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .overlay(Capsule().strokeBorder(GH.border))
            .fixedSize()
    }
}

/// Grey count bubble beside a tab title.
struct GHCounter: View {
    var count: Int
    var body: some View {
        Text(count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)")
            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(N.text)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 18)
            .background(GH.counterBg, in: Capsule())
    }
}

/// A branch name in GitHub's light-blue monospace pill; purple when it's checked out in a worktree here.
struct GHBranchName: View {
    var name: String
    var worktree = false
    var maxWidth: CGFloat = 260
    var copyable = true

    var body: some View {
        HStack(spacing: 4) {
            if worktree { Image(systemName: "square.stack.3d.down.right").font(.system(size: 9.5, weight: .semibold)) }
            Text(BranchTag.shortened(name, maxWidth: maxWidth)).font(.system(size: 11.5, design: .monospaced))
        }
        .lineLimit(1)
        .foregroundStyle(worktree ? TagColor.purple.fg : GH.link)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(worktree ? TagColor.purple.bg : GH.branchBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
        .help(worktree ? "\(name), checked out in a worktree on this Mac" : name)
        .contextMenu { if copyable { Button("Copy Branch Name") { RepoActions.copy(name) } } }
    }
}

/// A label in its GitHub colour.
struct GHLabelPill: View {
    var label: GHLabel
    var body: some View {
        let color = GH.hex(label.color) ?? N.text3
        Text(label.name)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(GH.isLight(label.color) ? Color.black.opacity(0.85) : .white)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(color, in: Capsule())
            .fixedSize()
    }
}

/// A topic on a repository's About panel.
struct GHTopic: View {
    var name: String
    var body: some View {
        Text(name)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(GH.link)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(GH.branchBg, in: Capsule())
            .fixedSize()
    }
}

struct GHLanguageDot: View {
    var language: GHLanguage
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(GH.hex(language.color) ?? N.text3).frame(width: 10, height: 10)
            Text(language.name)
        }
        .fixedSize()
    }
}

/// A GitHub user's picture, with a monogram while it loads or when offline.
struct GHAvatar: View {
    var login: String
    var size: CGFloat = 20
    var url: String? = nil

    var body: some View {
        let source = url.flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(login).png?size=\(Int(size * 2))")
        AsyncImage(url: source, transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                ZStack {
                    TagColor.hashed(login).bg
                    Text(login.prefix(1).uppercased())
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(TagColor.hashed(login).fg)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(N.divider))
        .help(login)
    }
}

/// GitHub's "Box": bordered, rounded, with an optional tinted header row.
struct GHBox<Header: View, Content: View>: View {
    var headerTint: Color = GH.canvasSubtle
    var borderTint: Color = GH.border
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(headerTint)
            Rectangle().fill(borderTint).frame(height: 1)
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GH.radius, style: .continuous).strokeBorder(borderTint))
    }
}

extension GHBox where Header == EmptyView {
    init(borderTint: Color = GH.border, @ViewBuilder content: () -> Content) {
        self.headerTint = .clear
        self.borderTint = borderTint
        self.header = EmptyView()
        self.content = content()
    }
}

/// GitHub's underlined tab strip: icon, title, optional count; the selected tab gets the orange underline.
struct GHTabBar<Tab: Hashable & Identifiable>: View {
    var tabs: [Tab]
    var selection: Tab
    var title: (Tab) -> String
    var symbol: (Tab) -> String
    var count: (Tab) -> Int? = { _ in nil }
    var select: (Tab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    TabButton(selected: tab == selection, title: title(tab), symbol: symbol(tab), count: count(tab)) { select(tab) }
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(GH.borderMuted).frame(height: 1)
        }
    }

    private struct TabButton: View {
        var selected: Bool
        var title: String
        var symbol: String
        var count: Int?
        var action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(N.text2)
                    Text(title).font(.system(size: 13.5, weight: selected ? .semibold : .regular)).foregroundStyle(N.text)
                    if let count { GHCounter(count: count) }
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(hover ? N.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.top, 6)
                .padding(.bottom, 8)
                // An overlay takes the label's width; a Rectangle in a stack would stretch the tab.
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? GH.tabUnderline : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}

/// The green primary button GitHub uses for Merge, Comment and New.
struct GHPrimaryButtonStyle: ButtonStyle {
    var tint: Color = GH.openButton
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(tint.opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45),
                        in: RoundedRectangle(cornerRadius: GH.radius, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// "+120 −14 ■■■■□", GitHub's diffstat.
struct GHDiffStat: View {
    var additions: Int
    var deletions: Int
    var boxes = true

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(additions)").foregroundStyle(GH.open)
            Text("−\(deletions)").foregroundStyle(GH.closed)
            if boxes {
                HStack(spacing: 1.5) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5).fill(color(i)).frame(width: 8, height: 8)
                    }
                }
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .fixedSize()
    }

    private func color(_ i: Int) -> Color {
        let total = additions + deletions
        guard total > 0 else { return GH.neutralBox }
        let green = Int((Double(additions) / Double(total) * 5).rounded())
        let red = min(5 - green, Int((Double(deletions) / Double(total) * 5).rounded()))
        if i < green { return GH.open }
        if i < green + red { return GH.closed }
        return GH.neutralBox
    }
}

enum GHFormat {
    static func dayTitle(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func count(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

// MARK: - HTML

/// Renders GitHub's HTML (README, comments, pull request bodies) with AppKit's HTML importer: selectable, links
/// clickable, sized to its width. Images are dropped; badges and screenshots would otherwise load synchronously.
struct GHHTMLView: NSViewRepresentable {
    var html: String
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [.foregroundColor: NSColor(GH.link), .cursor: NSCursor.pointingHand]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let text = GHHTML.attributed(html, dark: scheme == .dark)
        if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 600, 40)
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        view.frame.size = CGSize(width: width, height: height)
        return CGSize(width: width, height: height)
    }
}

@MainActor
enum GHHTML {
    private static var cache: [String: NSAttributedString] = [:]

    static func attributed(_ html: String, dark: Bool) -> NSAttributedString {
        let key = "\(dark ? 1 : 0)\(html.hashValue)"
        if let hit = cache[key] { return hit }
        let text = dark ? "#e6edf3" : "#1f2328"
        let muted = dark ? "#9198a1" : "#59636e"
        let code = dark ? "rgba(101,108,118,0.2)" : "rgba(129,139,152,0.12)"
        let link = dark ? "#4493f8" : "#0969da"
        let border = dark ? "#3d444d" : "#d1d9e0"
        let css = """
        <style>
        body { font-family: -apple-system, 'SF Pro Text'; font-size: 13.5px; line-height: 1.5; color: \(text); }
        a { color: \(link); text-decoration: none; }
        h1 { font-size: 24px; font-weight: 600; } h2 { font-size: 19px; font-weight: 600; } h3 { font-size: 16px; font-weight: 600; }
        h4, h5, h6 { font-size: 13.5px; font-weight: 600; }
        code, pre, tt { font-family: 'SF Mono', Menlo, monospace; font-size: 12px; background-color: \(code); }
        pre { padding: 10px; margin: 0 0 12px 0; }
        ul, ol { margin-bottom: 12px; }
        blockquote { color: \(muted); border-left: 3px solid \(border); padding-left: 10px; margin-left: 0; }
        table { border-collapse: collapse; } td, th { border: 1px solid \(border); padding: 4px 10px; }
        </style>
        """
        let cleaned = strip(html)
        let data = Data((css + "<body>" + cleaned + "</body>").utf8)
        let result = (try? NSMutableAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)) ?? NSMutableAttributedString(string: cleaned)
        // The importer leaves a trailing newline; trim it so boxes don't end with a blank line.
        while result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        if cache.count > 300 { cache.removeAll() }
        cache[key] = result
        return result
    }

    /// Drops images and SVG (alt text kept), and GitHub's anchor-link icons inside headings.
    static func strip(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"<svg[\s\S]*?</svg>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<img[^>]*alt="([^"]*)"[^>]*>"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<img[^>]*>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<picture[^>]*>|</picture>|<source[^>]*>"#, with: "", options: .regularExpression)
        return s
    }
}

/// Lays children out left to right, wrapping onto new lines: topics, labels, language legends.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * (lineSpacing ?? spacing)
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + (lineSpacing ?? spacing)
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
