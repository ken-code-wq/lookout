import Foundation
import LocalObserverEnv

/// Env rules: the dotenv parser reads what the `dotenv` package reads (export, quotes, escapes, multiline, comments,
/// interpolation shown not expanded), files are classified by name, precedence follows Next.js or Vite, template
/// keys nothing sets are missing, values are masked to their shape, and git tracking is reported.
enum EnvChecks {
    static func run() {
        checkParser()
        checkMultilineAndIssues()
        checkInterpolation()
        checkRoles()
        checkPrecedence()
        checkMissingAndExtra()
        checkMasking()
        checkScanner()
    }

    private static func value(_ text: String, _ key: String) -> String? { Dotenv.parse(text).effective[key]?.value }

    private static func checkParser() {
        precondition(value("A=1", "A") == "1", "Plain")
        precondition(value("  A = spaced value  ", "A") == "spaced value", "Spaces around = and the value are trimmed")
        precondition(value("export A=1", "A") == "1" && Dotenv.parse("export A=1").entries[0].exported, "export prefix")
        precondition(value("exporter=1", "exporter") == "1", "A key starting with 'export' is still a key")
        precondition(value("A=", "A") == "", "Empty value")
        precondition(value("A=1 # comment", "A") == "1", "Inline comment")
        precondition(value("A=abc#def", "A") == "abc", "dotenv ends unquoted values at #")
        precondition(Dotenv.parse("A=abc#def").issues.count == 1, "…and that's flagged")
        precondition(value("A=\"abc#def\"", "A") == "abc#def", "Quoted # is kept")
        precondition(value("A='x # y' # c", "A") == "x # y", "Single quotes with a trailing comment")
        precondition(value("A='a\\nb'", "A") == "a\\nb", "Single quotes are literal")
        precondition(value("A=`it's \"fine\"`", "A") == "it's \"fine\"", "Backticks hold both quote kinds")
        precondition(value("A=\"a\\nb\\t\\\"q\\\" \\\\ \\$X\"", "A") == "a\nb\t\"q\" \\ $X", "Double-quote escapes")
        precondition(value("A=\"C:\\\\path\\\\x\"", "A") == "C:\\path\\x", "Escaped backslashes")
        precondition(value("A=\"\\w\"", "A") == "\\w", "Unknown escapes keep their backslash")
        precondition(value("A: yaml-ish", "A") == "yaml-ish", "KEY: value")
        precondition(value("a.b-c_D=1", "a.b-c_D") == "1", "Dots and dashes in keys")
        precondition(value("A=1\r\nB=2\r\n", "B") == "2", "CRLF")
        precondition(value("A=first\nA=second", "A") == "second", "Later assignments win")
        precondition(Dotenv.parse("A=1\nB=2\nA=3").duplicates == ["A"], "Duplicates are listed")
        precondition(Dotenv.parse("# only\n\n   # indented comment\n").entries.isEmpty, "Comments and blanks")
        precondition(Dotenv.parse("B=2\nA=1\nB=3").keys == ["B", "A"], "Keys in first-seen order")
        let entry = Dotenv.parse("\n\nKEY=\"v\"").entries[0]
        precondition(entry.line == 3 && entry.quote == .double, "Line numbers and quote style")
    }

    private static func checkMultilineAndIssues() {
        let pem = "KEY=\"-----BEGIN KEY-----\nabc\ndef\n-----END KEY-----\"\nNEXT=1"
        let parsed = Dotenv.parse(pem)
        precondition(parsed.effective["KEY"]?.value == "-----BEGIN KEY-----\nabc\ndef\n-----END KEY-----", "Multiline double quotes")
        precondition(parsed.effective["NEXT"]?.line == 5, "Parsing continues after a multiline value")
        precondition(value("A='one\ntwo'", "A") == "one\ntwo", "Multiline single quotes")
        precondition(value("A=\"one\\ntwo\"", "A") == "one\ntwo", "\\n in double quotes")

        let broken = Dotenv.parse("A=\"never closed\nB=2")
        precondition(broken.issues.contains { $0.line == 1 }, "Unclosed quote is reported")
        precondition(broken.effective["B"]?.value == "2", "…without swallowing the lines after it")
        precondition(Dotenv.parse("just some words\nB=2").issues.first?.line == 1, "Junk lines are reported with their number")
        precondition(Dotenv.parse("NOVALUE").issues.count == 1, "A bare key is reported")
        precondition(Dotenv.parse("A=\"x\" trailing").issues.count == 1 && value("A=\"x\" trailing", "A") == "x", "Text after the closing quote")
        precondition(Dotenv.parse("=value").issues.count == 1, "Missing key")
    }

