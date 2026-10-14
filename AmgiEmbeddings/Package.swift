// swift-tools-version: 6.2

import PackageDescription

// Shared native MLX embedding engine and verified modular asset lifecycle.
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
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "AmgiEmbeddings", targets: ["AmgiEmbeddings"]),
    ],
    dependencies: [
        .package(path: "../Libraries/EmbeddingGemma2"),
    ],
    targets: [
        .target(
            name: "AmgiEmbeddings",
            dependencies: [
                .product(name: "EmbeddingGemma2", package: "EmbeddingGemma2"),
            ],
            resources: [
                .copy("Resources/Gemma2"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "AmgiEmbeddingsTests",
            dependencies: ["AmgiEmbeddings"],
            resources: [.copy("Fixtures/DigUpReference")],
            swiftSettings: sharedSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
