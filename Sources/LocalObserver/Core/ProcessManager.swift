import Foundation
import AppKit
import Darwin

/// Killing + launching local dev servers.
enum ProcessManager {

    static func isAlive(pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    static func isGroupAlive(pgid: Int32) -> Bool { pgid > 1 && kill(-pgid, 0) == 0 }

    @discardableResult
    static func terminate(pid: Int32, force: Bool = false) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, force ? SIGKILL : SIGTERM) == 0
    }

    /// Signals a whole process group — what Ctrl-C does in a terminal (npm → node → esbuild…).
    @discardableResult
    static func terminateGroup(pgid: Int32, force: Bool = false) -> Bool {
        guard pgid > 1, pgid != getpgrp() else { return false }
        return kill(-pgid, force ? SIGKILL : SIGTERM) == 0
    }

    // MARK: - launch

    static var logDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LocalObserver", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func logURL(for server: ManagedServer) -> URL {
        let safe = server.name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return logDirectory.appendingPathComponent("\(String(safe))-\(server.id.uuidString.prefix(6)).log")
    }

    enum LaunchError: LocalizedError {
        case missingDirectory(String)
        case spawn(Int32)
        var errorDescription: String? {
            switch self {
            case .missingDirectory(let p): return "Folder not found: \(p)"
            case .spawn(let code): return "Could not launch (\(String(cString: strerror(code))))"
            }
        }
    }

    /// Launches `command` through a login zsh in its own process group, detached from our lifetime.
    /// stdout/stderr go to the server's log file. Returns the new process group id.
    static func launch(_ server: ManagedServer) throws -> Int32 {
        var isDir: ObjCBool = false
        let cwd = server.workingDirectory
        if !cwd.isEmpty, !(FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue) {
            throw LaunchError.missingDirectory(cwd)
        }

        let log = logURL(for: server)
        let header = "\n── \(Date().formatted(date: .abbreviated, time: .standard)) · \(server.command)\n"
        if let data = header.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: log.path), let h = try? FileHandle(forWritingTo: log) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: log)
            }
        }

        // GUI apps get a bare PATH; pull in the user's shell setup (nvm, pyenv, homebrew…).
        var script = "[ -f ~/.zshrc ] && source ~/.zshrc >/dev/null 2>&1; "
        if !cwd.isEmpty { script += "cd \(shellQuote(cwd)) || exit 1; " }
        if let port = server.port { script += "export PORT=\(port); " }
        script += server.command

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

        var attrs: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attrs, 0)

        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.bun/bin", "\(NSHomeDirectory())/.cargo/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["FORCE_COLOR"] = "0"
        let envStrings = env.map { "\($0.key)=\($0.value)" }

        let argv = ["/bin/zsh", "-l", "-c", script]
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/zsh", &fileActions, &attrs, &cArgs, &cEnv)
        guard rc == 0 else { throw LaunchError.spawn(rc) }

        // Reap the shell when it exits so it never lingers as a zombie.
        DispatchQueue.global(qos: .background).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return pid
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - workspace

    static func openURL(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    static func reveal(path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func openInTerminal(path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openInEditor(path: String) {
        guard !path.isEmpty else { return }
        // Without `isDirectory`, Foundation checks the disk, so single files (from the agent diff) open as files.
        let url = URL(fileURLWithPath: path)
        let editors = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4"]
        for id in editors {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(url)
    }
}

extension ProcessManager {
    /// Whether something accepts connections on localhost:`port` (IPv4 or IPv6).
    static func isPortInUse(_ port: Int) -> Bool {
        for (family, address) in [(AF_INET, "127.0.0.1"), (AF_INET6, "::1")] {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var result: Int32 = -1
            if family == AF_INET {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(UInt16(port).bigEndian)
                inet_pton(AF_INET, address, &addr.sin_addr)
                result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var addr = sockaddr_in6()
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = in_port_t(UInt16(port).bigEndian)
                inet_pton(AF_INET6, address, &addr.sin6_addr)
                result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            if result == 0 { return true }
        }
        return false
    }
}
