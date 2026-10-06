// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalObserver",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "LocalObserver", targets: ["LocalObserver"]),
        .executable(name: "LocalObserverWidgets", targets: ["LocalObserverWidgets"]),
        // Run by agents' hooks, not by people. packaging/build-app.sh copies it next to the app's executable.
        .executable(name: "lookout-hook", targets: ["lookout-hook"]),
        // Command-line tool copied into the app bundle (Contents/Helpers) by packaging/build-app.sh.
        .executable(name: "lookout", targets: ["LookoutCLI"]),
        // Loaded by /usr/bin/perl, not linked into the app. See Sources/NowPlayingBridge.
        .library(name: "NowPlayingBridge", type: .dynamic, targets: ["NowPlayingBridge"])
    ],
    targets: [
        .target(
            name: "NowPlayingBridge",
            path: "Sources/NowPlayingBridge",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .target(
            name: "LocalObserverCore",
            path: "Sources/LocalObserverCore",
            resources: [.process("Resources")]
        ),
        // Shelf: drop zone and clipboard history. Depends on nothing else here, so it can't reach into
        // servers or agents by accident.
        .target(
            name: "LocalObserverShelf",
            path: "Sources/LocalObserverShelf"
        ),
        // Repos: git repositories, worktrees and pull requests. Uses Core only for its git checkout reader.
        .target(
            name: "LocalObserverRepos",
            dependencies: ["LocalObserverCore"],
            path: "Sources/LocalObserverRepos"
        ),
        // Disk: what's filling the drive (build leftovers, caches, worktrees, Docker) and clearing it safely.
        // Depends on nothing; the app hands it project folders and worktrees to look at.
        .target(
            name: "LocalObserverDisk",
            path: "Sources/LocalObserverDisk"
        ),
        // Hooks: agent hook events, permission answers, the local socket, and merging Lookout's entries into agents'
        // config files. Depends on nothing so the helper stays small and starts fast.
        .target(
            name: "LocalObserverHooks",
            path: "Sources/LocalObserverHooks"
        ),
        .executableTarget(
            name: "lookout-hook",
            dependencies: ["LocalObserverHooks"],
            path: "Sources/LookoutHook"
        ),
        // Widget views, shared by the extension and the app's debug snapshot harness.
        .target(
            name: "LocalObserverWidgetUI",
            dependencies: ["LocalObserverCore", "LocalObserverShelf"],
            path: "Sources/LocalObserverWidgetUI"
        ),
        .executableTarget(
            name: "LocalObserver",
            dependencies: ["LocalObserverCore", "LocalObserverWidgetUI", "LocalObserverShelf", "LocalObserverRepos", "LocalObserverDisk",
                           "LocalObserverHooks"],
            path: "Sources/LocalObserver"
        ),
        // WidgetKit extension. SwiftPM builds the executable; packaging/build-app.sh wraps it in an .appex.
        .executableTarget(
            name: "LocalObserverWidgets",
            dependencies: ["LocalObserverCore", "LocalObserverWidgetUI", "LocalObserverShelf"],
            path: "Sources/LocalObserverWidgets",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            // Enter through the system's extension runtime like Xcode does; it then finds the @main WidgetBundle.
            // Without this the process starts at Swift's main, returns, and exits before WidgetKit can ask it
            // for its widgets, so they never appear in the gallery.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
                .linkedFramework("WidgetKit")
            ]
        ),
        // `lookout` CLI: reads the widget snapshot and drives the app through lookout:// links.
        .executableTarget(
            name: "LookoutCLI",
            dependencies: ["LocalObserverCore"],
            path: "Sources/LookoutCLI"
        ),
        .executableTarget(
            name: "LocalObserverVerification",
            dependencies: ["LocalObserverCore", "LocalObserverShelf", "LocalObserverRepos", "LocalObserverDisk", "LocalObserverHooks"],
            path: "Sources/LocalObserverVerification"
        )
    ]
)
