import Foundation

// MARK: - EnvConvergeHistoryCommand
//
// Implements `shi env converge-history --target <host>`
// Queries the @db for recent ConvergeRecords for the given host.
//
// BR-SERA-08: ConvergeRecords are persisted to @db and queryable here.
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.2

public struct EnvConvergeHistoryCommand {

    public struct Options: Sendable, Equatable {
        public let jsonOutput: Bool
        public let limit: Int

        public init(jsonOutput: Bool = false, limit: Int = 10) {
            self.jsonOutput = jsonOutput
            self.limit = limit
        }
    }

    private let persistor: any ConvergeRecordPersistorProtocol

    public init(persistor: any ConvergeRecordPersistorProtocol) {
        self.persistor = persistor
    }

    public func run(
        host: String,
        options: Options,
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {
        let records = try await persistor.load(host: host, limit: options.limit)

        if records.isEmpty {
            outputStream.write("No converge history for host '\(host)'.\n")
            return 0
        }

        if options.jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(records),
               let json = String(data: data, encoding: .utf8) {
                outputStream.write(json + "\n")
            }
            return 0
        }

        outputStream.write("Converge history: \(host) (last \(records.count))\n")
        outputStream.write(String(repeating: "─", count: 60) + "\n")

        for record in records {
            let mode = record.wasDryRun ? "[dry-run]" : "[apply]  "
            let svcCount = record.results.count
            let okCount = record.results.filter { $0.succeeded }.count
            outputStream.write("\(mode) \(record.completedAt)  \(okCount)/\(svcCount) services ok\n")
            outputStream.write("         ID: \(record.id)\n")
            for result in record.results {
                let icon = result.succeeded ? "✓" : "✗"
                outputStream.write("         \(icon) \(result.serviceName)\n")
                for step in result.steps where step.status != .match {
                    outputStream.write("           \(step.status.rawValue) \(step.description)\n")
                }
            }
            outputStream.write("\n")
        }

        return 0
    }
}
