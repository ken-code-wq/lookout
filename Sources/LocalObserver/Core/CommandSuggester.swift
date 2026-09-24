import Foundation

/// Guesses start commands for a project folder.
enum CommandSuggester {
    struct Suggestion: Hashable, Identifiable {
        var label: String
        var command: String
        var id: String { command }
    }

    static func draft(for folder: String) -> LauncherDraft {
        var d = LauncherDraft()
        d.folder = folder
        d.name = (folder as NSString).lastPathComponent
        d.command = suggestions(for: folder).first?.command ?? ""
        return d
    }

    static func projectKind(_ folder: String) -> String? {
        let has = { (f: String) in FileManager.default.fileExists(atPath: folder + "/" + f) }
        if has("package.json") { return "Node project" }
        if has("manage.py") { return "Django project" }
        if has("pyproject.toml") || has("requirements.txt") { return "Python project" }
        if has("Gemfile") { return "Ruby project" }
        if has("Cargo.toml") { return "Rust project" }
        if has("go.mod") { return "Go project" }
        if has("docker-compose.yml") || has("compose.yaml") { return "Docker Compose" }
        if has("index.html") { return "Static site" }
        return nil
    }

    static func suggestions(for folder: String) -> [Suggestion] {
        guard !folder.isEmpty else { return [] }
        let fm = FileManager.default
        let has = { (f: String) in fm.fileExists(atPath: folder + "/" + f) }
        var out: [Suggestion] = []

        if has("package.json") {
            let runner: String
            if has("bun.lockb") || has("bun.lock") { runner = "bun" }
            else if has("pnpm-lock.yaml") { runner = "pnpm" }
            else if has("yarn.lock") { runner = "yarn" }
            else { runner = "npm" }

            let scripts = packageScripts(folder)
            for key in ["dev", "start", "serve", "preview", "develop"] where scripts[key] != nil {
                let cmd = runner == "npm" && key == "start" ? "npm start" : "\(runner) run \(key)"
                out.append(Suggestion(label: key, command: cmd))
            }
            if out.isEmpty { out.append(Suggestion(label: "start", command: "\(runner) start")) }
        }
        if has("manage.py") { out.append(Suggestion(label: "runserver", command: "python3 manage.py runserver")) }
        if has("Gemfile"), has("config.ru") || has("bin/rails") { out.append(Suggestion(label: "rails", command: "bin/rails server")) }
        if has("go.mod") { out.append(Suggestion(label: "go run", command: "go run .")) }
        if has("Cargo.toml") { out.append(Suggestion(label: "cargo run", command: "cargo run")) }
        if has("docker-compose.yml") || has("compose.yaml") { out.append(Suggestion(label: "compose", command: "docker compose up")) }
        if has("index.html") || out.isEmpty {
            out.append(Suggestion(label: "static", command: "python3 -m http.server 8000"))
        }
        return out
    }

    private static func packageScripts(_ folder: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: folder + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else { return [:] }
        return scripts
    }
}
