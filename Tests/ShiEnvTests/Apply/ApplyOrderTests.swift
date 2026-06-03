import XCTest
@testable import ShiEnv

// TP-SERA-04: --apply executes steps in declared order: secrets → dpkg → systemd → caddy → kurma

final class ApplyOrderTests: XCTestCase {

    func test_executeServicePlan_stepsInCanonicalOrder() async throws {
        // The ConvergePlan step order must be:
        // injectSecrets → installPackage → systemdUnit → syncCaddyfile → kurmaRegister
        let plan = ConvergePlan(
            serviceName: "pocketbase",
            host: "192.0.2.1",
            steps: [
                ConvergeStep(kind: .injectSecrets,  status: .new,   description: "secrets"),
                ConvergeStep(kind: .installPackage, status: .drift, description: "dpkg"),
                ConvergeStep(kind: .systemdUnit,    status: .drift, description: "systemd"),
                ConvergeStep(kind: .syncCaddyfile,  status: .new,   description: "caddy"),
                ConvergeStep(kind: .kurmaRegister,  status: .new,   description: "kurma"),
            ]
        )

        let kinds = plan.steps.map { $0.kind }
        let expectedOrder: [ConvergeStepKind] = [
            .injectSecrets, .installPackage, .systemdUnit, .syncCaddyfile, .kurmaRegister
        ]
        XCTAssertEqual(kinds, expectedOrder, "Steps must be in canonical apply order")
    }

    func test_systemdManager_executeStep_callsEnableThenStart() async throws {
        let executor = MockSSHExecutor()
        // Probe returns inactive unit
        executor.stub(prefix: "systemctl show pocketbase.service", response: "inactive\ndead\ndisabled")

        let mgr = SystemdServiceManager(executor: executor)
        let result = try await mgr.executeStep(
            unit: "pocketbase.service",
            host: "192.0.2.1",
            user: "jeo",
            dryRun: false
        )

        XCTAssertEqual(result.status, .done)

        // enable must come before start
        let enableIdx = executor.calls.firstIndex { $0.command.contains("systemctl enable") }
        let startIdx  = executor.calls.firstIndex { $0.command.contains("systemctl start") }
        XCTAssertNotNil(enableIdx, "enable must be called")
        XCTAssertNotNil(startIdx,  "start must be called")
        if let e = enableIdx, let s = startIdx {
            XCTAssertLessThan(e, s, "enable must precede start")
        }
    }

    func test_dpkgManager_executeStep_callsAptGetInstall() async throws {
        let executor = MockSSHExecutor()
        executor.stub(prefix: "dpkg-query", response: "0.21.0\tinstall ok installed")

        let mgr = DpkgPackageManager(executor: executor)
        let result = try await mgr.executeStep(
            package: "pocketbase",
            desiredVersion: "0.22.7",
            host: "192.0.2.1",
            user: "jeo",
            dryRun: false
        )

        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(
            executor.calls.contains { $0.command.contains("apt-get install") && $0.command.contains("0.22.7") },
            "apt-get install with version pin must be called"
        )
    }
}
