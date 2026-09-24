// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalObserver",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LocalObserver", targets: ["LocalObserver"])
    ],
    targets: [
        .executableTarget(
            name: "LocalObserver",
            path: "Sources/LocalObserver"
        )
    ]
)
