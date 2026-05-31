import Foundation

// MARK: - EnvListCommand
//
// Implements `shi env list`.
// Reads ~/.shikki/moto/.index.json and prints tabular output.
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md §3.6

public struct EnvListCommand: Sendable {

    public struct Options: Sendable {
        public var jsonOutput: Bool
        public var tenantsOnly: Bool
        public var operatingAgency: String?
        public var sourceAgency: String?
        public var clientType: ClientType?

        public init(
            jsonOutput: Bool = false,
            tenantsOnly: Bool = false,
            operatingAgency: String? = nil,
            sourceAgency: String? = nil,
            clientType: ClientType? = nil
        ) {
            self.jsonOutput = jsonOutput
            self.tenantsOnly = tenantsOnly
            self.operatingAgency = operatingAgency
            self.sourceAgency = sourceAgency
            self.clientType = clientType
        }
    }

    private let indexActor: MotoEnvironmentIndex

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.indexActor = MotoEnvironmentIndex(shikkiRoot: shikkiRoot)
    }

    public func run(options: Options = Options(), outputStream: inout some TextOutputStream) async throws -> Int32 {
        guard let index = try await indexActor.loadIndex() else {
            outputStream.write("No environment index found. Run `shi env reindex` to generate.\n")
            return 1
        }

        if options.jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(index.entries)
            outputStream.write(String(data: data, encoding: .utf8) ?? "")
            outputStream.write("\n")
            return 0
        }

        // Tabular output
        let col = (w: 14, p: 14, e: 12, prov: 14, host: 20, svc: 5)
        let header = pad("WORKSPACE", col.w) + pad("PROJECT", col.p) + pad("ENV", col.e)
            + pad("PROVIDER", col.prov) + pad("HOST", col.host) + pad("#SVC", col.svc)
        let sep = String(repeating: "-", count: header.count)
        outputStream.write(header + "\n")
        outputStream.write(sep + "\n")

        for entry in index.entries {
            let row = pad(entry.workspace, col.w) + pad(entry.project, col.p)
                + pad(entry.environment, col.e) + pad(entry.providerKind, col.prov)
                + pad(entry.host, col.host) + String(entry.serviceCount)
            outputStream.write(row + "\n")
        }

        return 0
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.count < width ? s + String(repeating: " ", count: width - s.count) : s + " "
    }
}
