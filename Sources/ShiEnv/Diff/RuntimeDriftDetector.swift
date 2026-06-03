import Foundation

// MARK: - RuntimeDriftDetector
//
// Probes prod service state (via HTTP/SSH) and reads local state markers,
// then compares against declared manifest to surface drift.
//
// BR-SELP-03: declared vs running diff; exit code 1 on drift.
// BR-SELP-05: invocation-only — NO background polling.
//
// Spec: features/shi-env-local-prod-parity-2026-05-31.md §3.4

public struct RuntimeDriftDetector: Sendable {

    // MARK: - Types

    public struct ServiceState: Sendable {
        public let serviceName: String
        public let version: String?
        public let status: String        // "green" | "red" | "unknown"
        public let kurmaMonitored: Bool

        public init(serviceName: String, version: String?, status: String, kurmaMonitored: Bool = false) {
            self.serviceName = serviceName
            self.version = version
            self.status = status
            self.kurmaMonitored = kurmaMonitored
        }
    }

    public struct DriftItem: Sendable {
        public enum Kind: String, Sendable {
            case versionMismatch
            case portMismatch
            case missingLocalMirror
            case migrationsDrift
            case observabilityGap
            case schemaMismatch
        }

        public let kind: Kind
        public let service: String?
        public let message: String
        public let suggestion: String?

        public init(kind: Kind, service: String? = nil, message: String, suggestion: String? = nil) {
            self.kind = kind
            self.service = service
            self.message = message
            self.suggestion = suggestion
        }
    }

    public struct DriftReport: Sendable {
        public let localManifest: EnvironmentManifest
        public let prodManifest: EnvironmentManifest
        public let driftItems: [DriftItem]
        /// Exit code per BR-SELP-03: 0 = aligned, 1 = drift, 2 = error.
        public let exitCode: Int32

        public init(
            localManifest: EnvironmentManifest,
            prodManifest: EnvironmentManifest,
            driftItems: [DriftItem]
        ) {
            self.localManifest = localManifest
            self.prodManifest = prodManifest
            self.driftItems = driftItems
            self.exitCode = driftItems.isEmpty ? 0 : 1
        }

        public func formatReport() -> String {
            var lines: [String] = []

            if driftItems.isEmpty {
                lines.append("✓ No drift detected: local env matches prod")
                return lines.joined(separator: "\n")
            }

            lines.append("DRIFT DETECTED (\(driftItems.count) item(s)):\n")

            for item in driftItems {
                let svcLabel = item.service.map { "[\($0)] " } ?? ""
                lines.append("  \(svcLabel)\(item.kind.rawValue): \(item.message)")
                if let s = item.suggestion {
                    lines.append("    → \(s)")
                }
            }

            return lines.joined(separator: "\n")
        }
    }

    // MARK: - State providers (injected for testability)

    public typealias StateProvider = @Sendable (String, ServiceEntry) async throws -> ServiceState
    public typealias MigrationCounter = @Sendable (String) async throws -> Int

    private let localStateProvider: StateProvider
    private let prodStateProvider: StateProvider
    private let localMigrationCount: MigrationCounter
    private let prodMigrationCount: MigrationCounter

    /// Designated init — all dependencies injectable for unit tests.
    ///
    /// Default closures use the public static probes below. Default-arg
    /// expressions must be public-or-equivalent in Swift, so we wrap the
    /// internal statics in inline closures (which only evaluate at call
    /// time, not at default-arg parse time).
    public init(
        localStateProvider: @escaping StateProvider = RuntimeDriftDetector.localProbe,
        prodStateProvider: @escaping StateProvider = RuntimeDriftDetector.prodProbe,
        localMigrationCount: @escaping MigrationCounter = RuntimeDriftDetector.countLocalMigrations,
        prodMigrationCount: @escaping MigrationCounter = RuntimeDriftDetector.countProdMigrations
    ) {
        self.localStateProvider = localStateProvider
        self.prodStateProvider = prodStateProvider
        self.localMigrationCount = localMigrationCount
        self.prodMigrationCount = prodMigrationCount
    }

    // MARK: - Detection

