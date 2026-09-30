import AppKit
import Combine
import CoreAudio
import AudioToolbox
import IOKit.pwr_mgt
import LocalObserverCore

/// Output volume (CoreAudio) and built-in display brightness, with change notifications for the notch HUD.
@MainActor
final class SystemControls: ObservableObject {
    static let shared = SystemControls()

    @Published private(set) var volume: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var volumeSupported = false
    @Published private(set) var brightness: Double = 0
    @Published private(set) var brightnessSupported = false
    /// True when brightness is applied by dimming (external displays that ignore DDC), not by the panel itself.
    @Published private(set) var brightnessIsSoftware = false

    /// Fires when volume or brightness changed from outside the app (keyboard keys, Control Center).
    let externalChange = PassthroughSubject<HUDKind, Never>()

    enum HUDKind: Equatable { case volume, brightness }

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var lastSetByUs = Date.distantPast
    private var brightnessTimer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        attachToDefaultDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachToDefaultDevice() }
        }
        readBrightness(initial: true)
        // Display changes (plugging in, waking) reset the output curve; put the dimming back.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SystemControls.shared.readBrightness(initial: true) }
        }
        if brightnessSupported && !brightnessIsSoftware {
            // No public notification for brightness keys; a cheap poll catches them.
            let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.readBrightness(initial: false) }
            }
            RunLoop.main.add(timer, forMode: .common)
            brightnessTimer = timer
        }
    }

    // MARK: Volume

    private func attachToDefaultDevice() {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return }
        device = id
        var volumeAddress = Self.volumeAddress
        volumeSupported = AudioObjectHasProperty(id, &volumeAddress)
        readVolume()
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(id, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.device == id else { return }
                    let before = (self.volume, self.isMuted)
                    self.readVolume()
                    if (self.volume, self.isMuted) != before, Date().timeIntervalSince(self.lastSetByUs) > 0.6 {
                        self.externalChange.send(.volume)
                    }
                }
            }
        }
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readVolume() {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.volumeAddress
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { volume = Double(value) }
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &mute) == noErr { isMuted = mute != 0 }
    }

    func setVolume(_ value: Double) {
        guard volumeSupported else { return }
        lastSetByUs = .now
        var level = Float32(min(max(value, 0), 1))
        var address = Self.volumeAddress
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
        if isMuted && level > 0 { setMuted(false) }
        volume = Double(level)
    }

    func setMuted(_ muted: Bool) {
        lastSetByUs = .now
        var value = UInt32(muted ? 1 : 0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        isMuted = muted
    }

    // MARK: Brightness (built-in displays only; external monitors need DDC, which this doesn't do)

    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness = dlsym(displayServices, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
    private static let setBrightnessFn = dlsym(displayServices, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }

    private var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        // Active, not just online: a closed lid keeps the built-in panel online but dark.
        guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private var externalDisplays: [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private func readBrightness(initial: Bool) {
        guard let get = Self.getBrightness, let display = builtInDisplay else {
            // No built-in panel in use: fall back to dimming the external displays.
            brightnessIsSoftware = !externalDisplays.isEmpty
            brightnessSupported = brightnessIsSoftware
            if brightnessIsSoftware {
                brightness = Preferences.shared.externalBrightness
                if initial { applySoftwareBrightness() }
            }
            return
        }
        brightnessIsSoftware = false
        var value: Float = 0
        guard get(display, &value) == 0 else { brightnessSupported = false; return }
        brightnessSupported = true
        let new = Double(value)
        if !initial, abs(new - brightness) > 0.004, Date().timeIntervalSince(lastSetByUs) > 0.6 {
            brightness = new
            externalChange.send(.brightness)
        } else {
            brightness = new
        }
    }

    func setBrightness(_ value: Double) {
        if brightnessIsSoftware {
            lastSetByUs = .now
            brightness = min(max(value, 0.2), 1)
            Preferences.shared.externalBrightness = brightness
            applySoftwareBrightness()
            return
        }
        guard let set = Self.setBrightnessFn, let display = builtInDisplay else { return }
        lastSetByUs = .now
        let level = Float(min(max(value, 0.02), 1))
        _ = set(display, level)
        brightness = Double(level)
    }
}

extension SystemControls {
    /// Scales each external display's output curve. 100% restores the ColorSync profile untouched.
    /// Floor of 20% so the screen can never be dimmed to unreadable.
    func applySoftwareBrightness() {
        let level = Float(min(max(Preferences.shared.externalBrightness, 0.2), 1))
        if level >= 0.999 {
            CGDisplayRestoreColorSyncSettings()
            return
        }
        for display in externalDisplays {
            CGSetDisplayTransferByFormula(display, 0, level, 1, 0, level, 1, 0, level, 1)
        }
    }

    /// Called on quit so a dimmed display doesn't stay dim without the app running.
    static func restoreDisplays() { CGDisplayRestoreColorSyncSettings() }
}

/// Keeps the Mac from idle-sleeping, always or only while an agent is working.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var isHolding = false
    private var assertion: IOPMAssertionID = 0
    private var cancellables: Set<AnyCancellable> = []

    func attach(to store: AgentStore) {
        guard cancellables.isEmpty else { return }
        Publishers.CombineLatest(Preferences.shared.$keepAwake, store.$snapshot)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] mode, _ in
                guard let self, let store else { return }
                let working = store.runningSessions.contains { AgentActivityBucket($0) == .working }
                self.hold(mode == .always || (mode == .whileWorking && working))
            }
            .store(in: &cancellables)
    }

    private func hold(_ on: Bool) {
        guard on != isHolding else { return }
        if on {
            let reason = "Lookout is keeping the Mac awake while agents work" as CFString
            isHolding = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            isHolding = false
        }
    }
}

/// Simple countdown shown beside the notch ("Timers stay in sight").
@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()

    @Published private(set) var endsAt: Date?
    @Published private(set) var length: TimeInterval = 25 * 60
    private var task: Task<Void, Never>?

    var isRunning: Bool { endsAt != nil }

    func start(minutes: Int) {
        length = TimeInterval(minutes * 60)
        endsAt = Date().addingTimeInterval(length)
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            guard !Task.isCancelled, let self else { return }
            self.endsAt = nil
            NSSound(named: "Glass")?.play()
            NotchController.shared.show(NotchAlert(
                id: "timer-\(Date().timeIntervalSince1970)", kind: .finished, agent: nil,
                title: "Timer done", detail: "\(minutes) minutes are up", badge: "Time's up", sessionID: nil
            ), seconds: 6)
        }
    }

    func stop() {
        task?.cancel()
        endsAt = nil
    }

    func remaining(at date: Date) -> TimeInterval { max(0, (endsAt ?? date).timeIntervalSince(date)) }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
