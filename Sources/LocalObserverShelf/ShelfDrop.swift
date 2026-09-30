import AppKit
import UniformTypeIdentifiers

/// Reads drops (Finder files, browser images and links, selected text) into `ShelfContent`, and makes the
/// providers that drag items back out.
public enum ShelfDrop {
    /// What the shelf accepts, for `onDrop(of:)`.
    public static let types: [UTType] = [.fileURL, .image, .url, .plainText]

    /// One content per provider, in the order dropped. A provider offering several forms is read as its most
    /// faithful one: a file, then image data, then a link, then text.
    public static func contents(of providers: [NSItemProvider]) async -> [ShelfContent] {
        var result: [ShelfContent] = []
        for provider in providers {
            if let content = await content(of: provider) { result.append(content) }
        }
        return result
    }

    private static func content(of provider: NSItemProvider) async -> ShelfContent? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider, type: .fileURL), url.isFileURL {
            return .file(url)
        }
        if let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: { $0.conforms(to: .image) }),
           let data = await loadData(provider, type: type) {
            // TIFF is uncompressed; everything else keeps its own encoding.
            if type.conforms(to: .tiff) {
                guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
                return .image(png, ext: "png")
            }
            return .image(data, ext: type.preferredFilenameExtension ?? "png")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = await loadURL(provider, type: .url) {
            return url.isFileURL ? .file(url) : .link(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(provider) {
            return ShelfPasteboard.classify(text)
        }
        return nil
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL: continuation.resume(returning: url)
                case let data as Data: continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                case let string as String: continuation.resume(returning: URL(string: string))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                continuation.resume(returning: string as? String)
            }
        }
    }
}

extension ShelfItem {
    /// What dragging the item out carries: files and images as files (the destination copies them), links as URLs,
    /// text and colours as text.
    public func itemProvider() -> NSItemProvider {
        switch kind {
        case .file, .image:
            let path = kind == .image && degraded == true ? thumbnailPath : filePath
            if let path, let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) {
                provider.suggestedName = URL(fileURLWithPath: path).lastPathComponent
                return provider
            }
            return NSItemProvider()
        case .link:
            if let url = linkURL { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: (text ?? "") as NSString)
        case .text:
            return NSItemProvider(object: (text ?? "") as NSString)
        case .color:
            return NSItemProvider(object: (text ?? colorHex ?? "") as NSString)
        }
    }
}
