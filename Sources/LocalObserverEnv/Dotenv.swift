import Foundation

/// One `KEY=value` from a dotenv file.
public struct DotenvEntry: Hashable, Sendable {
    public enum Quote: String, Sendable { case none, single, double, backtick }

    public var key: String
    /// The value as the app will see it: quotes removed, escapes applied in double quotes. Interpolation is not
    /// expanded; `references` lists what it would pull in.
    public var value: String
    /// 1-based line the entry starts on.
    public var line: Int
    public var quote: Quote
    public var exported: Bool
    /// Variables referenced as `${NAME}`, `${NAME:-default}` or `$NAME`, in order. Single-quoted values have none.
    public var references: [String]

    public init(key: String, value: String, line: Int, quote: Quote = .none, exported: Bool = false, references: [String] = []) {
        self.key = key
        self.value = value
        self.line = line
        self.quote = quote
        self.exported = exported
        self.references = references
    }
}

public struct DotenvIssue: Hashable, Sendable {
    public var line: Int
    public var message: String
    public init(line: Int, message: String) { self.line = line; self.message = message }
}

public struct DotenvFile: Hashable, Sendable {
    /// Every assignment in file order, duplicates included.
    public var entries: [DotenvEntry]
    public var issues: [DotenvIssue]

    public init(entries: [DotenvEntry] = [], issues: [DotenvIssue] = []) {
        self.entries = entries
        self.issues = issues
    }

    /// The assignment that wins for each key: the last one, as in dotenv.
    public var effective: [String: DotenvEntry] {
        var out: [String: DotenvEntry] = [:]
        for entry in entries { out[entry.key] = entry }
        return out
    }

    public var keys: [String] {
        var seen = Set<String>()
        return entries.map(\.key).filter { seen.insert($0).inserted }
    }

    /// Keys assigned more than once; the later line wins.
    public var duplicates: [String] {
        var seen = Set<String>(), dup: [String] = []
        for entry in entries where !seen.insert(entry.key).inserted && !dup.contains(entry.key) { dup.append(entry.key) }
        return dup
    }
}

/// A dotenv parser that follows the `dotenv` npm package (which Next.js and Vite load files with), so the value
/// shown is the value the app gets:
/// - `KEY=value`, optional `export ` prefix, spaces around `=` allowed, `KEY: value` accepted too.
/// - Unquoted values end at the first `#` and are trimmed.
/// - Single quotes and backticks are literal; double quotes turn `\n`, `\r`, `\t`, `\"`, `\\` and `\$` into the
///   character. Any of the three may span lines.
/// - `#` lines and blank lines are skipped. Later assignments of a key win.
/// - `${VAR}` / `$VAR` are recorded as references, not expanded (that's dotenv-expand's job, and showing the raw
///   text is more honest than guessing what it resolves to).
/// Anything it can't read becomes an issue with a line number rather than being silently dropped.
public enum Dotenv {
    public static func parse(_ text: String) -> DotenvFile {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var file = DotenvFile()
        var i = 0
        while i < lines.count {
            let number = i + 1
            var rest = Substring(lines[i]).drop { $0 == " " || $0 == "\t" }
            i += 1
            if rest.isEmpty || rest.hasPrefix("#") { continue }

            var exported = false
            if rest.hasPrefix("export"), let next = rest.dropFirst(6).first, next == " " || next == "\t" {
                exported = true
                rest = rest.dropFirst(6).drop { $0 == " " || $0 == "\t" }
            }
            let key = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
            guard !key.isEmpty, key.unicodeScalars.allSatisfy(\.isASCII) else {
                file.issues.append(DotenvIssue(line: number, message: "Line \(number) isn't KEY=value"))
                continue
            }
            rest = rest.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
            guard let separator = rest.first, separator == "=" || separator == ":" else {
                file.issues.append(DotenvIssue(line: number, message: rest.isEmpty
                                               ? "\(key) has no = and no value" : "Line \(number) isn't KEY=value"))
                continue
            }
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }

            if let q = rest.first, q == "\"" || q == "'" || q == "`" {
                let quote: DotenvEntry.Quote = q == "\"" ? .double : (q == "'" ? .single : .backtick)
                // Look for the closing quote, pulling in following lines if the value spans them.
                var body = String(rest.dropFirst())
                var consumed = 0
                var close = closingQuote(in: body, quote: q)
                while close == nil, i + consumed < lines.count {
                    body += "\n" + lines[i + consumed]
                    consumed += 1
                    close = closingQuote(in: body, quote: q)
                }
                guard let close else {
                    file.issues.append(DotenvIssue(line: number, message: "\(key) opens a \(quote.rawValue) quote that never closes"))
                    let raw = String(rest.dropFirst())
                    file.entries.append(DotenvEntry(key: String(key), value: raw, line: number, quote: .none, exported: exported,
                                                    references: quote == .single ? [] : references(raw)))
                    continue
                }
                i += consumed
                let raw = String(body[..<close])
                let after = body[body.index(after: close)...].drop { $0 == " " || $0 == "\t" }
                if !after.isEmpty, !after.hasPrefix("#") {
                    file.issues.append(DotenvIssue(line: number, message: "Text after \(key)'s closing quote is ignored"))
                }
                let value = quote == .double ? unescape(raw) : raw
                file.entries.append(DotenvEntry(key: String(key), value: value, line: number, quote: quote, exported: exported,
                                                references: quote == .single ? [] : references(raw)))
            } else {
                let raw = String(rest.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
                // `PASSWORD=abc#123` is "abc" to dotenv. Easy to miss, so say so.
                if let hash = rest.firstIndex(of: "#"), hash > rest.startIndex,
                   let before = rest[..<hash].last, before != " " && before != "\t" {
                    file.issues.append(DotenvIssue(line: number, message: "\(key)'s value stops at # (dotenv reads the rest as a comment); quote it to keep it"))
                }
                file.entries.append(DotenvEntry(key: String(key), value: raw, line: number, exported: exported, references: references(raw)))
            }
        }
        return file
    }

    /// Index of the closing quote. In double quotes a backslash escapes the next character.
    static func closingQuote(in text: String, quote: Character) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "\\", quote == "\"" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if c == quote { return index }
            index = text.index(after: index)
        }
        return nil
    }

    static func unescape(_ raw: String) -> String {
        var out = ""
        var escaping = false
        for c in raw {
            if escaping {
                switch c {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\"", "\\", "$": out.append(c)
                default: out.append("\\"); out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        if escaping { out.append("\\") }
        return out
    }

    /// `${NAME}`, `${NAME:-fallback}` and `$NAME`, skipping `\$`.
    static func references(_ raw: String) -> [String] {
        var out: [String] = []
        let chars = Array(raw)
        var i = 0
        func isName(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            guard chars[i] == "$", i + 1 < chars.count else { i += 1; continue }
            var j = i + 1
            if chars[j] == "{" {
                j += 1
                let start = j
                while j < chars.count, isName(chars[j]) { j += 1 }
                if j > start, j < chars.count, chars[j] == "}" || chars[j] == ":" || chars[j] == "-" {
                    out.append(String(chars[start..<j]))
                }
            } else if !chars[j].isNumber {
                let start = j
                while j < chars.count, isName(chars[j]) { j += 1 }
                if j > start { out.append(String(chars[start..<j])) }
            }
            i = max(j, i + 1)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}
