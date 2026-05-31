import Foundation

// MARK: - EnvLogsCommand
//
// `shi env logs <addr> [--follow]`
//
// Local: journalctl wrapper.
// Remote: SSH + journalctl.
// BR-SEV-02: --json output.
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.1

public struct EnvLogsCommand: Sendable {

    public struct Options: Sendable {
        public var follow: Bool
        public var jsonOutput: Bool
        public var lines: Int

        public init(follow: Bool = false, jsonOutput: Bool = false, lines: Int = 100) {
            self.follow = follow
            self.jsonOutput = jsonOutput
            self.lines = lines
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
        guard let entry = entries.first else {
            fputs("No environment matches: \(address)\n", stderr)
            return 1
        }

        let manifestURL = shikkiRoot
            .appendingPathComponent("workspaces/\(entry.workspace)/projects/\(entry.project)")
            .appendingPathComponent(entry.manifestPath.replacingOccurrences(of: ".yml", with: ".json"))

        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? EnvironmentManifest.decode(fromJSON: data) else {
            fputs("Could not load manifest for \(entry.dotAddress)\n", stderr)
            return 1
        }

        let backend = backendOverride ?? BackendFactory.make(for: manifest)

        // Extract service name from address if provided
        let addrParts = address.split(separator: ".").map(String.init)
        let requestedService = addrParts.count >= 4 ? addrParts[3] : nil

        let servicesToQuery: [(String, ServiceEntry)]
        if let svcName = requestedService, let svcEntry = manifest.services?[svcName] {
            servicesToQuery = [(svcName, svcEntry)]
        } else {
            servicesToQuery = (manifest.services ?? [:]).sorted { $0.key < $1.key }
        }

        for (serviceName, serviceEntry) in servicesToQuery {
            outputStream.write("=== \(serviceName) ===\n")
            let output = try await backend.logs(service: serviceName, serviceEntry: serviceEntry,
                                                 follow: options.follow)
            outputStream.write(output)
            outputStream.write("\n")
        }

        return 0
    }
}
