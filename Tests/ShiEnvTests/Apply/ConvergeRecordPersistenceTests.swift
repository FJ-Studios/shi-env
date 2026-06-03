import XCTest
@testable import ShiEnv

// TP-SERA-09: ConvergeRecord persisted to @db; queryable via converge-history

final class ConvergeRecordPersistenceTests: XCTestCase {

    func test_mockPersistor_savesAndLoads() async throws {
        let persistor = MockConvergeRecordPersistor()

        let result = ConvergeResult(
            serviceName: "pocketbase",
            host: "192.0.2.1",
            steps: [ConvergeStep(kind: .systemdUnit, status: .done, description: "systemd pb.service")],
            wasDryRun: false,
            succeeded: true
        )
        let record = ConvergeRecord(
            host: "192.0.2.1",
            env: "prod",
            results: [result],
            wasDryRun: false
        )

        try await persistor.save(record: record)

        let loaded = try await persistor.load(host: "192.0.2.1", limit: 10)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].host, "192.0.2.1")
        XCTAssertEqual(loaded[0].env, "prod")
        XCTAssertFalse(loaded[0].wasDryRun)
        XCTAssertEqual(loaded[0].results.count, 1)
    }

    func test_mockPersistor_respectsHostFilter() async throws {
        let persistor = MockConvergeRecordPersistor()

        let record1 = ConvergeRecord(host: "192.0.2.1", env: "prod", results: [], wasDryRun: false)
        let record2 = ConvergeRecord(host: "192.0.2.2", env: "prod", results: [], wasDryRun: false)

        try await persistor.save(record: record1)
        try await persistor.save(record: record2)

        let host1Records = try await persistor.load(host: "192.0.2.1", limit: 10)
        XCTAssertEqual(host1Records.count, 1)
        XCTAssertEqual(host1Records[0].host, "192.0.2.1")
    }

    func test_mockPersistor_respectsLimit() async throws {
        let persistor = MockConvergeRecordPersistor()

        for _ in 0..<5 {
            let rec = ConvergeRecord(host: "192.0.2.1", env: "prod", results: [], wasDryRun: false)
            try await persistor.save(record: rec)
        }

        let limited = try await persistor.load(host: "192.0.2.1", limit: 3)
        XCTAssertEqual(limited.count, 3)
    }

    func test_convergeHistoryCommand_displaysRecords() async throws {
        let persistor = MockConvergeRecordPersistor()

        let result = ConvergeResult(
            serviceName: "pocketbase",
            host: "192.0.2.1",
            steps: [ConvergeStep(kind: .systemdUnit, status: .done, description: "systemd pb.service")],
            wasDryRun: false,
            succeeded: true
        )
        let record = ConvergeRecord(
            host: "192.0.2.1",
            env: "prod",
            results: [result],
            wasDryRun: false
        )
        try await persistor.save(record: record)

        let cmd = EnvConvergeHistoryCommand(persistor: persistor)
        var output = ""
        let exitCode = try await cmd.run(
            host: "192.0.2.1",
            options: .init(jsonOutput: false, limit: 10),
            outputStream: &output
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(output.contains("pocketbase"), "output must mention service name")
        XCTAssertTrue(output.contains("192.0.2.1"), "output must mention host")
    }

    func test_convergeHistoryCommand_emptyHistory() async throws {
        let persistor = MockConvergeRecordPersistor()
        let cmd = EnvConvergeHistoryCommand(persistor: persistor)
        var output = ""
        let exitCode = try await cmd.run(
            host: "192.0.2.1",
            options: .init(),
            outputStream: &output
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(output.contains("No converge history"))
    }
}
