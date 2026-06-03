import XCTest
@testable import ShiEnv

// TP-SERA-03: --dry-run shows plan, makes zero SSH writes

final class DryRunTests: XCTestCase {

    var shikkiRoot: URL!
    var executor: MockSSHExecutor!
    var resolver: MockSecretsResolver!
    var persistor: MockConvergeRecordPersistor!
    var nats: MockNATSEmitter!
    var orchestrator: ConvergeOrchestrator!

    override func setUp() async throws {
        shikkiRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shienv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shikkiRoot, withIntermediateDirectories: true)

        executor = MockSSHExecutor()
        resolver = MockSecretsResolver()
        persistor = MockConvergeRecordPersistor()
        nats = MockNATSEmitter()

        // Capture executor in factory to inject the mock (avoids real SSH connections)
        let capturedExecutor = executor!
        orchestrator = ConvergeOrchestrator(
            shikkiRoot: shikkiRoot,
            secretsResolver: resolver,
            recordPersistor: persistor,
            natsEmitter: nats,
            executorFactory: { _ in capturedExecutor }
        )

        // Stub SSH probes
        executor.stub(prefix: "systemctl is-active", response: "inactive")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: shikkiRoot)
    }

    func test_dryRun_noSSHWrites() async throws {
        let manifest = makeManifest(services: ["pocketbase": makeServiceEntry(unit: "pocketbase.service")])

        var output = ""
        let opts = ApplyOptions(dryRun: true, apply: false, targetHost: "192.0.2.1")

        let results = try await orchestrator.run(
            manifest: manifest,
            host: "192.0.2.1",
            options: opts,
            output: &output
        )

        // All steps should be SKIPPED (dry-run)
        for result in results {
            XCTAssertTrue(result.wasDryRun)
        }

        // No records should be saved to @db (dry-run)
        let saved = await persistor.savedRecords
        XCTAssertTrue(saved.isEmpty, "dry-run must not persist to @db")

        // No NATS events
        let published = await nats.published
        XCTAssertTrue(published.isEmpty, "dry-run must not emit NATS events")

        // No SSH write commands
        XCTAssertTrue(executor.writeCommands.isEmpty, "dry-run must issue zero SSH writes")

        XCTAssertTrue(output.contains("dry-run"), "output must mention dry-run")
    }

    // Helper

    func makeManifest(services: [String: ServiceEntry]) -> EnvironmentManifest {
        EnvironmentManifest(
            addressing: EnvAddressing(workspace: "obyw-one", project: "obyw-one", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "192.0.2.1",
                ssh: ProviderSSH(user: "jeo", key_ref: "shi-secret://obyw/deploy-key")
            ),
            services: services
        )
    }

    func makeServiceEntry(unit: String) -> ServiceEntry {
        ServiceEntry(systemd: SystemdBlock(unit: unit))
    }
}
