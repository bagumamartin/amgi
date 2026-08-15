// swift-tools-version: 6.2

import PackageDescription

// Opt-in debug diagnostics, off by default. ANY use of unsafeFlags opts a
// target out of explicit-module compilation caching (commit 8fc0fa7), so these
// are gated behind an env var instead of always-on. Turn on deliberately:
//   AMGI_DIAGNOSTICS=1 xcodebuild ...   (or `swift build`)
let diagnosticFlags: [SwiftSetting] = Context.environment["AMGI_DIAGNOSTICS"] != nil
    ? [.unsafeFlags(
        [
            "-enable-actor-data-race-checks",
            "-warn-implicit-overrides",
            "-Xfrontend", "-warn-long-function-bodies=200",
            "-Xfrontend", "-warn-long-expression-type-checking=200",
        ],
        .when(configuration: .debug)
    )]
    : []

// StrictConcurrency dropped: it's the implicit default under .v6 language mode.
let sharedSwiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("IsolatedAny"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("FullTypedThrows"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableExperimentalFeature("AccessLevelOnImport"),
    .enableExperimentalFeature("StrictMemorySafety"),
    .enableExperimentalFeature("StrictSendableMetatypes"),
] + diagnosticFlags

let package = Package(
    name: "AmgiFeatures",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)],
    products: [
        .library(name: "AmgiAppCore", targets: ["AmgiAppCore"]),
        .library(name: "AmgiAppShared", targets: ["AmgiAppShared"]),
        .library(name: "AmgiCharts", targets: ["AmgiCharts"]),
        .library(name: "FeatureTemplates", targets: ["FeatureTemplates"]),
        .library(name: "FeatureStats", targets: ["FeatureStats"]),
        .library(name: "FeatureBrowse", targets: ["FeatureBrowse"]),
        .library(name: "FeatureSync", targets: ["FeatureSync"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(path: "../AmgiUI"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-navigation", from: "2.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "AmgiAppCore",
            dependencies: [
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "Sharing", package: "swift-sharing"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "AmgiAppCoreTests",
            dependencies: ["AmgiAppCore"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "AmgiAppShared",
            dependencies: [
                "AmgiAppCore",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AnkiServices", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "AmgiAppSharedTests",
            dependencies: ["AmgiAppShared"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "AmgiCharts",
            dependencies: [
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "FeatureTemplates",
            dependencies: [
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AnkiServices", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "FeatureStats",
            dependencies: [
                "AmgiCharts",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "FeatureStatsTests",
            dependencies: ["FeatureStats"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "FeatureBrowse",
            dependencies: [
                "AmgiAppShared",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AnkiServices", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SwiftUINavigation", package: "swift-navigation"),
                .product(name: "CasePaths", package: "swift-case-paths"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "FeatureBrowseTests",
            dependencies: [
                "FeatureBrowse",
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AnkiServices", package: "amgi"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "FeatureSync",
            dependencies: [
                "AmgiAppCore",
                "AmgiAppShared",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AnkiSync", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "FeatureSyncTests",
            dependencies: [
                "FeatureSync",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "Sharing", package: "swift-sharing"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
