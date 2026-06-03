import Foundation

// MARK: - CaddyfileLocalGenerator
//
// Generates a Caddyfile for local listening with `tls internal` per host (§3.8 + BR-SELP-15).
// No mkcert dependency — Caddy provisions its own internal CA.
// Iterates `manifest.clients[]` for per-tenant blocks (BR-SELP-13).
//
// Spec: features/shi-env-local-prod-parity-2026-05-31.md §3.2 (caddyfile-local) + §3.8

public struct CaddyfileLocalGenerator: Sendable {

    public struct Options: Sendable {
        /// HTTP port for local Caddy listener (default: 8080, BR-SELP-08).
        public var httpPort: Int
        /// HTTPS port for local Caddy listener (default: 8443, BR-SELP-08).
        public var httpsPort: Int
        /// Omit per-tenant client blocks (--no-per-tenant flag, BR-SELP-13 opt-out).
        public var skipPerTenant: Bool

        public init(httpPort: Int = 8080, httpsPort: Int = 8443, skipPerTenant: Bool = false) {
            self.httpPort = httpPort
            self.httpsPort = httpsPort
            self.skipPerTenant = skipPerTenant
        }
    }

    public struct GenerationResult: Sendable {
        /// The generated Caddyfile content.
        public let caddyfile: String
        /// Hosts covered by the generated file.
        public let hosts: [String]

        public init(caddyfile: String, hosts: [String]) {
            self.caddyfile = caddyfile
            self.hosts = hosts
        }
    }

    public init() {}

    /// Generate a local Caddyfile from a resolved manifest.
    ///
    /// Emits one server block per service + one per tenant client.
    /// Each block uses `tls internal` (Caddy's built-in CA, §3.8).
    public func generate(
        manifest: EnvironmentManifest,
        options: Options = Options()
    ) -> GenerationResult {
        var blocks: [String] = []
        var hosts: [String] = []

        // Global options block
        blocks.append("""
        {
        \thttp_port \(options.httpPort)
        \thttps_port \(options.httpsPort)
        }
        """)

        // Per-service blocks
        let services = (manifest.services ?? [:]).sorted(by: { $0.key < $1.key })
        for (svcName, svc) in services {
            let hostname = "\(svcName).dev"
            let upstreamPort = svc.ports?.values.first ?? 80
            let block = serviceBlock(hostname: hostname, upstreamPort: upstreamPort, serviceName: svcName)
            blocks.append(block)
            hosts.append(hostname)
        }

        // home.dev catch-all hub
        let homeBlock = """
        home.dev {
        \ttls internal
        \treverse_proxy 127.0.0.1:8080
        }
        """
        blocks.append(homeBlock)
        hosts.insert("home.dev", at: 0)

        // Per-tenant client blocks (BR-SELP-13)
        if !options.skipPerTenant {
            for client in (manifest.clients ?? []) {
                let hostname = "\(client.slug).dev"
                if !hosts.contains(hostname) {
                    let block = clientBlock(client: client, hostname: hostname, services: manifest.services ?? [:])
                    blocks.append(block)
                    hosts.append(hostname)
                }
            }
        }

        return GenerationResult(caddyfile: blocks.joined(separator: "\n\n"), hosts: hosts)
    }

    // MARK: Private

    private func serviceBlock(hostname: String, upstreamPort: Int, serviceName: String) -> String {
        """
        \(hostname) {
        \ttls internal
        \treverse_proxy 127.0.0.1:\(upstreamPort)
        }
        """
    }

    private func clientBlock(
        client: ClientEntry,
        hostname: String,
        services: [String: ServiceEntry]
    ) -> String {
        let pocketbasePort = services["pocketbase"]?.ports?["http"] ?? 8091
        let caddyPort = services["caddy"]?.ports?["http"] ?? 8080

        // Per-spec §3.6: per-client storybook and path-based routing
        var handleBlocks = ""

        if let scopes = client.scopes, scopes.contains("storybook") {
            handleBlocks += """

        \thandle_path /storybook/* {
        \t\treverse_proxy 127.0.0.1:\(caddyPort)
        \t}
        """
        }

        // API routes delegated to PocketBase
        if let scopes = client.scopes, scopes.contains("backend") || scopes.contains("api") {
            handleBlocks += """

        \thandle_path /api/* {
        \t\treverse_proxy 127.0.0.1:\(pocketbasePort)
        \t}
        """
        }

        return """
        \(hostname) {
        \ttls internal\(handleBlocks)
        \treverse_proxy 127.0.0.1:\(caddyPort)
        }
        """
    }
}
