// swift-tools-version: 5.9
// Vendored copy of https://github.com/phosphor-icons/swift @ 2.1.0 (MIT).
// See VENDOR_NOTE.md — the only change vs upstream is this manifest:
// upstream declares no `resources:` rule but its code uses `Bundle.module`,
// which fails to compile under SwiftPM (no resource accessor is generated).
// The `resources:` rule below fixes that.
import PackageDescription

let package = Package(
    name: "PhosphorSwift",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13)],
    products: [
        .library(
            name: "PhosphorSwift",
            targets: ["PhosphorSwift"]),
    ],
    targets: [
        .target(
            name: "PhosphorSwift",
            path: "Sources",
            resources: [
                .process("PhosphorSwift/Resources"),
            ])
    ]
)
