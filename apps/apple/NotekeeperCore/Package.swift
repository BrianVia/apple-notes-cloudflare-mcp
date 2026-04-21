// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotekeeperCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "NotekeeperCore", targets: ["NotekeeperCore"]),
    ],
    targets: [
        .target(
            name: "NotekeeperCore",
            path: "Sources/NotekeeperCore"
        ),
        .testTarget(
            name: "NotekeeperCoreTests",
            dependencies: ["NotekeeperCore"],
            path: "Tests/NotekeeperCoreTests"
        ),
    ]
)
