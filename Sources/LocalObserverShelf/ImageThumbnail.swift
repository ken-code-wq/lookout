import AppKit

/// Rasterises an image into a small square bitmap, aspect-fit, so big images don't sit in memory.
/// Shared by the servers' favicons (IconStore) and the shelf's previews.
public enum ImageThumbnail {
    public static func render(_ image: NSImage, side: CGFloat = 64) -> NSImage? {
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

    /// PNG bytes of an image's first bitmap representation.
    public static func png(_ image: NSImage) -> Data? {
        if let rep = image.representations.first as? NSBitmapImageRep {
            return rep.representation(using: .png, properties: [:])
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
