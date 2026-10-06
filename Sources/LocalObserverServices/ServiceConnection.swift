import Foundation

/// How to connect to a service: host, port, and for Docker the user, password and database its container was started
/// with. Parts that are defaults rather than read from the container are listed in `guessed`, so the UI can say so.
public struct ServiceConnection: Hashable, Sendable {
    public enum Field: String, Sendable, Hashable { case user, password, database }

    public var kind: ServiceKind
    public var host: String
    public var port: Int
    public var user: String?
    /// Kept in memory only. Never shown unless the user reveals it, never logged.
    public var password: String?
    public var database: String?
    /// Extra query string, e.g. `authSource=admin` for a Mongo root user.
    public var query: String?
    public var guessed: Set<Field>
    /// The container reads its password from a secret file (`POSTGRES_PASSWORD_FILE`), which Lookout doesn't open.
    public var passwordInFile: Bool
    /// OpenSearch with its security plugin turned off answers plain HTTP instead of HTTPS.
    public var plainHTTP = false

    public init(kind: ServiceKind, host: String = "localhost", port: Int, user: String? = nil, password: String? = nil,
                database: String? = nil, query: String? = nil, guessed: Set<Field> = [], passwordInFile: Bool = false) {
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.query = query
        self.guessed = guessed
        self.passwordInFile = passwordInFile
    }

    /// What goes before `://`, or nil for services addressed as a bare `host:port` (Kafka brokers, Memcached).
    public var scheme: String? {
        switch kind {
        case .postgres: return "postgresql"
        case .mysql, .mariadb: return "mysql"
        case .redis, .valkey: return "redis"
        case .mongodb: return "mongodb"
        case .rabbitmq: return "amqp"
        case .nats: return "nats"
        case .opensearch: return plainHTTP ? "http" : "https"
        case .elasticsearch, .minio, .mailpit, .mailhog, .clickhouse, .localstack: return "http"
        case .kafka, .memcached: return nil
        }
    }

    /// Whether the user and password belong in the URL. HTTP consoles take them separately.
    var credentialsInURL: Bool {
        switch kind {
        case .postgres, .mysql, .mariadb, .redis, .valkey, .mongodb, .rabbitmq, .nats: return true
        default: return false
        }
    }

    public static let mask = "••••••"

    /// The connection URL. With `revealPassword` false the password is replaced by dots; that's the only form that
    /// should ever be on screen unless the user asked to see it.
    public func url(revealPassword: Bool) -> String {
        let hostPort = "\(host.contains(":") ? "[\(host)]" : host):\(port)"
        guard let scheme else { return hostPort }
        var auth = ""
        if credentialsInURL {
            let u = user.map(Self.encode) ?? ""
            if let password, !password.isEmpty {
                auth = "\(u):\(revealPassword ? Self.encode(password) : Self.mask)@"
            } else if !u.isEmpty {
                auth = "\(u)@"
            }
        }
        var url = "\(scheme)://\(auth)\(hostPort)"
        if let database, !database.isEmpty {
            // RabbitMQ's default vhost "/" is spelled %2F in a URL.
            url += "/" + (database == "/" ? "%2F" : Self.encode(database))
        }
        if let query, !query.isEmpty { url += "?" + query }
        return url
    }

    /// Percent-encodes everything but unreserved characters, so `p@ss:word` can't break the URL.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public var hasPassword: Bool { !(password ?? "").isEmpty }

    // MARK: Building

