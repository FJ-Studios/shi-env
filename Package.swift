// swift-tools-version: 6.0

import PackageDescription

// shi-env — unified declarative deployment topology plugin.
// Version: 0.3.0
//
// Sub-spec #2: 8 verbs (up/down/status/open/restart/logs/shell/attach)
// + Katagami-backed TUI + BackendAdapter pattern + kotoba attach.
// Sub-spec #1: inventory schema (moto [environment] artifact type +
// 3-layer addressing + agency-tenant entry shape).
// Sub-spec #3: bridge unification (BridgeOpener + 4 verbs + doctor check).
//
// Spec #1: features/shi-env-inventory-schema-2026-05-31.md
// Spec #2: features/shi-env-verbs-2026-05-31.md
// Spec #3: features/shi-bridge-unification-2026-05-31.md
// Umbrella: features/shi-env-umbrella-vision-2026-05-31.md
// Plugin rule: BR-SEIS-11 / BR-SEV-11 / BR-SBU-11 — ALL source lives here, NEVER in shikki monorepo.

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
            exclude: [
                // Bridge/Fixtures duplicates are superseded by Fixtures/Bridge/
                // These .md files live at Bridge/Fixtures/ (old layout) and are not
                // used directly — tests create temp dirs at runtime.
                "Bridge/Fixtures",
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
