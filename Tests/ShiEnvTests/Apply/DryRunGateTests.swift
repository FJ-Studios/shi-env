import XCTest
@testable import ShiEnv

// TP-SERA-05: --apply WITHOUT prior --dry-run is refused with helpful error

final class DryRunGateTests: XCTestCase {

    func test_applyWithoutPriorDryRun_throws() async throws {
        let shikkiRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shienv-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shikkiRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let resolver = MockSecretsResolver()
        let persistor = MockConvergeRecordPersistor()
        let nats = MockNATSEmitter()
        let orchestrator = ConvergeOrchestrator(
            shikkiRoot: shikkiRoot,
            secretsResolver: resolver,
            recordPersistor: persistor,
            natsEmitter: nats
        )

        let manifest = EnvironmentManifest(
            addressing: EnvAddressing(workspace: "obyw-one", project: "obyw-one", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "192.0.2.1",
                ssh: ProviderSSH(user: "jeo", key_ref: "shi-secret://obyw/deploy-key")
            )
        )

        var output = ""
        let opts = ApplyOptions(
            dryRun: false,
            apply: true,
            yes: true,      // confirm provided
            targetHost: "192.0.2.1"
        )

        do {
            _ = try await orchestrator.run(
                manifest: manifest,
                host: "192.0.2.1",
                options: opts,
                output: &output
            )
            XCTFail("Expected ApplyError.dryRunRequired to be thrown")
        } catch let err as ApplyError {
            if case .dryRunRequired(let host) = err {
                XCTAssertEqual(host, "192.0.2.1")
            } else {
                XCTFail("Wrong ApplyError case: \(err)")
            }
        }
    }

    func test_applyHistory_recordsAndChecks() async throws {
        let shikkiRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shienv-hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shikkiRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let history = ApplyHistory(shikkiRoot: shikkiRoot)

        // No prior dry-run
        let noPrior = await history.hasPriorDryRun(host: "192.0.2.1")
        XCTAssertFalse(noPrior)

        // Record a dry-run
        try await history.recordDryRun(host: "192.0.2.1")

        let hasPrior = await history.hasPriorDryRun(host: "192.0.2.1")
        XCTAssertTrue(hasPrior, "After recording dry-run, hasPriorDryRun must return true")
    }
}
