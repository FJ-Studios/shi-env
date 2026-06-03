import Foundation

// MARK: - LocalEnvStarter
//
// Orchestrates LocalBackend.start() for each service in a resolved local manifest.
// Called by `shi env up local`.
//
// BR-SELP-07: idempotent — re-running on already-up stack = no-op + status report.
// BR-SELP-08: non-privileged ports by default (8080/8443).
// BR-SELP-15: checks Caddy root CA trust before starting Caddy.
//
// Spec: features/shi-env-local-prod-parity-2026-05-31.md §3.1 + §3.8

public struct LocalEnvStarter: Sendable {

    public struct Options: Sendable {
        /// Perform dry-run only (no actual starts).
        public var dryRun: Bool
        /// Skip idempotency check (force re-start even if services appear running).
        public var force: Bool
        /// Emit per-tenant entries for clients[] (BR-SELP-13). Default: true.
        public var perTenant: Bool
        /// Skip the CaddyTrustChecker prompt (e.g. in tests).
        public var skipTrustCheck: Bool

        public init(
            dryRun: Bool = false,
            force: Bool = false,
            perTenant: Bool = true,
            skipTrustCheck: Bool = false
        ) {
            self.dryRun = dryRun
            self.force = force
            self.perTenant = perTenant
            self.skipTrustCheck = skipTrustCheck
        }
    }

    public struct StartResult: Sendable {
        public let serviceName: String
        public let success: Bool
        public let output: String
        public let skipped: Bool   // idempotent skip

        public init(serviceName: String, success: Bool, output: String, skipped: Bool = false) {
            self.serviceName = serviceName
            self.success = success
            self.output = output
            self.skipped = skipped
        }
    }

    private let backend: any BackendAdapter
    private let trustChecker: CaddyTrustChecker
    private let runDir: URL

    public init(
        backend: any BackendAdapter = LocalBackend(),
        trustChecker: CaddyTrustChecker = CaddyTrustChecker(),
        runDir: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".shikki/run/local")
    ) {
        self.backend = backend
        self.trustChecker = trustChecker
        self.runDir = runDir
    }

    /// Start all services in the resolved manifest.
    ///
    /// Returns one `StartResult` per service. Services already running (per
    /// `runDir` state marker) are skipped unless `options.force == true`.
    public func start(
        manifest: EnvironmentManifest,
        options: Options = Options(),
        outputStream: inout some TextOutputStream
    ) async throws -> [StartResult] {
        var results: [StartResult] = []

        let services = manifest.services ?? [:]
        if services.isEmpty {
            outputStream.write("No services declared in manifest.\n")
            return results
        }

        // BR-SELP-15: Caddy trust check before starting Caddy
        if services["caddy"] != nil && !options.dryRun && !options.skipTrustCheck {
            let trusted = try await trustChecker.isCAInstalled()
            if !trusted {
                outputStream.write("[caddy] Root CA not in system keychain.\n")
                outputStream.write("[caddy] Run: sudo caddy trust  (one-time setup)\n")
                results.append(StartResult(
                    serviceName: "caddy",
                    success: false,
                    output: "Caddy Local Authority not trusted — run sudo caddy trust first"
                ))
                return results
            }
        }

        for (serviceName, serviceEntry) in services.sorted(by: { $0.key < $1.key }) {
            // Idempotency: check state marker
            if !options.force && !options.dryRun {
                let marker = stateMarker(for: serviceName)
                if FileManager.default.fileExists(atPath: marker.path) {
                    let msg = "[skip] \(serviceName): already started (use --force to restart)\n"
                    outputStream.write(msg)
                    results.append(StartResult(serviceName: serviceName, success: true,
                                               output: msg.trimmingCharacters(in: .whitespacesAndNewlines),
                                               skipped: true))
                    continue
                }
            }

            let result = try await backend.start(
                service: serviceName,
                serviceEntry: serviceEntry,
                dryRun: options.dryRun
            )
            outputStream.write("\(result.success ? "✓" : "✗") \(serviceName): \(result.output)\n")

            if result.success && !options.dryRun {
                try? writeStateMarker(for: serviceName)
            }

            results.append(StartResult(
                serviceName: serviceName,
                success: result.success,
                output: result.output
            ))
        }

        return results
    }

    /// Stop all services in the resolved manifest.
    public func stop(
        manifest: EnvironmentManifest,
        options: Options = Options(),
        outputStream: inout some TextOutputStream
    ) async throws -> [StartResult] {
        var results: [StartResult] = []

        for (serviceName, serviceEntry) in (manifest.services ?? [:]).sorted(by: { $0.key < $1.key }) {
            let result = try await backend.stop(
                service: serviceName,
                serviceEntry: serviceEntry,
                dryRun: options.dryRun
            )
            outputStream.write("\(result.success ? "✓" : "✗") \(serviceName): \(result.output)\n")

            if result.success && !options.dryRun {
                try? removeStateMarker(for: serviceName)
            }

            results.append(StartResult(
                serviceName: serviceName,
                success: result.success,
                output: result.output
            ))
        }

        return results
    }

    // MARK: State markers

    private func stateMarker(for service: String) -> URL {
        runDir.appendingPathComponent("\(service).running")
    }

    private func writeStateMarker(for service: String) throws {
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let data = ISO8601DateFormatter().string(from: Date()).data(using: .utf8) ?? Data()
        try data.write(to: stateMarker(for: service), options: .atomic)
    }

    private func removeStateMarker(for service: String) throws {
        let url = stateMarker(for: service)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
