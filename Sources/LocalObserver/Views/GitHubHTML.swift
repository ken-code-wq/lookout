import SwiftUI
import AppKit

// MARK: - HTML

/// Renders GitHub's HTML (README, comments, pull request bodies) with AppKit's HTML importer: selectable, links
/// clickable, sized to its width. Images are dropped; badges and screenshots would otherwise load synchronously.
struct GHHTMLView: NSViewRepresentable {
    var html: String
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1: code boxes, quote bars and tables are NSTextBlocks, which TextKit 2 doesn't draw.
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let dark = scheme == .dark
        view.linkTextAttributes = [.foregroundColor: GHHTML.Palette(dark: dark).link, .cursor: NSCursor.pointingHand]
        let text = GHHTML.attributed(html, dark: dark)
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

/// GitHub HTML to a typeset attributed string. AppKit's importer gets the structure right (lists, tables, inline
/// styles) but ignores most CSS spacing, so the CSS only tags each block with a marker colour and the result is
/// re-typeset here: Lookout's fonts and colours, spacing between blocks, hanging list indents, padded code boxes.
@MainActor
enum GHHTML {
    private static var cache: [String: NSAttributedString] = [:]

    static func attributed(_ html: String, dark: Bool) -> NSAttributedString {
        let key = "\(dark ? 1 : 0)\(html.hashValue)"
        if let hit = cache[key] { return hit }
        let palette = Palette(dark: dark)
        let cleaned = strip(html)
        let data = Data((css(palette) + "<body>" + cleaned + "</body>").utf8)
        let imported = (try? NSMutableAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)) ?? NSMutableAttributedString(string: cleaned)
        let result = Typesetter(text: imported, palette: palette).run()
        if cache.count > 300 { cache.removeAll() }
        cache[key] = result
        return result
    }

    /// Drops images and SVG (alt text kept), and GitHub's anchor-link icons inside headings. Task-list checkboxes
    /// become glyphs, since the importer drops form controls.
    static func strip(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"<svg[\s\S]*?</svg>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<img[^>]*alt="([^"]*)"[^>]*>"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<img[^>]*>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<picture[^>]*>|</picture>|<source[^>]*>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<input[^>]*type="checkbox"[^>]*\bchecked\b[^>]*>\s*"#, with: "\u{2611}\u{00A0}",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"<input[^>]*type="checkbox"[^>]*>\s*"#, with: "\u{2610}\u{00A0}", options: .regularExpression)
        // The importer draws <hr> as an empty line; a tagged paragraph becomes a hairline instead.
        s = s.replacingOccurrences(of: #"<hr[^>]*>"#, with: "<p style=\"color: \(Marker.rule.css)\">\u{200B}</p>",
                                   options: .regularExpression)
        return s
    }

    /// Lookout's text tokens for rendered markdown.
    struct Palette {
        let text, strong, muted, link, codeBackground, border: NSColor

        init(dark: Bool) {
            func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
                NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
            }
            text = dark ? rgb(0xD0D0D0) : rgb(0x37352F)
            strong = dark ? rgb(0xEBEBEB) : rgb(0x2B2A26)
            muted = dark ? rgb(0x9B9B9B) : rgb(0x787774)
            link = dark ? rgb(0x529CCA) : rgb(0x2383E2)
            codeBackground = dark ? rgb(0xFFFFFF, 0.08) : rgb(0x878378, 0.15)
            border = dark ? rgb(0xFFFFFF, 0.13) : rgb(0x37352F, 0.16)
        }
    }

    /// Marker colours: rgb(1, 0, n) tags the block a run came from; the typesetter swaps them for real colours.
    fileprivate enum Marker: Int {
        case body = 0, h1, h2, h3, h4, h5, h6
        case pre = 10, quote = 11, rule = 12, inlineCode = 20

        var css: String { "rgb(1,0,\(rawValue))" }

        init?(_ color: Any?) {
            guard let c = (color as? NSColor)?.usingColorSpace(.sRGB), c.alphaComponent > 0.99,
                  Int((c.redComponent * 255).rounded()) == 1, Int((c.greenComponent * 255).rounded()) == 0 else { return nil }
            self.init(rawValue: Int((c.blueComponent * 255).rounded()))
        }
    }

    private static func css(_ palette: Palette) -> String {
        let border = palette.border.usingColorSpace(.sRGB).map {
            String(format: "rgba(%.0f,%.0f,%.0f,%.2f)", $0.redComponent * 255, $0.greenComponent * 255, $0.blueComponent * 255,
                   $0.alphaComponent)
        } ?? "gray"
        return """
        <style>
        body { font-family: -apple-system, 'SF Pro Text'; font-size: 13.5px; color: \(Marker.body.css); }
        h1 { color: \(Marker.h1.css); } h2 { color: \(Marker.h2.css); } h3 { color: \(Marker.h3.css); }
        h4 { color: \(Marker.h4.css); } h5 { color: \(Marker.h5.css); } h6 { color: \(Marker.h6.css); }
        a { text-decoration: none; }
        code, tt, kbd, samp { font-family: Menlo, monospace; font-size: 12px; background-color: \(Marker.inlineCode.css); }
        pre { font-family: Menlo, monospace; font-size: 12px; color: \(Marker.pre.css); }
        pre code { background-color: transparent; }
        blockquote { color: \(Marker.quote.css); }
        table { border-collapse: collapse; } td, th { border: 1px solid \(border); padding: 5px 10px; }
        </style>
        """
    }
}

// MARK: - Typesetting

private struct Typesetter {
    let text: NSMutableAttributedString
    let palette: GHHTML.Palette

