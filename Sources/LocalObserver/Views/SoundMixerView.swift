import SwiftUI
import AppKit

/// Per-app mixer: system output on top, then every app making sound with 0–200% volume, mute, and its own output.
/// Uses semantic colours so it reads on the black notch and in the light or dark menu bar panel.
struct SoundMixerView: View {
    @ObservedObject private var audio = AppAudio.shared
    @ObservedObject private var system = SystemControls.shared
    var maxRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            systemRow
            if let error = audio.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if audio.apps.isEmpty {
                Text("No apps are making sound right now.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ForEach(audio.apps.prefix(maxRows)) { app in
                    AppVolumeRow(app: app)
                }
            }
        }
        .onAppear { audio.refresh() }
    }

    private var systemRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(audio.outputs) { device in
                    Button {
                        audio.setSystemOutput(device)
                    } label: {
                        if device.uid == audio.systemOutputUID { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: currentOutput?.symbol ?? "hifispeaker")
                    Text(currentOutput?.name ?? "Output").lineLimit(1)
                }
                .font(.system(size: 11.5, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("System output")
            if system.volumeSupported {
                GainSlider(value: system.isMuted ? 0 : system.volume, range: 1) { system.setVolume($0) }
                Text("\(Int(((system.isMuted ? 0 : system.volume) * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Spacer()
            }
        }
    }

    private var currentOutput: AppAudio.OutputDevice? {
        audio.outputs.first { $0.uid == audio.systemOutputUID }
    }
}

private struct AppVolumeRow: View {
    var app: AppAudio.AudioApp
    @ObservedObject private var audio = AppAudio.shared

    private var setting: AppAudio.Setting { audio.setting(for: app.bundleID) }
    private var icon: NSImage? { NSRunningApplication(processIdentifier: app.pid)?.icon }
    private var routedDevice: AppAudio.OutputDevice? {
        setting.deviceUID.flatMap { uid in audio.outputs.first { $0.uid == uid } }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                if app.isPlaying && !setting.muted {
                    EqualizerBars(playing: true).frame(width: 9, height: 7).offset(x: 3, y: 2)
                }
            }
            .frame(width: 22)
            Text(app.name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
                .foregroundStyle(setting.muted ? .tertiary : .primary)
            Button { audio.toggleMute(app) } label: {
                Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(setting.muted ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            GainSlider(value: setting.muted ? 0 : setting.volume, range: 2) { audio.setVolume($0, for: app) }
                .opacity(setting.muted ? 0.4 : 1)
            Text("\(Int((setting.volume * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(setting.volume > 1.005 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 34, alignment: .trailing)
            deviceMenu
        }
        .contextMenu {
            Button("Reset \(app.name)") { audio.reset(app) }.disabled(setting.isDefault)
        }
    }

    private var deviceMenu: some View {
        Menu {
            Button {
                audio.setDevice(nil, for: app)
            } label: {
                if setting.deviceUID == nil { Label("System output", systemImage: "checkmark") } else { Text("System output") }
            }
            Divider()
            ForEach(audio.outputs) { device in
                Button {
                    audio.setDevice(device.uid, for: app)
                } label: {
                    if device.uid == setting.deviceUID { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                }
            }
            if !setting.isDefault {
                Divider()
                Button("Reset to 100%, system output") { audio.reset(app) }
            }
        } label: {
            Image(systemName: routedDevice?.symbol ?? "arrow.triangle.branch")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(routedDevice == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22)
        .help(routedDevice.map { "\(app.name) plays on \($0.name)" } ?? "\(app.name) plays on the system output")
    }
}

/// Drag slider over 0...range. With range 2 (200%) it snaps to 100% and colours the boost above it.
struct GainSlider: View {
    var value: Double
    var range: Double
    var onChange: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = min(max(value / range, 0), 1)
            let unity = 1 / range
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(.primary.opacity(0.75)).frame(width: max(5, width * min(fraction, unity)))
                if fraction > unity {
                    // Boost past 100% in orange, starting where unity sits.
                    Capsule().fill(Color.orange)
                        .frame(width: width * (fraction - unity) + 5)
                        .offset(x: width * unity - 5)
                }
                if range > 1 {
                    Capsule().fill(.primary.opacity(0.45)).frame(width: 1.5, height: dragging ? 12 : 9).offset(x: width * unity - 0.75)
                }
            }
            .frame(height: dragging ? 7 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        var new = min(max(drag.location.x / width, 0), 1) * range
                        if range > 1, abs(new - 1) < 0.05 { new = 1 } // detent at 100%
                        onChange(new)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: dragging)
        .help("\(Int((value * 100).rounded()))%")
    }
}
