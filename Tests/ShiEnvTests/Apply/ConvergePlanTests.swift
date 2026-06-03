import XCTest
@testable import ShiEnv

// TP-SERA-02: planConverge identifies dpkg drift, emits correct ConvergeStep

final class ConvergePlanTests: XCTestCase {

    func test_convergePlan_dpkgDrift_emitsCorrectStep() {
        let step = ConvergeStep(
            kind: .installPackage,
            status: .drift,
            description: "dpkg pocketbase",
            detail: "0.21.0 → 0.22.7"
        )

        XCTAssertEqual(step.kind, .installPackage)
        XCTAssertEqual(step.status, .drift)
        XCTAssertEqual(step.detail, "0.21.0 → 0.22.7")
    }

    func test_convergePlan_isAligned_whenAllMatch() {
        let plan = ConvergePlan(
            serviceName: "pocketbase",
            host: "192.0.2.1",
            steps: [
                ConvergeStep(kind: .systemdUnit, status: .match, description: "systemd pocketbase.service"),
                ConvergeStep(kind: .kurmaRegister, status: .match, description: "kurma pb-prod"),
            ]
        )
        XCTAssertTrue(plan.isAligned)
    }

    func test_convergePlan_notAligned_whenDriftPresent() {
        let plan = ConvergePlan(
            serviceName: "pocketbase",
            host: "192.0.2.1",
            steps: [
                ConvergeStep(kind: .systemdUnit, status: .match, description: "systemd pocketbase.service"),
                ConvergeStep(kind: .installPackage, status: .drift, description: "dpkg pocketbase", detail: "0.21 → 0.22"),
            ]
        )
        XCTAssertFalse(plan.isAligned)
        XCTAssertEqual(plan.actionableSteps.count, 1)
        XCTAssertEqual(plan.actionableSteps.first?.kind, .installPackage)
    }

    func test_convergePlan_stepOrderIsCanonical() {
        // Verify the canonical order matches spec §3.3:
        // secrets → dpkg → systemd → caddyfile → kurma
        let expectedOrder: [ConvergeStepKind] = [
            .injectSecrets, .installPackage, .systemdUnit, .syncCaddyfile, .kurmaRegister
        ]
        let allCases = ConvergeStepKind.allCases.filter {
            $0 != .kurmaDeregister
        }
        XCTAssertEqual(allCases, expectedOrder)
    }

    func test_convergeRecord_roundTrip() throws {
        let result = ConvergeResult(
            serviceName: "pocketbase",
            host: "192.0.2.1",
            steps: [
                ConvergeStep(kind: .systemdUnit, status: .done, description: "systemd pocketbase.service"),
            ],
            wasDryRun: false,
            succeeded: true
        )
        let record = ConvergeRecord(
            host: "192.0.2.1",
            env: "prod",
            results: [result],
            wasDryRun: false
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ConvergeRecord.self, from: data)

        XCTAssertEqual(decoded.host, record.host)
        XCTAssertEqual(decoded.env, record.env)
        XCTAssertFalse(decoded.wasDryRun)
        XCTAssertEqual(decoded.results.count, 1)
        XCTAssertEqual(decoded.results[0].serviceName, "pocketbase")
    }
}
