import Foundation

// MARK: - BridgeListCommand
//
// Implements `shi bridge list [--env <env>]`
//
// Lists every service + bridge combination available in the inventory.
//
// Spec: features/shi-bridge-unification-2026-05-31.md §3.2

// Private row type for JSON output — must be at file scope for Codable synthesis.
private struct BridgeRow: Codable {
    let service: String
    let bridge: String
    let localPort: Int
    let remotePort: Int
    let openPath: String?
    let description: String?
}

public struct BridgeListCommand: Sendable {

    public struct Options: Sendable {
        public var env: String
        public var jsonOutput: Bool

        public init(env: String = "prod", jsonOutput: Bool = false) {
            self.env = env
            self.jsonOutput = jsonOutput
        }
    }

    private let manifestLoader: ManifestLoader

    public init(manifestLoader: ManifestLoader = ManifestLoader()) {
        self.manifestLoader = manifestLoader
    }

    public func run(
        options: Options = Options(),
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {
        let manifest: EnvironmentManifest
        do {
            manifest = try await manifestLoader.load(env: options.env)
        } catch {
            outputStream.write("Error loading manifest for env '\(options.env)': \(error.localizedDescription)\n")
            return 1
        }

        guard let services = manifest.services else {
            outputStream.write("No services defined in inventory for env '\(options.env)'.\n")
            return 0
        }

        // Collect all bridge entries
        var rows: [BridgeRow] = []
        for (serviceName, service) in services.sorted(by: { $0.key < $1.key }) {
            guard let bridges = service.bridges else { continue }
            for (bridgeName, entry) in bridges.sorted(by: { $0.key < $1.key }) {
                rows.append(BridgeRow(
                    service: serviceName,
                    bridge: bridgeName,
                    localPort: entry.local_port,
                    remotePort: entry.remote_port,
                    openPath: entry.open_path,
                    description: entry.description
                ))
            }
        }

        if rows.isEmpty {
            outputStream.write("No bridges defined for env '\(options.env)'.\n")
            return 0
        }

        if options.jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            if let data = try? encoder.encode(rows),
               let s = String(data: data, encoding: .utf8) {
                outputStream.write(s + "\n")
            }
            return 0
        }

        // Tabular output
        let col = (svc: 16, br: 12, lp: 11, rp: 11, desc: 44)
        let header = pad("SERVICE", col.svc) + pad("BRIDGE", col.br)
            + pad("LOCAL", col.lp) + pad("REMOTE", col.rp) + "DESCRIPTION"
        outputStream.write(header + "\n")
        outputStream.write(String(repeating: "-", count: header.count + col.desc) + "\n")
        for row in rows {
            let line = pad(row.service, col.svc) + pad(row.bridge, col.br)
                + pad(":\(row.localPort)", col.lp) + pad(":\(row.remotePort)", col.rp)
                + (row.description ?? "")
            outputStream.write(line + "\n")
        }
        return 0
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.count < width ? s + String(repeating: " ", count: width - s.count) : s + " "
    }
}
