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
    dependencies: [
        // Local SQLite cache for the Mac/iOS clients. Pinned to 6.x; the
        // observation APIs and FTS5 helpers we'll likely add later live here.
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "NotekeeperCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/NotekeeperCore"
        ),
        .testTarget(
            name: "NotekeeperCoreTests",
            dependencies: ["NotekeeperCore"],
            path: "Tests/NotekeeperCoreTests"
        ),
    ]
)
