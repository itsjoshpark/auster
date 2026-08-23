// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AusterCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AusterCore", targets: ["AusterCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/dropbox/SwiftyDropbox", from: "10.2.4"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "AusterCore",
            dependencies: [
                .product(name: "SwiftyDropbox", package: "SwiftyDropbox"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "AusterCoreTests",
            dependencies: [
                "AusterCore",
                .product(name: "SwiftyDropbox", package: "SwiftyDropbox"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // Opt-in, and opt-in twice: AUSTER_INTEGRATION=1 plus a credential.
        // Without both, every test in it reports as skipped, so `swift test`
        // stays green on a machine with no Dropbox account (api-notes §7).
        .testTarget(
            name: "AusterCoreIntegrationTests",
            dependencies: [
                "AusterCore",
                .product(name: "SwiftyDropbox", package: "SwiftyDropbox"),
            ]
        ),
    ]
)
