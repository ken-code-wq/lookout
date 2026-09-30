import AppKit
import CryptoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// `~/Library/Application Support/LocalObserver/Shelf/`, resolved from the real home so the sandboxed widget and
/// the app agree on it.
public enum ShelfPaths {
    public static var root: URL {
        URL(fileURLWithPath: realHome).appendingPathComponent("Library/Application Support/LocalObserver/Shelf", isDirectory: true)
    }

    private static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }
}

/// Turns content into an item with its files on disk. Everything here is file work (copying, encoding,
/// thumbnailing), so it runs off the main thread.
enum ShelfItemBuilder {
    static let thumbnailSide: CGFloat = 96
    /// Larger images keep only their thumbnail.
    static let maxImageBytes = 8 * 1024 * 1024
    /// Dropped files on the same volume are copied as APFS clones, which cost no space. From another volume a copy is
    /// real, so above this size the shelf keeps a reference instead.
    static let maxCrossVolumeCopy: Int64 = 512 * 1024 * 1024
    static let thumbnailName = ".thumbnail.png"

    /// `copyFiles` is true for drops (the source may be moved or deleted right after) and false for the clipboard,
    /// where a copied Finder file is remembered by its path.
    static func make(_ content: ShelfContent, sourceApp: String?, blobs: URL, copyFiles: Bool, now: Date = .now) async -> ShelfItem? {
        switch content {
        case .text(let text):
            return ShelfItem(kind: .text, createdAt: now, sourceApp: sourceApp, text: text)
        case .link(let url):
            return ShelfItem(kind: .link, createdAt: now, sourceApp: sourceApp, text: url.absoluteString)
        case .color(let hex, let original):
            return ShelfItem(kind: .color, createdAt: now, sourceApp: sourceApp, text: original ?? hex, colorHex: hex)
        case .image(let data, let ext):
            return makeImage(data, ext: ext, sourceApp: sourceApp, blobs: blobs, now: now)
        case .file(let url):
            return await makeFile(url, sourceApp: sourceApp, blobs: blobs, copy: copyFiles, now: now)
        }
    }

    private static func makeImage(_ data: Data, ext: String, sourceApp: String?, blobs: URL, now: Date) -> ShelfItem? {
        guard let image = NSImage(data: data) else { return nil }
        var item = ShelfItem(kind: .image, createdAt: now, sourceApp: sourceApp, digest: digest(data))
        let folder = blobs.appendingPathComponent(item.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            item.thumbnailPath = writeThumbnail(image, in: folder)
            if data.count <= maxImageBytes {
                let file = folder.appendingPathComponent("Image \(stamp(now)).\(ext)")
                try data.write(to: file, options: .atomic)
                item.filePath = file.path
            } else {
                item.degraded = true
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return item.thumbnailPath == nil && item.filePath == nil ? nil : item
    }

    private static func makeFile(_ url: URL, sourceApp: String?, blobs: URL, copy: Bool, now: Date) async -> ShelfItem? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        var item = ShelfItem(kind: .file, createdAt: now, sourceApp: sourceApp, filePath: url.path)
        let folder = blobs.appendingPathComponent(item.id.uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if copy && shouldCopy(url, into: blobs) {
                // Keep the original name, so dragging it back out gives the file it was.
                let destination = folder.appendingPathComponent(url.lastPathComponent)
                try fm.copyItem(at: url, to: destination)
                item.filePath = destination.path
            }
        } catch {
            try? fm.removeItem(at: folder)
            return nil
        }
        if let preview = await fileThumbnail(url) { item.thumbnailPath = writeThumbnail(preview, in: folder) }
        return item
    }

    private static func shouldCopy(_ url: URL, into blobs: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        let target = try? blobs.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        if let source = values.volumeIdentifier, let target, source.isEqual(target) { return true }
        // Another volume: a folder's size isn't known without walking it, so only plain files under the limit are copied.
        guard values.isDirectory != true else { return false }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? .max) <= maxCrossVolumeCopy
    }

    /// Quick Look's preview when there is one (images, PDFs, video frames), otherwise the Finder icon.
    static func fileThumbnail(_ url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: thumbnailSide, height: thumbnailSide),
                                                   scale: 2, representationTypes: .all)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func writeThumbnail(_ image: NSImage, in folder: URL) -> String? {
        guard let thumbnail = ImageThumbnail.render(image, side: thumbnailSide), let png = ImageThumbnail.png(thumbnail) else { return nil }
        let url = folder.appendingPathComponent(thumbnailName)
        do {
            try png.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// "2026-09-27 at 14.03.12", like a macOS screenshot's name.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
