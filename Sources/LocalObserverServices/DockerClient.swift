import Foundation
import LocalObserverDisk

/// Talks to Docker through its CLI, found the same way Cleanup finds it (Docker Desktop, Homebrew, OrbStack).
/// Every function blocks; call them off the main thread.
public enum DockerClient {
    public enum Action: String, Sendable {
        case start, stop, restart

        public var title: String { rawValue.capitalized }
        public var doneTitle: String {
            switch self {
            case .start: return "Started"
            case .stop: return "Stopped"
            case .restart: return "Restarted"
            }
        }
    }

    public static var dockerPath: String? { DiskScanner.dockerPath }

    /// Every container, running or not, and whether Docker could be asked at all.
    public static func list() -> (DockerAvailability, [DockerContainer]) {
        guard let docker = dockerPath else { return (.notInstalled, []) }
        let out = DiskScanner.run(docker, ["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout: 15)
        let availability = DockerAvailability.classify(status: out.status, stderr: out.stderr)
        guard availability.isReady else { return (availability, []) }
        return (.ready, DockerParsing.containers(out.stdout))
    }

    /// Environment, command and start time for the given containers, in one call.
    public static func inspect(_ ids: [String]) -> [String: DockerInspect] {
        guard let docker = dockerPath, !ids.isEmpty else { return [:] }
        let out = DiskScanner.run(docker, ["inspect"] + ids, timeout: 15)
        return out.status == 0 ? DockerParsing.inspect(out.stdout) : [:]
    }

    /// Start, stop or restart containers. Returns docker's first line of complaint on failure.
    public static func perform(_ action: Action, ids: [String]) -> Result<Void, DiskScanner.Failure> {
        guard let docker = dockerPath else { return .failure(DiskScanner.Failure("Docker isn't installed")) }
        guard !ids.isEmpty else { return .success(()) }
        let out = DiskScanner.run(docker, [action.rawValue] + ids, timeout: action == .start ? 60 : 90)
        if out.status == 0 { return .success(()) }
        let line = (out.stderr.isEmpty ? out.stdout : out.stderr).split(separator: "\n").first.map(String.init)
        return .failure(DiskScanner.Failure(line ?? "docker \(action.rawValue) exited with \(out.status)"))
    }

    /// The last `tail` lines of a container's output, stdout and stderr merged back into the order they were written.
    public static func logs(_ id: String, tail: Int = 300) -> Result<[DockerLogLine], DiskScanner.Failure> {
        guard let docker = dockerPath else { return .failure(DiskScanner.Failure("Docker isn't installed")) }
        let out = DiskScanner.run(docker, ["logs", "--tail", "\(tail)", "--timestamps", id], timeout: 15)
        guard out.status == 0 else {
            return .failure(DiskScanner.Failure(out.stderr.split(separator: "\n").first.map(String.init) ?? "docker logs exited with \(out.status)"))
        }
        return .success(DockerParsing.logs(stdout: out.stdout, stderr: out.stderr))
    }
}
