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
        .library(name: "TemplatesFeature", targets: ["TemplatesFeature"]),
        .library(name: "StatsFeature", targets: ["StatsFeature"]),
        .library(name: "BrowseFeature", targets: ["BrowseFeature"]),
        .library(name: "SyncFeature", targets: ["SyncFeature"]),
        .library(name: "ReaderFeature", targets: ["ReaderFeature"]),
        .library(name: "AmgiReviewCore", targets: ["AmgiReviewCore"]),
        .library(name: "ReviewFeature", targets: ["ReviewFeature"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(path: "../AmgiUI"),
        .package(path: "../AmgiReader"),
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
            name: "TemplatesFeature",
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
            name: "StatsFeature",
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
            name: "StatsFeatureTests",
            dependencies: ["StatsFeature"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "BrowseFeature",
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
            name: "BrowseFeatureTests",
            dependencies: [
                "BrowseFeature",
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AnkiServices", package: "amgi"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The review state machine + template render-engine overrides, shared
        // by the iOS review screen and AmgiWatchApp. Exists ONLY because both
        // need it: before 2026-08-15 project.yml cherry-picked these files
        // into the watch target by path, compiling them twice into two
        // distinct types. Same role AmgiCharts plays for the stats views.
        //
        // Must stay watchOS-clean — no AmgiAppShared (UIKit/WidgetKit
        // unguarded), no UI. Guard any UIKit use with #if canImport(UIKit).
        .target(
            name: "AmgiReviewCore",
            dependencies: [
                "AmgiAppCore",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AnkiServices", package: "amgi"),
                .product(name: "AmgiCardWeb", package: "amgi"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The review screen: WebKit card host, flip chrome, rating bar,
        // native renderer, render-mode UI. The session state machine itself is
        // AmgiReviewCore, which the watch also links — keep engine logic there
        // and presentation here.
        //
        // Depends on ReaderFeature for LookupPopupView (the dictionary popup
        // is shared with the reader) and on BrowseFeature/TemplatesFeature for
        // note editing and template editing off the card.
        //
        // .interoperabilityMode(.Cxx) is required *because of* that
        // ReaderFeature edge, not because anything here touches C++: Cxx
        // interop is transitive through the module graph, so importing a
        // Cxx-mode module drags the CHoshiDicts modulemap into this target's
        // Clang dependency scan. Without it the build fails with "module
        // 'CHoshiDicts' requires feature 'cplusplus'".
        //
        // The cost is that this target also drops out of explicit modules /
        // compilation caching (rdar://122829880). To get it back, the
        // ReaderFeature edge has to go — invert it, and have the app inject
        // the lookup-popup view into ReviewView instead of ReviewFeature
        // importing it. Two call sites (ContentView, DeckDetailPresentations).
        // Not done: unmeasured on a 2.1k-line target, and this session has
        // twice over-predicted build wins in this exact area.
        .target(
            name: "ReviewFeature",
            dependencies: [
                "AmgiAppCore",
                "AmgiAppShared",
                "AmgiReviewCore",
                "BrowseFeature",
                "ReaderFeature",
                "TemplatesFeature",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AmgiCardWeb", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
            ],
            swiftSettings: sharedSwiftSettings + [.interoperabilityMode(.Cxx)]
        ),
        // The EPUB reader, its dictionary lookup UI, and the study landing
        // screen. The only target that touches AmgiReaderDictionary, which is
        // built in Cxx-interop mode for the hoshidicts bridge — hence the
        // .interoperabilityMode below. SPM passes that to the dependency
        // scanner natively, so unlike the Xcode app target this needs no
        // OTHER_SWIFT_FLAGS duplication (see AmgiApp/project.yml).
        //
        // Keeping the Cxx chain contained here is the point: any target in it
        // loses explicit modules and therefore compilation caching
        // (rdar://122829880), so it must not spread back into the app.
        .target(
            name: "ReaderFeature",
            dependencies: [
                "AmgiAppCore",
                "AmgiAppShared",
                "BrowseFeature",
                .product(name: "AmgiReader", package: "AmgiReader"),
                .product(name: "AmgiReaderDictionary", package: "AmgiReader"),
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
            ],
            swiftSettings: sharedSwiftSettings + [.interoperabilityMode(.Cxx)]
        ),
        .target(
            name: "SyncFeature",
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
            name: "SyncFeatureTests",
            dependencies: [
                "SyncFeature",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "Sharing", package: "swift-sharing"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
