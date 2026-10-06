import Foundation
import LocalObserverCore
import LocalObserverHooks

/// Agent hooks: parsing what agents send, the answers Claude Code expects, merging Lookout's entries into config
/// files without disturbing anything else, hook states beating inference, and the socket round trip.
enum HookChecks {
    static func run() {
        checkParsing()
        checkResponses()
        checkClaudeConfig()
        checkCodexConfig()
        checkConfigFile()
        checkOverlay()
        checkTerminalScript()
        checkSocket()
    }

    private static func event(_ json: String, pids: [Int32] = []) -> HookEvent {
        let payload = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        let line = HookEvent.envelope(agent: .claude, payload: payload, pids: pids)!
        guard let event = HookEvent.parse(envelope: line) else { preconditionFailure("Envelope round trip: \(json)") }
        return event
    }

    private static let bashRequest = #"{"session_id":"s1","cwd":"/p/app","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test","description":"Run the tests"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test"}],"behavior":"allow","destination":"localSettings"}]}"#

    private static func checkParsing() {
        let request = event(bashRequest, pids: [300, 200])
        precondition(request.kind == .permissionRequest && request.awaitsDecision && request.signal == .needsYou, "PermissionRequest parsing")
        precondition(request.sessionID == "s1" && request.cwd == "/p/app" && request.pids == [300, 200], "Common fields and pids survive the envelope")
        precondition(request.preview?.body == .command("npm test") && request.preview?.detail == "Run the tests", "Bash preview")
        precondition(request.suggestions != nil, "Permission suggestions kept for Always allow")

        let edit = HookToolPreview(tool: "Edit", input: ["file_path": "/p/a.swift", "old_string": "a", "new_string": "b"])
        precondition(edit.title == "Edit a.swift" && edit.body == .edit(path: "/p/a.swift", old: "a", new: "b"), "Edit preview")
        let multi = HookToolPreview(tool: "MultiEdit", input: ["file_path": "/p/a.swift", "edits": [["old_string": "x", "new_string": "y"], ["old_string": "1", "new_string": "2"]]])
        precondition(multi.detail == "2 changes" && multi.body == .edit(path: "/p/a.swift", old: "x", new: "y"), "MultiEdit previews its first change")
        precondition(HookToolPreview(tool: "mcp__github__create_issue", input: ["title": "Bug"]).title == "Use github: create issue", "MCP tool titles")
        precondition(HookToolPreview(tool: "Bash", input: ["command": "a\nb"]).subject == "a …", "Multi-line commands show their first line")

        precondition(event(#"{"session_id":"s","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission"}"#).signal == .needsYou, "Permission prompt notification")
        precondition(event(#"{"session_id":"s","hook_event_name":"Notification","notification_type":"idle_prompt"}"#).signal == .yourTurn, "Idle notification")
        precondition(event(#"{"session_id":"s","hook_event_name":"Notification","notification_type":"auth_success"}"#).signal == nil, "Other notifications say nothing")
        let stop = event(#"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"Done."}"#)
        precondition(stop.signal == .yourTurn && stop.message == "Done.", "Stop hands the turn back with the last message")
        precondition(event(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#).signal == .working, "Prompt starts work")
        precondition(event(#"{"session_id":"s","hook_event_name":"SessionStart","source":"compact"}"#).signal == nil, "Compaction isn't a new turn")
        precondition(event(#"{"session_id":"s","hook_event_name":"SessionEnd"}"#).signal == .ended, "Session end")

        let codex = HookEvent.parse(agent: .codex, payload: ["type": "agent-turn-complete", "thread-id": "t1", "cwd": "/p", "last-assistant-message": "Fixed it"])
        precondition(codex?.kind == .turnComplete && codex?.sessionID == "t1" && codex?.signal == .yourTurn && codex?.message == "Fixed it", "Codex notify payload")
        precondition(HookEvent.parse(envelope: Data("not json".utf8)) == nil, "Garbage is ignored")
    }

    private static func decision(_ data: Data?) -> [String: Any] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["hookSpecificOutput"] as? [String: Any],
              output["hookEventName"] as? String == "PermissionRequest",
              let decision = output["decision"] as? [String: Any] else { preconditionFailure("PermissionRequest output shape") }
        return decision
    }

    private static func checkResponses() {
        let request = event(bashRequest)
        precondition(HookResponse.claudePermission(nil, for: request) == nil, "No decision prints nothing")
        precondition(decision(HookResponse.claudePermission(.allow, for: request))["behavior"] as? String == "allow", "Allow")
        let deny = decision(HookResponse.claudePermission(.deny, for: request))
        precondition(deny["behavior"] as? String == "deny" && deny["message"] is String && deny["updatedPermissions"] == nil, "Deny explains itself")
        let always = decision(HookResponse.claudePermission(.alwaysAllow, for: request))
        let updates = always["updatedPermissions"] as? [[String: Any]] ?? []
        precondition(always["behavior"] as? String == "allow" && updates.count == 1 && updates[0]["destination"] as? String == "localSettings",
                     "Always allow echoes Claude Code's own suggestion")

        // No suggestions: an exact Bash rule in local settings; other tools only for the session.
        let bare = event(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make"}}"#)
        let rule = HookAlwaysAllow(event: bare)
        let rules = rule.updates.first?["rules"] as? [[String: Any]]
        precondition(rule.updates.first?["type"] as? String == "addRules" && rules?.first?["ruleContent"] as? String == "make"
                     && rule.updates.first?["destination"] as? String == "localSettings", "Fallback Bash rule")
        precondition(rule.summary == "Allow Bash(make) in this project", "Always allow says what it saves: \(rule.summary)")
        let write = HookAlwaysAllow(event: event(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"file_path":"/a","content":"x"}}"#))
        precondition(write.updates.first?["destination"] as? String == "session", "Non-Bash fallback stays in the session")
        let bypass = event(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"permission_suggestions":[{"type":"setMode","mode":"bypassPermissions","destination":"session"}]}"#)
        let filtered = HookAlwaysAllow(event: bypass).updates
        precondition(!filtered.contains { $0["mode"] as? String == "bypassPermissions" }, "One click never turns on bypass mode")
        precondition(JSONSerialization.isValidJSONObject(["u": HookAlwaysAllow(event: request).updates]), "Updates serialize")
    }

    private static func checkClaudeConfig() {
        let command = HookHelper.command(helperPath: "/Applications/Look out.app/Contents/MacOS/lookout-hook", agent: .claude)
        precondition(command == "'/Applications/Look out.app/Contents/MacOS/lookout-hook' claude", "Helper path is shell-quoted")
        let original = try! ClaudeHookConfig.parse("""
        {"model":"opus","permissions":{"allow":["Bash(ls)"]},
         "hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],
                  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"}]}]}}
        """)
        precondition(ClaudeHookConfig.status(original, command: command) == .notConnected, "Fresh settings aren't connected")
        let installed = ClaudeHookConfig.install(original, command: command)
        precondition(ClaudeHookConfig.status(installed, command: command) == .connected, "Installed settings are connected")
        precondition(installed["model"] as? String == "opus" && (installed["permissions"] as? [String: Any]) != nil, "Other settings untouched")
        let hooks = installed["hooks"] as! [String: Any]
        precondition((hooks["Stop"] as! [Any]).count == 2 && (hooks["PreToolUse"] as! [Any]).count == 1, "Other hooks kept alongside Lookout's")
        let permission = (hooks["PermissionRequest"] as! [[String: Any]])[0]
        precondition(permission["matcher"] as? String == "*", "Permission requests for every tool")
        precondition(NSDictionary(dictionary: ClaudeHookConfig.install(installed, command: command)).isEqual(to: installed), "Installing twice changes nothing")
        let moved = HookHelper.command(helperPath: "/tmp/lookout-hook", agent: .claude)
        precondition(ClaudeHookConfig.status(installed, command: moved) == .outdated, "Another helper path reads as outdated")
        let updated = ClaudeHookConfig.install(installed, command: moved)
        precondition(ClaudeHookConfig.status(updated, command: moved) == .connected && ClaudeHookConfig.status(updated, command: command) == .outdated,
                     "Updating replaces the old entries")
        let removed = ClaudeHookConfig.uninstall(updated)
        precondition(NSDictionary(dictionary: removed).isEqual(to: original), "Disconnecting restores the original settings")
        precondition(NSDictionary(dictionary: ClaudeHookConfig.uninstall(original)).isEqual(to: original), "Disconnecting unconnected settings is a no-op")
        let empty = ClaudeHookConfig.uninstall(ClaudeHookConfig.install([:], command: command))
        precondition(empty.isEmpty, "An empty file goes back to empty, without a leftover hooks key")
        do { _ = try ClaudeHookConfig.parse("[1,2]"); preconditionFailure("A JSON array isn't settings") } catch {}
    }

    private static func checkCodexConfig() {
        let path = "/Applications/Lookout.app/Contents/MacOS/lookout-hook"
        let original = "model = \"gpt-5-codex\"\n\n[profiles.fast]\nnotify = [\"other\"]\n"
        precondition(CodexNotifyConfig.status(original, helperPath: path) == .notConnected, "A notify inside a table isn't top-level")
        let installed = try! CodexNotifyConfig.install(original, helperPath: path)
        precondition(installed.hasPrefix(CodexNotifyConfig.marker + "\nnotify = [\"\(path)\", \"codex\"]\n"), "notify goes at the top level: \(installed)")
        precondition(CodexNotifyConfig.status(installed, helperPath: path) == .connected, "Codex connected")
        precondition(try! CodexNotifyConfig.install(installed, helperPath: path) == installed, "Codex install is idempotent")
        precondition(CodexNotifyConfig.status(installed, helperPath: "/tmp/lookout-hook") == .outdated, "Codex outdated path")
        precondition(CodexNotifyConfig.uninstall(installed) == original, "Codex disconnect restores the file exactly")
        precondition(CodexNotifyConfig.uninstall(try! CodexNotifyConfig.install("", helperPath: path)) == "", "Empty config round trip")

        let taken = "notify = [\n  \"/usr/local/bin/notifier\",\n  \"--flag\" # mine\n]\nmodel = \"o3\"\n"
        precondition(CodexNotifyConfig.status(taken, helperPath: path) == .conflict("notifier"), "Someone else's notify is a conflict")
        precondition(CodexNotifyConfig.findNotify(taken)?.lines == 0..<4, "Multi-line notify arrays are read whole")
        do { _ = try CodexNotifyConfig.install(taken, helperPath: path); preconditionFailure("Must not replace another notify") } catch {}
        precondition(CodexNotifyConfig.uninstall(taken) == taken, "Disconnect leaves someone else's notify alone")
    }

    private static func checkConfigFile() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hook-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".claude/settings.json")
        let created = try! HookConfigFile.update(url) { _ in "{}\n" }
        precondition(created == nil && (try? HookConfigFile.read(url)) == "{}\n", "A missing file is created without a backup")
        let backup = try! HookConfigFile.update(url) { _ in "{\"a\":1}\n" }
        precondition(backup.map { (try? String(contentsOf: $0, encoding: .utf8)) == "{}\n" } == true, "The previous file is backed up")
        precondition(try! HookConfigFile.update(url) { $0 } == nil, "No change, no write")
    }

    private static func checkOverlay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func session(_ id: String, pid: Int32, sessionID: String, cwd: String, updated: TimeInterval) -> AgentSession {
            AgentSession(id: id, agent: .claude, sessionID: sessionID, title: "t",
                         process: AgentProcess(pid: pid, parentPID: 1, processName: "claude", executablePath: "", workingDirectory: cwd,
                                               startedAt: now.addingTimeInterval(-600), terminal: "ttys001"),
                         projectPath: cwd, projectName: (cwd as NSString).lastPathComponent, model: "", account: "", branch: "",
                         state: .working, startedAt: now.addingTimeInterval(-600), updatedAt: now.addingTimeInterval(updated),
                         sourcePath: "", sourceKind: .process, usage: nil, cost: nil, requests: nil)
        }
        let a = session("a", pid: 200, sessionID: "uuid-a", cwd: "/p/app", updated: -5)
        let b = session("b", pid: 201, sessionID: "uuid-b", cwd: "/p/app", updated: -1)
        let all = [a, b]
        precondition(AgentHookOverlay.match(agent: .claude, pids: [300, 200], sessionID: "uuid-b", cwd: "/p/app", in: all)?.id == "a", "The process tree names the session first")
        precondition(AgentHookOverlay.match(agent: .claude, pids: [], sessionID: "uuid-a", cwd: "/p/app", in: all)?.id == "a", "Then the agent's session id")
        precondition(AgentHookOverlay.match(agent: .claude, pids: [], sessionID: "new", cwd: "/p/app", in: all)?.id == "b", "Then the newest session in the folder")
        precondition(AgentHookOverlay.match(agent: .codex, pids: [200], sessionID: "", cwd: "/p/app", in: all) == nil, "Never another agent's session")

        let fresh = AgentHookOverlay.apply(["a": AgentHookState(state: .waiting, at: now)], to: all)
        precondition(fresh[0].state == .waiting && fresh[0].stateSource == .hook && fresh[1].stateSource == .inferred, "A fresh hook state wins")
        let stale = AgentHookOverlay.apply(["b": AgentHookState(state: .waiting, at: now.addingTimeInterval(-60))], to: all)
        precondition(stale[1].state == .working && stale[1].stateSource == .inferred, "A transcript newer than the hook wins")
        let pinned = AgentHookOverlay.apply(["b": AgentHookState(state: .needsInput, at: now.addingTimeInterval(-60), pinned: true)], to: all)
        precondition(pinned[1].state == .needsInput && pinned[1].needsAttention, "A waiting request holds Needs you")
    }

    private static func checkTerminalScript() {
        precondition(TerminalScript.quoted(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#, "AppleScript quoting")
        precondition(TerminalScript.singleLine("fix it\n\n  and test ") == "fix it and test", "Replies are one line")
        precondition(TerminalScript.reply("x", tty: "/dev/ttys001", bundleID: TerminalScript.iTermBundleID)?.contains("write text \"x\"") == true, "iTerm2 script")
        precondition(TerminalScript.reply("x", tty: "/dev/ttys001", bundleID: TerminalScript.terminalBundleID)?.contains("do script \"x\" in t") == true, "Terminal script")
        precondition(TerminalScript.reply("x", tty: "/dev/ttys001", bundleID: "com.mitchellh.ghostty") == nil, "Other hosts fall back to the clipboard")
    }

    /// A real socket in /tmp: an answered request, an unanswered one, and no app at all.
    private static func checkSocket() {
        let path = "/tmp/lookout-check-\(getpid()).sock"
        precondition(HookClient.send(Data("{}".utf8), to: path, wait: 1) == nil, "No app running: the helper gets nothing, at once")
        let server = HookServer(path: path) { line, connection in
            guard let event = HookEvent.parse(envelope: line) else { connection.reply(nil); return }
            connection.reply(event.awaitsDecision && event.sessionID == "s1" ? HookResponse.claudePermission(.allow, for: event) : nil)
        }
        do { try server.start() } catch { preconditionFailure("Hook server didn't start: \(error)") }
        defer { server.stop() }
        let payload = try! JSONSerialization.jsonObject(with: Data(bashRequest.utf8))
        let line = HookEvent.envelope(agent: .claude, payload: payload, pids: [1234])!
        let reply = HookClient.send(line, to: path, wait: 5)
        precondition(decision(reply)["behavior"] as? String == "allow", "Socket round trip returns the decision")
        let other = HookEvent.envelope(agent: .claude, payload: ["session_id": "s2", "hook_event_name": "PermissionRequest", "tool_name": "Bash"], pids: [])!
        precondition(HookClient.send(other, to: path, wait: 5) == nil, "Hanging up means no decision")
        let second = HookServer(path: path) { _, connection in connection.reply(nil) }
        do { try second.start(); preconditionFailure("A second listener must not steal the socket") } catch {
            precondition(error as? HookSocket.Failure == .inUse, "Second listener reports the socket in use")
        }
    }
}
