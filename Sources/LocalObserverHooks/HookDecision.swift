import Foundation

/// The user's answer to a permission request.
public enum HookDecision: Hashable, Sendable {
    case allow
    case deny
    /// Allow, and stop asking for this kind of call (see `HookAlwaysAllow`).
    case alwaysAllow
}

/// What "Always allow" will save, so the button can say so before it's pressed.
public struct HookAlwaysAllow {
    /// Permission update entries in Claude Code's `updatedPermissions` format.
    public var updates: [[String: Any]]
    /// "Allow Bash(npm test) in this project", for the button's tooltip.
    public var summary: String

    /// Claude Code's own suggestions win: they're what its terminal dialog offers as "don't ask again". Without any,
    /// a Bash call gets an exact-command rule in the project's local settings, and anything else is allowed for the
    /// rest of the session only, since a whole-tool rule (all edits, all fetches) is broader than one click should grant.
    public init(event: HookEvent) {
        if let data = event.suggestions,
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let usable = list.filter { entry in
                // Never let one click switch on bypass mode, even if it's suggested.
                (entry["mode"] as? String) != "bypassPermissions" && entry["type"] is String
            }
            if !usable.isEmpty {
                updates = usable
                summary = usable.map(Self.describe).joined(separator: "; ")
                return
            }
        }
        let tool = event.toolName.isEmpty ? "this tool" : event.toolName
        if event.toolName == "Bash", case .command(let command)? = event.preview?.body, !command.isEmpty, !command.contains("\n") {
            let rule: [String: Any] = ["toolName": "Bash", "ruleContent": command]
            updates = [["type": "addRules", "rules": [rule], "behavior": "allow", "destination": "localSettings"]]
            summary = "Allow Bash(\(command)) in this project"
        } else {
            let rule: [String: Any] = ["toolName": event.toolName]
            updates = event.toolName.isEmpty ? [] : [["type": "addRules", "rules": [rule], "behavior": "allow", "destination": "session"]]
            summary = "Allow \(tool) for the rest of this session"
        }
    }

    static func describe(_ entry: [String: Any]) -> String {
        let place: String
        switch entry["destination"] as? String {
        case "session": place = "for this session"
        case "localSettings": place = "in this project (local settings)"
        case "projectSettings": place = "in this project (shared settings)"
        case "userSettings": place = "everywhere"
        default: place = ""
        }
        switch entry["type"] as? String {
        case "addRules":
            let rules = (entry["rules"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map { rule -> String in
                let tool = rule["toolName"] as? String ?? "?"
                return (rule["ruleContent"] as? String).map { "\(tool)(\($0))" } ?? tool
            }
            return "Allow \(rules.joined(separator: ", ")) \(place)".trimmingCharacters(in: .whitespaces)
        case "setMode":
            let mode = entry["mode"] as? String ?? ""
            return mode == "acceptEdits" ? "Accept edits \(place)".trimmingCharacters(in: .whitespaces) : "Switch to \(mode) mode \(place)"
        case "addDirectories":
            let dirs = (entry["directories"] as? [String] ?? []).map { ($0 as NSString).lastPathComponent }
            return "Allow access to \(dirs.joined(separator: ", ")) \(place)".trimmingCharacters(in: .whitespaces)
        default:
            return "Save a permission rule \(place)".trimmingCharacters(in: .whitespaces)
        }
    }
}

/// What `lookout-hook` prints back to the agent.
public enum HookResponse {
    /// Claude Code's PermissionRequest decision:
    /// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny",…}}}`.
    /// Nil means "no decision": the helper prints nothing and the agent shows its own prompt.
    public static func claudePermission(_ decision: HookDecision?, for event: HookEvent) -> Data? {
        guard let decision else { return nil }
        var body: [String: Any]
        switch decision {
        case .allow:
            body = ["behavior": "allow"]
        case .deny:
            body = ["behavior": "deny", "message": "The user denied this from Lookout."]
        case .alwaysAllow:
            body = ["behavior": "allow"]
            let updates = HookAlwaysAllow(event: event).updates
            if !updates.isEmpty { body["updatedPermissions"] = updates }
        }
        let object: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