    private static func checkInterpolation() {
        let parsed = Dotenv.parse("""
        URL=postgres://${DB_USER}:${DB_PASS:-secret}@$DB_HOST/db
        LITERAL='${NOT_EXPANDED}'
        ESCAPED=\\$HOME
        PRICE="costs $5"
        DQ="${A}-${A}"
        """)
        let e = parsed.effective
        precondition(e["URL"]?.value == "postgres://${DB_USER}:${DB_PASS:-secret}@$DB_HOST/db", "Interpolation is shown, not expanded")
        precondition(e["URL"]?.references == ["DB_USER", "DB_PASS", "DB_HOST"], "References (\(e["URL"]?.references ?? []))")
        precondition(e["LITERAL"]?.references == [], "Single quotes don't interpolate")
        precondition(e["ESCAPED"]?.references == [], "\\$ is not a reference")
        precondition(e["PRICE"]?.references == [], "$5 is not a variable")
        precondition(e["DQ"]?.references == ["A"], "References are listed once")
    }

    private static func checkRoles() {
        let cases: [(String, EnvFileRole?)] = [
            (".env", .base), (".env.local", .local), (".env.development", .mode("development")),
            (".env.production.local", .modeLocal("production")), (".env.example", .template), (".env.sample", .template),
            (".env.template", .template), (".env.production.example", .template), (".env.vault", .other), (".env.bak", .other),
            (".env.local.backup", .other), (".envrc", nil), (".environment", nil), ("env", nil), (".env.", nil),
        ]
        for (name, role) in cases { precondition(EnvFileRole.classify(name) == role, "Role of \(name)") }
    }

    private static func file(_ name: String, _ text: String, tracked: Bool? = false, ignored: Bool? = true) -> EnvFileInfo {
        EnvFileInfo(name: name, parsed: Dotenv.parse(text), tracked: tracked, ignored: ignored)
    }

    private static func checkPrecedence() {
        let files = [
            file(".env", "A=base\nB=base\nC=base\nD=base"),
            file(".env.local", "A=local\nB=local"),
            file(".env.development", "A=dev\nB=dev\nC=dev"),
            file(".env.development.local", "A=devlocal"),
            file(".env.production", "P=prod"),
        ]
        func effective(_ r: EnvReport, _ key: String) -> String? { r.keys.first { $0.key == key }?.effective?.entry.value }
        let next = EnvResolver.resolve(folder: "/x", files: files, mode: "development", convention: .nextjs)
        precondition(effective(next, "A") == "devlocal", ".env.[mode].local wins")
        precondition(effective(next, "B") == "local", "Next.js: .env.local beats .env.development")
        precondition(effective(next, "C") == "dev" && effective(next, "D") == "base", "Then mode, then .env")
        let b = next.keys.first { $0.key == "B" }!
        precondition(b.sources.map(\.file) == [".env.local", ".env.development", ".env"], "Overridden files in order")
        precondition(b.dependsOnConvention, "B differs between Next.js and Vite")
        precondition(next.keys.first { $0.key == "A" }!.dependsOnConvention == false, "A doesn't")
        precondition(next.keys.first { $0.key == "P" }!.status == .otherModeOnly, "Production-only keys aren't effective in development")

        let vite = EnvResolver.resolve(folder: "/x", files: files, mode: "development", convention: .vite)
        precondition(effective(vite, "B") == "dev", "Vite: .env.development beats .env.local")

        let test = EnvResolver.resolve(folder: "/x", files: files, mode: "test", convention: .nextjs)
        precondition(effective(test, "B") == "base", "Next.js skips .env.local in test")
        let prod = EnvResolver.resolve(folder: "/x", files: files, mode: "production", convention: .nextjs)
        precondition(effective(prod, "P") == "prod" && effective(prod, "B") == "local", "Production mode")
        precondition(EnvResolver.modes(in: files) == ["development", "production"], "Modes found in the folder")
    }

