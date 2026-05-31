import Foundation

// MARK: - EnvDownCommand
//
// `shi env down <addr> [--dry-run | --apply]`
//
// BR-SEV-03: mandatory --dry-run first invocation per target.
// BR-SEV-04: delegates to BackendAdapter.
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.1

public struct EnvDownCommand: Sendable {

    public struct Options: Sendable {
        public var dryRun: Bool
        public var apply: Bool
        public var jsonOutput: Bool

        public init(dryRun: Bool = false, apply: Bool = false, jsonOutput: Bool = false) {
            self.dryRun = dryRun
            self.apply = apply
            self.jsonOutput = jsonOutput
        }
    }

    private let shikkiRoot: URL

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.shikkiRoot = shikkiRoot
    }

    public func run(
        address: String,
        options: Options = Options(),
        outputStream: inout some TextOutputStream,
        backendOverride: (any BackendAdapter)? = nil
    ) async throws -> Int32 {

        let indexActor = MotoEnvironmentIndex(shikkiRoot: shikkiRoot)
        guard let index = try await indexActor.loadIndex() else {
            fputs("No index. Run: shi env reindex\n", stderr)
            return 1
        }

        let entries = EnvCommand.expandAddress(address, in: index)
        guard !entries.isEmpty else {
            fputs("No environments match address: \(address)\n", stderr)
            return 1
        }

        if entries.count > 5 && !options.dryRun {
            fputs("WARNING: \(entries.count) services matched. Use --dry-run first.\n", stderr)
            return 1
        }

        let history = DryRunHistory(shikkiRoot: shikkiRoot)
        var results: [BackendResult] = []

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

            if options.apply && !options.dryRun {
                guard history.hasDryRun(host: manifest.provider.host) else {
                    fputs("Error: --apply requires a prior --dry-run for host \(manifest.provider.host).\n", stderr)
                    return 1
                }
            }

            let isDryRun = options.dryRun || !options.apply

            for (serviceName, serviceEntry) in manifest.services ?? [:] {
                if isDryRun {
                    let plan = backend.plan(service: serviceName, serviceEntry: serviceEntry, action: .stop)
                    outputStream.write("[dry-run] \(plan.description)\n")
                } else {
                    let result = try await backend.stop(service: serviceName, serviceEntry: serviceEntry, dryRun: false)
                    results.append(result)
                }
            }

            if options.dryRun {
                try? history.recordDryRun(host: manifest.provider.host)
            }
        }

        if options.jsonOutput, !results.isEmpty {
            let data = try JSONEncoder().encode(results.map { ["host": $0.host, "service": $0.serviceName, "success": $0.success ? "true" : "false"] })
            outputStream.write(String(data: data, encoding: .utf8) ?? "")
        }

        return results.allSatisfy(\.success) ? 0 : 1
    }
}
