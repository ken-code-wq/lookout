import Foundation
import AppKit
import LocalObserverServices

/// Connects the Services pillar to the server list: names the databases and containers behind listening ports,
/// and carries out "Open in" for a connection (a desktop client, or a shell client in Terminal).
@MainActor
final class ServicesCoordinator {
    static let shared = ServicesCoordinator()

    func attach(state: AppState) {
        let services = ServicesStore.shared
        services.onActionResult = { [weak state] message, ok in
            state?.show(Toast(message: message, symbol: ok ? "checkmark.circle" : "exclamationmark.triangle", tone: ok ? .success : .danger))
        }
        // A started or stopped container opens or closes ports; catch it without waiting for the next tick.
        services.onContainersChanged = { [weak state] in state?.refresh(quiet: true) }
    }

    // MARK: Tagging scanned ports

    /// The container index is re-read at most this often while Docker forwards a port it doesn't know about yet.
    nonisolated static let missRefreshAge: TimeInterval = 30
    /// …and this often anyway while any Docker port is listening, so a replaced container gets renamed.
    nonisolated static let staleRefreshAge: TimeInterval = 120

    /// Runs inside every port scan, off the main thread. Ports that a database or other known service listens on
    /// become the Database type, named after the service; ports Docker forwards take their container's name and
    /// compose folder instead of just "Docker".
    nonisolated static func tag(_ entries: inout [ServerEntry]) {
        let index = ServicePortIndex.shared
        var missing = false, forwarded = false
        for i in entries.indices {
            let entry = entries[i]
            let forwarder = ServiceRecognizer.isContainerForwarder(processName: entry.processName, command: entry.command)
            let container = forwarder ? index.entry(port: entry.port) : nil
            if forwarder { forwarded = true; if container == nil { missing = true } }
            if let container {
                entries[i].projectName = container.composeProject.map { "\($0) · \(container.name)" } ?? container.name
                if let folder = container.composeFolder { entries[i].projectRoot = folder }
            }
            guard let found = ServiceRecognizer.recognize(processName: entry.processName, command: entry.command,
                                                          port: entry.port, image: container?.image) else { continue }
            entries[i].projectType = .database
            entries[i].projectName = found.kind.name + (container.map { " · " + ($0.composeProject ?? $0.name) } ?? "")
        }
        guard forwarded else { return }
        let age = index.updatedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if (missing && age > missRefreshAge) || age > staleRefreshAge {
            Task { @MainActor in ServicesStore.shared.refreshIfStale(missRefreshAge) }
        }
    }

    // MARK: Per server

    /// What's behind a server's port, if Lookout recognises it, with the container when Docker published it.
    struct Service {
        var kind: ServiceKind
        var basis: ServiceRecognizer.Recognition.Basis
        var container: DockerContainer?
        var connection: ServiceConnection
    }

    func service(for server: ServerEntry) -> Service? {
        let store = ServicesStore.shared
        let forwarder = ServiceRecognizer.isContainerForwarder(processName: server.processName, command: server.command)
        let container = forwarder ? store.container(publishing: server.port) : nil
        guard let found = ServiceRecognizer.recognize(processName: server.processName, command: server.command,
                                                      port: server.port, image: container?.image) else { return nil }
        let connection: ServiceConnection
        if let container {
            let detail = store.inspected[container.id]
            connection = .forContainer(kind: found.kind, hostPort: server.port, env: detail?.env ?? [:], command: detail?.command ?? [])
        } else {
            connection = .forNative(kind: found.kind, port: server.port, macUser: NSUserName())
        }
        return Service(kind: found.kind, basis: found.basis, container: container, connection: connection)
    }

    // MARK: Open in

    /// Installed desktop clients for a kind of service.
    func installedApps(for kind: ServiceKind) -> [(ServiceApp, URL)] {
        ServiceApp.apps(for: kind).compactMap { app in
            app.bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first.map { (app, $0) }
        }
    }

    /// Hands the URL to apps that accept one; for the rest, puts it on the clipboard and opens the app.
    func open(_ connection: ServiceConnection, in app: ServiceApp, at appURL: URL, state: AppState) {
        let full = connection.url(revealPassword: true)
        let config = NSWorkspace.OpenConfiguration()
        if app.opensURL, let url = URL(string: full) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(full, forType: .string)
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            state.show(Toast(message: "Copied the connection URL. Paste it into \(app.name).", symbol: "doc.on.doc", tone: .success))
        }
    }

    /// Runs a command in a new Terminal window through a throwaway `.command` file, so no scripting permission is
    /// needed. The command never holds a password: clients are asked to prompt for it.
    func runInTerminal(_ command: String, title: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/zsh -l\n# \(title), opened from Lookout\nprintf '\\e]0;%s\\a' \(ProcessManager.shellQuote(title))\n\(command)\n"
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        // Terminal has read it by then; don't leave scripts lying around.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: url) }
    }

    /// The shell client for a connection: inside its container when there is one (nothing to install), else the
    /// client on the Mac if it's installed.
    func shellCommand(for service: Service) -> (label: String, command: String)? {
        if let container = service.container, let docker = DockerClient.dockerPath,
           let command = ServiceShell.inContainer(service.connection, container: container.name, docker: docker) {
            return ("\(ServiceShell.containerBinary(service.kind) ?? "Shell") in the container", command)
        }
        guard let binary = ServiceShell.localBinary(service.kind), let path = ServiceShell.findLocal(binary) else { return nil }
        return (binary, ServiceShell.local(service.connection, binary: path))
    }
}
