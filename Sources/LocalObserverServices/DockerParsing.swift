import Foundation

/// Reads what the docker CLI prints. Pure, so every quirk of its formats has a check.
public enum DockerParsing {
    /// `docker ps -a --format '{{json .}}'`: one JSON object per line. Lines that don't parse are skipped.
    public static func containers(_ text: String) -> [DockerContainer] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> DockerContainer? in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["ID"] as? String, !id.isEmpty else { return nil }
            let status = row["Status"] as? String ?? ""
            let state = (row["State"] as? String).flatMap { DockerState(rawValue: $0.lowercased()) } ?? state(fromStatus: status)
            // Names can be a comma list when a container has links; the first is its own.
            let name = (row["Names"] as? String ?? "").split(separator: ",").first.map(String.init) ?? id
            return DockerContainer(
                id: id, name: name.hasPrefix("/") ? String(name.dropFirst()) : name, image: row["Image"] as? String ?? "",
                state: state, status: status, ports: ports(row["Ports"] as? String ?? ""),
                labels: labels(row["Labels"] as? String ?? ""), createdAt: createdAt(row["CreatedAt"] as? String ?? ""),
                uptime: state.isUp ? uptime(status: status) : nil
            )
        }
    }

    /// Older engines leave out `State`; the status sentence still says it.
    static func state(fromStatus status: String) -> DockerState {
        let lower = status.lowercased()
        if lower.hasPrefix("up") { return lower.contains("(paused)") ? .paused : .running }
        if lower.hasPrefix("restarting") { return .restarting }
        if lower.hasPrefix("created") { return .created }
        if lower.hasPrefix("dead") { return .dead }
        if lower.hasPrefix("removal") { return .removing }
        return .exited
    }

    /// `0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 6379/tcp, 127.0.0.1:8000-8001->8000-8001/tcp`.
    /// IPv4 and IPv6 bindings of the same port collapse into one; small ranges are expanded.
    public static func ports(_ text: String) -> [DockerPort] {
        var out: [DockerPort] = []
        for raw in text.split(separator: ",") {
            let item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            let (mapping, proto) = splitProto(item)
            if let arrow = mapping.range(of: "->") {
                let host = String(mapping[..<arrow.lowerBound])
                let container = String(mapping[arrow.upperBound...])
                guard let colon = host.lastIndex(of: ":") else { continue }
                var ip = String(host[..<colon]).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                if ip.isEmpty || ip == "::" { ip = "0.0.0.0" }
                let hostRange = range(String(host[host.index(after: colon)...]))
                let containerRange = range(container)
                guard !hostRange.isEmpty, hostRange.count == containerRange.count else { continue }
                for (h, c) in zip(hostRange, containerRange) {
                    out.append(DockerPort(hostIP: ip, hostPort: h, containerPort: c, proto: proto))
                }
            } else {
                for c in range(mapping) { out.append(DockerPort(hostIP: nil, hostPort: nil, containerPort: c, proto: proto)) }
            }
        }
        // `0.0.0.0` and `::` are the same publish to a user; keep the first of each host/container/proto.
        var seen = Set<String>()
        return out.filter { port in
            let ip = port.hostIP == "0.0.0.0" ? "*" : (port.hostIP ?? "")
            return seen.insert("\(ip)|\(port.hostPort ?? -1)|\(port.containerPort)|\(port.proto)").inserted
        }
    }

    private static func splitProto(_ item: String) -> (String, String) {
        guard let slash = item.lastIndex(of: "/") else { return (item, "tcp") }
        return (String(item[..<slash]), String(item[item.index(after: slash)...]))
    }

    /// `8000` or `8000-8003`. Ranges wider than 64 ports are almost always a mistake; take only their first port.
    private static func range(_ text: String) -> [Int] {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard let first = parts.first else { return [] }
        guard parts.count == 2, parts[1] >= first else { return [first] }
        return parts[1] - first > 64 ? [first] : Array(first...parts[1])
    }

    /// `a=1,b=2`. Values may themselves contain `=`; commas inside values can't be told apart and split the label.
    public static func labels(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in text.split(separator: ",") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            out[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return out
    }

    /// `2024-05-01 10:00:00 +0200 CEST`.
    public static func createdAt(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: parts.prefix(3).joined(separator: " "))
    }

    /// "Up 2 hours (healthy)" → 7200. Docker rounds ("About an hour"), so this is only as exact as the sentence.
    public static func uptime(status: String) -> TimeInterval? {
        guard status.lowercased().hasPrefix("up ") else { return nil }
        var rest = String(status.dropFirst(3))
        if let paren = rest.firstIndex(of: "(") { rest = String(rest[..<paren]) }
        return duration(rest.trimmingCharacters(in: .whitespaces))
    }

    /// Docker's human durations: "Less than a second", "About a minute", "45 seconds", "3 hours", "2 weeks", "1 year".
    public static func duration(_ text: String) -> TimeInterval? {
        let lower = text.lowercased()
        if lower.hasPrefix("less than a second") { return 0 }
        let words = lower.split(separator: " ")
        guard words.count >= 2 else { return nil }
        let count: Double
        if words[0] == "about" || words[0] == "a" || words[0] == "an" {
            count = 1
        } else if let n = Double(words[0]) {
            count = n
        } else {
            return nil
        }
        let unit = words.last.map(String.init) ?? ""
        let seconds: Double
        switch unit.hasSuffix("s") ? String(unit.dropLast()) : unit {
        case "second": seconds = 1
        case "minute": seconds = 60
        case "hour": seconds = 3_600
        case "day": seconds = 86_400
        case "week": seconds = 604_800
        case "month": seconds = 2_592_000
        case "year": seconds = 31_536_000
        default: return nil
        }
        return count * seconds
    }

    /// `docker inspect <id>…`: a JSON array. Only the environment, the command and the start time are kept.
    public static func inspect(_ text: String) -> [String: DockerInspect] {
        guard let rows = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return [:] }
        var out: [String: DockerInspect] = [:]
        for row in rows {
            guard let id = row["Id"] as? String else { continue }
            let config = row["Config"] as? [String: Any] ?? [:]
            let state = row["State"] as? [String: Any] ?? [:]
            let entrypoint = config["Entrypoint"] as? [String] ?? []
            let cmd = config["Cmd"] as? [String] ?? []
            out[id] = DockerInspect(id: id, env: env(config["Env"] as? [String] ?? []), command: entrypoint + cmd,
                                    startedAt: (state["Running"] as? Bool ?? false) ? isoDate(state["StartedAt"] as? String ?? "") : nil)
        }
        return out
    }

    /// `["POSTGRES_USER=app", "PATH=/usr/bin"]` → dictionary. Later duplicates win, as in the container.
    public static func env(_ list: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for item in list {
            guard let eq = item.firstIndex(of: "=") else { continue }
            out[String(item[..<eq])] = String(item[item.index(after: eq)...])
        }
        return out
    }

    /// RFC 3339 with up to nanosecond fractions, which ISO8601DateFormatter can't read; the fraction is dropped.
    static func isoDate(_ text: String) -> Date? {
        guard !text.hasPrefix("0001") else { return nil }
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// `docker logs --timestamps` replays a container's stderr on its own stderr, so the two streams arrive apart.
    /// Each line starts with an RFC 3339 timestamp; merging on it restores the order they were written in.
    /// Lines without one (a stack trace's continuation) stay with the line before them.
    public static func logs(stdout: String, stderr: String) -> [DockerLogLine] {
        var lines: [(key: String, order: Int, line: DockerLogLine)] = []
        var order = 0
        for (text, isError) in [(stdout, false), (stderr, true)] {
            var lastKey = ""
            for raw in text.split(separator: "\n") {
                let line = String(raw)
                var key = lastKey
                var time: Date?
                var message = line
                if line.first?.isNumber == true, let space = line.firstIndex(of: " "),
                   let date = isoDate(String(line[..<space])) {
                    key = sortKey(String(line[..<space]))
                    time = date
                    message = String(line[line.index(after: space)...])
                }
                lastKey = key
                lines.append((key, order, DockerLogLine(time: time, text: message, isStderr: isError)))
                order += 1
            }
        }
        return lines.sorted { $0.key != $1.key ? $0.key < $1.key : $0.order < $1.order }.map(\.line)
    }

    /// Docker trims trailing zeros from the nanoseconds (`.5Z`, `.123Z`, or none at all); pad to nine digits so the
    /// timestamps sort as text.
    static func sortKey(_ stamp: String) -> String {
        guard stamp.hasSuffix("Z") else { return stamp }
        let body = stamp.dropLast()
        guard let dot = body.firstIndex(of: ".") else { return body + ".000000000Z" }
        let fraction = body[body.index(after: dot)...]
        return body[..<dot] + "." + fraction + String(repeating: "0", count: max(0, 9 - fraction.count)) + "Z"
    }
}

public struct DockerLogLine: Hashable, Sendable {
    public var time: Date?
    public var text: String
    public var isStderr: Bool

    public init(time: Date?, text: String, isStderr: Bool) {
        self.time = time
        self.text = text
        self.isStderr = isStderr
    }
}
