import Foundation

/// A backing service a project talks to: a database, cache, queue, search engine, object store or mail catcher.
public enum ServiceKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case postgres, mysql, mariadb, redis, valkey, mongodb, elasticsearch, opensearch, rabbitmq, kafka,
         minio, mailpit, mailhog, memcached, clickhouse, nats, localstack

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .postgres: return "Postgres"
        case .mysql: return "MySQL"
        case .mariadb: return "MariaDB"
        case .redis: return "Redis"
        case .valkey: return "Valkey"
        case .mongodb: return "MongoDB"
        case .elasticsearch: return "Elasticsearch"
        case .opensearch: return "OpenSearch"
        case .rabbitmq: return "RabbitMQ"
        case .kafka: return "Kafka"
        case .minio: return "MinIO"
        case .mailpit: return "Mailpit"
        case .mailhog: return "MailHog"
        case .memcached: return "Memcached"
        case .clickhouse: return "ClickHouse"
        case .nats: return "NATS"
        case .localstack: return "LocalStack"
        }
    }

    public enum Role: String, Sendable {
        case database = "Database", cache = "Cache", queue = "Queue", search = "Search", storage = "Object storage",
             mail = "Mail catcher", cloud = "Cloud emulator"
    }

    public var role: Role {
        switch self {
        case .postgres, .mysql, .mariadb, .mongodb, .clickhouse: return .database
        case .redis, .valkey, .memcached: return .cache
        case .rabbitmq, .kafka, .nats: return .queue
        case .elasticsearch, .opensearch: return .search
        case .minio: return .storage
        case .mailpit, .mailhog: return .mail
        case .localstack: return .cloud
        }
    }

    public var symbol: String {
        switch role {
        case .database: return "cylinder.split.1x2"
        case .cache: return "bolt.horizontal"
        case .queue: return "tray.2"
        case .search: return "magnifyingglass"
        case .storage: return "externaldrive"
        case .mail: return "envelope"
        case .cloud: return "cloud"
        }
    }

    /// Ports the service listens on out of the box. The first is the one clients connect to.
    public var defaultPorts: [Int] {
        switch self {
        case .postgres: return [5432]
        case .mysql, .mariadb: return [3306, 33060]
        case .redis, .valkey: return [6379]
        case .mongodb: return [27017, 27018, 27019]
        case .elasticsearch, .opensearch: return [9200, 9300]
        case .rabbitmq: return [5672, 15672]
        case .kafka: return [9092]
        case .minio: return [9000, 9001]
        case .mailpit, .mailhog: return [8025, 1025]
        case .memcached: return [11211]
        case .clickhouse: return [8123, 9000]
        case .nats: return [4222, 8222]
        case .localstack: return [4566]
        }
    }

    /// A port that serves a browser UI, when the service has one: RabbitMQ's management plugin, Mailpit's inbox…
    public var webPorts: [Int] {
        switch self {
        case .rabbitmq: return [15672]
        case .minio: return [9001]
        case .mailpit, .mailhog: return [8025]
        case .elasticsearch: return [9200]
        case .clickhouse: return [8123]
        case .nats: return [8222]
        default: return []
        }
    }

    // MARK: Recognition

    /// Executable names, compared against the process's own name.
    var processNames: [String] {
        switch self {
        case .postgres: return ["postgres", "postmaster"]
        case .mysql: return ["mysqld"]
        case .mariadb: return ["mariadbd"]
        case .redis: return ["redis-server"]
        case .valkey: return ["valkey-server"]
        case .mongodb: return ["mongod", "mongos"]
        case .minio: return ["minio"]
        case .mailpit: return ["mailpit"]
        case .mailhog: return ["mailhog"]
        case .memcached: return ["memcached"]
        case .clickhouse: return ["clickhouse", "clickhouse-server"]
        case .nats: return ["nats-server"]
        case .elasticsearch, .opensearch, .rabbitmq, .kafka, .localstack: return []
        }
    }

    /// Text in the command line that gives away services running inside a JVM, BEAM or Python.
    var commandMarkers: [String] {
        switch self {
        case .elasticsearch: return ["org.elasticsearch.bootstrap"]
        case .opensearch: return ["org.opensearch.bootstrap"]
        case .rabbitmq: return ["-s rabbit", "rabbitmq"]
        case .kafka: return ["kafka.kafka", "kafka-server-start"]
        case .localstack: return ["localstack"]
        case .mariadb: return ["mariadb"]
        default: return []
        }
    }

    /// Image names (the last path component, without registry or tag) that run this service.
    static let imageNames: [String: ServiceKind] = [
        "postgres": .postgres, "postgresql": .postgres, "postgis": .postgres, "pgvector": .postgres,
        "timescaledb": .postgres, "timescaledb-ha": .postgres, "postgres-alpine": .postgres,
        "mysql": .mysql, "mysql-server": .mysql, "percona-server": .mysql,
        "mariadb": .mariadb,
        "redis": .redis, "redis-stack": .redis, "redis-stack-server": .redis, "keydb": .redis, "dragonfly": .redis,
        "valkey": .valkey,
        "mongo": .mongodb, "mongodb": .mongodb, "mongodb-community-server": .mongodb,
        "elasticsearch": .elasticsearch,
        "opensearch": .opensearch,
        "rabbitmq": .rabbitmq,
        "kafka": .kafka, "cp-kafka": .kafka, "redpanda": .kafka,
        "minio": .minio,
        "mailpit": .mailpit,
        "mailhog": .mailhog,
        "memcached": .memcached,
        "clickhouse-server": .clickhouse, "clickhouse": .clickhouse,
        "nats": .nats,
        "localstack": .localstack,
    ]
}

