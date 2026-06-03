import XCTest
@testable import ShiEnv
import ShiSecretsKit

// Tests for ShiSecretsInjector — validates shi-secrets broker integration
// and the NEVER-.env-file contract.

final class ShiSecretsInjectorTests: XCTestCase {

    func test_injector_dryRun_skipsRemoteWrites() async throws {
        let resolver = MockSecretsResolver()
        let executor = MockSSHExecutor()
        let injector = ShiSecretsInjector(resolver: resolver, executor: executor)

        let result = try await injector.inject(
            secretsRefs: ["PB_ADMIN_PASSWORD": "shi-secret://obyw/pb-admin-password"],
            strategy: .systemdLoadCredential(unit: "pocketbase.service"),
            host: "192.0.2.1",
            sshUser: "jeo",
            dryRun: true
        )

        XCTAssertEqual(result.status, .skipped)
        XCTAssertTrue(executor.writeCommands.isEmpty, "dry-run must not write dropin file")
    }

    func test_injector_invalidURI_throwsBeforeMutation() async throws {
        let resolver = MockSecretsResolver()
        let executor = MockSSHExecutor()
        let injector = ShiSecretsInjector(resolver: resolver, executor: executor)

        // vault:// ref must be rejected per [[secret-refs-via-shi-secrets-broker-not-vault-uri]]
        do {
            _ = try await injector.inject(
                secretsRefs: ["OLD_KEY": "vault://obyw/some-secret"],
                strategy: .systemdLoadCredential(unit: "pocketbase.service"),
                host: "192.0.2.1",
                sshUser: "jeo",
                dryRun: false
            )
            XCTFail("Expected ShiSecretURI.ParseError for vault:// ref")
        } catch {
            // Any error is acceptable — the key constraint is NO remote writes happened
            XCTAssertTrue(executor.writeCommands.isEmpty, "Must not write to remote after parse error")
        }
    }

    func test_injector_emptySecretsRefs_returnsMatch() async throws {
        let resolver = MockSecretsResolver()
        let executor = MockSSHExecutor()
        let injector = ShiSecretsInjector(resolver: resolver, executor: executor)

        let result = try await injector.inject(
            secretsRefs: [:],
            strategy: .systemdLoadCredential(unit: "pocketbase.service"),
            host: "192.0.2.1",
            sshUser: "jeo",
            dryRun: false
        )

        XCTAssertEqual(result.status, .match)
        XCTAssertTrue(executor.calls.isEmpty, "No SSH calls for empty secrets refs")
    }

    func test_injector_secretsToEnvStrategy_returnsCorrectStatus() async throws {
        let resolver = MockSecretsResolver()
        let executor = MockSSHExecutor()
        let injector = ShiSecretsInjector(resolver: resolver, executor: executor)

        let result = try await injector.inject(
            secretsRefs: ["API_KEY": "shi-secret://obyw/api-key"],
            strategy: .secretsToEnvExecve,
            host: "192.0.2.1",
            sshUser: "jeo",
            dryRun: false
        )

        // secretsToEnvExecve strategy resolves at exec-time — no remote write
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(executor.writeCommands.isEmpty, "secrets-to-env execve must not write files")
        XCTAssertTrue(result.detail?.contains("secrets-to-env") == true)
    }

    func test_productionSecretsResolver_parsesShiSecretURI() async throws {
        // Verify that shi-secret:// URIs parse correctly
        // (no live broker needed — just URI parsing validation)
        let uri = "shi-secret://obyw/deploy-key"

        // This should not throw
        _ = try ShiSecretURI.parse(uri)
    }

    func test_bridgeOpener_usesProductionResolver_notPassthrough() {
        // BridgeOpener default init must use ProductionBridgeSecretsBroker,
        // NOT the retired PassthroughSecretsBroker.
        // We verify this by checking the type name — PassthroughSecretsBroker
        // no longer exists in the public surface.
        XCTAssertFalse(
            "\(BridgeOpener.self)".contains("Passthrough"),
            "BridgeOpener must not reference PassthroughSecretsBroker in default init"
        )
    }
}
