// swift-tools-version: 6.2

import PackageDescription

// Mirrors the sibling packages' strict-concurrency feature set so async
// function-type mangling stays consistent across the package ↔ app link
// boundary (see root AnkiBridge Package.swift).
//
// Deliberately WITHOUT InternalImportsByDefault / AccessLevelOnImport:
// Xcode's CoreML code generation emits plain `import CoreML` in its
// generated model class, which turns internal under those features and
// breaks every public declaration in the generated file (verified 2026-08,
// device build).
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
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AmgiIcons", targets: ["AmgiIcons"]),
    ],
    dependencies: [
        // Shared e5 engine (moved out 2026-09 — AmgiIcons is icons-only).
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
                // 1512 × 384 unit vectors keyed by Phosphor camelCase case
                // name. Produced by scripts/icon-embeddings/precompute_
                // embeddings.py — regenerate there if the model changes.
                .process("Resources/IconEmbeddings.json"),
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
