// swift-tools-version: 6.2

import PackageDescription

// Shared text-embedding engine (e5-small CoreML) + its CDN weight lifecycle,
// used by AmgiIcons (deck-icon suggestion) and Browse (semantic search) so
// only ONE resident model instance exists. Split out of AmgiIcons 2026-09:
// icons-only there, engine here.
//
// Deliberately WITHOUT InternalImportsByDefault / AccessLevelOnImport, same
// as AmgiIcons: plain `import CoreML` / `public import SwiftUI` in this
// target must keep their default visibility (verified pattern 2026-08).
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
    name: "AmgiEmbeddings",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AmgiEmbeddings", targets: ["AmgiEmbeddings"]),
    ],
    dependencies: [
        // Tokenizer runtime for the e5 tokenizer.json — no hand-rolled
        // SentencePiece/WordPiece.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        // Zip extraction for the CDN-downloaded .mlpackage archive
        // (ModelAssetManager). No system unzip API exists on iOS.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "AmgiEmbeddings",
            dependencies: [
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [
                .copy("Resources/Tokenizer"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "AmgiEmbeddingsTests",
            dependencies: ["AmgiEmbeddings"],
            swiftSettings: sharedSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
