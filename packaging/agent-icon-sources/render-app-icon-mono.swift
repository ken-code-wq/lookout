import AppKit

import CoreGraphics
// Turns a colourful macOS app icon into the flat black, alpha-only mark the agent list expects.
//
// The source is a raster app icon, so the mark sits on an off-white matte inside a rounded-rect
// silhouette. Ink coverage is recovered from luminance, then ramped hard around 0.5: the glyph is
// solid ink and the matte edge is faint, so the ramp drops the silhouette without eating the glyph.
// The result is trimmed to its bounding box and re-centred with 12% padding, matching SOURCES.md.
let a = CommandLine.arguments
guard let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])),
      
let source = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("load fail"); exit(1)
}
let w = source.width, h = source.height
let bytesPerRow = w * 4
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var buffer = [UInt8](repeating: 0, count: bytesPerRow * h)
let reader = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

reader.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
var minX = w, minY = h, maxX = 0, maxY = 0

for pixel in 0..<(w * h) {
    let i = pixel * 4
    let r = Double(buffer[i]) / 255, g = Double(buffer[i + 1]) / 255, b = Double(buffer[i + 2]) / 255
    let alpha = Double(buffer[i + 3]) / 255
    let ink = min(max((((1 - (0.2126 * r + 0.7152 * g + 0.0722 * b)) * alpha) - 0.40) / 0.25, 0), 1)
    buffer[i] = 0; buffer[i + 1] = 0; buffer[i + 2] = 0
    buffer[i + 3] = UInt8(ink * 255)
    guard ink > 0.02 else { continue }
    let x = pixel % w, y = pixel / w
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
}

guard maxX > minX, maxY > minY else { print("no ink found"); exit(1) }
// Rows are copied out of the buffer by hand rather than with `cropping(to:)`, whose coordinate
// origin does not match the one the drawing context wrote them in.
let rows = maxY - minY + 1, columns = maxX - minX + 1
var trimmed = [UInt8](repeating: 0, count: columns * 4 * rows)
for row in 0..<rows {
    let from = (minY + row) * bytesPerRow + minX * 4
    for column in 0..<(columns * 4) { trimmed[row * columns * 4 + column] = buffer[from + column] }
}

guard let flat = CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: columns * 4, space: space,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: CGDataProvider(data: Data(trimmed) as CFData)!,
                         decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
    print("build fail"); exit(1)
}

let side = 256, pad = 0.12
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let canvas = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
canvas.interpolationQuality = .high

let available = Double(side) * (1 - 2 * pad)
let scale = min(available / Double(flat.width), available / Double(flat.height))
let width = Double(flat.width) * scale, height = Double(flat.height) * scale
canvas.draw(flat, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("bbox", minX, minY, maxX, maxY)
