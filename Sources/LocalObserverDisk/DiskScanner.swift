import Foundation

/// Finds what's taking space and clears it. Every function blocks; call them off the main thread.
public enum DiskScanner {
    // MARK: Volume

    public static func volume(at path: String = NSHomeDirectory()) -> DiskVolume? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                                             .volumeAvailableCapacityKey, .volumeLocalizedNameKey]),
              let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return DiskVolume(name: values.volumeLocalizedName ?? "Macintosh HD", total: Int64(total), available: available)
    }

    // MARK: Build artifacts

    /// Folder names that hold rebuildable output, and the file next to them that proves it.
    /// The proof matters: a folder called `target` or `build` is only Rust's or Gradle's when Cargo.toml or
    /// build.gradle sits beside it.
    static func artifactKind(_ name: String, in parent: String, fm: FileManager = .default) -> DiskKind? {
        func has(_ file: String) -> Bool { fm.fileExists(atPath: (parent as NSString).appendingPathComponent(file)) }
        switch name {
        case "node_modules": return has("package.json") ? .nodeModules : nil
        case ".build": return has("Package.swift") ? .swiftBuild : nil
        case "target": return has("Cargo.toml") ? .rustTarget : nil
        case ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular":
            return has("package.json") ? .webBuild : nil
        case ".venv", "venv", "env", ".env":
            return fm.fileExists(atPath: (parent as NSString).appendingPathComponent(name + "/pyvenv.cfg")) ? .pythonVenv : nil
        case "build": return has("build.gradle") || has("build.gradle.kts") ? .gradleBuild : nil
        case "Pods": return has("Podfile") ? .pods : nil
        default: return nil
        }
    }

    /// Never descended into while looking: they're either artifacts themselves or too big to be worth walking.
    static let skip: Set<String> = [".git", "node_modules", ".build", "target", "Pods", ".venv", "venv", "DerivedData",
                                    ".next", ".nuxt", ".svelte-kit", ".turbo", "dist", "build", "vendor", ".cache"]

    /// Artifact folders inside each project, at most `depth` levels down so monorepo packages are found too.
    public static func artifacts(in projects: [DiskProject], depth: Int = 3) -> [DiskItem] {
        let fm = FileManager.default
        var found: [String: DiskItem] = [:]
        for project in projects {
            var queue: [(String, Int)] = [(project.root, 0)]
            while let (dir, level) = queue.popLast() {
                guard let children = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for name in children {
                    let path = (dir as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, !isSymlink(path) else { continue }
                    if let kind = artifactKind(name, in: dir, fm: fm) {
                        guard found[path] == nil else { continue }
                        let sub = dir == project.root ? nil : String(dir.dropFirst(project.root.count + 1))
                        let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                        let used = [project.lastTouched, modified].compactMap { $0 }.max()
                        found[path] = DiskItem(kind: kind, path: path, name: name, project: sub.map { "\(project.name)/\($0)" } ?? project.name,
                                               lastUsed: used, safety: project.inUse == nil ? .safe : .review,
                                               note: project.inUse ?? kind.rebuildHint)
                    } else if level + 1 < depth, !skip.contains(name), !name.hasPrefix(".") {
                        queue.append((path, level + 1))
                    }
                }
            }
        }
        return Array(found.values)
    }

    static func isSymlink(_ path: String) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    // MARK: Caches, Xcode, agent data

    static func fixed() -> [(DiskKind, String, String)] {
        let home = NSHomeDirectory()
        let lib = home + "/Library"
        return [
            (.npmCache, home + "/.npm/_cacache", "npm cache"),
            (.pnpmStore, lib + "/pnpm/store", "pnpm store"),
            (.yarnCache, lib + "/Caches/Yarn", "Yarn cache"),
            (.bunCache, home + "/.bun/install/cache", "Bun cache"),
            (.homebrewCache, lib + "/Caches/Homebrew", "Homebrew downloads"),
            (.pipCache, lib + "/Caches/pip", "pip cache"),
            (.uvCache, home + "/.cache/uv", "uv cache"),
            (.goBuildCache, lib + "/Caches/go-build", "Go build cache"),
            (.cargoRegistry, home + "/.cargo/registry", "Cargo registry"),
            (.gradleCache, home + "/.gradle/caches", "Gradle caches"),
            (.derivedData, lib + "/Developer/Xcode/DerivedData", "DerivedData"),
            (.simulatorCaches, lib + "/Developer/CoreSimulator/Caches", "Simulator caches"),
            (.deviceSupport, lib + "/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport"),
            (.xcodeArchives, lib + "/Developer/Xcode/Archives", "Archives"),
            (.agentData, home + "/.claude/projects", "Claude Code transcripts"),
            (.agentData, home + "/.codex/sessions", "Codex sessions"),
            (.agentData, home + "/.gemini/tmp", "Gemini CLI history"),
            (.agentData, lib + "/Application Support/Cursor/User/workspaceStorage", "Cursor workspace storage"),
        ]
    }

    public static func fixedItems() -> [DiskItem] {
        let fm = FileManager.default
        return fixed().compactMap { kind, path, name in
            guard fm.fileExists(atPath: path) else { return nil }
            let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let safety: DiskSafety
            switch kind {
            case .agentData, .xcodeArchives: safety = .keep
            case .deviceSupport: safety = .review
            default: safety = .safe
            }
            return DiskItem(kind: kind, path: path, name: name, lastUsed: modified, safety: safety, note: kind.rebuildHint)
        }
    }

    // MARK: Worktrees

    public static func worktreeItems(_ worktrees: [DiskWorktree]) -> [DiskItem] {
        worktrees.map { wt in
            let (safety, note) = wt.verdict
            return DiskItem(id: wt.path, kind: wt.prunable ? .prunableWorktree : .worktree, path: wt.path,
                            name: wt.branch ?? (wt.path as NSString).lastPathComponent,
                            project: [wt.repoName, wt.owner].compactMap { $0 }.joined(separator: " · "),
                            ownerRoot: wt.mainRoot, bytes: wt.prunable ? 0 : nil, lastUsed: wt.lastTouched, safety: safety, note: note)
        }
    }

    // MARK: Docker

    public static var dockerPath: String? {
        let home = NSHomeDirectory()
        return ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.docker/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker", home + "/.orbstack/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What `docker system df` says can be reclaimed, or nothing when Docker isn't installed or running.
    public static func dockerItems() -> [DiskItem] {
        guard let docker = dockerPath else { return [] }
        let out = run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 20)
        guard out.status == 0 else { return [] }
        return parseDockerDF(out.stdout)
    }

    public static func parseDockerDF(_ text: String) -> [DiskItem] {
        text.split(separator: "\n").compactMap { line -> DiskItem? in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = row["Type"] as? String else { return nil }
            let reclaimable = DiskFormat.parseDockerSize(row["Reclaimable"] as? String ?? "0B")
            let total = DiskFormat.parseDockerSize(row["Size"] as? String ?? "0B")
            let count = row["TotalCount"].map { "\($0)" } ?? "?"
            let active = row["Active"].map { "\($0)" } ?? "?"
            switch type {
            case "Images":
                return DiskItem(id: "docker:images", kind: .dockerImages, path: "", name: "Unused images", bytes: reclaimable,
                                safety: .review, note: "\(count) images, \(active) in use · \(DiskFormat.bytes(total)) total")
            case "Containers":
                return DiskItem(id: "docker:containers", kind: .dockerContainers, path: "", name: "Stopped containers", bytes: reclaimable,
                                safety: .review, note: "\(count) containers, \(active) running")
            case "Local Volumes":
                return DiskItem(id: "docker:volumes", kind: .dockerVolumes, path: "", name: "Unused volumes", bytes: reclaimable,
                                safety: .keep, note: "\(count) volumes, \(active) in use. Volumes hold data, so Lookout leaves them alone.")
            case "Build Cache":
                return DiskItem(id: "docker:builder", kind: .dockerBuildCache, path: "", name: "Build cache", bytes: reclaimable,
                                safety: .safe, note: "\(DiskFormat.bytes(total)) total")
            default:
                return nil
            }
        }
    }

    // MARK: Sizing

    /// Allocated size on disk, in bytes, via `du` (much faster than walking in Swift for node_modules-sized trees).
    public static func size(_ path: String, timeout: TimeInterval = 120) -> Int64? {
        let out = run("/usr/bin/du", ["-sk", path], timeout: timeout)
        guard let kb = out.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.flatMap({ Int64($0) }) else { return nil }
        return kb * 1024
    }

    // MARK: Clearing

    public struct Failure: Error, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    /// Clears one item, re-checking right before deleting that the folder is still what it was found as.
    public static func clear(_ item: DiskItem) -> Result<Int64, Failure> {
        let before = item.bytes ?? 0
        guard item.canClear else { return .failure(Failure("\(item.name) is kept on purpose")) }
        switch item.kind {
        case .dockerImages, .dockerBuildCache, .dockerContainers:
            guard let docker = dockerPath else { return .failure(Failure("Docker isn't installed")) }
            let args: [String] = switch item.kind {
            case .dockerImages: ["image", "prune", "-a", "-f"]
            case .dockerBuildCache: ["builder", "prune", "-f"]
            default: ["container", "prune", "-f"]
            }
            let out = run(docker, args, timeout: 600)
            return out.status == 0 ? .success(before) : .failure(Failure(firstLine(out) ?? "docker exited with \(out.status)"))
        case .worktree:
            guard let owner = item.ownerRoot else { return .failure(Failure("No repository for \(item.name)")) }
            // No --force: git itself refuses when there are modified or untracked files.
            let out = run("/usr/bin/git", ["-C", owner, "worktree", "remove", item.path], timeout: 120)
            return out.status == 0 ? .success(before) : .failure(Failure(firstLine(out)?.replacingOccurrences(of: "fatal: ", with: "") ?? "git failed"))
        case .prunableWorktree:
            guard let owner = item.ownerRoot else { return .failure(Failure("No repository for \(item.name)")) }
            let out = run("/usr/bin/git", ["-C", owner, "worktree", "prune"], timeout: 60)
            return out.status == 0 ? .success(0) : .failure(Failure(firstLine(out) ?? "git failed"))
        default:
            guard isStillClearable(item) else { return .failure(Failure("\(item.displayPath) changed since the scan; scan again")) }
            do {
                try FileManager.default.removeItem(atPath: item.path)
                return .success(before)
            } catch {
                return .failure(Failure(error.localizedDescription))
            }
        }
    }

    /// The last guard before a delete: inside home, not a symlink, and still recognised as the same kind of folder.
    static func isStillClearable(_ item: DiskItem) -> Bool {
        let home = NSHomeDirectory()
        let path = (item.path as NSString).standardizingPath
        guard path.hasPrefix(home + "/"), path.count > home.count + 4, !isSymlink(path),
              FileManager.default.fileExists(atPath: path) else { return false }
        switch item.kind.category {
        case .artifacts:
            let parent = (path as NSString).deletingLastPathComponent
            return artifactKind((path as NSString).lastPathComponent, in: parent) == item.kind
        case .caches, .xcode:
            return fixed().contains { $0.0 == item.kind && $0.1 == path }
        default:
            return false
        }
    }

    // MARK: Process

    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    static func firstLine(_ out: Output) -> String? {
        (out.stderr.isEmpty ? out.stdout : out.stderr).split(separator: "\n").first.map(String.init)
    }

    /// Reads both pipes before waiting, and kills the process after `timeout`.
    public static func run(_ executable: String, _ args: [String], timeout: TimeInterval) -> Output {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        proc.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return Output(status: -1, stdout: "", stderr: error.localizedDescription) }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if proc.isRunning { proc.terminate() } }
        timer.resume()
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        proc.waitUntilExit()
        timer.cancel()
        return Output(status: proc.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }
}
