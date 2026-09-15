// swift-tools-version: 6.2
// Note: 6.2 is the minimum that exposes `.iOS(.v26)` / `.macOS(.v26)` as platform literals.
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "ReadReadKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "ReadReadUI", targets: ["ReadReadUI"]),
        .library(name: "ReadReadModel", targets: ["ReadReadModel"]),
        .library(name: "ReadReadSupport", targets: ["ReadReadSupport"]),
        .library(name: "FreshRSSAPI", targets: ["FreshRSSAPI"]),
        .library(name: "MastodonAPI", targets: ["MastodonAPI"]),
        .library(name: "ReadReadSync", targets: ["ReadReadSync"]),
    ],
    targets: [
        // MARK: - Support

        .target(
            name: "ReadReadSupport",
            swiftSettings: swiftSettings
        ),

        // Helpers shared between test targets: a stub HTTP transport and a clock that does not
        // actually sleep. Not listed in `products`, so it never reaches the app.
        .target(
            name: "ReadReadTestSupport",
            dependencies: ["ReadReadSupport", "ReadReadModel"],
            path: "Tests/TestSupport",
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "ReadReadSupportTests",
            dependencies: ["ReadReadSupport", "ReadReadTestSupport"],
            swiftSettings: swiftSettings
        ),

        // MARK: - Model

        .target(
            name: "ReadReadModel",
            dependencies: ["ReadReadSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ReadReadModelTests",
            dependencies: ["ReadReadModel", "ReadReadTestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),

        // MARK: - Providers

        .target(
            name: "FreshRSSAPI",
            dependencies: ["ReadReadSupport", "ReadReadModel"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "FreshRSSAPITests",
            dependencies: ["FreshRSSAPI", "ReadReadTestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "MastodonAPI",
            dependencies: ["ReadReadSupport", "ReadReadModel"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MastodonAPITests",
            dependencies: ["MastodonAPI", "ReadReadTestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),

        // MARK: - Sync

        .target(
            name: "ReadReadSync",
            dependencies: ["ReadReadSupport", "ReadReadModel", "FreshRSSAPI", "MastodonAPI"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ReadReadSyncTests",
            dependencies: ["ReadReadSync", "ReadReadTestSupport"],
            swiftSettings: swiftSettings
        ),

        // MARK: - UI

        .target(
            name: "ReadReadUI",
            dependencies: ["ReadReadSupport", "ReadReadModel", "FreshRSSAPI", "MastodonAPI", "ReadReadSync"],
            swiftSettings: swiftSettings
        ),

        // For the parts of the UI layer that are ordinary logic rather than views: poll arithmetic,
        // shortcode segmentation, key-binding translation. Views themselves are still verified by
        // running the app.
        .testTarget(
            name: "ReadReadUITests",
            dependencies: ["ReadReadUI", "ReadReadTestSupport"],
            swiftSettings: swiftSettings
        ),
    ]
)
