// swift-tools-version: 6.0

import PackageDescription

// shi-env — unified declarative deployment topology plugin.
//
// Sub-spec #1: inventory schema (moto [environment] artifact type +
// 3-layer addressing + agency-tenant entry shape).
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md
// Umbrella: features/shi-env-umbrella-vision-2026-05-31.md
// Plugin rule: BR-SEIS-11 — ALL source lives here, NEVER in shikki monorepo.

let package = Package(
    name: "shi-env",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "ShiEnv", targets: ["ShiEnv"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FJ-Studios/shikki-plugin-api.git",
            from: "0.1.3"
        ),
    ],
    targets: [
        .target(
            name: "ShiEnv",
            dependencies: [
                .product(name: "ShikkiPluginAPI", package: "shikki-plugin-api"),
            ],
            path: "Sources/ShiEnv"
        ),
        .testTarget(
            name: "ShiEnvTests",
            dependencies: ["ShiEnv"],
            path: "Tests/ShiEnvTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
