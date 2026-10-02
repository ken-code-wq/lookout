import AppKit
import Combine
import CoreAudio
import AudioToolbox

/// Per-app volume (0–200%), mute, and output routing, like SoundSource.
///
/// How it works (public Core Audio, macOS 14.2+): for each app with a custom setting, a process tap captures the
/// app's audio and mutes its normal output (`mutedWhenTapped`). The tap is attached to a private aggregate device
/// built on the chosen output, and an IO proc copies tap → output with gain and a soft limiter. Apps left at
/// 100% on the system output aren't touched at all. First use asks for "System Audio Recording" permission.
@MainActor
final class AppAudio: ObservableObject {
    static let shared = AppAudio()

    struct AudioApp: Identifiable, Equatable {
        var id: String { bundleID }
        var bundleID: String
        var name: String
        var processObjects: [AudioObjectID]
        var bundleIDs: [String]
        var isPlaying: Bool
        var pid: pid_t
    }

    struct OutputDevice: Identifiable, Equatable {
        var id: String { uid }
        var uid: String
        var name: String
        var objectID: AudioObjectID
        var transport: UInt32

        var symbol: String {
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
            case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
            case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
            case kAudioDeviceTransportTypeUSB: return "cable.connector"
            default: return "hifispeaker"
            }
        }
    }

    struct Setting: Codable, Equatable {
        var volume: Double = 1
        var muted = false
        /// nil follows the system output.
        var deviceUID: String?

        var isDefault: Bool { abs(volume - 1) < 0.005 && !muted && deviceUID == nil }
    }

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var outputs: [OutputDevice] = []
    @Published private(set) var systemOutputUID: String?
    @Published private(set) var settings: [String: Setting] = [:]
    /// Set when macOS refused a tap, usually because System Audio Recording permission is off.
    @Published private(set) var error: String?

    private var routes: [String: AppRoute] = [:]
    /// When each app last made sound, so the list doesn't flicker between songs or videos.
    private var lastHeard: [String: Date] = [:]
    private var timer: Timer?
    private let defaultsKey = "LocalObserver.appAudioSettings"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([String: Setting].self, from: data) {
            settings = stored
        }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        // Structural changes (apps starting/stopping audio, devices, default output) arrive as
        // CoreAudio notifications, so the poll is only a safety net for per-app playing state.
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { AppAudio.shared.refresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(object, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        }
    }

    private var refreshPending = false

    /// Coalesces bursts of CoreAudio notifications (one app start fires several) into a single refresh.
    private func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }

    /// Tear down every tap so apps play normally again (called on quit).
    func stopAll() {
        routes.values.forEach { $0.stop() }
        routes = [:]
    }

    // MARK: Settings

    func setting(for bundleID: String) -> Setting { settings[bundleID] ?? Setting() }

    func setVolume(_ volume: Double, for app: AudioApp) {
        update(app) { $0.volume = min(max(volume, 0), 2) }
    }

    func toggleMute(_ app: AudioApp) {
        update(app) { $0.muted.toggle() }
    }

    func setDevice(_ uid: String?, for app: AudioApp) {
        update(app) { $0.deviceUID = uid }
    }

    func reset(_ app: AudioApp) {
        update(app) { $0 = Setting() }
    }

    func setSystemOutput(_ device: OutputDevice) {
        var id = device.objectID
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
        refresh()
    }

    private func update(_ app: AudioApp, _ change: (inout Setting) -> Void) {
        var setting = self.setting(for: app.bundleID)
        change(&setting)
        settings[app.bundleID] = setting.isDefault ? nil : setting
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        apply(app)
    }

    // MARK: Routing

    private func apply(_ app: AudioApp) {
        let setting = self.setting(for: app.bundleID)
        guard !setting.isDefault, !app.processObjects.isEmpty else {
            routes.removeValue(forKey: app.bundleID)?.stop()
            return
        }
        let outputUID = setting.deviceUID.flatMap { uid in outputs.contains { $0.uid == uid } ? uid : nil } ?? systemOutputUID
        guard let outputUID else { return }
        let gain = Float(setting.muted ? 0 : setting.volume)
        // Reuse the route when only the gain changed; rebuild when the device or the app's processes changed.
        if let route = routes[app.bundleID], route.outputUID == outputUID, Set(route.processObjects) == Set(app.processObjects) {
            route.gain = gain
            return
        }
        routes.removeValue(forKey: app.bundleID)?.stop()
        do {
            let route = try AppRoute(app: app, outputUID: outputUID, gain: gain)
            routes[app.bundleID] = route
            error = nil
        } catch let failure as AppRoute.Failure {
            error = failure.message
        } catch {}
    }

    // MARK: Discovery

    #if DEBUG
    private var isDemo = false
    /// Debug/demo (snapshot harness): shows these apps and outputs instead of this Mac's; never refreshes again.
    func loadDemo(apps demoApps: [AudioApp], outputs demoOutputs: [OutputDevice], systemOutputUID system: String?) {
        isDemo = true
        apps = demoApps
        outputs = demoOutputs
        systemOutputUID = system
        settings = [:]
    }
    #else
    private let isDemo = false
    #endif

    func refresh() {
        guard !isDemo else { return }
        let previousSystem = systemOutputUID
        let foundOutputs = Self.readOutputs()
        if foundOutputs != outputs { outputs = foundOutputs }
        let foundSystem = Self.defaultOutputUID()
        if foundSystem != systemOutputUID { systemOutputUID = foundSystem }
        let now = Date()
        let all = Self.readApps()
        for app in all where app.isPlaying { lastHeard[app.bundleID] = now }
        // Show what's playing, what played in the last two minutes, and anything with a custom setting.
        let found = all.filter { app in
            app.isPlaying || settings[app.bundleID] != nil || lastHeard[app.bundleID].map { now.timeIntervalSince($0) < 120 } == true
        }
        if found != apps { apps = found }
        // Keep customised apps routed; rebuild routes that follow the system output when it changes.
        for app in apps where settings[app.bundleID] != nil {
            if previousSystem != systemOutputUID, settings[app.bundleID]?.deviceUID == nil {
                routes.removeValue(forKey: app.bundleID)?.stop()
            }
            apply(app)
        }
        // Apps that quit: drop their routes.
        for bundleID in routes.keys where !all.contains(where: { $0.bundleID == bundleID }) {
            routes.removeValue(forKey: bundleID)?.stop()
        }
    }

    /// Audio processes grouped under the app the user knows (browser helpers roll up into the browser).
    private static func readApps() -> [AudioApp] {
        let objects: [AudioObjectID] = readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        let me = ProcessInfo.processInfo.processIdentifier
        let ownBundle = Bundle.main.bundleIdentifier ?? "dev.localobserver.app"
        var grouped: [String: AudioApp] = [:]
        for object in objects {
            let pid: pid_t = readValue(object, kAudioProcessPropertyPID) ?? -1
            guard pid > 0, pid != me else { continue }
            let bundle = readString(object, kAudioProcessPropertyBundleID) ?? ""
            let running: UInt32 = readValue(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            // The owning app: exact pid match, else the longest bundle-ID prefix (com.google.Chrome.helper → Chrome).
            // Case-insensitive: Arc's helpers are "company.thebrowser.browser.helper" under "company.thebrowser.Browser".
            let lowered = bundle.lowercased()
            let owner = regularApps.first { $0.processIdentifier == pid }
                ?? regularApps.filter { app in !bundle.isEmpty && lowered.hasPrefix(app.bundleIdentifier!.lowercased()) }
                    .max { $0.bundleIdentifier!.count < $1.bundleIdentifier!.count }
            guard let owner, let ownerID = owner.bundleIdentifier, ownerID != ownBundle, ownerID != "dev.localobserver.app" else { continue }
            var entry = grouped[ownerID] ?? AudioApp(bundleID: ownerID, name: owner.localizedName ?? ownerID, processObjects: [],
                                                     bundleIDs: [], isPlaying: false, pid: owner.processIdentifier)
            entry.processObjects.append(object)
            if !entry.bundleIDs.contains(ownerID) { entry.bundleIDs.append(ownerID) }
            if !bundle.isEmpty && !entry.bundleIDs.contains(bundle) { entry.bundleIDs.append(bundle) }
            entry.isPlaying = entry.isPlaying || running != 0
            grouped[ownerID] = entry
        }
        return grouped.values.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    }

    private static func readOutputs() -> [OutputDevice] {
        let devices: [AudioObjectID] = readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return devices.compactMap { id in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
            guard let uid = readString(id, kAudioDevicePropertyDeviceUID), let name = readString(id, kAudioObjectPropertyName) else { return nil }
            let transport: UInt32 = readValue(id, kAudioDevicePropertyTransportType) ?? 0
            // Skip aggregates (ours and others') and virtual plumbing.
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual { return nil }
            return OutputDevice(uid: uid, name: name, objectID: id, transport: transport)
        }
    }

    private static func defaultOutputUID() -> String? {
        let id: AudioObjectID? = readValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        return id.flatMap { readString($0, kAudioDevicePropertyDeviceUID) }
    }

    // MARK: Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    static func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// One app's tap → aggregate device → output, with live gain.
final class AppRoute: @unchecked Sendable {
    struct Failure: Error { var message: String }

    let outputUID: String
    let processObjects: [AudioObjectID]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Read on the audio thread; a single aligned Float store is safe enough for a volume knob.
    private let gainPointer = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    var gain: Float {
        get { gainPointer.pointee }
        set { gainPointer.pointee = newValue }
    }

    init(app: AppAudio.AudioApp, outputUID: String, gain: Float) throws {
        self.outputUID = outputUID
        self.processObjects = app.processObjects
        gainPointer.pointee = gain

        let description = CATapDescription(stereoMixdownOfProcesses: app.processObjects)
        description.name = "Lookout: \(app.name)"
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        if #available(macOS 26.0, *) {
            // Follow the app's bundle IDs so new helper processes (browser tabs) are captured too.
            description.bundleIDs = app.bundleIDs
            description.isProcessRestoreEnabled = true
        }
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            gainPointer.deallocate()
            throw Failure(message: "macOS didn't allow capturing \(app.name)'s audio. Turn on Lookout in System Settings › Privacy & Security › Screen & System Audio Recording.")
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lookout \(app.name)",
            kAudioAggregateDeviceUIDKey: "dev.localobserver.route.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            gainPointer.deallocate()
            throw Failure(message: "Couldn't open the output for \(app.name) (\(status)).")
        }

        let gainPointer = self.gainPointer
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            AppRoute.render(input: input, output: output, gain: gainPointer.pointee)
        }
        guard status == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            gainPointer.deallocate()
            throw Failure(message: "Couldn't start audio for \(app.name) (\(status)).")
        }
        AudioDeviceStart(aggregateID, procID)
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            gainPointer.deallocate()
        }
    }

    /// Tap (stereo Float32) → every output channel, scaled, with a soft knee above 0.9 so 200% doesn't hard-clip.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard let source = inputs.first, let sourceData = source.mData?.assumingMemoryBound(to: Float.self) else {
            for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            return
        }
        let sourceChannels = max(Int(source.mNumberChannels), 1)
        let sourceFrames = Int(source.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
        var channelOffset = 0
        for buffer in outputs {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    var sample: Float = 0
                    if frame < sourceFrames {
                        sample = sourceData[frame * sourceChannels + (channelOffset + channel) % sourceChannels] * gain
                        let magnitude = abs(sample)
                        if magnitude > 0.9 { sample = copysign(0.9 + 0.1 * tanh((magnitude - 0.9) / 0.1), sample) }
                    }
                    data[frame * channels + channel] = sample
                }
            }
            channelOffset += channels
        }
    }
}
