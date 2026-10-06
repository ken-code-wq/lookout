import Foundation
import LocalObserverServices

/// Services rules: docker's output formats parse (ports, labels, durations, inspect, logs), services are recognised
/// from image, process and port, connection URLs come from container env with the password masked, and shell
/// commands never carry a password.
enum ServiceChecks {
    static func run() {
        if ProcessInfo.processInfo.environment["DOCKER_LIST"] == "1" { listThisMac() }
        checkRecognition()
        checkPS()
        checkDurations()
        checkInspectAndLogs()
        checkConnections()
        checkShell()
        checkProbeReplies()
        checkAvailability()
    }

    /// `DOCKER_LIST=1`: what the Containers page would show on this Mac. Read-only; env values aren't printed.
    private static func listThisMac() {
        let (availability, list) = DockerClient.list()
        print("docker: \(availability), \(list.count) containers")
        for group in DockerGroup.group(list) {
            print("  \(group.title): \(group.running)/\(group.containers.count) running")
            for c in group.containers {
                print("    \(c.name) \(c.image) \(c.state.rawValue) \(c.ports.map(\.label)) kind=\(c.kind?.name ?? "-")")
            }
        }
    }

    private static func checkRecognition() {
        precondition(ServiceRecognizer.imageName("docker.io/library/postgres:16-alpine") == "postgres", "Registry and tag are dropped")
        precondition(ServiceRecognizer.imageName("localhost:5000/pgvector/pgvector@sha256:abc") == "pgvector", "Registry port and digest are dropped")
        precondition(ServiceRecognizer.kind(image: "bitnami/postgresql:15") == .postgres, "Bitnami Postgres")
        precondition(ServiceRecognizer.kind(image: "redis/redis-stack-server:latest") == .redis, "Redis Stack")
        precondition(ServiceRecognizer.kind(image: "mongo:7") == .mongodb, "Mongo image")
        precondition(ServiceRecognizer.kind(image: "axllent/mailpit") == .mailpit, "Mailpit")
        precondition(ServiceRecognizer.kind(image: "confluentinc/cp-kafka:7.6.0") == .kafka, "Confluent Kafka")
        precondition(ServiceRecognizer.kind(image: "node:20") == nil, "An app image isn't a service")

        precondition(ServiceRecognizer.kind(processName: "postgres", command: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16") == .postgres, "Native Postgres")
        precondition(ServiceRecognizer.kind(processName: "redis-server", command: "/opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379") == .redis, "Native Redis")
        precondition(ServiceRecognizer.kind(processName: "mysqld", command: "/opt/homebrew/opt/mariadb/bin/mysqld --basedir=/opt/homebrew/opt/mariadb") == .mariadb, "MariaDB's mysqld")
        precondition(ServiceRecognizer.kind(processName: "mysqld", command: "/usr/local/mysql/bin/mysqld --user=_mysql") == .mysql, "MySQL")
        precondition(ServiceRecognizer.kind(processName: "java", command: "java -cp x org.elasticsearch.bootstrap.Elasticsearch") == .elasticsearch, "Elasticsearch in a JVM")
        precondition(ServiceRecognizer.kind(processName: "node", command: "node server.js --port 5432") == nil, "A node server on 5432 is not Postgres")

        // The port only counts for container forwarders, and only for distinctive ports.
        let forwarded = ServiceRecognizer.recognize(processName: "com.docker.backend", command: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", port: 5432, image: nil)
        precondition(forwarded == .init(kind: .postgres, basis: .port), "Docker-forwarded 5432 is probably Postgres")
        precondition(ServiceRecognizer.recognize(processName: "com.docker.backend", command: "", port: 9000, image: nil) == nil, "9000 is too common to guess")
        precondition(ServiceRecognizer.recognize(processName: "node", command: "node", port: 5432, image: nil) == nil, "Ports aren't guessed for native processes")
        precondition(ServiceRecognizer.recognize(processName: "com.docker.backend", command: "", port: 5432, image: "redis:7")?.kind == .redis, "The image beats the port")
    }

    private static func checkPS() {
        let text = """
        {"Command":"\\"docker-entrypoint.s…\\"","CreatedAt":"2024-05-01 10:00:00 +0200 CEST","ID":"a1b2c3d4e5f6a1b2c3d4","Image":"postgres:16","Labels":"com.docker.compose.project=aurora,com.docker.compose.service=db,com.docker.compose.project.working_dir=/Users/dev/code/aurora","Names":"aurora-db-1","Ports":"0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp","RunningFor":"2 hours ago","State":"running","Status":"Up 2 hours (healthy)"}
        {"ID":"bbb","Image":"redis:7","Labels":"","Names":"cache","Ports":"6379/tcp","State":"exited","Status":"Exited (137) 3 days ago"}
        {"ID":"ccc","Image":"nginx","Labels":"","Names":"web","Ports":"127.0.0.1:8000-8002->80-82/tcp","Status":"Up About a minute"}
        not json
        """
        let list = DockerParsing.containers(text)
        precondition(list.count == 3, "Three containers, the junk line skipped")
        let db = list[0]
        precondition(db.ports == [DockerPort(hostIP: "0.0.0.0", hostPort: 5433, containerPort: 5432)], "IPv4 and IPv6 bindings collapse (\(db.ports))")
        precondition(db.primaryHostPort == 5433 && db.kind == .postgres, "Postgres on its published port")
        precondition(db.composeProject == "aurora" && db.composeService == "db" && db.composeFolder == "/Users/dev/code/aurora", "Compose labels")
        precondition(db.health == "healthy" && db.uptime == 7_200, "Health and uptime from the status")
        precondition(db.createdAt != nil, "CreatedAt parses")
        let cache = list[1]
        precondition(cache.state == .exited && cache.exitCode == 137 && cache.uptime == nil, "Exit code from the status")
        precondition(cache.ports == [DockerPort(hostPort: nil, containerPort: 6379)] && cache.primaryHostPort == nil, "Exposed but unpublished")
        let web = list[2]
        precondition(web.state == .running, "State falls back to the status sentence")
        precondition(web.ports.map(\.hostPort) == [8000, 8001, 8002] && web.ports.map(\.containerPort) == [80, 81, 82], "Port ranges expand")
        precondition(web.uptime == 60, "About a minute")

        let groups = DockerGroup.group(list)
        precondition(groups.map(\.title) == ["aurora", "Standalone"], "Compose projects first, standalone last")
        precondition(groups[1].containers.first?.name == "web", "Running containers sort before stopped ones")
        precondition(DockerParsing.labels("a=1,b=x=y") == ["a": "1", "b": "x=y"], "Label values keep their equals signs")
    }

    private static func checkDurations() {
        precondition(DockerParsing.duration("Less than a second") == 0, "Less than a second")
        precondition(DockerParsing.duration("45 seconds") == 45, "Seconds")
        precondition(DockerParsing.duration("About an hour") == 3_600, "About an hour")
        precondition(DockerParsing.duration("3 days") == 259_200, "Days")
        precondition(DockerParsing.duration("2 weeks") == 1_209_600, "Weeks")
        precondition(DockerParsing.duration("nonsense") == nil, "Unknown text")
        precondition(DockerParsing.uptime(status: "Up 5 minutes (Paused)") == 300, "Paused suffix")
        precondition(DockerParsing.uptime(status: "Exited (0) 2 hours ago") == nil, "Stopped containers have no uptime")
    }

    private static func checkInspectAndLogs() {
        let json = """
        [{"Id":"a1","Config":{"Env":["POSTGRES_USER=app","POSTGRES_PASSWORD=s3cret","PATH=/usr/bin","X=a=b"],"Cmd":["postgres"],"Entrypoint":["docker-entrypoint.sh"]},
          "State":{"Running":true,"StartedAt":"2024-05-01T08:00:00.123456789Z"}},
         {"Id":"b2","Config":{"Env":null},"State":{"Running":false,"StartedAt":"0001-01-01T00:00:00Z"}}]
        """
        let detail = DockerParsing.inspect(json)
        precondition(detail["a1"]?.env["POSTGRES_PASSWORD"] == "s3cret" && detail["a1"]?.env["X"] == "a=b", "Env values keep equals signs")
        precondition(detail["a1"]?.command == ["docker-entrypoint.sh", "postgres"], "Entrypoint then command")
        precondition(detail["a1"]?.startedAt == Date(timeIntervalSince1970: 1_714_550_400), "Nanosecond start time")
        precondition(detail["b2"]?.env.isEmpty == true && detail["b2"]?.startedAt == nil, "Stopped container, null env")

        // stderr arrives separately; timestamps put it back in place. Continuation lines stay with their line.
        let out = "2024-05-01T08:00:01.5Z ready\n2024-05-01T08:00:03Z done\n"
        let err = "2024-05-01T08:00:02.25Z warning: slow\n  at frame\n"
        let lines = DockerParsing.logs(stdout: out, stderr: err)
        precondition(lines.map(\.text) == ["ready", "warning: slow", "  at frame", "done"], "Logs merge by time (\(lines.map(\.text)))")
        precondition(lines[1].isStderr && !lines[0].isStderr && lines[2].time == nil, "Stream and time kept")
    }

    private static func checkConnections() {
        let pg = ServiceConnection.forContainer(kind: .postgres, hostPort: 5433,
                                                env: ["POSTGRES_USER": "app", "POSTGRES_PASSWORD": "p@ss:w/rd", "POSTGRES_DB": "aurora"])
        precondition(pg.url(revealPassword: false) == "postgresql://app:••••••@localhost:5433/aurora", "Masked by default (\(pg.url(revealPassword: false)))")
        precondition(pg.url(revealPassword: true) == "postgresql://app:p%40ss%3Aw%2Frd@localhost:5433/aurora", "Revealed and percent-encoded")
        precondition(!pg.url(revealPassword: false).contains("p@ss"), "The masked URL never contains the password")
        precondition(pg.guessed.isEmpty, "Everything read from the container")

        let bare = ServiceConnection.forContainer(kind: .postgres, hostPort: 5432, env: ["POSTGRES_PASSWORD_FILE": "/run/secrets/pg"])
        precondition(bare.user == "postgres" && bare.database == "postgres" && bare.guessed == [.user, .database], "Image defaults are marked")
        precondition(bare.passwordInFile && !bare.hasPassword, "A secret file is noted, not read")

        let mysql = ServiceConnection.forContainer(kind: .mysql, hostPort: 3306, env: ["MYSQL_ROOT_PASSWORD": "root", "MYSQL_DATABASE": "shop"])
        precondition(mysql.user == "root" && mysql.password == "root" && mysql.database == "shop", "MySQL root")
        let maria = ServiceConnection.forContainer(kind: .mariadb, hostPort: 3306, env: ["MARIADB_USER": "u", "MARIADB_PASSWORD": "pw"])
        precondition(maria.user == "u" && maria.password == "pw" && maria.scheme == "mysql", "MariaDB app user")

        let redis = ServiceConnection.forContainer(kind: .redis, hostPort: 6379, env: [:], command: ["redis-server", "--requirepass", "hunter2"])
        precondition(redis.password == "hunter2" && redis.url(revealPassword: false) == "redis://default:••••••@localhost:6379", "Redis password from the command line")
        let openRedis = ServiceConnection.forContainer(kind: .redis, hostPort: 6380, env: [:])
        precondition(openRedis.url(revealPassword: false) == "redis://localhost:6380", "Redis without auth")

        let mongo = ServiceConnection.forContainer(kind: .mongodb, hostPort: 27017,
                                                   env: ["MONGO_INITDB_ROOT_USERNAME": "root", "MONGO_INITDB_ROOT_PASSWORD": "x"])
        precondition(mongo.url(revealPassword: true) == "mongodb://root:x@localhost:27017?authSource=admin", "Mongo root authenticates against admin")
        let rabbit = ServiceConnection.forContainer(kind: .rabbitmq, hostPort: 5672, env: [:])
        precondition(rabbit.user == "guest" && rabbit.guessed.contains(.password), "RabbitMQ guest default")
        precondition(ServiceConnection(kind: .rabbitmq, port: 5672, database: "/").url(revealPassword: false) == "amqp://localhost:5672/%2F", "Default vhost encodes")
        precondition(ServiceConnection(kind: .kafka, port: 9092).url(revealPassword: true) == "localhost:9092", "Kafka is host:port")
        let minio = ServiceConnection.forContainer(kind: .minio, hostPort: 9000, env: ["MINIO_ROOT_USER": "a", "MINIO_ROOT_PASSWORD": "b"])
        precondition(minio.url(revealPassword: true) == "http://localhost:9000", "HTTP consoles keep credentials out of the URL")
        let search = ServiceConnection.forContainer(kind: .opensearch, hostPort: 9200, env: ["DISABLE_SECURITY_PLUGIN": "true"])
        precondition(search.scheme == "http", "OpenSearch without security is plain HTTP")

        let native = ServiceConnection.forNative(kind: .postgres, port: 5432, macUser: "dev")
        precondition(native.url(revealPassword: true) == "postgresql://dev@localhost:5432/postgres" && native.guessed == [.user, .database], "Native Postgres is a guess")
    }

    private static func checkShell() {
        let pg = ServiceConnection.forContainer(kind: .postgres, hostPort: 5433, env: ["POSTGRES_USER": "app", "POSTGRES_PASSWORD": "s3cret", "POSTGRES_DB": "my db"])
        precondition(ServiceShell.local(pg, binary: "psql") == "psql -h localhost -p 5433 -U app 'my db'", "Local psql (\(ServiceShell.local(pg, binary: "psql")))")
        precondition(ServiceShell.inContainer(pg, container: "aurora-db-1") == "docker exec -it aurora-db-1 psql -U app 'my db'", "psql in the container")
        let mysql = ServiceConnection.forContainer(kind: .mysql, hostPort: 3307, env: ["MYSQL_ROOT_PASSWORD": "s3cret"])
        precondition(ServiceShell.local(mysql, binary: "mysql") == "mysql -h 127.0.0.1 -P 3307 -u root -p", "mysql prompts")
        let redis = ServiceConnection.forContainer(kind: .redis, hostPort: 6379, env: ["REDIS_PASSWORD": "s3cret"])
        precondition(ServiceShell.local(redis, binary: "redis-cli") == "redis-cli -h localhost -p 6379 --askpass", "redis-cli asks")
        let mongo = ServiceConnection.forContainer(kind: .mongodb, hostPort: 27017, env: ["MONGO_INITDB_ROOT_USERNAME": "root", "MONGO_INITDB_ROOT_PASSWORD": "s3cret"])
        for command in [ServiceShell.local(pg, binary: "psql"), ServiceShell.inContainer(pg, container: "c") ?? "",
                        ServiceShell.local(mysql, binary: "mysql"), ServiceShell.inContainer(mysql, container: "c") ?? "",
                        ServiceShell.local(redis, binary: "redis-cli"), ServiceShell.local(mongo, binary: "mongosh"),
                        ServiceShell.inContainer(mongo, container: "c") ?? ""] {
            precondition(!command.contains("s3cret"), "A password reached a shell command: \(command)")
        }
        precondition(ServiceShell.inContainer(ServiceConnection(kind: .kafka, port: 9092), container: "k") == nil, "No shell client for Kafka")
        precondition(ServiceShell.quote("it's") == "'it'\\''s'", "Single quotes escape")
    }

    private static func checkProbeReplies() {
        precondition(ServiceProbe.interpretRedis(Array("+PONG\r\n".utf8), ms: 1) == .responding(detail: "Responding (PONG)", ms: 1), "PONG")
        precondition(ServiceProbe.interpretRedis(Array("-NOAUTH Authentication required.\r\n".utf8), ms: 1) == .needsAuth(ms: 1), "NOAUTH is alive")
        precondition(ServiceProbe.interpretRedis(Array("HTTP/1.1 400".utf8), ms: 1) == .unexpected(ms: 1), "Not Redis")
        precondition(ServiceProbe.interpretPostgres([UInt8(ascii: "N")], ms: 2) == .responding(detail: "Responding", ms: 2), "Postgres without SSL")
        precondition(ServiceProbe.interpretPostgres([UInt8(ascii: "S")], ms: 2).isAlive, "Postgres with SSL")
        let greeting: [UInt8] = [0x4a, 0, 0, 0, 10] + Array("8.4.0".utf8) + [0, 1, 2]
        precondition(ServiceProbe.interpretMySQL(greeting, ms: 3) == .responding(detail: "Responding (8.4.0)", ms: 3), "MySQL greeting version")
        precondition(ServiceProbe.interpretMySQL([0x10, 0, 0, 0, 0xFF, 0x6a, 0x04], ms: 3).isAlive, "MySQL error packet still means MySQL")
        precondition(!ServiceLiveness.refused.isAlive && !ServiceLiveness.timedOut.isAlive, "Dead states")
        // A port nothing listens on is refused, quickly.
        precondition(!ServiceProbe.check(kind: .redis, port: 1, timeout: 0.5).isAlive, "Closed port")
    }

    private static func checkAvailability() {
        precondition(DockerAvailability.classify(status: 1, stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n")
                        == .daemonDown("Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"), "Daemon down")
        precondition(DockerAvailability.classify(status: 0, stderr: "") == .ready, "Ready")
        if case .failed = DockerAvailability.classify(status: 125, stderr: "unknown flag: --format") {} else { preconditionFailure("Other failures stay failures") }
    }
}
