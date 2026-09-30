import Foundation

/// Something parked on the shelf or captured from the clipboard. Metadata lives in `history.json`; payload bytes
/// (images, dropped files) live in their own folder under `Shelf/blobs`, never inside the JSON.
public struct ShelfItem: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, link, image, file, color }

    public var id: UUID
    public var kind: Kind
    public var createdAt: Date
    public var pinned: Bool
    /// Bundle id of the app it was copied or dragged from, for context only.
    public var sourceApp: String?
    /// `.text` and `.link` (the URL string). `.color` keeps what was copied, e.g. "#ff6a00".
    public var text: String?
    /// `.file`, `.image`: the shelf's own copy under `blobs`. A file copied in Finder points at the file itself.
    public var filePath: String?
    /// `.image`, `.file`: a small PNG preview, generated once.
    public var thumbnailPath: String?
    /// `.color`: "#RRGGBB".
    public var colorHex: String?
    /// The image was too large to keep whole, so only its thumbnail was stored.
    public var degraded: Bool?
    /// Content fingerprint for images, so one screenshot copied twice is stored once.
    public var digest: String?

    public init(id: UUID = UUID(), kind: Kind, createdAt: Date = .now, pinned: Bool = false, sourceApp: String? = nil,
                text: String? = nil, filePath: String? = nil, thumbnailPath: String? = nil, colorHex: String? = nil,
                degraded: Bool? = nil, digest: String? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.pinned = pinned
        self.sourceApp = sourceApp
        self.text = text
        self.filePath = filePath
        self.thumbnailPath = thumbnailPath
        self.colorHex = colorHex
        self.degraded = degraded
        self.digest = digest
    }

    public var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }
    public var linkURL: URL? { kind == .link ? text.flatMap(URL.init(string:)) : nil }

    /// One line that names the item: the first line of text, a link's host and path, a file's name, a colour's hex.
    public var title: String {
        switch kind {
        case .text:
            let line = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.trimmingCharacters(in: .whitespaces)
        case .link:
            guard let url = linkURL, let host = url.host() else { return text ?? "" }
            let path = url.path()
            return path.isEmpty || path == "/" ? host : host + path
        case .image:
            // Its file is named for when it was captured; that's what the age next to it already says.
            return degraded == true ? "Image (preview only)" : "Image"
        case .file:
            return fileURL?.lastPathComponent ?? "File"
        case .color:
            return colorHex ?? text ?? "Color"
        }
    }

    /// A link's domain without "www.", shown instead of a favicon.
    public var domain: String? {
        guard let host = linkURL?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public var kindTitle: String {
        switch kind {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        case .color: return "Color"
        }
    }

    public var symbol: String {
        switch kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }

    /// Case-insensitive substring match on the text and the file name.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if let text, text.localizedCaseInsensitiveContains(query) { return true }
        if let name = fileURL?.lastPathComponent, name.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    /// Same payload, ignoring when and where it came from.
    public func hasSameContent(as other: ShelfItem) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .text, .link: return text == other.text
        case .color: return colorHex == other.colorHex
        case .image: return digest != nil && digest == other.digest
        case .file: return filePath == other.filePath || (digest != nil && digest == other.digest)
        }
    }
}

/// What a drop or a clipboard change carries, before it becomes a `ShelfItem` with files on disk.
public enum ShelfContent: Sendable, Equatable {
    case text(String)
    case link(URL)
    /// `original` is the text that was copied ("#f60"), kept so copying it back gives the same string.
    case color(hex: String, original: String?)
    /// Encoded image bytes and their file extension ("png", "jpeg", …).
    case image(Data, ext: String)
    case file(URL)
}
