import XCTest
@testable import ShiEnv

// TP-SERA-06: --apply with --yes skips interactive prompt
// TP-SERA-08: --all flag without --i-know-what-im-doing is refused

final class ApplyConfirmationTests: XCTestCase {

    private func makeOrchestrator(shikkiRoot: URL) -> ConvergeOrchestrator {
        ConvergeOrchestrator(
            shikkiRoot: shikkiRoot,
            secretsResolver: MockSecretsResolver(),
            recordPersistor: MockConvergeRecordPersistor(),
            natsEmitter: MockNATSEmitter()
        )
    }

    private func makeManifest() -> EnvironmentManifest {
        EnvironmentManifest(
            addressing: EnvAddressing(workspace: "obyw-one", project: "obyw-one", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "192.0.2.1",
                ssh: ProviderSSH(user: "jeo", key_ref: "shi-secret://obyw/deploy-key")
            )
        )
    }

    // TP-SERA-06: --apply --yes skips confirmation gate
    func test_applyWithYes_doesNotThrowConfirmationError() async throws {
        let shikkiRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shienv-confirm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shikkiRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let orchestrator = makeOrchestrator(shikkiRoot: shikkiRoot)
        let manifest = makeManifest()

        // Pre-record dry-run so the dryRunRequired gate passes
        let history = ApplyHistory(shikkiRoot: shikkiRoot)
        try await history.recordDryRun(host: "192.0.2.1")

        var output = ""
        let opts = ApplyOptions(
            dryRun: false,
            apply: true,
            yes: true,      // this is the key flag
            targetHost: "192.0.2.1"
        )

        // Should NOT throw applyRequiresConfirmation
        do {
            _ = try await orchestrator.run(
                manifest: manifest,
                host: "192.0.2.1",
                options: opts,
                output: &output
            )
        } catch let err as ApplyError {
            if case .applyRequiresConfirmation = err {
                XCTFail("--yes flag should bypass confirmation requirement")
            }
            // Other errors (e.g., missingSSHConfig) are acceptable in unit test context
        } catch {
            // SSH errors in unit tests are expected (no real host)
        }
    }

    // TP-SERA-06: --apply WITHOUT --yes throws applyRequiresConfirmation
    func test_applyWithoutYes_throwsConfirmationError() async throws {
        let shikkiRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shienv-noyes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shikkiRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let orchestrator = makeOrchestrator(shikkiRoot: shikkiRoot)
        let manifest = makeManifest()

        var output = ""
        let opts = ApplyOptions(
            dryRun: false,
            apply: true,
            yes: false,     // missing --yes
            targetHost: "192.0.2.1"
        )

        do {
            _ = try await orchestrator.run(
                manifest: manifest,
                host: "192.0.2.1",
                options: opts,
                output: &output
            )
            XCTFail("Expected applyRequiresConfirmation error")
        } catch let err as ApplyError {
            if case .applyRequiresConfirmation = err {
                // Expected
            } else {
                XCTFail("Wrong error: \(err)")
            }
        }
    }

    // TP-SERA-08: --all without --i-know-what-im-doing is refused
    func test_allFlagWithoutConfirmation_throws() async throws {
        let shikkiRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shienv-all-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shikkiRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let orchestrator = makeOrchestrator(shikkiRoot: shikkiRoot)
        let manifest = makeManifest()

        var output = ""
        let opts = ApplyOptions(
            dryRun: true,
            apply: false,
            yes: false,
            all: true,
            iKnowWhatImDoing: false  // missing
        )

        do {
            _ = try await orchestrator.run(
                manifest: manifest,
                host: "192.0.2.1",
                options: opts,
                output: &output
            )
            XCTFail("Expected allFlagRequiresConfirmation error")
        } catch let err as ApplyError {
            if case .allFlagRequiresConfirmation = err {
                // Expected
            } else {
                XCTFail("Wrong error: \(err)")
            }
        }
    }

    // TP-SERA-08: --all WITH --i-know-what-im-doing passes the gate
    func test_allFlagWithConfirmation_passesGate() async throws {
        let shikkiRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shienv-all-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shikkiRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let orchestrator = makeOrchestrator(shikkiRoot: shikkiRoot)
        let manifest = makeManifest()

        var output = ""
        let opts = ApplyOptions(
            dryRun: true,
            apply: false,
            all: true,
            iKnowWhatImDoing: true  // provided
        )

        // Should NOT throw allFlagRequiresConfirmation
        do {
            _ = try await orchestrator.run(
                manifest: manifest,
                host: "192.0.2.1",
                options: opts,
                output: &output
            )
        } catch let err as ApplyError {
            if case .allFlagRequiresConfirmation = err {
                XCTFail("--i-know-what-im-doing should clear the --all gate")
            }
            // Other errors acceptable
        } catch {
            // SSH / other errors in unit tests are fine
        }
    }
}
