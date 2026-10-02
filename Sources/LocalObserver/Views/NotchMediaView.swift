import SwiftUI
import AppKit

/// Media page of the open notch: artwork, track, scrubber, transport, then volume and brightness.
struct NotchMediaPage: View {
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var system = SystemControls.shared

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            artwork
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // Which app is playing: a browser tab, a podcast app, Spotify…
                .overlay(alignment: .bottomTrailing) {
                    if media.artwork != nil, let icon = media.track?.appIcon {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                            .offset(x: 5, y: 5)
                    }
                }
                .onTapGesture { media.openPlayer() }
                .help(media.track.map { "Open \($0.appName)" } ?? "")
            VStack(alignment: .leading, spacing: 6) {
                trackInfo
                HStack(spacing: 12) {
                    controls
                    Spacer(minLength: 12)
                    levels
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var artwork: some View {
        if let image = media.artwork {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.06)
                if let icon = media.track?.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                } else {
                    Image(systemName: "music.note").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.3))
                }
            }
        }
    }

    @ViewBuilder private var trackInfo: some View {
        if let track = media.track {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(track.album.isEmpty ? track.artist : "\(track.artist), \(track.album)")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Scrubber(track: track) { media.seek(to: $0) }
        } else if media.permissionDenied {
            Text("Allow Lookout to control your music player in System Settings › Privacy & Security › Automation.")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing playing").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Text("Play something in any app or browser tab.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TransportButton(symbol: "backward.fill", size: 13) { media.previous() }
            TransportButton(symbol: media.track?.isPlaying == true ? "pause.fill" : "play.fill", size: 18) { media.playPause() }
            TransportButton(symbol: "forward.fill", size: 13) { media.next() }
        }
        .padding(.leading, -4)
        .disabled(media.track == nil)
    }

    private var levels: some View {
        HStack(spacing: 14) {
            if system.volumeSupported {
                LevelRow(symbol: volumeSymbol, value: system.isMuted ? 0 : system.volume,
                         tap: { system.setMuted(!system.isMuted) }) { system.setVolume($0) }
                    .frame(width: 150)
                    .help("Volume")
            }
            if system.brightnessSupported {
                LevelRow(symbol: "sun.max.fill", value: system.brightness, tap: nil) { system.setBrightness($0) }
                    .frame(width: 130)
                    .help(system.brightnessIsSoftware ? "Brightness (dims this display in software; it doesn't accept hardware brightness control)" : "Brightness")
            }
        }
    }

    private var volumeSymbol: String {
        if system.isMuted || system.volume == 0 { return "speaker.slash.fill" }
        return system.volume < 0.34 ? "speaker.wave.1.fill" : system.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

private struct TransportButton: View {
    var symbol: String
    var size: CGFloat
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.85))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1).animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Elapsed / remaining with a draggable line.
private struct Scrubber: View {
    var track: MediaController.Track
    var seek: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = dragging ?? track.position(at: context.date)
            let fraction = track.duration > 0 ? position / track.duration : 0
            HStack(spacing: 8) {
                Text(time(position)).frame(width: 34, alignment: .leading)
                NotchSlider(value: fraction, height: 4) { dragging = $0 * track.duration } onEnd: { value in
                    seek(value * track.duration)
                    dragging = nil
                }
                Text("-" + time(max(0, track.duration - position))).frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func time(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct LevelRow: View {
    var symbol: String
    var value: Double
    var tap: (() -> Void)?
    var set: (Double) -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18)
                .contentShape(Rectangle())
                .onTapGesture { tap?() }
            NotchSlider(value: value, height: 6, onChange: set, onEnd: set)
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 24, alignment: .trailing)
        }
    }
}

/// White-on-dark slider that thickens while dragged.
struct NotchSlider: View {
    var value: Double
    var height: CGFloat
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void
    @State private var active = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let thickness = active ? height + 3 : height
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(.white.opacity(0.9)).frame(width: max(thickness, width * min(max(value, 0), 1)))
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !active { withAnimation(.easeOut(duration: 0.12)) { active = true } }
                        onChange(min(max(drag.location.x / width, 0), 1))
                    }
                    .onEnded { drag in
                        withAnimation(.easeOut(duration: 0.15)) { active = false }
                        onEnd(min(max(drag.location.x / width, 0), 1))
                    }
            )
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.12), value: active)
    }
}

/// Drop-down for volume and brightness key presses, styled after the NotchView HUD.
struct NotchLevelHUD: View {
    var kind: SystemControls.HUDKind
    var notchHeight: CGFloat
    @ObservedObject private var system = SystemControls.shared

    private var value: Double {
        kind == .volume ? (system.isMuted ? 0 : system.volume) : system.brightness
    }

    private var symbol: String {
        switch kind {
        case .brightness: return "sun.max.fill"
        case .volume:
            if system.isMuted || system.volume == 0 { return "speaker.slash.fill" }
            return system.volume < 0.34 ? "speaker.wave.1.fill" : system.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: value))
            }
            .frame(height: notchHeight)
            LevelTicks(value: value, tint: kind == .volume ? Color(red: 1, green: 0.6, blue: 0.22) : Color(red: 1, green: 0.84, blue: 0.35))
        }
        .padding(.horizontal, 30)
        .animation(.easeOut(duration: 0.15), value: value)
    }
}

/// Thin vertical ticks that light up to the current level, brighter toward the end.
private struct LevelTicks: View {
    var value: Double
    var tint: Color
    var count = 36

    var body: some View {
        let lit = Int((value * Double(count)).rounded())
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < lit ? tint.opacity(0.55 + 0.45 * Double(index) / Double(count)) : .white.opacity(0.14))
                    .frame(width: 3, height: 14)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Closed-notch wing: tiny artwork plus bars that bounce while music plays.
struct NowPlayingWing: View {
    @ObservedObject private var media = MediaController.shared

    var body: some View {
        if let track = media.track {
            HStack(spacing: 6) {
                Group {
                    if let image = media.artwork { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    else if let icon = track.appIcon { Image(nsImage: icon).resizable() }
                }
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                EqualizerBars(playing: track.isPlaying)
                    .frame(width: 14, height: 12)
            }
            .help("\(track.title), \(track.artist)")
        }
    }
}

struct EqualizerBars: View {
    var playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 5, paused: !playing || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = sin(t * (5.2 + Double(i) * 1.7) + Double(i) * 1.3)
                    Capsule()
                        .fill(Color(red: 1, green: 0.42, blue: 0.62))
                        .frame(width: 2, height: playing ? 4 + 8 * (phase + 1) / 2 : 3)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
