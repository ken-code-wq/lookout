import Foundation

/// A desktop app that can browse a service. Lookout only offers the ones that are installed.
public struct ServiceApp: Hashable, Sendable, Identifiable {
    public var name: String
    public var bundleIDs: [String]
    public var kinds: Set<ServiceKind>
    /// Opens a connection URL handed to it. Apps that don't get the URL on the clipboard instead.
    public var opensURL: Bool

    public var id: String { name }

    public static let all: [ServiceApp] = [
        ServiceApp(name: "TablePlus", bundleIDs: ["com.tinyapp.TablePlus", "com.tinyapp.TablePlus-setapp"],
                   kinds: [.postgres, .mysql, .mariadb, .redis, .valkey, .mongodb, .clickhouse], opensURL: true),
        ServiceApp(name: "Postico", bundleIDs: ["at.eggerapps.Postico2", "at.eggerapps.Postico"], kinds: [.postgres], opensURL: true),
        ServiceApp(name: "Sequel Ace", bundleIDs: ["com.sequel-ace.sequel-ace"], kinds: [.mysql, .mariadb], opensURL: true),
        ServiceApp(name: "DBeaver", bundleIDs: ["org.jkiss.dbeaver.core.product", "com.dbeaver.product"],
                   kinds: [.postgres, .mysql, .mariadb, .clickhouse, .mongodb], opensURL: false),
        ServiceApp(name: "DataGrip", bundleIDs: ["com.jetbrains.datagrip"],
                   kinds: [.postgres, .mysql, .mariadb, .clickhouse, .mongodb, .redis], opensURL: false),
        ServiceApp(name: "Beekeeper Studio", bundleIDs: ["io.beekeeperstudio.desktop"], kinds: [.postgres, .mysql, .mariadb], opensURL: false),
        ServiceApp(name: "Redis Insight", bundleIDs: ["org.RedisLabs.RedisInsight-V2", "com.redislabs.redisinsight"],
                   kinds: [.redis, .valkey], opensURL: false),
        ServiceApp(name: "MongoDB Compass", bundleIDs: ["com.mongodb.compass"], kinds: [.mongodb], opensURL: false),
    ]

    public static func apps(for kind: ServiceKind) -> [ServiceApp] { all.filter { $0.kinds.contains(kind) } }
}

/// The shell command that opens an interactive client for a service. Passwords are never put on the command line,
/// where they'd land in shell history; the clients prompt for them instead.
public enum ServiceShell {
    /// The client binary for a kind, as run on the Mac.
    public static func localBinary(_ kind: ServiceKind) -> String? {
        switch kind {
        case .postgres: return "psql"
        case .mysql: return "mysql"
        case .mariadb: return "mariadb"
        case .redis: return "redis-cli"
        case .valkey: return "valkey-cli"
        case .mongodb: return "mongosh"
        case .clickhouse: return "clickhouse"
        default: return nil
        }
    }

    /// The client binary inside the service's official image.
    public static func containerBinary(_ kind: ServiceKind) -> String? {
        kind == .clickhouse ? "clickhouse-client" : localBinary(kind)
    }

    /// Where Homebrew, Postgres.app and friends put client binaries. A GUI app's PATH has none of them.
    public static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/opt/libpq/bin", "/usr/local/opt/libpq/bin",
                                     "/Applications/Postgres.app/Contents/Versions/latest/bin", "/opt/homebrew/opt/mysql-client/bin",
                                     "/usr/local/mysql/bin", "/usr/bin"]

    public static func findLocal(_ binary: String, fileManager: FileManager = .default) -> String? {
        searchPaths.map { "\($0)/\(binary)" }.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// A client on the Mac: `psql -h localhost -p 5432 -U app app`.
    public static func local(_ c: ServiceConnection, binary: String) -> String {
        let q = quote
        switch c.kind {
        case .postgres:
            var args = [binary, "-h", c.host, "-p", "\(c.port)"]
            if let user = c.user { args += ["-U", q(user)] }
            if let db = c.database { args.append(q(db)) }
            return args.joined(separator: " ")
        case .mysql, .mariadb:
            var args = [binary, "-h", c.host == "localhost" ? "127.0.0.1" : c.host, "-P", "\(c.port)"]
            if let user = c.user { args += ["-u", q(user)] }
            if c.hasPassword || c.passwordInFile { args.append("-p") }
            if let db = c.database { args.append(q(db)) }
            return args.joined(separator: " ")
        case .redis, .valkey:
            var args = [binary, "-h", c.host, "-p", "\(c.port)"]
            if let user = c.user, user != "default" { args += ["--user", q(user)] }
            if c.hasPassword || c.passwordInFile { args.append("--askpass") }
            return args.joined(separator: " ")
        case .mongodb:
            // mongosh prompts for the password when the URL has a user but none.
            var safe = c
            safe.password = nil
            return "\(binary) \(q(safe.url(revealPassword: false)))"
        case .clickhouse:
            var args = [binary, "client", "--host", c.host]
            if let user = c.user { args += ["--user", q(user)] }
            if c.hasPassword { args.append("--ask-password") }
            return args.joined(separator: " ")
        default:
            return binary
        }
    }

    /// A client inside the container, so nothing needs installing on the Mac: `docker exec -it db psql -U app app`.
    public static func inContainer(_ c: ServiceConnection, container: String, docker: String = "docker") -> String? {
        let q = quote
        guard let binary = containerBinary(c.kind) else { return nil }
        let exec = "\(docker) exec -it \(q(container)) \(binary)"
        switch c.kind {
        case .postgres:
            // Inside the container, local connections are trusted by the official image, so no password prompt.
            var args = [exec]
            if let user = c.user { args += ["-U", q(user)] }
            if let db = c.database { args.append(q(db)) }
            return args.joined(separator: " ")
        case .mysql, .mariadb:
            var args = [exec]
            if let user = c.user { args += ["-u", q(user)] }
            if c.hasPassword || c.passwordInFile { args.append("-p") }
            if let db = c.database { args.append(q(db)) }
            return args.joined(separator: " ")
        case .redis, .valkey:
            var args = [exec]
            if let user = c.user, user != "default" { args += ["--user", q(user)] }
            if c.hasPassword || c.passwordInFile { args.append("--askpass") }
            return args.joined(separator: " ")
        case .mongodb:
            var args = [exec]
            if let user = c.user { args += ["-u", q(user)] }
            if c.query?.contains("authSource=admin") == true { args += ["--authenticationDatabase", "admin"] }
            if let db = c.database { args.append(q(db)) }
            return args.joined(separator: " ")
        case .clickhouse:
            return exec
        default:
            return nil
        }
    }

    /// Single-quotes anything that isn't plainly safe for zsh.
    public static func quote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@=,+%"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