    private enum Kind: Equatable { case body, heading(Int), code, table, rule }

    private struct Paragraph {
        var range: NSRange
        var kind: Kind
        var quote: Bool
        var lists: [NSTextList]
        var style: NSParagraphStyle
    }

    private static let bodySize: CGFloat = 13.5
    private static let codeSize: CGFloat = 12
    private static let headingSizes: [CGFloat] = [22, 18, 15.5, 13.5, 13, 12.5]

    func run() -> NSAttributedString {
        splitCodeFromText()
        let paragraphs = classify()
        var codeBlock: NSTextBlock?
        var quoteBlock: NSTextBlock?
        var styles: [NSParagraphStyle] = []
        // Styles first, front to back (spacing depends on the previous paragraph, blocks span runs of paragraphs)...
        for (index, paragraph) in paragraphs.enumerated() {
            let previous = index > 0 ? paragraphs[index - 1] : nil
            if paragraph.quote, previous?.quote != true { quoteBlock = makeQuoteBlock() }
            if paragraph.kind == .code, !continuesCode(paragraph, after: previous) { codeBlock = makeCodeBlock() }
            styles.append(style(for: paragraph, after: previous, code: paragraph.kind == .code ? codeBlock : nil,
                                quote: paragraph.quote ? quoteBlock : nil))
        }
        // Spacing before a block's first paragraph lands inside the box (or is dropped, for table cells, and block
        // margins are ignored), so the paragraph above the block carries the gap as spacing after.
        for index in paragraphs.indices.dropFirst() where opensBlock(paragraphs[index], after: paragraphs[index - 1]) {
            let style = styles[index - 1].mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = gap(paragraphs[index], after: paragraphs[index - 1])
            styles[index - 1] = style
        }
        // ...then attributes and list markers back to front, since rewriting a marker shifts every later range.
        for (paragraph, style) in zip(paragraphs, styles).reversed() {
            restyle(paragraph)
            text.addAttribute(.paragraphStyle, value: style, range: paragraph.range)
            if !paragraph.lists.isEmpty, paragraph.kind == .body { rewriteListMarker(paragraph) }
        }
        while text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        return text
    }

    // MARK: Classification

    /// The importer runs a `<pre>` into the text before it when both sit in one `<li>` ("Install:<pre>…"), and into
    /// the text after it. Break the paragraph at those edges so the code gets its own box.
    private func splitCodeFromText() {
        let string = text.string as NSString
        var breaks: [Int] = []
        func isText(_ index: Int) -> Bool {
            guard index >= 0, index < string.length, string.character(at: index) != 0x0A else { return false }
            let attributes = text.attributes(at: index, effectiveRange: nil)
            return attributes[.link] == nil && GHHTML.Marker(attributes[.foregroundColor]) != .pre
        }
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard GHHTML.Marker(value) == .pre else { return }
            if isText(range.location - 1) { breaks.append(range.location) }
            if string.character(at: NSMaxRange(range) - 1) != 0x0A, isText(NSMaxRange(range)) { breaks.append(NSMaxRange(range)) }
        }
        for location in breaks.reversed() {
            let attributes = text.attributes(at: location - 1, effectiveRange: nil)
            text.insert(NSAttributedString(string: "\n", attributes: attributes), at: location)
        }
    }

    private func continuesCode(_ paragraph: Paragraph, after previous: Paragraph?) -> Bool {
        guard let previous, previous.kind == .code else { return false }
        return previous.lists.count == paragraph.lists.count && previous.quote == paragraph.quote
    }

    /// Whether this paragraph starts a drawn block: a code box, a quote bar or a table.
    private func opensBlock(_ paragraph: Paragraph, after previous: Paragraph?) -> Bool {
        if paragraph.quote, previous?.quote != true { return true }
        if paragraph.kind == .code { return !continuesCode(paragraph, after: previous) }
        return paragraph.kind == .table && previous?.kind != .table
    }

