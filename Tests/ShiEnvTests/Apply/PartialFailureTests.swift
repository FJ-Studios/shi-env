import XCTest
@testable import ShiEnv

// TP-SERA-07: Failure mid-step: partial state recorded, no auto-rollback, clear error

final class PartialFailureTests: XCTestCase {

    func test_dpkgManager_failedStep_throwsSSHError() async throws {
        let executor = MockSSHExecutor()
        // Probe reports old version
        executor.stub(prefix: "dpkg-query", response: "0.21.0\tinstall ok installed")
        // All subsequent commands fail (simulating apt-get failure)
        executor.forcedError = SSHError.commandFailed(
            host: "192.0.2.1",
            command: "apt-get install",
            exitCode: 1,
            stderr: "E: Package 'pocketbase=0.22.7' has no installation candidate"
        )

        let mgr = DpkgPackageManager(executor: executor)

        do {
            _ = try await mgr.executeStep(
                package: "pocketbase",
                desiredVersion: "0.22.7",
                host: "192.0.2.1",
                user: "jeo",
                dryRun: false
            )
            XCTFail("Expected SSHError.commandFailed to be thrown")
        } catch let err as SSHError {
            if case .commandFailed = err {
                // Expected — error propagates to caller; no auto-rollback per spec §3.5
            } else {
                XCTFail("Wrong SSHError: \(err)")
            }
        }
    }

    func test_kurmaRegistrar_failedRegistration_serviceStaysUp() async throws {
        let failingClient = FailingKurmaClient()
        let registrar = KurmaMonitorRegistrar(client: failingClient)
        let monitor = KurmaMonitor(
            slug: "pb-prod",
            name: "pocketbase (prod)",
            url: "https://192.0.2.1"
        )

        // Should NOT throw — kurma failure is non-fatal (BR-SERA-06)
        let result = try await registrar.executeStep(monitor: monitor, dryRun: false)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.description.contains("pb-prod"))
        XCTAssertTrue(result.detail?.contains("service remains up") == true)
    }

    func test_systemdManager_dryRun_returnsSkipped_noRemoteWrites() async throws {
        let executor = MockSSHExecutor()
        executor.stub(prefix: "systemctl show", response: "inactive\ndead\ndisabled")

        let mgr = SystemdServiceManager(executor: executor)
        let result = try await mgr.executeStep(
            unit: "pocketbase.service",
            host: "192.0.2.1",
            user: "jeo",
            dryRun: true
        )

        XCTAssertEqual(result.status, .skipped)
        XCTAssertTrue(executor.writeCommands.isEmpty, "dry-run must not write to remote")
    }

    func test_caddyfileSyncer_dryRun_noRemoteMutation() async throws {
        let executor = MockSSHExecutor()
        executor.stub(prefix: "sha256sum", response: "abc123\t/etc/caddy/Caddyfile")

        let syncer = CaddyfileSyncer(executor: executor)
        let result = try await syncer.execute(
            desiredContent: "# new Caddyfile",
            host: "192.0.2.1",
            user: "jeo",
            dryRun: true
        )

        XCTAssertEqual(result.status, .skipped)
        XCTAssertTrue(executor.writeCommands.isEmpty, "dry-run must not write Caddyfile to remote")
    }
}

// MARK: - FailingKurmaClient

/// Always fails registration — used to test BR-SERA-06 non-fatal behaviour.
actor FailingKurmaClient: KurmaClientProtocol {
    func isRegistered(slug: String) async throws -> Bool { false }
    func registerMonitor(_ monitor: KurmaMonitor) async throws {
        throw KurmaError.registrationFailed(slug: monitor.slug, httpStatus: 500)
    }
    func deregisterMonitor(slug: String) async throws {}
}
