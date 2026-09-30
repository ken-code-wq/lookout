// Renders the Lookout app icon. Run: swift packaging/icon/make-icon.swift <out.png> [size]
// The mark: a lens whose rim is the app's segmented provider ring, with the pace tick crossing it.
import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Apple's macOS icon grid: an 824pt continuous-corner tile centred on a 1024pt canvas.
struct LookoutIcon: View {
    private let tile: CGFloat = 824
    private let rimDiameter: CGFloat = 540
    private let rimWidth: CGFloat = 62
    private let segments = 3
    private let gap = 0.045
    /// Where the pace tick crosses the rim, as a fraction of a turn from the top, clockwise.
    private let tickAt = 0.075

    private let sea = [Color(hex: 0x1D5C55), Color(hex: 0x0E3532)]
    private let rim = Color(hex: 0xF2EEE6)
    private let signal = Color(hex: 0xF08A3C)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: sea, startPoint: .top, endPoint: .bottom))
                .overlay(
                    // A faint lit top edge so the tile reads as an object, not a flat swatch.
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)],
                                                     startPoint: .top, endPoint: .center), lineWidth: 3)
                )
                .frame(width: tile, height: tile)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            glass
            ring
            tick
        }
        .frame(width: 1024, height: 1024)
    }

    /// The window itself: deeper water in the middle, with one curved glint.
    private var glass: some View {
        let inner = rimDiameter - rimWidth - 34
        return ZStack {
            Circle().fill(RadialGradient(colors: [Color(hex: 0x2B7A70), Color(hex: 0x123F3B)],
                                         center: UnitPoint(x: 0.42, y: 0.35), startRadius: 10, endRadius: inner * 0.62))
            Circle()
                .trim(from: 0.60, to: 0.78)
                .stroke(Color.white.opacity(0.38), style: StrokeStyle(lineWidth: 22, lineCap: .round))
                .padding(52)
        }
        .frame(width: inner, height: inner)
    }

    private var ring: some View {
        ZStack {
            ForEach(0..<segments, id: \.self) { index in
                let start = Double(index) / Double(segments) + gap / 2
                let end = Double(index + 1) / Double(segments) - gap / 2
                Circle()
                    .trim(from: start, to: end)
                    .stroke(rim, style: StrokeStyle(lineWidth: rimWidth, lineCap: .round))
            }
        }
        // Gaps at 2, 6 and 10 o'clock: an unbroken top arc, so it never reads as a power button.
        .rotationEffect(.degrees(-90 + 60))
        .frame(width: rimDiameter, height: rimDiameter)
    }

    private var tick: some View {
        Capsule()
            .fill(signal)
            .shadow(color: Color(hex: 0x0A2624).opacity(0.45), radius: 6, y: 3)
            .frame(width: 30, height: rimWidth + 70)
            .offset(y: -rimDiameter / 2)
            .rotationEffect(.degrees(tickAt * 360))
    }
}

@MainActor func render() {
    let args = CommandLine.arguments
    let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "icon.png")
    let size = args.count > 2 ? Double(args[2]) ?? 1024 : 1024
    let renderer = ImageRenderer(content: LookoutIcon().scaleEffect(size / 1024).frame(width: size, height: size))
    renderer.scale = 1
    renderer.isOpaque = false
    guard let cg = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        fatalError("render failed")
    }
    try! png.write(to: out)
}

MainActor.assumeIsolated { render() }
