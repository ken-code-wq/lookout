import Foundation
import LocalObserverCore

extension SidebarItem {
    init(_ page: LookoutPage) {
        switch page {
        case .dashboard: self = .home
        case .sessions: self = .agentActivity
        case .usage: self = .agentUsage
        case .limits: self = .agentLimits
        case .repos: self = .repos
        case .github: self = .github
        case .ci: self = .ci
        case .inbox: self = .inbox
        case .pulls: self = .pullRequests
        case .servers: self = .all
        case .favorites: self = .favorites
        case .launchers: self = .launchers
        case .containers: self = .containers
        case .cleanup: self = .cleanup
        case .shelf: self = .shelf
        case .clipboard: self = .clipboard
        }
    }
}

/// Links the `lookout` tool that ships inside the app onto the user's PATH.
enum CLIInstaller {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// `Contents/Helpers/lookout` in the packaged app; next to the executable in a `swift run` build.
    static var bundledTool: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lookout"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("lookout")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Where the symlink is now, if it points at a `lookout` tool.
    static var installedPath: String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/lookout", home + "/.local/bin/lookout"].first {
            (try? fm.destinationOfSymbolicLink(atPath: $0))?.hasSuffix("/lookout") == true
        }
    }

    /// Symlinks the bundled tool into `/usr/local/bin` or `~/.local/bin` and returns the link's path.
    static func install() throws -> String {
        guard let tool = bundledTool else {
            throw Failure(errorDescription: "This build has no lookout tool. Build the app with packaging/build-app.sh.")
        }
        let fm = FileManager.default
        let directory = CLIInstallLocation.directory(home: fm.homeDirectoryForCurrentUser.path) { path in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue && fm.isWritableFile(atPath: path)
        }
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let link = (directory as NSString).appendingPathComponent("lookout")
        if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
            try fm.removeItem(atPath: link)
        } else if fm.fileExists(atPath: link) {
            throw Failure(errorDescription: "\(link) already exists and isn't a link to Lookout. Remove it and try again.")
        }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: tool.path)
        return link
    }
}
