import Foundation

// MARK: - PerTenantEmitter
//
// Iterates manifest.clients[] to emit per-tenant /etc/hosts + Caddy blocks.
// Central orchestrator called by HostsGenerator + CaddyfileLocalGenerator
// so per-tenant logic stays DRY.
//
// BR-SELP-13: generators iterate clients[] — default ON, --no-per-tenant to skip.
// §3.6: each client gets <slug>.dev hostname + optional /storybook/* handle.
//
// Spec: features/shi-env-local-prod-parity-2026-05-31.md §3.6

public struct PerTenantEmitter: Sendable {

    public struct TenantEntry: Sendable, Equatable {
        public let slug: String
        /// Local hostname (e.g. "sigma-analytics.dev")
        public let localHostname: String
        /// Tailscale IP if resolved; nil for pure-local single-machine runs.
        public let resolvedIP: String
        /// Scopes declared for this client in the manifest.
        public let scopes: [String]

        public init(slug: String, localHostname: String, resolvedIP: String = "127.0.0.1", scopes: [String] = []) {
            self.slug = slug
            self.localHostname = localHostname
            self.resolvedIP = resolvedIP
            self.scopes = scopes
        }

        public var hasStorybook: Bool { scopes.contains("storybook") }
        public var hasAPI: Bool { scopes.contains("api") || scopes.contains("backend") }
    }

    public init() {}

    /// Emit per-tenant entries for all clients in the manifest.
    ///
    /// - Parameter manifest: Resolved manifest.
    /// - Parameter resolvedIPs: Optional map of client slug → IP (from TailscaleProviderResolver).
    ///                          Falls back to 127.0.0.1 when nil.
    /// - Returns: One `TenantEntry` per client.
    public func emit(
        manifest: EnvironmentManifest,
        resolvedIPs: [String: String] = [:]
    ) -> [TenantEntry] {
        (manifest.clients ?? []).map { client in
            TenantEntry(
                slug: client.slug,
                localHostname: "\(client.slug).dev",
                resolvedIP: resolvedIPs[client.slug] ?? "127.0.0.1",
                scopes: client.scopes ?? []
            )
        }
    }
}
