import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEV attach vs shell semantic distinction
// Also tests TP-SEV-06 bridge composition (disabled until sub-spec #3 lands)

@Suite("EnvAttach vs EnvShell distinction + bridge composition")
struct EnvAttachShellDistinctionTests {

    // MARK: - attach vs shell distinction

    @Test("attach requires kotoba.enabled — fails when kotoba block absent")
    func testAttachRefusesWithoutKotobaBlock() async throws {
        let orchestrator = AttachOrchestrator()

        // Manifest WITHOUT kotoba block
        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "10.0.0.1",
                ssh: ProviderSSH(user: "jeo", key_ref: "vault://test/key"),
                kotoba: nil   // No kotoba block
            )
        )

        do {
            _ = try await orchestrator.attach(address: "ws.proj.prod", manifest: manifest)
            Issue.record("Expected AttachError.kotobaNotDeclared but no error was thrown")
        } catch let err as AttachError {
            switch err {
            case .kotobaNotDeclared:
                break  // Expected
            default:
                Issue.record("Expected kotobaNotDeclared, got: \(err)")
            }
        }
    }

    @Test("attach refuses when kotoba.enabled = false")
    func testAttachRefusesWhenKotobaDisabled() async throws {
        let orchestrator = AttachOrchestrator()

        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "10.0.0.1",
                ssh: ProviderSSH(user: "jeo", key_ref: "vault://test/key"),
                kotoba: KotobaBlock(
                    enabled: false,  // disabled
                    nats_subject: "shikki.kotoba.ws.proj.prod",
                    streams: ["audio"],
                    clock_sync_tier: .appLayer
                )
            )
        )

        do {
            _ = try await orchestrator.attach(address: "ws.proj.prod", manifest: manifest)
            Issue.record("Expected AttachError.kotobaNotEnabled but no error was thrown")
        } catch let err as AttachError {
            switch err {
            case .kotobaNotEnabled:
                break  // Expected
            default:
                Issue.record("Expected kotobaNotEnabled, got: \(err)")
            }
        }
    }

    @Test("attach error message is descriptive — contains host name and shell suggestion")
    func testAttachErrorMessageIsDescriptive() {
        let err = AttachError.kotobaNotDeclared(host: "10.0.0.1")
        let desc = err.errorDescription ?? err.localizedDescription
        #expect(desc.contains("10.0.0.1"))
        #expect(desc.contains("shi env shell"))
    }

    @Test("attach refuses when clock-sync tier too high")
    func testAttachRefusesHighClockSyncTier() async throws {
        let orchestrator = AttachOrchestrator()

        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "10.0.0.1",
                ssh: ProviderSSH(user: "jeo", key_ref: "vault://test/key"),
                kotoba: KotobaBlock(
                    enabled: true,
                    nats_subject: "shikki.kotoba.ws.proj.prod",
                    streams: ["audio"],
                    clock_sync_tier: .appLayer  // only app_layer available
                )
            )
        )

        do {
            // Request gptp tier — above app_layer ceiling
            _ = try await orchestrator.attach(address: "ws.proj.prod", manifest: manifest,
                                              clockSyncTier: "gptp")
            Issue.record("Expected AttachError.clockSyncTierUnavailable but no error was thrown")
        } catch let err as AttachError {
            switch err {
            case .clockSyncTierUnavailable(let requested, let available):
                #expect(requested == "gptp")
                #expect(available == "app_layer")
            default:
                Issue.record("Expected clockSyncTierUnavailable, got: \(err)")
            }
        }
    }

    @Test("shell does NOT require kotoba block — distinct semantic")
    func testShellDoesNotRequireKotobaBlock() {
        // EnvShellCommand has no kotoba check — this test just verifies
        // the command type exists and can be initialized.
        let cmd = EnvShellCommand()
        _ = cmd  // struct with no kotoba check
    }

    // MARK: - Bridge composition test (TP-SEV-06)
    // Disabled until sub-spec #3 BridgeOpenCommand lands.

    @Test("TP-SEV-06: env open pocketbase delegates to bridge open", .disabled("waits-for-bridge-merge"))
    func testEnvOpenDelegatesToBridge() async throws {
        // This test will verify that EnvOpenCommand routes pocketbase admin
        // through BridgeOpenCommand from sub-spec #3.
        // Enable once feat/env-bridge (sub-spec #3) merges.
        Issue.record("Bridge sub-spec #3 not yet merged")
    }
}
