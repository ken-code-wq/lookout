import AppKit
import Combine

/// Now Playing for every source (browsers, YouTube, podcasts, Spotify, Music…) with transport controls.
///
/// macOS 15.4+ only answers Now Playing queries from Apple-signed processes, so the app runs a tiny bridge
/// library (Sources/NowPlayingBridge) inside /usr/bin/perl and reads JSON lines from it. When the bridge
/// can't run (e.g. a bare `swift run` without the dylib), it falls back to asking Spotify and Music directly.
@MainActor
final class MediaController: ObservableObject {
    static let shared = MediaController()

    struct Track: Equatable {
        var bundleID: String
        var appName: String
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var position: Double
        var isPlaying: Bool
        var fetchedAt: Date

        /// Equality ignoring `fetchedAt` (which changes on every update) so unchanged state isn't republished.
        func sameContent(as other: Track) -> Bool {
            bundleID == other.bundleID && appName == other.appName && title == other.title
                && artist == other.artist && album == other.album && duration == other.duration
                && position == other.position && isPlaying == other.isPlaying
        }

        /// Position now, advancing between updates while playing.
        func position(at date: Date) -> Double {
            guard isPlaying else { return position }
            return duration > 0 ? min(duration, position + date.timeIntervalSince(fetchedAt)) : position + date.timeIntervalSince(fetchedAt)
        }

        var appIcon: NSImage? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    /// Only relevant to the Spotify/Music fallback: the player refused Apple Events.
    @Published private(set) var permissionDenied = false

    private var bridge: Process?
    private var buffer = Data()
    private var fallbackTimer: Timer?
    private let scriptQueue = DispatchQueue(label: "LocalObserver.media")
    private var restartDelay: TimeInterval = 3
    private var restartCount = 0
    private var lastArtworkData: Data?
    private static let maxBridgeRestarts = 5

    #if DEBUG
    private var isDemo = false
    /// Debug/demo (snapshot harness): shows this track instead of what's playing; the bridge never starts.
    func loadDemo(track demoTrack: Track?, artwork demoArtwork: NSImage?) {
        isDemo = true
        track = demoTrack
        artwork = demoArtwork
    }
    #else
    private let isDemo = false
    #endif

    func start() {
        guard !isDemo, bridge == nil, fallbackTimer == nil else { return }
        if !startBridge() { startFallback() }
    }

    // MARK: Transport

    private enum Command: Int32 { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    func playPause() {
        if var current = track {
            // Flip immediately so the button responds; the next update confirms.
            current.position = current.position(at: .now)
            current.isPlaying.toggle()
            current.fetchedAt = .now
            track = current
        }
        send(.toggle, appleScript: "playpause")
    }
    func next() { send(.next, appleScript: "next track") }
    func previous() { send(.previous, appleScript: "previous track") }

    func seek(to seconds: Double) {
        if var current = track {
            current.position = max(0, seconds)
            current.fetchedAt = .now
            track = current
        }
        if Self.bridgeLibrary != nil {
            runBridgeCommand(environment: ["NP_SEEK": String(max(0, seconds))])
        } else if let player = FallbackPlayer(rawValue: track?.appName ?? "") {
            runScript("tell application \"\(player.rawValue)\" to set player position to \(max(0, seconds))")
        }
    }

    func openPlayer() {
        guard let track, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: track.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: Command, appleScript: String) {
        if Self.bridgeLibrary != nil {
            runBridgeCommand(environment: ["NP_COMMAND": String(command.rawValue)])
        } else if let player = FallbackPlayer.allCases.first(where: { $0.rawValue == track?.appName }) ?? FallbackPlayer.allCases.first(where: \.isRunning) {
            runScript("tell application \"\(player.rawValue)\" to \(appleScript)")
        }
    }

    // MARK: Bridge

    /// Loads the bridge library into perl and calls np_stream or np_command.
    private static let bridgeScript = """
    use DynaLoader;
    my ($library, $mode) = @ARGV;
    my $handle = DynaLoader::dl_load_file($library, 0) or die "cannot load $library";
    my $symbol = DynaLoader::dl_find_symbol($handle, $mode eq "command" ? "np_command" : "np_stream") or die "missing symbol";
    DynaLoader::dl_install_xsub("main::bridge", $symbol);
    bridge();
    """

    /// Packaged app: Contents/Resources. Development: next to the executable in .build.
    private static let bridgeLibrary: String? = {
        let name = "libNowPlayingBridge.dylib"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ].compactMap { $0?.path }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }()

