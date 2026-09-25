// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalObserver",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LocalObserver", targets: ["LocalObserver"])
    ],
    targets: [
        .target(
            name: "LocalObserverCore",
            path: "Sources/LocalObserverCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "LocalObserver",
            dependencies: ["LocalObserverCore"],
            path: "Sources/LocalObserver"
        ),
        .executableTarget(
            name: "LocalObserverVerification",
            dependencies: ["LocalObserverCore"],
            path: "Sources/LocalObserverVerification"
        )
    ]
)
