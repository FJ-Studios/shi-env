// swift-tools-version: 6.0

import PackageDescription

// shi-env — unified declarative deployment topology plugin.
// Version: 0.5.0
//
// Sub-spec #5: remote apply (RemoteManagedServiceImpl + 5 service-managers +
// ConvergeOrchestrator + 3 verbs: env apply / env probe / env converge-history).
// shi-secrets dependency UNBLOCKED: gh:FJ-Studios/shi-secrets v0.1.0 (2026-06-03).
// BridgeOpener PassthroughSecretsBroker stub RETIRED — ShiSecretsClient broker
// used directly per BR-SSEC-11 + [[container-secrets-no-file-residency]].
// Sub-spec #4: local-prod parity (LocalEnvStarter, MirrorSync FSEvents-watched,
// HostsGenerator + CaddyfileLocalGenerator iterating clients[] for per-tenant,
// TailscaleProviderResolver for cross-machine, CaddyTrustChecker for tls internal,
// RuntimeDriftDetector, env generate + env mirror verbs).
// Sub-spec #2: 8 verbs (up/down/status/open/restart/logs/shell/attach)
// + Katagami-backed TUI + BackendAdapter pattern + kotoba attach.
// Sub-spec #1: inventory schema (moto [environment] artifact type +
// 3-layer addressing + agency-tenant entry shape).
// Sub-spec #3: bridge unification (BridgeOpener + 4 verbs + doctor check).
//
// Spec #1: features/shi-env-inventory-schema-2026-05-31.md
// Spec #2: features/shi-env-verbs-2026-05-31.md
// Spec #3: features/shi-bridge-unification-2026-05-31.md
// Spec #4: features/shi-env-local-prod-parity-2026-05-31.md
// Spec #5: features/shi-env-remote-apply-2026-05-31.md
// Umbrella: features/shi-env-umbrella-vision-2026-05-31.md
// Plugin rule: BR-SEIS-11 / BR-SEV-11 / BR-SBU-11 / BR-SELP-11 / BR-SERA-13 —
// ALL source lives here, NEVER in shikki monorepo.

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
            from: "0.1.4"
        ),
        .package(
            url: "https://github.com/FJ-Studios/shi-secrets.git",
            from: "0.1.0"
        ),
    ],
    targets: [
        .target(
            name: "ShiEnv",
            dependencies: [
                .product(name: "ShikkiPluginAPI", package: "shikki-plugin-api"),
                .product(name: "ShiSecretsKit", package: "shi-secrets"),
                .product(name: "ShiSecretsClient", package: "shi-secrets"),
            ],
            path: "Sources/ShiEnv"
        ),
        .testTarget(
            name: "ShiEnvTests",
            dependencies: [
                "ShiEnv",
                .product(name: "ShiSecretsKit", package: "shi-secrets"),
            ],
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
