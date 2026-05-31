import Foundation

// MARK: - EnvStatusCommand
//
// `shi env status [<addr>] [--json]`
//
// Probes each service's observability.probes and reports green/red.
// BR-SEV-06: cache TTL = 5s per-invocation. NO background polling.
// BR-SEV-02: --json output.
//
// JSON shape:
//   {"env":"prod","services":[{"name":"pocketbase","status":"green","probe_latency_ms":42},...]}
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.4

public struct EnvStatusCommand: Sendable {

    public struct Options: Sendable {
        public var jsonOutput: Bool
        public init(jsonOutput: Bool = false) { self.jsonOutput = jsonOutput }
    }

    /// JSON output shape for status.
    public struct EnvStatusResult: Codable, Sendable {
        public let env: String
        public let workspace: String
        public let project: String
        public let services: [ServiceStatus]

        public init(env: String, workspace: String, project: String, services: [ServiceStatus]) {
            self.env = env
            self.workspace = workspace
            self.project = project
            self.services = services
        }
    }

    private let shikkiRoot: URL

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.shikkiRoot = shikkiRoot
    }

    public func run(
        address: String? = nil,
        options: Options = Options(),
        outputStream: inout some TextOutputStream,
        backendOverride: (any BackendAdapter)? = nil
    ) async throws -> Int32 {

        let indexActor = MotoEnvironmentIndex(shikkiRoot: shikkiRoot)
        guard let index = try await indexActor.loadIndex() else {
            fputs("No index. Run: shi env reindex\n", stderr)
            return 1
        }

        let entries = address.map { EnvCommand.expandAddress($0, in: index) } ?? index.entries
        guard !entries.isEmpty else {
            fputs("No environments match address: \(address ?? "all")\n", stderr)
            return 1
        }

        var allResults: [EnvStatusResult] = []

        for entry in entries {
            let manifestURL = shikkiRoot
                .appendingPathComponent("workspaces/\(entry.workspace)/projects/\(entry.project)")
                .appendingPathComponent(entry.manifestPath.replacingOccurrences(of: ".yml", with: ".json"))

            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? EnvironmentManifest.decode(fromJSON: data) else {
                fputs("Could not load manifest for \(entry.dotAddress)\n", stderr)
                continue
            }

            let backend = backendOverride ?? BackendFactory.make(for: manifest)

            var serviceStatuses: [ServiceStatus] = []
            for (serviceName, serviceEntry) in manifest.services ?? [:] {
                let status = try await backend.status(service: serviceName, serviceEntry: serviceEntry)
                serviceStatuses.append(status)
            }
            serviceStatuses.sort { $0.name < $1.name }

            allResults.append(EnvStatusResult(
                env: entry.environment,
                workspace: entry.workspace,
                project: entry.project,
                services: serviceStatuses
            ))
        }

        if options.jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(allResults)
            outputStream.write(String(data: data, encoding: .utf8) ?? "")
            outputStream.write("\n")
            return 0
        }

        // Tabular output
        for result in allResults {
            outputStream.write("\(result.workspace).\(result.project).\(result.env):\n")
            for svc in result.services {
                let dot = svc.status == "green" ? "●" : "○"
                let latency = svc.probeLatencyMs.map { " (\(Int($0))ms)" } ?? ""
                outputStream.write("  \(dot) \(svc.name)  \(svc.status)\(latency)\n")
            }
        }

        return 0
    }
}
