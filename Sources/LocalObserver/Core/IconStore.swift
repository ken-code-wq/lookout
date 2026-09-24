import AppKit

/// Resolves a favicon for a project: first from the folder on disk, then from the running server.
/// Results (including misses) are cached so rows never flicker between refreshes.
@MainActor
final class IconStore {
    static let shared = IconStore()

    private var cache: [String: NSImage] = [:]
    private var misses: [String: Date] = [:]
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    /// Checked in order, relative to the project root. Covers Next, Vite, CRA, Astro, SvelteKit, Django, Rails…
    nonisolated static let candidates = [
        "app/favicon.ico", "src/app/favicon.ico", "app/icon.png", "src/app/icon.png", "app/icon.svg", "src/app/icon.svg",
        "public/favicon.ico", "public/favicon.png", "public/favicon.svg", "public/icon.png", "public/icon.svg",
        "public/apple-touch-icon.png", "public/logo192.png", "public/logo.png", "public/logo.svg",
        "static/favicon.ico", "static/favicon.png", "static/favicon.svg",
        "src/favicon.ico", "src/assets/favicon.ico", "src/assets/logo.png", "assets/favicon.ico", "assets/icon.png",
        "favicon.ico", "favicon.png", "favicon.svg", "icon.png", "logo.png", "logo.svg",
        "web/favicon.ico", "frontend/public/favicon.ico", "client/public/favicon.ico",
    ]

    func cached(_ key: String) -> NSImage? { cache[key] }

    func icon(for server: ServerEntry) async -> NSImage? {
        if server.projectRoot.isEmpty, let app = server.appBundlePath {
            if let img = cache[app] { return img }
            guard FileManager.default.fileExists(atPath: app) else { return nil }
            let img = NSWorkspace.shared.icon(forFile: app)
            img.size = NSSize(width: 64, height: 64)
            cache[app] = img
            return img
        }
        return await icon(key: server.iconKey, folder: server.projectRoot,
                   baseURL: server.isResponding ? server.urlString : nil, href: server.iconHref)
    }

    func icon(forFolder folder: String) async -> NSImage? {
        await icon(key: folder, folder: folder, baseURL: nil, href: "")
    }

    private func icon(key: String, folder: String, baseURL: String?, href: String) async -> NSImage? {
        if let img = cache[key] { return img }
        let missKey = key + (baseURL == nil ? "" : "#http")
        if let missed = misses[missKey], Date().timeIntervalSince(missed) < 30 { return nil }
        if let task = inflight[key] { return await task.value }

        let task = Task.detached(priority: .utility) { () -> NSImage? in
            if let img = Self.fromDisk(folder) { return img }
            if let base = baseURL { return await Self.fromServer(base: base, href: href) }
            return nil
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result { cache[key] = result; misses[missKey] = nil } else { misses[missKey] = Date() }
        return result
    }

    nonisolated private static func fromDisk(_ folder: String) -> NSImage? {
        guard !folder.isEmpty else { return nil }
        let fm = FileManager.default
        for rel in candidates {
            let path = folder + "/" + rel
            guard fm.fileExists(atPath: path),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int, size > 0, size < 4_000_000,
                  let img = NSImage(contentsOfFile: path) else { continue }
            if let thumb = thumbnail(img) { return thumb }
        }
        return nil
    }

    nonisolated private static func fromServer(base: String, href: String) async -> NSImage? {
        guard let baseURL = URL(string: base) else { return nil }
        var urls: [URL] = []
        if !href.isEmpty, !href.hasPrefix("data:"), let u = URL(string: href, relativeTo: baseURL) { urls.append(u.absoluteURL) }
        if let u = URL(string: "/favicon.ico", relativeTo: baseURL) { urls.append(u.absoluteURL) }
        for url in urls {
            guard let (data, resp) = try? await PortScanner.session.data(from: url),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  !(http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html"),
                  let img = NSImage(data: data), let thumb = thumbnail(img) else { continue }
            return thumb
        }
        return nil
    }

    /// Rasterises to a small bitmap so big logos don't sit in memory.
    nonisolated private static func thumbnail(_ image: NSImage, side: CGFloat = 64) -> NSImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let px = Int(side * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let scale = min(side / image.size.width, side / image.size.height)
        let w = image.size.width * scale, h = image.size.height * scale
        image.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }
}
