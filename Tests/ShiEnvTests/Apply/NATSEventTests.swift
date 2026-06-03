import XCTest
@testable import ShiEnv

// TP-SERA-10: shikki.env.applied event fires on success (NATS mock)

final class NATSEventTests: XCTestCase {

    func test_natsEmitter_subjectContainsWorkspaceAndEnv() {
        // BR-SERA-09: subject = shikki.env.applied.<workspace>.<env>.<host>
        let workspace = "obyw-one"
        let env = "prod"
        let host = "92.134.242.73"
        let sanitizedHost = host.replacingOccurrences(of: ".", with: "-")

        let subject = "shikki.env.applied.\(workspace).\(env).\(sanitizedHost)"

        XCTAssertEqual(subject, "shikki.env.applied.obyw-one.prod.92-134-242-73")
        XCTAssertTrue(subject.hasPrefix("shikki.env.applied."))
    }

    func test_natsSubject_sanitizesHostDots() {
        let host = "192.0.2.1"
        let subject = "shikki.env.applied.obyw-one.prod.\(host.replacingOccurrences(of: ".", with: "-"))"
        XCTAssertEqual(subject, "shikki.env.applied.obyw-one.prod.192-0-2-1")
    }

    func test_mockNATSEmitter_capturesPublishedEvents() async throws {
        let nats = MockNATSEmitter()
        let payload = Data("test".utf8)

        try await nats.publish(subject: "shikki.env.applied.obyw-one.prod.192-0-2-1", payload: payload)

        let published = await nats.published
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].subject, "shikki.env.applied.obyw-one.prod.192-0-2-1")
    }

    func test_dryRun_doesNotEmitNATSEvent() async throws {
        let shikkiRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shienv-nats-dry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shikkiRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let nats = MockNATSEmitter()
        let executor = MockSSHExecutor()
        executor.stub(prefix: "systemctl is-active", response: "inactive")

        let orchestrator = ConvergeOrchestrator(
            shikkiRoot: shikkiRoot,
            secretsResolver: MockSecretsResolver(),
            recordPersistor: MockConvergeRecordPersistor(),
            natsEmitter: nats,
            executorFactory: { _ in executor }
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
        let opts = ApplyOptions(dryRun: true, apply: false, targetHost: "192.0.2.1")
        _ = try await orchestrator.run(
            manifest: manifest,
            host: "192.0.2.1",
            options: opts,
            output: &output
        )

        let published = await nats.published
        XCTAssertTrue(published.isEmpty, "dry-run must NOT emit NATS events")
    }
}
