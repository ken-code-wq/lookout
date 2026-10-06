import AppKit
import LocalObserverCore

// `lookout`: Lookout from the terminal, Raycast script commands, or Shortcuts' "Run Shell Script".
// It reads the snapshot the app writes for its widgets and asks the app to act through lookout:// links,
// so it never scans anything itself and needs no IPC of its own.

let usage = """
usage: lookout <command> [--json]

  status              agents, plan limits and servers
  agents              running agent sessions
  limits              plan-limit windows and what's left
  servers             listening dev servers
  open <page>         open a page: \(LookoutPage.allCases.map(\.rawValue).joined(separator: ", "))
  launcher start|stop|toggle <name>
  palette             open the ⌘K palette
  task                start a new agent task
  weekly              open the weekly report
  timer <minutes>|stop
  awake on|off|toggle keep the Mac awake
  refresh             rescan agents, limits and servers

Reads what Lookout last published; the app has to be running for it to stay current.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// Hands a route to the app. `-g` keeps it in the background unless the route is about showing something.
func send(_ route: LookoutRoute, foreground: Bool = false) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = (foreground ? [] : ["-g"]) + [route.url.absoluteString]
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("Couldn't run open: \(error.localizedDescription)") }
    process.waitUntilExit()
    if process.terminationStatus != 0 { fail("Lookout isn't installed, or macOS doesn't know it handles lookout:// links yet. Open the app once.") }
}

func loadStatus() -> LookoutStatus {
    guard let status = LookoutStatus.load() else {
        fail("No status from Lookout yet. Open Lookout and give it a few seconds.", code: 2)
    }
    let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.localobserver.app").isEmpty
    if !running || status.stale {
        let age = Int(Date().timeIntervalSince(status.generatedAt) / 60)
        FileHandle.standardError.write(Data("note: \(running ? "" : "Lookout isn't running; ")showing data from \(age) min ago\n".utf8))
    }
    return status
}

func printJSON<T: Encodable>(_ value: T) {
    guard let data = try? LookoutStatus.encoder.encode(value) else { fail("Couldn't encode JSON") }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
args.removeAll { $0 == "--json" }
let command = args.first ?? "status"
let rest = Array(args.dropFirst())

switch command {
case "status":
    let status = loadStatus()
    if json { printJSON(status); break }
    print("Agents\n" + status.agentsText.indented + "\n\nPlan limits\n" + status.limitsText.indented + "\n\nServers\n" + status.serversText.indented)
case "agents":
    let status = loadStatus()
    if json { printJSON(status.agents) } else { print(status.agentsText) }
case "limits":
    let status = loadStatus()
    if json { printJSON(status.limits) } else { print(status.limitsText) }
case "servers":
    let status = loadStatus()
    if json { printJSON(status.servers) } else { print(status.serversText) }
case "open":
    guard let slug = rest.first, let page = LookoutPage(slug: slug) else { fail("usage: lookout open <page>\npages: \(LookoutPage.allCases.map(\.rawValue).joined(separator: ", "))") }
    send(.open(page), foreground: true)
case "launcher", "launchers":
    guard rest.count >= 2, let action = LookoutRoute.LauncherAction(rawValue: rest[0].lowercased()) else {
        fail("usage: lookout launcher start|stop|toggle <name>")
    }
    send(.launcher(name: rest.dropFirst().joined(separator: " "), action: action))
case "palette":
    send(.palette, foreground: true)
case "task", "new-task":
    send(.newTask, foreground: true)
case "weekly", "report":
    send(.weeklyReport, foreground: true)
case "timer":
    let arg = rest.first ?? String(LookoutRoute.defaultTimerMinutes)
    if arg == "stop" { send(.timer(minutes: nil)); break }
    guard let minutes = Int(arg), (1...1440).contains(minutes) else { fail("usage: lookout timer <minutes>|stop") }
    send(.timer(minutes: minutes))
case "awake", "keep-awake":
    guard let value = LookoutRoute.Switch(rawValue: (rest.first ?? "toggle").lowercased()) else { fail("usage: lookout awake on|off|toggle") }
    send(.keepAwake(value))
case "refresh":
    send(.refresh)
case "help", "-h", "--help":
    print(usage)
default:
    fail(usage)
}

extension String {
    var indented: String { split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n") }
}