    private static func checkMissingAndExtra() {
        let files = [
            file(".env.example", "DATABASE_URL=\nSTRIPE_KEY=sk_test_placeholder\nSENTRY_DSN=\nEMPTY_OK=", tracked: true, ignored: false),
            file(".env", "DATABASE_URL=postgres://localhost/app\nEXTRA=1\nEMPTY_OK="),
            file(".env.production", "SENTRY_DSN=https://x@sentry.io/1"),
        ]
        let r = EnvResolver.resolve(folder: "/x", files: files)
        precondition(r.missing.map(\.key) == ["STRIPE_KEY"], "Missing: in the template, in no real file (\(r.missing.map(\.key)))")
        precondition(r.keys.first { $0.key == "SENTRY_DSN" }?.status == .otherModeOnly, "Set for production only is not missing")
        precondition(r.keys.first { $0.key == "EMPTY_OK" }?.status == .empty, "Set but empty")
        precondition(r.extra.map(\.key) == ["EXTRA"], "Extra: set but not in the template")
        precondition(r.keys.first?.key == "DATABASE_URL", "Template order first")
        precondition(r.warnings.isEmpty, "A tracked template is expected, not a warning (\(r.warnings.map(\.message)))")

        let none = EnvResolver.resolve(folder: "/x", files: [file(".env.example", "A=\nB=")])
        precondition(none.missing.count == 2 && !none.hasRealFiles, "Template only: everything missing")
        precondition(EnvResolver.resolve(folder: "/x", files: [file(".env", "A=1")]).extra.isEmpty, "No template, no extras")

        let leaky = EnvResolver.resolve(folder: "/x", files: [
            file(".env", "A=1", tracked: true, ignored: false),
            file(".env.local", "A=1", tracked: false, ignored: false),
            file(".env.development", "A=1", tracked: nil, ignored: nil),
            file(".env.example", "OPENAI_API_KEY=sk-proj-a8Fj3kLm9QzX2vB7nR4tY6wP1"),
        ])
        precondition(leaky.warnings.contains { $0.kind == .tracked && $0.file == ".env" }, "Tracked .env warns")
        precondition(leaky.warnings.contains { $0.kind == .notIgnored && $0.file == ".env.local" }, "Unignored .env.local warns")
        precondition(!leaky.warnings.contains { $0.file == ".env.development" && $0.kind != .parse }, "Outside git, no git warning")
        precondition(leaky.warnings.contains { $0.kind == .secretInTemplate }, "A real-looking key in a template warns")
    }

    private static func checkMasking() {
        precondition(EnvMask.shape("sk-proj-a8Fj3kLm9QzX2vB7nR4tY6wP1abcdefghij") == "sk-proj-…(43)", "Two-segment prefix")
        precondition(EnvMask.shape("sk_live_51HxYzABCDEFGHIJKLMNOP") == "sk_live_…(30)", "Stripe live prefix")
        precondition(EnvMask.shape("ghp_abcdefghijklmnopqrstuvwxyz0123456789") == "ghp_…(40)", "GitHub token")
        precondition(EnvMask.shape("postgresql://user:pw@localhost:5432/app") == "postgresql://…(39)", "URL scheme")
        precondition(EnvMask.shape("3000") == "…(4)", "Short values show only length")
        precondition(EnvMask.shape("abcdef0123456789abcdef0123456789") == "…(32)", "No prefix in a hex string")
        precondition(EnvMask.shape("") == "empty", "Empty")
        precondition(EnvMask.shape("line1\nline2\nline3") == "…(17, 3 lines)", "Multiline")
        let secret = "sk-proj-a8Fj3kLm9QzX2vB7nR4tY6wP1"
        precondition(!EnvMask.shape(secret).contains("a8Fj3"), "The shape never includes the secret part")
        precondition(!EnvMask.hidden.contains("s"), "Hidden is just dots")
        precondition(EnvMask.looksLikeSecret("ghp_abcdefghijklmnopqrstuvwxyz0123456789"), "Real-looking token")
        precondition(!EnvMask.looksLikeSecret("sk-your-key-here-xxxxxxxxxxxx"), "Placeholder")
        precondition(!EnvMask.looksLikeSecret("changeme"), "Short")
    }

    /// A throwaway folder with real files, a `.env` virtualenv impostor next to it, and git's verdicts.
    private static func checkScanner() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lookout-env-check-\(UUID().uuidString.prefix(8))").path
        defer { try? fm.removeItem(atPath: root) }
        try? fm.createDirectory(atPath: root + "/sub/.env", withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) { try? text.write(toFile: root + "/" + path, atomically: true, encoding: .utf8) }
        write(".env.example", "A=\nB=\n")
        write(".env", "A=1\n")
        write(".env.local", "B=2\n")
        write(".gitignore", ".env.local\n")
        write(".envrc", "export X=1\n")

        let outside = EnvScanner.scan(folder: root)
        precondition(Set(outside.map(\.name)) == [".env.example", ".env", ".env.local"], "Env files found (\(outside.map(\.name)))")
        precondition(outside.allSatisfy { $0.tracked == nil }, "Not a repository yet")
        precondition(EnvScanner.scan(folder: root + "/sub").isEmpty, "A .env folder (virtualenv) isn't an env file")

        let git = "/usr/bin/git"
        func run(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", root] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        run(["init", "-q"])
        run(["add", ".env", ".env.example"])
        let inside = Dictionary(uniqueKeysWithValues: EnvScanner.scan(folder: root).map { ($0.name, $0) })
        precondition(inside[".env"]?.tracked == true && inside[".env"]?.gitWarning == .tracked, "Tracked .env")
        precondition(inside[".env.local"]?.ignored == true && inside[".env.local"]?.gitWarning == nil, "Ignored .env.local is fine")
        precondition(inside[".env.example"]?.gitWarning == nil, "Templates never warn")
        let report = EnvResolver.resolve(folder: root, files: Array(inside.values))
        precondition(report.missing.isEmpty && report.keys.count == 2, "Both template keys set")
    }
}
