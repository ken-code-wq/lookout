import AppKit
let a = CommandLine.arguments
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1])))!
var minX = src.pixelsWide, minY = src.pixelsHigh, maxX = 0, maxY = 0
for y in 0..<src.pixelsHigh { for x in 0..<src.pixelsWide {
  if (src.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 { minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y) } } }
let cg = src.cgImage!.cropping(to: CGRect(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1))!
let S = 256, pad = 0.12
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
ctx.interpolationQuality = .high
let avail = Double(S)*(1-2*pad), w = Double(cg.width), h = Double(cg.height), sc = min(avail/w, avail/h)
ctx.draw(cg, in: CGRect(x: (Double(S)-w*sc)/2, y: (Double(S)-h*sc)/2, width: w*sc, height: h*sc))
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("bbox", minX, minY, maxX, maxY)