    private func startBridge() -> Bool {
        guard let library = Self.bridgeLibrary else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.bridgeScript, library, "stream"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in MediaController.shared.consume(data) }
        }
        process.terminationHandler = { _ in
            // Restart after a pause if it dies (e.g. after sleep); fall back if it can't run at all.
            Task { @MainActor in
                let media = MediaController.shared
                guard !media.isDemo else { return }
                media.bridge = nil
                media.restartCount += 1
                // Give up after a few attempts and poll Spotify/Music directly instead.
                if media.restartCount > Self.maxBridgeRestarts {
                    media.startFallback()
                    return
                }
                let delay = media.restartDelay
                media.restartDelay = min(delay * 2, 60)
                try? await Task.sleep(for: .seconds(delay))
                media.start()
            }
        }
        do {
            try process.run()
            bridge = process
            return true
        } catch {
            return false
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            apply(object)
        }
    }

    private func apply(_ object: [String: Any]) {
        guard !isDemo else { return }
        // A healthy message means the bridge works: reset the restart backoff.
        restartCount = 0
        restartDelay = 3
        guard let title = object["title"] as? String, !title.isEmpty else {
            if track != nil { track = nil }
            if artwork != nil { artwork = nil }
            lastArtworkData = nil
            return
        }
        let bundleID = object["bundle"] as? String ?? ""
        let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
        let next = Track(
            bundleID: bundleID,
            appName: appName,
            title: title,
            artist: object["artist"] as? String ?? "",
            album: object["album"] as? String ?? "",
            duration: (object["duration"] as? NSNumber)?.doubleValue ?? 0,
            position: (object["elapsed"] as? NSNumber)?.doubleValue ?? 0,
            isPlaying: (object["playing"] as? Bool) ?? false,
            fetchedAt: .now
        )
        let trackChanged = track.map { ($0.bundleID, $0.title, $0.artist) != (next.bundleID, next.title, next.artist) } ?? true
        if track?.sameContent(as: next) != true { track = next }
        if let encoded = object["artwork"] as? String, let data = Data(base64Encoded: encoded) {
            if data != lastArtworkData {
                lastArtworkData = data
                artwork = NSImage(data: data)
            }
        } else if trackChanged {
            lastArtworkData = nil
            if artwork != nil { artwork = nil }
        }
    }

    private func runBridgeCommand(environment: [String: String]) {
        guard let library = Self.bridgeLibrary else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.bridgeScript, library, "command"]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Fallback (Spotify and Music over Apple Events)

    private enum FallbackPlayer: String, CaseIterable {
        case spotify = "Spotify"
        case music = "Music"

        var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }

    private func startFallback() {
        guard fallbackTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { MediaController.shared.pollFallback() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
        pollFallback()
    }

    private func pollFallback() {
        guard !isDemo else { return }
        let running = FallbackPlayer.allCases.filter(\.isRunning)
        guard !running.isEmpty else {
            if track != nil { track = nil }
            if artwork != nil { artwork = nil }
            return
        }
        let separator = "‖"
        let scripts = running.map { player -> (FallbackPlayer, String) in
            let scale = player == .spotify ? "/ 1000" : ""
            return (player, """
            tell application "\(player.rawValue)"
                if player state is stopped then return ""
                set t to current track
                return (player state as string) & "\(separator)" & (name of t) & "\(separator)" & (artist of t) & "\(separator)" & (album of t) & "\(separator)" & ((duration of t) \(scale) as string) & "\(separator)" & (player position as string)
            end tell
            """)
        }
        scriptQueue.async {
            var found: [Track] = []
            var denied = false
            for (player, source) in scripts {
                var error: NSDictionary?
                let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
                if (error?[NSAppleScript.errorNumber] as? Int) == -1743 { denied = true }
                let parts = output?.components(separatedBy: separator) ?? []
                guard parts.count >= 6, !parts[1].isEmpty else { continue }
                func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                found.append(Track(bundleID: player.bundleID, appName: player.rawValue, title: parts[1], artist: parts[2],
                                   album: parts[3], duration: number(parts[4]), position: number(parts[5]),
                                   isPlaying: parts[0] == "playing", fetchedAt: .now))
            }
            Task { @MainActor in
                let chosen = found.first(where: \.isPlaying) ?? found.first
                let media = MediaController.shared
                let isDenied = denied && found.isEmpty
                if media.permissionDenied != isDenied { media.permissionDenied = isDenied }
                if chosen?.title != media.track?.title, media.artwork != nil { media.artwork = nil }
                // Keep the existing value (and its fetchedAt) when nothing but the clock moved.
                if let chosen, let current = media.track, current.sameContent(as: chosen) { return }
                if chosen == nil && media.track == nil { return }
                media.track = chosen
            }
        }
    }

    private func runScript(_ source: String) {
        scriptQueue.async { _ = NSAppleScript(source: source)?.executeAndReturnError(nil) }
    }
}
