// swift-tools-version: 6.2

import PackageDescription

// Mirrors the sibling packages' strict-concurrency feature set so async
// function-type mangling stays consistent across the package ↔ app link
// boundary (see root AnkiBridge Package.swift).
let sharedSwiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("IsolatedAny"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("FullTypedThrows"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableExperimentalFeature("StrictMemorySafety"),
    .enableExperimentalFeature("StrictSendableMetatypes"),
]

let package = Package(
    name: "AmgiIcons",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "AmgiIcons", targets: ["AmgiIcons"]),
    ],
    dependencies: [
        // One MLX runtime shared with retrieval.
        .package(path: "../AmgiEmbeddings"),
        // Vendored (see Vendor/PhosphorSwift/VENDOR_NOTE.md): upstream
        // 2.1.0's manifest omits the `resources:` rule its code requires.
        .package(path: "Vendor/PhosphorSwift"),
    ],
    targets: [
        .target(
            name: "AmgiIcons",
            dependencies: [
                .product(name: "AmgiEmbeddings", package: "AmgiEmbeddings"),
                .product(name: "PhosphorSwift", package: "PhosphorSwift"),
            ],
            resources: [
                // Tag descriptions are embedded locally with the installed model.
                .process("Resources/IconTags.json"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "AmgiIconsTests",
            dependencies: ["AmgiIcons"],
            swiftSettings: sharedSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
