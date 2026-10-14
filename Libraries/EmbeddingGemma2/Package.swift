// swift-tools-version: 6.3
import PackageDescription

// Audited native implementation with app-owned ordered mixed/video graph support.
// Upstream: Obscyra-app/EmbeddingGemma2Swift
// Revision: 2c7815fc9e2f6d99df05b3cd259f6086ed65e9cc
let package = Package(
    name: "EmbeddingGemma2",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "EmbeddingGemma2", targets: ["EmbeddingGemma2"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
    ],
    targets: [.target(name: "EmbeddingGemma2", dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers"),
    ], resources: [.copy("Resources")])],
    swiftLanguageModes: [.v6]
)
