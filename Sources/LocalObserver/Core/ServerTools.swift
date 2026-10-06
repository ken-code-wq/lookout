import Foundation
import AppKit
import Combine
import LocalObserverCore

// MARK: - Tunnels

/// A public URL for a local port, through cloudflared (no account needed) or ngrok (needs its authtoken set).
@MainActor
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    struct Tunnel: Equatable {
        var port: Int
        var tool: String
        var url: String?
        var error: String?
    }

    @Published private(set) var tunnels: [Int: Tunnel] = [:]
    private var processes: [Int: Process] = [:]

    static var cloudflared: String? { ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    static var ngrok: String? { ["/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok", NSHomeDirectory() + "/.local/bin/ngrok"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    static var isAvailable: Bool { cloudflared != nil || ngrok != nil }

    func start(port: Int) {
        guard processes[port] == nil else { return }
        let proc = Process()
        let tool: String
        if let cf = Self.cloudflared {
            tool = "cloudflared"
            proc.executableURL = URL(fileURLWithPath: cf)
            proc.arguments = ["tunnel", "--no-autoupdate", "--url", "http://localhost:\(port)"]
        } else if let ng = Self.ngrok {
            tool = "ngrok"
            proc.executableURL = URL(fileURLWithPath: ng)
            proc.arguments = ["http", "\(port)", "--log", "stdout", "--log-format", "json"]
        } else {
            tunnels[port] = Tunnel(port: port, tool: "", error: "Install cloudflared (brew install cloudflared) or ngrok to share servers.")
            return
        }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        tunnels[port] = Tunnel(port: port, tool: tool)
        // Both tools print the public URL once it's up; read until then, keep draining after.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            let url = text.range(of: #"https://[a-z0-9-]+\.(trycloudflare\.com|ngrok-free\.app|ngrok\.app|ngrok\.io|ngrok-free\.dev)"#,
                                 options: .regularExpression).map { String(text[$0]) }
            let failure = text.contains("ERR_NGROK") || text.lowercased().contains("authentication failed")
                ? (text.split(separator: "\n").first { $0.contains("ERR_NGROK") || $0.lowercased().contains("authentication") }.map(String.init)) : nil
            guard url != nil || failure != nil else { return }
            Task { @MainActor in
                guard var t = TunnelManager.shared.tunnels[port], t.url == nil else { return }
                if let url { t.url = url } else { t.error = "ngrok needs its authtoken: run ngrok config add-authtoken <token>" }
                TunnelManager.shared.tunnels[port] = t
                if let url {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    LiveSurfaces.shared.toast("Sharing :\(port) at \(url) (copied)")
                }
            }
        }
        proc.terminationHandler = { _ in
            Task { @MainActor in
                TunnelManager.shared.processes[port] = nil
                if TunnelManager.shared.tunnels[port]?.error == nil { TunnelManager.shared.tunnels[port] = nil }
            }
        }
        do {
            try proc.run()
            processes[port] = proc
        } catch {
            tunnels[port] = Tunnel(port: port, tool: tool, error: error.localizedDescription)
        }
    }

    func stop(port: Int) {
        processes[port]?.terminate()
        processes[port] = nil
        tunnels[port] = nil
    }

    func stopAll() { for port in Array(processes.keys) { stop(port: port) } }
}

// MARK: - Launcher groups

/// Launchers belonging to one project (the git repository their folders are in, else the folder itself), for
/// starting and stopping a whole stack together.
struct LauncherGroup: Identifiable {
    var id: String { root }
    var root: String
    var name: String
    var launchers: [ManagedServer]

    static func groups(_ launchers: [ManagedServer]) -> [LauncherGroup] {
        var byRoot: [String: [ManagedServer]] = [:]
        var order: [String] = []
        for launcher in launchers {
            let root = GitCheckout.locate(launcher.workingDirectory)?.mainRoot ?? launcher.workingDirectory
            if byRoot[root] == nil { order.append(root) }
            byRoot[root, default: []].append(launcher)
        }
        return order.compactMap { root in
            guard let list = byRoot[root], list.count > 1 else { return nil }
            return LauncherGroup(root: root, name: (root as NSString).lastPathComponent, launchers: list)
        }
    }
}

/// Launchers sharing a fixed port: only one of them can run at a time.
func launcherPortClashes(_ launchers: [ManagedServer]) -> [Int: [ManagedServer]] {
    Dictionary(grouping: launchers.filter { $0.port != nil }, by: { $0.port! }).filter { $0.value.count > 1 }
}
