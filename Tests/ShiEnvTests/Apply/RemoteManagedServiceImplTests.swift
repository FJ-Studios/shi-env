import XCTest
@testable import ShiEnv

// TP-SERA-01: RemoteManagedService probe against fixture host returns expected state

final class RemoteManagedServiceImplTests: XCTestCase {

    func test_probeRemote_returnsSystemdState() async throws {
        let executor = MockSSHExecutor()
        executor.stub(prefix: "systemctl is-active", response: "active")
        executor.stub(prefix: "dpkg-query", response: "0.22.7\t")

        let manifest = ServiceManifest(
            name: "pocketbase",
            systemdUnit: "pocketbase.service",
            dpkgPackage: "pocketbase"
        )
        let impl = RemoteManagedServiceImpl(
            host: "192.0.2.1",
            sshUser: "jeo",
            manifest: manifest,
            executor: executor
        )

        let state = try await impl.probeRemote()

        XCTAssertEqual(state["systemd_state"], "active")
        XCTAssertEqual(state["dpkg_version"], "0.22.7")
        XCTAssertEqual(state["host"], "192.0.2.1")
        XCTAssertEqual(state["service"], "pocketbase")
    }

    func test_probeRemote_noSystemdUnit_skipsSystemdProbe() async throws {
        let executor = MockSSHExecutor()
        executor.stub(prefix: "dpkg-query", response: "1.0.0\t")

        let manifest = ServiceManifest(
            name: "caddy",
            dpkgPackage: "caddy"
        )
        let impl = RemoteManagedServiceImpl(
            host: "192.0.2.1",
            sshUser: "jeo",
            manifest: manifest,
            executor: executor
        )

        let state = try await impl.probeRemote()

        // systemd probe should not be called
        XCTAssertFalse(executor.calls.contains { $0.command.contains("systemctl") })
        XCTAssertNil(state["systemd_state"])
    }

    func test_planConverge_identifiesDpkgDrift() async throws {
        let executor = MockSSHExecutor()
        let manifest = ServiceManifest(
            name: "pocketbase",
            systemdUnit: "pocketbase.service",
            dpkgPackage: "pocketbase",
            dpkgVersion: "0.22.7"
        )
        let impl = RemoteManagedServiceImpl(
            host: "192.0.2.1",
            sshUser: "jeo",
            manifest: manifest,
            executor: executor
        )

        let currentState = RemoteServiceState(
            serviceName: "pocketbase",
            systemdState: "active",
            dpkgVersion: "0.21.0"
        )

        let plan = try await impl.planConverge(from: currentState, to: manifest)

        let dpkgStep = plan.steps.first { $0.kind == .installPackage }
        XCTAssertNotNil(dpkgStep)
        XCTAssertEqual(dpkgStep?.status, .drift)
        XCTAssertTrue(dpkgStep?.detail?.contains("0.21.0") == true)
        XCTAssertTrue(dpkgStep?.detail?.contains("0.22.7") == true)
    }

    func test_planConverge_alignedHost_allMatch() async throws {
        let executor = MockSSHExecutor()
        let manifest = ServiceManifest(
            name: "pocketbase",
            systemdUnit: "pocketbase.service",
            dpkgPackage: "pocketbase",
            dpkgVersion: "0.22.7",
            kurmaSlug: "pb-prod"
        )
        let impl = RemoteManagedServiceImpl(
            host: "192.0.2.1",
            sshUser: "jeo",
            manifest: manifest,
            executor: executor
        )

        let alignedState = RemoteServiceState(
            serviceName: "pocketbase",
            systemdState: "active",
            dpkgVersion: "0.22.7",
            kurmaRegistered: true
        )

        let plan = try await impl.planConverge(from: alignedState, to: manifest)

        XCTAssertTrue(plan.isAligned, "Expected all steps to be MATCH on aligned host")
    }
}
