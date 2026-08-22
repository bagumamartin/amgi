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
// device build). This target is the only one that bundles a .mlmodelc.
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
        // Tokenizer runtime for the bundled e5 tokenizer.json — no
        // hand-rolled SentencePiece/WordPiece.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        // Vendored (see Vendor/PhosphorSwift/VENDOR_NOTE.md): upstream
        // 2.1.0's manifest omits the `resources:` rule its code requires.
        .package(path: "Vendor/PhosphorSwift"),
    ],
    targets: [
        .target(
            name: "AmgiIcons",
            dependencies: [
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "PhosphorSwift", package: "PhosphorSwift"),
            ],
            resources: [
                // 1512 × 384 unit vectors keyed by Phosphor camelCase case
                // name. Produced by scripts/icon-embeddings/precompute_
                // embeddings.py — regenerate there if the manifest changes.
                .process("Resources/IconEmbeddings.json"),
                // fp16 CoreML e5-small, PRECOMPILED to .mlmodelc at dev time
                // (`xcrun coremlcompiler compile`) — bundling the raw
                // .mlpackage made Xcode auto-generate a Swift model class
                // whose plain `import CoreML` breaks under this repo's
                // import-discipline settings, and cost ~8s first-launch
                // compile. `.copy` keeps the folder intact everywhere.
                // Regenerate via scripts/icon-embeddings/ docs if the model
                // is ever swapped.
                .copy("Resources/MultilingualE5Small.mlmodelc"),
                .copy("Resources/Tokenizer"),
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
