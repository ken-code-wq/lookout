// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalObserver",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "LocalObserver", targets: ["LocalObserver"]),
        .executable(name: "LocalObserverWidgets", targets: ["LocalObserverWidgets"]),
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
        // Widget views, shared by the extension and the app's debug snapshot harness.
        .target(
            name: "LocalObserverWidgetUI",
            dependencies: ["LocalObserverCore", "LocalObserverShelf"],
            path: "Sources/LocalObserverWidgetUI"
        ),
        .executableTarget(
            name: "LocalObserver",
            dependencies: ["LocalObserverCore", "LocalObserverWidgetUI", "LocalObserverShelf"],
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
        .executableTarget(
            name: "LocalObserverVerification",
            dependencies: ["LocalObserverCore", "LocalObserverShelf"],
            path: "Sources/LocalObserverVerification"
        )
    ]
)