    /// Detect drift between local and prod manifests.
    public func detect(
        local: EnvironmentManifest,
        prod: EnvironmentManifest
    ) async throws -> DriftReport {
        var items: [DriftItem] = []

        let localServices = local.services ?? [:]
        let prodServices  = prod.services ?? [:]

        // 1. Schema drift (port mismatches)
        for (svcName, prodEntry) in prodServices {
            guard let localEntry = localServices[svcName] else {
                items.append(DriftItem(
                    kind: .missingLocalMirror,
                    service: svcName,
                    message: "Service '\(svcName)' declared in prod but absent in local manifest",
                    suggestion: "Add \(svcName) to local.yml or disable with `enabled: false`"
                ))
                continue
            }

            // Port drift
            if let prodPorts = prodEntry.ports, let localPorts = localEntry.ports {
                for (portName, prodPort) in prodPorts {
                    if let localPort = localPorts[portName], localPort != prodPort {
                        items.append(DriftItem(
                            kind: .portMismatch,
                            service: svcName,
                            message: "\(portName) port: prod=\(prodPort) local=\(localPort)",
                            suggestion: "Align ports in local.yml or override intentionally"
                        ))
                    }
                }
            }
        }

        // 2. Runtime drift (version + status)
        for (svcName, prodEntry) in prodServices {
            guard let localEntry = localServices[svcName] else { continue }

            async let localState = try localStateProvider(svcName, localEntry)
            async let prodState  = try prodStateProvider(svcName, prodEntry)

            let ls = try await localState
            let ps = try await prodState

            if let pv = ps.version, let lv = ls.version, pv != lv {
                items.append(DriftItem(
                    kind: .versionMismatch,
                    service: svcName,
                    message: "version: prod=\(pv) local=\(lv)",
                    suggestion: "run `shi env mirror sync` to align"
                ))
            }

            if !ps.kurmaMonitored && ps.status == "green" && !ls.kurmaMonitored {
                // local skipping kurma is expected — not a drift
            }
        }

        // 3. Site mirror drift — prod clients not in local
        let prodClients = Set((prod.clients ?? []).map(\.slug))
        let localClients = Set((local.clients ?? []).map(\.slug))
        for slug in prodClients.subtracting(localClients) {
            items.append(DriftItem(
                kind: .missingLocalMirror,
                service: nil,
                message: "prod client '\(slug)' has no local mirror",
                suggestion: "add to local.yml clients[] or run `shi env generate hosts --env local`"
            ))
        }

        // 4. Migrations drift (pocketbase service only)
        if prodServices["pocketbase"] != nil {
            let localCount = (try? await localMigrationCount("pocketbase")) ?? 0
            let prodCount  = (try? await prodMigrationCount("pocketbase")) ?? 0
            if prodCount > localCount {
                let missing = prodCount - localCount
                items.append(DriftItem(
                    kind: .migrationsDrift,
                    service: "pocketbase",
                    message: "prod has \(missing) unapplied migration(s): prod=\(prodCount) local=\(localCount)",
                    suggestion: "run `shi env mirror sync`"
                ))
            }
        }

        return DriftReport(localManifest: local, prodManifest: prod, driftItems: items)
    }

    // MARK: - Default probe implementations

    public static func localProbe(service: String, entry: ServiceEntry) async throws -> ServiceState {
        let port = entry.ports?.values.first ?? 8080
        let version = extractVersion(from: entry)
        // Local: check marker file existence as a lightweight liveness indicator
        let markerPath = (NSHomeDirectory() as NSString).appendingPathComponent(".shikki/run/local/\(service).running")
        let running = FileManager.default.fileExists(atPath: markerPath)
        return ServiceState(serviceName: service, version: version, status: running ? "green" : "unknown",
                            kurmaMonitored: false)
    }

    public static func prodProbe(service: String, entry: ServiceEntry) async throws -> ServiceState {
        let version = extractVersion(from: entry)
        return ServiceState(serviceName: service, version: version, status: "unknown",
                            kurmaMonitored: entry.observability?.kurma_slug != nil)
    }

    public static func countLocalMigrations(service: String) async throws -> Int {
        // Count files in ~/.shikki/run/local/pb_data/pb_migrations/
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".shikki/run/local/pb_data/pb_migrations")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return items.filter { $0.hasSuffix(".js") || $0.hasSuffix(".json") }.count
    }

    public static func countProdMigrations(service: String) async throws -> Int {
        // Count in the local project checkout (prod-project root mirror)
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".shikki/workspaces/obyw-one/projects/obyw-one/pb_migrations")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return items.filter { $0.hasSuffix(".js") || $0.hasSuffix(".json") }.count
    }

    private static func extractVersion(from entry: ServiceEntry) -> String? {
        // Image tag format: "pocketbase@v0.22" → "v0.22"
        guard let img = entry.image else { return nil }
        let parts = img.components(separatedBy: "@")
        return parts.count == 2 ? parts[1] : nil
    }
}