    private func classify() -> [Paragraph] {
        let string = text.string as NSString
        var result: [Paragraph] = []
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                ?? NSParagraphStyle.default
            var markers: Set<GHHTML.Marker> = []
            text.enumerateAttribute(.foregroundColor, in: range) { value, _, _ in
                if let marker = GHHTML.Marker(value) { markers.insert(marker) }
            }
            let kind: Kind
            if style.textBlocks.contains(where: { $0 is NSTextTableBlock }) {
                kind = .table
            } else if markers.contains(.rule) {
                kind = .rule
            } else if markers.contains(.pre) {
                kind = .code
            } else if let level = (1...6).first(where: { markers.contains(GHHTML.Marker(rawValue: $0)!) }) {
                kind = .heading(level)
            } else {
                kind = .body
            }
            result.append(Paragraph(range: range, kind: kind, quote: markers.contains(.quote), lists: style.textLists, style: style))
        }
        return result
    }

    // MARK: Paragraph styles

    /// Vertical gap above a paragraph, given the one before it.
    private func gap(_ paragraph: Paragraph, after previous: Paragraph?) -> CGFloat {
        guard let previous else { return 0 }
        if case .heading(let level) = paragraph.kind { return level <= 2 ? 20 : 16 }
        if case .heading(let level) = previous.kind { return level <= 2 ? 10 : 8 }
        if continuesCode(paragraph, after: previous) || (previous.kind == .table && paragraph.kind == .table) { return 0 }
        if paragraph.kind == .rule || previous.kind == .rule { return 12 }
        if !paragraph.lists.isEmpty, !previous.lists.isEmpty, paragraph.lists.first === previous.lists.first,
           paragraph.kind == .body, previous.kind == .body {
            return 4
        }
        return 10
    }

    /// Where list text starts for these nesting levels; bullets hang in the space before it.
    private func listIndent(_ lists: [NSTextList]) -> CGFloat {
        lists.reduce(2) { $0 + (isOrdered($1) ? 24 : 18) }
    }

    private func isOrdered(_ list: NSTextList) -> Bool {
        ![NSTextList.MarkerFormat.disc, .circle, .square, .hyphen, .box, .check, .diamond].contains(list.markerFormat)
    }

    private func style(for paragraph: Paragraph, after previous: Paragraph?, code: NSTextBlock?, quote: NSTextBlock?) -> NSParagraphStyle {
        let style = paragraph.style.mutableCopy() as! NSMutableParagraphStyle
        let gap = gap(paragraph, after: previous)
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = gap
        style.lineSpacing = 0
        style.headIndent = 0
        style.firstLineHeadIndent = 0
        style.tabStops = []
        style.defaultTabInterval = 28

        var blocks = paragraph.style.textBlocks
        let indent = paragraph.lists.isEmpty ? 0 : listIndent(paragraph.lists)
        if opensBlock(paragraph, after: previous) { style.paragraphSpacingBefore = 0 }
        if let quote, !blocks.contains(where: { $0 === quote }) { blocks.append(quote) }
        if let code {
            code.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
            style.paragraphSpacingBefore = 0
            blocks.append(code)
        }
        style.textBlocks = blocks

        switch paragraph.kind {
        case .heading:
            style.lineHeightMultiple = 1.1
        case .code:
            style.lineHeightMultiple = 1.15
            style.lineBreakMode = .byWordWrapping
        case .rule:
            let rule = makeBlock()
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setBorderColor(palette.border, for: .maxY)
            style.textBlocks = blocks + [rule]
            style.lineHeightMultiple = 1
        case .table:
            style.lineHeightMultiple = 1.1
            style.paragraphSpacingBefore = 0
            for case let cell as NSTextTableBlock in blocks {
                cell.setBorderColor(palette.border)
            }
        case .body:
            style.lineHeightMultiple = 1.2
            if !paragraph.lists.isEmpty {
                style.headIndent = indent
                style.firstLineHeadIndent = hasListMarker(paragraph) ? 0 : indent
                style.tabStops = [NSTextTab(textAlignment: .right, location: indent - 6), NSTextTab(textAlignment: .left, location: indent)]
            }
        }
        return style
    }

    /// A full-width block; without an explicit content width TextKit 1 lays it out as if it weren't there.
    private func makeBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    private func makeCodeBlock() -> NSTextBlock {
        let block = makeBlock()
        block.backgroundColor = palette.codeBackground
        for edge in [NSRectEdge.minX, .maxX] { block.setWidth(12, type: .absoluteValueType, for: .padding, edge: edge) }
        for edge in [NSRectEdge.minY, .maxY] { block.setWidth(9, type: .absoluteValueType, for: .padding, edge: edge) }
        return block
    }

    private func makeQuoteBlock() -> NSTextBlock {
        let block = makeBlock()
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(palette.border, for: .minX)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        return block
    }

    // MARK: Character attributes

    /// Lookout fonts and colours over the importer's: sizes by block, bold/italic/monospace kept from the run.
    private func restyle(_ paragraph: Paragraph) {
        text.enumerateAttributes(in: paragraph.range) { attributes, range, _ in
            let old = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: Self.bodySize)
            text.addAttribute(.font, value: font(from: old, kind: paragraph.kind), range: range)

            let marker = GHHTML.Marker(attributes[.foregroundColor])
            if attributes[.link] != nil {
                text.addAttribute(.foregroundColor, value: palette.link, range: range)
            } else if let marker {
                let color: NSColor
                switch paragraph.kind {
                case .heading(let level): color = level == 6 ? palette.muted : palette.strong
                default: color = marker == .quote ? palette.muted : palette.text
                }
                text.addAttribute(.foregroundColor, value: color, range: range)
            } else if attributes[.foregroundColor] == nil {
                text.addAttribute(.foregroundColor, value: palette.text, range: range)
            }

            if let background = attributes[.backgroundColor] {
                if paragraph.kind == .code {
                    text.removeAttribute(.backgroundColor, range: range)
                } else if GHHTML.Marker(background) == .inlineCode {
                    text.addAttribute(.backgroundColor, value: palette.codeBackground, range: range)
                } else if (background as? NSColor)?.alphaComponent == 0 {
                    text.removeAttribute(.backgroundColor, range: range)
                }
            }
        }
    }

    private func font(from old: NSFont, kind: Kind) -> NSFont {
        let traits = old.fontDescriptor.symbolicTraits
        let mono = traits.contains(.monoSpace) || old.isFixedPitch
        let bold = traits.contains(.bold)
        let size: CGFloat
        var weight: NSFont.Weight = bold ? .semibold : .regular
        switch kind {
        case .heading(let level):
            size = Self.headingSizes[level - 1]
            weight = .semibold
        case .table: size = old.pointSize  // column widths were measured at the importer's size
        case .rule: size = 2
        case .body, .code: size = Self.bodySize
        }
        var font = mono
            ? NSFont.monospacedSystemFont(ofSize: kind == .body || kind == .code || kind == .table ? Self.codeSize : size * 0.9,
                                          weight: weight == .semibold ? .medium : .regular)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if traits.contains(.italic) {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
        return font
    }

    // MARK: List markers

    /// The importer writes each item as "\t<marker>\t<text>".
    private func markerRange(_ paragraph: Paragraph) -> NSRange? {
        let string = text.string as NSString
        let range = paragraph.range
        guard range.length > 2, string.character(at: range.location) == 0x09 else { return nil }
        let search = NSRange(location: range.location + 1, length: min(range.length - 1, 12))
        let tab = string.range(of: "\t", range: search)
        guard tab.location != NSNotFound else { return nil }
        return NSRange(location: range.location + 1, length: tab.location - range.location - 1)
    }

    private func hasListMarker(_ paragraph: Paragraph) -> Bool { markerRange(paragraph) != nil }

    /// Clean bullets per nesting level, "1." for ordered items, no bullet before a task checkbox.
    private func rewriteListMarker(_ paragraph: Paragraph) {
        guard let range = markerRange(paragraph), let list = paragraph.lists.last else { return }
        let string = text.string as NSString
        let afterMarker = NSMaxRange(range) + 1
        let content = afterMarker < NSMaxRange(paragraph.range) ? string.substring(from: afterMarker) : ""
        let marker: String
        if content.hasPrefix("\u{2610}") || content.hasPrefix("\u{2611}") {
            marker = ""
        } else if isOrdered(list) {
            marker = string.substring(with: range) + "."
        } else {
            let depth = paragraph.lists.filter { !isOrdered($0) }.count
            marker = ["\u{2022}", "\u{25E6}", "\u{25AA}"][(depth - 1) % 3]
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: isOrdered(list) ? NSFont.monospacedDigitSystemFont(ofSize: Self.bodySize, weight: .regular)
                                   : NSFont.systemFont(ofSize: Self.bodySize),
            .foregroundColor: palette.muted,
            .paragraphStyle: text.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil) as Any,
        ]
        text.replaceCharacters(in: range, with: NSAttributedString(string: marker, attributes: attributes))
        // The tabs around the marker take the first run's attributes; an item starting with `code` would shade them.
        let gutter = NSRange(location: paragraph.range.location, length: (marker as NSString).length + 2)
        text.removeAttribute(.backgroundColor, range: gutter)
        text.removeAttribute(.link, range: gutter)
    }
}
