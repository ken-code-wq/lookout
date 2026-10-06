import Foundation
import Combine
import LocalObserverDisk

/// Which running container published which host port. Read by the port scanner off the main thread, so it's
/// lock-protected rather than published.
public final class ServicePortIndex: @unchecked Sendable {
    public static let shared = ServicePortIndex()

    public struct Entry: Hashable, Sendable {
        public var containerID: String
        public var name: String
        public var image: String
        public var composeProject: String?
        public var composeFolder: String?
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var updated: Date?

    public func entry(port: Int) -> Entry? { lock.withLock { entries[port] } }

    /// When the container list was last read; nil if never (or Docker isn't there).
    public var updatedAt: Date? { lock.withLock { updated } }

    func update(_ containers: [DockerContainer], at date: Date) {
        var next: [Int: Entry] = [:]
        for c in containers where c.state.isUp {
            for port in c.publishedPorts {
                guard let host = port.hostPort, next[host] == nil else { continue }
                next[host] = Entry(containerID: c.id, name: c.name, image: c.image, composeProject: c.composeProject,
                                   composeFolder: c.composeFolder)
            }
        }
        lock.withLock {
            entries = next
            updated = date
        }
    }
}

/// The Services pillar: Docker containers (running and stopped, grouped by compose project) and the connection
/// details of the databases and other services among them. Stands alone like the Disk pillar: the app asks it for a
/// container by port; it never reads the server list.
@MainActor
public final class ServicesStore: ObservableObject {
    public static let shared = ServicesStore()

    @Published public private(set) var availability: DockerAvailability = .unknown
    @Published public private(set) var containers: [DockerContainer] = []
    /// `docker inspect` for service containers only: their environment holds the connection details.
    @Published public private(set) var inspected: [String: DockerInspect] = [:]
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastRefresh: Date?
    /// Containers with an action in flight.
    @Published public private(set) var busy: Set<String> = []
    @Published public var searchText = ""

    /// Result of an action, for the app to show as a toast: message, succeeded.
    public var onActionResult: ((String, Bool) -> Void)?
    /// Called after the container list changes, so the app can rescan ports.
    public var onContainersChanged: (() -> Void)?

    private var refreshTask: Task<Void, Never>?
    private var isDemo = false

    public init() {}

    // MARK: Reading

    public func refresh() {
        guard !isDemo, refreshTask == nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            let (availability, list) = await Task.detached(priority: .utility) { DockerClient.list() }.value
            // Only containers that run a known service are inspected; nothing else's environment is read.
            let services = list.filter { $0.kind != nil }.map(\.id)
            let details = await Task.detached(priority: .utility) { DockerClient.inspect(services) }.value
            guard let self else { return }
            let now = Date()
            ServicePortIndex.shared.update(list, at: now)
            let changed = list.map(\.id) != self.containers.map(\.id) || list.map(\.state) != self.containers.map(\.state)
            if availability != self.availability { self.availability = availability }
            // `docker inspect`'s start time is exact; the status sentence ("Up About an hour") is rounded.
            let next = list.map { c in
                var c = c
                if let started = details[c.id]?.startedAt { c.uptime = max(0, now.timeIntervalSince(started)) }
                return c
            }
            if next != self.containers { self.containers = next }
            if details != self.inspected { self.inspected = details }
            self.lastRefresh = now
            self.isRefreshing = false
            self.refreshTask = nil
            if changed { self.onContainersChanged?() }
        }
    }

    /// Re-reads only when the last read is older than `age`, so pages and inspectors can call it on appear.
    public func refreshIfStale(_ age: TimeInterval = 20) {
        if lastRefresh.map({ Date().timeIntervalSince($0) > age }) ?? true { refresh() }
    }

    // MARK: Derived

    public var groups: [DockerGroup] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? containers : containers.filter { c in
            [c.name, c.image, c.composeProject ?? "", c.kind?.name ?? "", c.ports.map(\.label).joined(separator: " ")]
                .contains { $0.lowercased().contains(q) }
        }
        return DockerGroup.group(list)
    }

    public var runningCount: Int { containers.filter { $0.state.isUp }.count }

    /// The running container that published `port` on the Mac.
    public func container(publishing port: Int) -> DockerContainer? {
        containers.first { $0.state.isUp && $0.publishedPorts.contains { $0.hostPort == port } }
    }

    /// Connection details for a service container, read from its environment. Nil for containers that aren't a
    /// known service or don't publish a port.
    public func connection(for container: DockerContainer) -> ServiceConnection? {
        guard let kind = container.kind, let port = container.primaryHostPort else { return nil }
        let detail = inspected[container.id]
        return ServiceConnection.forContainer(kind: kind, hostPort: port, env: detail?.env ?? [:], command: detail?.command ?? [])
    }

    // MARK: Actions

    public func perform(_ action: DockerClient.Action, on targets: [DockerContainer], label: String? = nil) {
        let targets = targets.filter { !busy.contains($0.id) }
        guard !targets.isEmpty else { return }
        let name = label ?? (targets.count == 1 ? targets[0].name : "\(targets.count) containers")
        if isDemo {
            onActionResult?("\(action.doneTitle) \(name) (demo)", true)
            return
        }
        busy.formUnion(targets.map(\.id))
        let ids = targets.map(\.id)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { DockerClient.perform(action, ids: ids) }.value
            guard let self else { return }
            self.busy.subtract(ids)
            switch result {
            case .success: self.onActionResult?("\(action.doneTitle) \(name)", true)
            case .failure(let failure): self.onActionResult?(failure.message, false)
            }
            self.refresh()
        }
    }

    public func logs(for container: DockerContainer, tail: Int = 300) async -> Result<[DockerLogLine], DiskScanner.Failure> {
        if isDemo { return .success(demoLogs[container.id] ?? []) }
        let id = container.id
        return await Task.detached(priority: .userInitiated) { DockerClient.logs(id, tail: tail) }.value
    }

    // MARK: Demo

    private var demoLogs: [String: [DockerLogLine]] = [:]

    public func loadDemo(availability: DockerAvailability, containers: [DockerContainer], inspected: [String: DockerInspect],
                         logs: [String: [DockerLogLine]] = [:]) {
        isDemo = true
        self.availability = availability
        self.containers = containers
        self.inspected = inspected
        demoLogs = logs
        lastRefresh = Date()
        ServicePortIndex.shared.update(containers, at: Date())
    }
}
