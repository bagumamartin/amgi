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
        .library(name: "DecksFeature", targets: ["DecksFeature"]),
        .library(name: "WidgetFeature", targets: ["WidgetFeature"]),
        .library(name: "SettingsFeature", targets: ["SettingsFeature"]),
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
                "AmgiAppCore",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AnkiServices", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "SwiftUINavigation", package: "swift-navigation"),
                .product(name: "CasePaths", package: "swift-case-paths"),
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
        // Deck list, deck detail, deck config + the FSRS simulator, and the
        // profile picker. Depends on ReviewFeature only to present ReviewView
        // off a deck row.
        //
        // No .interoperabilityMode(.Cxx). This target used to need it purely
        // transitively — DecksFeature -> ReviewFeature -> ReaderFeature ->
        // AmgiReaderDictionary put the CHoshiDicts modulemap in its Clang
        // scan. That edge was inverted on 2026-08-15 (the app injects the
        // lookup popup via EnvironmentValues.lookupPopup), so the Cxx chain is
        // ReaderFeature and the app target only. Importing any Cxx-mode module
        // under this target brings the setting — and the loss of compilation
        // caching — straight back.
        .target(
            name: "DecksFeature",
            dependencies: [
                "AmgiAppCore",
                "AmgiAppShared",
                "BrowseFeature",
                "ReviewFeature",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SwiftUINavigation", package: "swift-navigation"),
                .product(name: "CasePaths", package: "swift-case-paths"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The review screen: WebKit card host, flip chrome, rating bar,
        // native renderer, render-mode UI. The session state machine itself is
        // AmgiReviewCore, which the watch also links — keep engine logic there
        // and presentation here.
        //
        // Depends on BrowseFeature/TemplatesFeature for note editing and
        // template editing off the card.
        //
        // It deliberately does NOT depend on ReaderFeature. It used to, for
        // LookupPopupView (the dictionary popup is shared with the reader),
        // and that single edge forced .interoperabilityMode(.Cxx) here and on
        // DecksFeature behind it — Cxx interop is transitive, so importing a
        // Cxx-mode module drags the CHoshiDicts modulemap into the Clang
        // dependency scan, and any target in that chain drops out of explicit
        // modules and compilation caching (rdar://122829880).
        //
        // Inverted on 2026-08-15: the app root supplies the popup through
        // EnvironmentValues.lookupPopup (AmgiAppShared), so ReviewView renders
        // it without knowing what it is. Do not re-add the import.
        .target(
            name: "ReviewFeature",
            dependencies: [
                "AmgiAppCore",
                "AmgiAppShared",
                "AmgiReviewCore",
                "BrowseFeature",
                "TemplatesFeature",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AmgiCardWeb", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "SwiftUINavigation", package: "swift-navigation"),
                .product(name: "CasePaths", package: "swift-case-paths"),
            ],
            swiftSettings: sharedSwiftSettings
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
        // The iOS widget extension's entire body: the Widget, its AppIntent
        // configuration, the timeline provider, and the three family views.
        // Only @main AmgiWidgetBundle stays behind in the AmgiWidget target.
        //
        // Same hard rule as AmgiAppCore, for a sharper reason: the widget is a
        // separate process that reads the app group via WidgetSnapshotStore.
        // It must NEVER gain AnkiClients — it has no business being able to
        // reach the Rust engine at all.
        //
        // AnkiKit is deliberately absent: no widget source imports it. The
        // AmgiWidget target used to list it, which was vestigial.
        .target(
            name: "WidgetFeature",
            dependencies: [
                "AmgiAppCore",
                .product(name: "AmgiTheme", package: "AmgiUI"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The settings aggregator: the Settings root plus every screen it
        // pushes to (appearance, accounts, sync, review, card rendering,
        // reader, code editor, template overrides, maintenance, empty cards,
        // media check, backups, about) and the shared row/control chrome.
        //
        // It is the app's fan-in point, so it depends on nearly every other
        // feature — that is inherent to what a settings screen is, not a
        // layering smell. Public surface is SettingsView alone.
        //
        // Two consequences of that fan-in, both deliberate:
        //   - It imports ReaderFeature (ReaderSettingsView, dictionary
        //     settings), so it joins the Cxx chain and needs
        //     .interoperabilityMode(.Cxx) — and loses compilation caching
        //     with it (rdar://122829880). Unavoidable while the reader's own
        //     settings screens live in ReaderFeature.
        //   - It imports AnkiBackend directly, for MaintenanceModel's
        //     closeCollection() in "Reset Everything". No other *Feature does;
        //     AnkiClients already links it, so this costs no new linkage.
        //
        // switchProfile(to:) stays in AmgiAppApp.swift (it closes/reopens the
        // collection, cancels sync, flips the keychain anchor), so
        // SettingsView takes it as onSwitchProfile — same shape as
        // DeckListView.
        .target(
            name: "SettingsFeature",
            dependencies: [
                "AmgiAppCore",
                "AmgiReviewCore",
                "BrowseFeature",
                "ReaderFeature",
                "ReviewFeature",
                "SyncFeature",
                "TemplatesFeature",
                .product(name: "AnkiKit", package: "amgi"),
                .product(name: "AnkiBackend", package: "amgi"),
                .product(name: "AnkiClients", package: "amgi"),
                .product(name: "AnkiServices", package: "amgi"),
                .product(name: "AnkiSync", package: "amgi"),
                .product(name: "AmgiCardWeb", package: "amgi"),
                .product(name: "AmgiTheme", package: "AmgiUI"),
                .product(name: "AmgiUI", package: "AmgiUI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "SwiftNavigation", package: "swift-navigation"),
                .product(name: "SwiftUINavigation", package: "swift-navigation"),
                .product(name: "CasePaths", package: "swift-case-paths"),
            ],
            swiftSettings: sharedSwiftSettings + [.interoperabilityMode(.Cxx)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