    /// Connection details for a container, from the environment it was started with and its command line.
    /// `env` and `command` come from `docker inspect`; missing values fall back to each image's documented defaults.
    public static func forContainer(kind: ServiceKind, hostPort: Int, env: [String: String], command: [String] = []) -> ServiceConnection {
        func first(_ keys: [String]) -> String? {
            keys.lazy.compactMap { env[$0] }.first { !$0.isEmpty }
        }
        func hasFile(_ keys: [String]) -> Bool { keys.contains { env[$0 + "_FILE"].map { !$0.isEmpty } ?? false } }
        var c = ServiceConnection(kind: kind, port: hostPort)
        switch kind {
        case .postgres:
            let user = first(["POSTGRES_USER", "POSTGRESQL_USERNAME", "POSTGRESQL_USER"])
            c.user = user ?? "postgres"
            c.password = first(["POSTGRES_PASSWORD", "POSTGRESQL_PASSWORD"])
            c.database = first(["POSTGRES_DB", "POSTGRESQL_DATABASE"]) ?? c.user
            if user == nil { c.guessed.insert(.user) }
            if first(["POSTGRES_DB", "POSTGRESQL_DATABASE"]) == nil { c.guessed.insert(.database) }
            c.passwordInFile = c.password == nil && hasFile(["POSTGRES_PASSWORD", "POSTGRESQL_PASSWORD"])
        case .mysql, .mariadb:
            // An app user when one was created, otherwise root with the root password.
            let prefixes = kind == .mariadb ? ["MARIADB_", "MYSQL_"] : ["MYSQL_"]
            let appUser = first(prefixes.map { $0 + "USER" })
            if let appUser, appUser != "root" {
                c.user = appUser
                c.password = first(prefixes.map { $0 + "PASSWORD" })
                c.passwordInFile = c.password == nil && hasFile(prefixes.map { $0 + "PASSWORD" })
            } else {
                c.user = "root"
                c.password = first(prefixes.map { $0 + "ROOT_PASSWORD" })
                c.passwordInFile = c.password == nil && hasFile(prefixes.map { $0 + "ROOT_PASSWORD" })
                if appUser == nil { c.guessed.insert(.user) }
            }
            c.database = first(prefixes.map { $0 + "DATABASE" })
        case .redis, .valkey:
            c.password = first(["REDIS_PASSWORD", "VALKEY_PASSWORD"]) ?? argument("--requirepass", in: command)
            c.user = first(["REDIS_USERNAME", "VALKEY_USERNAME"]) ?? (c.password != nil ? "default" : nil)
            c.passwordInFile = c.password == nil && hasFile(["REDIS_PASSWORD", "VALKEY_PASSWORD"])
        case .mongodb:
            if let root = first(["MONGO_INITDB_ROOT_USERNAME"]) {
                c.user = root
                c.password = first(["MONGO_INITDB_ROOT_PASSWORD"])
                c.database = first(["MONGO_INITDB_DATABASE"])
                c.query = "authSource=admin"
            } else if let user = first(["MONGODB_USERNAME"]) {
                c.user = user
                c.password = first(["MONGODB_PASSWORD"])
                c.database = first(["MONGODB_DATABASE"])
            } else if let root = first(["MONGODB_ROOT_PASSWORD"]) {
                c.user = first(["MONGODB_ROOT_USER"]) ?? "root"
                c.password = root
                c.query = "authSource=admin"
            }
            c.passwordInFile = c.password == nil && hasFile(["MONGO_INITDB_ROOT_PASSWORD"])
        case .rabbitmq:
            let user = first(["RABBITMQ_DEFAULT_USER", "RABBITMQ_USERNAME"])
            let pass = first(["RABBITMQ_DEFAULT_PASS", "RABBITMQ_PASSWORD"])
            c.user = user ?? "guest"
            c.password = pass ?? "guest"
            c.database = first(["RABBITMQ_DEFAULT_VHOST"])
            if user == nil { c.guessed.insert(.user) }
            if pass == nil { c.guessed.insert(.password) }
        case .minio:
            let user = first(["MINIO_ROOT_USER", "MINIO_ACCESS_KEY"])
            let pass = first(["MINIO_ROOT_PASSWORD", "MINIO_SECRET_KEY"])
            c.user = user ?? "minioadmin"
            c.password = pass ?? "minioadmin"
            if user == nil { c.guessed.insert(.user) }
            if pass == nil { c.guessed.insert(.password) }
        case .elasticsearch:
            if let pass = first(["ELASTIC_PASSWORD"]) { c.user = "elastic"; c.password = pass }
        case .opensearch:
            if (env["DISABLE_SECURITY_PLUGIN"] ?? env["plugins.security.disabled"])?.lowercased() == "true" {
                c.plainHTTP = true
            } else {
                c.user = "admin"
                c.password = first(["OPENSEARCH_INITIAL_ADMIN_PASSWORD"]) ?? "admin"
                if first(["OPENSEARCH_INITIAL_ADMIN_PASSWORD"]) == nil { c.guessed.insert(.password) }
            }
        case .clickhouse:
            let user = first(["CLICKHOUSE_USER"])
            c.user = user ?? "default"
            c.password = first(["CLICKHOUSE_PASSWORD"])
            c.database = first(["CLICKHOUSE_DB"])
            if user == nil { c.guessed.insert(.user) }
        case .nats, .kafka, .memcached, .mailpit, .mailhog, .localstack:
            break
        }
        return c
    }

    /// A service running natively on the Mac (Homebrew, Postgres.app). There's no environment to read, so everything
    /// beyond host and port is the installer's default and marked as a guess.
    public static func forNative(kind: ServiceKind, port: Int, macUser: String) -> ServiceConnection {
        var c = ServiceConnection(kind: kind, port: port)
        switch kind {
        case .postgres:
            // Homebrew and Postgres.app create a superuser named after you, and a `postgres` database.
            c.user = macUser
            c.database = "postgres"
            c.guessed = [.user, .database]
        case .mysql, .mariadb:
            c.user = "root"
            c.guessed = [.user]
        case .rabbitmq:
            c.user = "guest"
            c.password = "guest"
            c.guessed = [.user, .password]
        case .minio:
            c.user = "minioadmin"
            c.password = "minioadmin"
            c.guessed = [.user, .password]
        default:
            break
        }
        return c
    }

    /// `--requirepass secret` or `--requirepass=secret` in a command line.
    static func argument(_ flag: String, in command: [String]) -> String? {
        for (i, arg) in command.enumerated() {
            if arg == flag, i + 1 < command.count { return command[i + 1] }
            if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
        }
        // A single shell string: `redis-server --requirepass secret`.
        for arg in command where arg.contains(flag + " ") {
            let words = arg.split(separator: " ").map(String.init)
            if let i = words.firstIndex(of: flag), i + 1 < words.count { return words[i + 1] }
        }
        return nil
    }
}
