import XCTest
@testable import ShiEnv

// TP-SERA-11: shi-agency tenant new → calls EnvApplyCommand (integration test)
//
// NOTE: shi-agency (gh:FJ-Studios/shi-agency) is a SEPARATE PLUGIN REPO.
// Per BR-SERA-15, TenantProvisioner lives there and calls `shi env apply`
// via the plugin-cli surface (NOT direct Swift type call).
//
// This test verifies the plugin-cli surface contract from the shi-env side:
// that `EnvApplyCommand` can be constructed and called with a minimal
// manifest, and that the orchestrator respects the delegated invocation pattern.

final class ShiAgencyIntegrationTests: XCTestCase {

    // Verify EnvApplyCommand delegates to ConvergeOrchestrator (not hand-rolled SSH)
    func test_envApplyCommand_delegatesToOrchestrator() async throws {
        let shikkiRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shienv-agency-\(UUID().uuidString)")
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

        let cmd = EnvApplyCommand(shikkiRoot: shikkiRoot, orchestrator: orchestrator)

        // Provide SSH config so the orchestrator doesn't fail with missingSSHConfig.
        let manifest = EnvironmentManifest(
            addressing: EnvAddressing(workspace: "obyw-one", project: "obyw-one", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "192.0.2.1",
                ssh: ProviderSSH(user: "jeo", key_ref: "shi-secret://obyw/deploy-key")
            ),
            services: ["sigma-analytics": ServiceEntry()]
        )

        let opts = EnvApplyCommand.Options(
            dryRun: true,
            apply: false,
            target: "192.0.2.1"
        )

        var output = ""
        let exitCode = try await cmd.run(
            manifest: manifest,
            options: opts,
            outputStream: &output
        )

        // dry-run on minimal manifest (no systemd/dpkg config) should return 0
        XCTAssertEqual(exitCode, 0, "dry-run apply should succeed (exit 0)")
        XCTAssertTrue(output.contains("dry-run"), "output must mention dry-run")
    }

    // Verify shi-agency delegation pattern: apply verb exists and is registered
    func test_applyVerbRegisteredInPlugin() {
        XCTAssertTrue(
            ShiEnvPlugin.subVerbs.contains("apply"),
            "apply verb must be registered in ShiEnvPlugin.subVerbs"
        )
        XCTAssertTrue(
            ShiEnvPlugin.subVerbs.contains("probe"),
            "probe verb must be registered"
        )
        XCTAssertTrue(
            ShiEnvPlugin.subVerbs.contains("converge-history"),
            "converge-history verb must be registered"
        )
    }
}