/// Works out which service is behind a listening port, from what Lookout can see: the process, its command line, and
/// for Docker the image of the container that published the port.
public enum ServiceRecognizer {
    /// `docker.io/library/postgres:16-alpine` → `postgres`; `ghcr.io/org/pgvector/pgvector@sha256:…` → `pgvector`.
    public static func imageName(_ image: String) -> String {
        var name = image.lowercased()
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        var parts = name.split(separator: "/").map(String.init)
        guard var last = parts.popLast() else { return "" }
        if let colon = last.firstIndex(of: ":") { last = String(last[..<colon]) }
        return last
    }

    public static func kind(image: String) -> ServiceKind? {
        ServiceKind.imageNames[imageName(image)]
    }

    /// From a native process. `processName` is what lsof calls it (often truncated), `command` the full command line.
    public static func kind(processName: String, command: String) -> ServiceKind? {
        let name = (processName as NSString).lastPathComponent.lowercased()
        let executable = (command.split(separator: " ").first.map(String.init) ?? "")
        let binary = (executable as NSString).lastPathComponent.lowercased()
        let lower = command.lowercased()
        // MariaDB still ships a `mysqld`; its command line usually names it.
        if (name == "mysqld" || binary == "mysqld"), lower.contains("mariadb") { return .mariadb }
        for kind in ServiceKind.allCases where !kind.processNames.isEmpty {
            if kind.processNames.contains(name) || kind.processNames.contains(binary) { return kind }
        }
        for kind in ServiceKind.allCases where kind != .mariadb {
            if kind.commandMarkers.contains(where: lower.contains) { return kind }
        }
        return nil
    }

    /// Ports distinctive enough to name a service when nothing else is known (Docker published it, but the container
    /// list hasn't been read yet). Shared ports like 9000 or 8000 are left out on purpose.
    static let distinctivePorts: [Int: ServiceKind] = [
        5432: .postgres, 3306: .mysql, 6379: .redis, 27017: .mongodb, 9200: .elasticsearch, 5672: .rabbitmq,
        15672: .rabbitmq, 9092: .kafka, 11211: .memcached, 8025: .mailpit, 1025: .mailpit, 4222: .nats, 4566: .localstack,
        8123: .clickhouse,
    ]

    /// Whether the process is something that forwards ports for containers (Docker Desktop, OrbStack, Colima…), in
    /// which case its name says nothing about the service behind it.
    public static func isContainerForwarder(processName: String, command: String) -> Bool {
        let lower = (processName + " " + command).lowercased()
        return ["com.docker", "vpnkit", "docker-proxy", "orbstack", "limactl", "colima", "gvproxy", "rancher", "podman"]
            .contains(where: lower.contains) || processName.lowercased().hasPrefix("docker")
    }

    /// The best answer, most certain first: the container's image, then the process, then the port for forwarders.
    public static func recognize(processName: String, command: String, port: Int, image: String?) -> Recognition? {
        if let image, let kind = kind(image: image) { return Recognition(kind: kind, basis: .image) }
        if let kind = kind(processName: processName, command: command) { return Recognition(kind: kind, basis: .process) }
        if isContainerForwarder(processName: processName, command: command), let kind = distinctivePorts[port] {
            return Recognition(kind: kind, basis: .port)
        }
        return nil
    }

    public struct Recognition: Hashable, Sendable {
        public var kind: ServiceKind
        public var basis: Basis
        public init(kind: ServiceKind, basis: Basis) { self.kind = kind; self.basis = basis }

        public enum Basis: String, Sendable {
            case image, process, port
            /// What to tell the user about how sure this is.
            public var explanation: String {
                switch self {
                case .image: return "From the container's image"
                case .process: return "From the process"
                case .port: return "Guessed from the port number"
                }
            }
        }
    }
}
