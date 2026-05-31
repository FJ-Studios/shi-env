import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEIS-04, TP-SEIS-05, TP-SEIS-06

@Suite("Linter — TP-SEIS-04/05/06")
struct LinterTests {

    let linter = Linter()

    func fixture(_ name: String) throws -> EnvironmentManifest {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        return try EnvironmentManifest.decode(fromJSON: data)
    }

    // MARK: TP-SEIS-04: literal secret rejected

    @Test("TP-SEIS-04a: linter rejects non-vault:// key_ref in provider.ssh")
    func testLiteralSshKeyRefRejected() throws {
        let m = try fixture("broken_literal_secret")
        let findings = linter.lint(m)
        let errors = findings.filter { $0.level == .error }
        #expect(!errors.isEmpty)
        let sshError = errors.first { $0.field?.contains("key_ref") == true }
        #expect(sshError != nil)
    }

    @Test("TP-SEIS-04b: linter rejects non-vault:// in secrets_refs")
    func testLiteralServiceSecretRejected() throws {
        let m = try fixture("broken_literal_secret")
        let findings = linter.lint(m)
        let errors = findings.filter { $0.level == .error }
        let secretError = errors.first { $0.field?.contains("secrets_refs") == true }
        #expect(secretError != nil)
        #expect(secretError?.message.contains("vault://") == true)
    }

    @Test("TP-SEIS-04c: prod fixture with all vault:// refs passes lint")
    func testProdFixtureClean() throws {
        let m = try fixture("prod")
        let findings = linter.lint(m)
        let errors = findings.filter { $0.level == .error }
        #expect(errors.isEmpty)
    }

    // MARK: TP-SEIS-05: port collision

    @Test("TP-SEIS-05: linter detects port collision (service-a and service-b both bind 8080)")
    func testPortCollisionDetected() throws {
        let m = try fixture("broken_port_collision")
        let findings = linter.lint(m)
        let portErrors = findings.filter { $0.level == .error && $0.message.contains("collision") }
        #expect(!portErrors.isEmpty)
        #expect(portErrors.first?.message.contains("8080") == true)
    }

    @Test("TP-SEIS-05b: prod fixture has no port collision (8091 + 80/443 + 8093)")
    func testProdNoPortCollision() throws {
        let m = try fixture("prod")
        let findings = linter.lint(m)
        let portErrors = findings.filter { $0.level == .error && $0.message.contains("collision") }
        #expect(portErrors.isEmpty)
    }

    // MARK: TP-SEIS-06: dep cycle detection

    @Test("TP-SEIS-06a: dep cycle detected when service-a depends on service-b and vice versa")
    func testDepCycleDetected() {
        let cycleManifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "t", project: "t", environment: "t"),
            provider: ProviderBlock(kind: .local, host: "127.0.0.1"),
            services: [
                "svc-a": ServiceEntry(deps: [ServiceDep(service: "svc-b")]),
                "svc-b": ServiceEntry(deps: [ServiceDep(service: "svc-a")])
            ]
        )
        let findings = linter.lint(cycleManifest)
        let cycleErrors = findings.filter { $0.level == .error && $0.message.contains("cycle") }
        #expect(!cycleErrors.isEmpty)
    }

    @Test("TP-SEIS-06b: acyclic dep graph passes lint")
    func testAcyclicDepGraphPasses() {
        // caddy → pocketbase (one-direction, no cycle)
        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "t", project: "t", environment: "t"),
            provider: ProviderBlock(kind: .local, host: "127.0.0.1"),
            services: [
                "pocketbase": ServiceEntry(ports: ["http": 8091]),
                "caddy": ServiceEntry(
                    ports: ["http": 80],
                    deps: [ServiceDep(service: "pocketbase")]
                )
            ]
        )
        let findings = linter.lint(manifest)
        let cycleErrors = findings.filter { $0.level == .error && $0.message.contains("cycle") }
        #expect(cycleErrors.isEmpty)
    }

    // MARK: Agency slug validation

    @Test("TP-SEIS-linter-agency: client with unknown operating_agency fails lint")
    func testUnknownOperatingAgencyFails() {
        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "t", project: "t", environment: "t"),
            provider: ProviderBlock(kind: .local, host: "127.0.0.1"),
            agencies: [
                AgencyEntry(slug: "fj-studios", name: "FJ-Studios", type: .developerStudio,
                            gh_org: "FJ-Studios", role: .sourceOnly)
            ],
            clients: [
                ClientEntry(slug: "my-client", source_agency: "fj-studios",
                            operating_agency: "unknown-agency", type: .agencyClient, phase: .pending)
            ]
        )
        let findings = linter.lint(manifest)
        let errors = findings.filter {
            $0.level == .error && $0.field?.contains("operating_agency") == true
        }
        #expect(!errors.isEmpty)
    }

    // MARK: Kotoba block validation

    @Test("TP-SEIS-linter-kotoba: invalid NATS subject rejected")
    func testKotobaInvalidSubject() {
        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "t", project: "t", environment: "t"),
            provider: ProviderBlock(
                kind: .local,
                host: "127.0.0.1",
                kotoba: KotobaBlock(
                    enabled: true,
                    nats_subject: "wrong.prefix.subject",
                    streams: ["audio"],
                    clock_sync_tier: .appLayer
                )
            )
        )
        let findings = linter.lint(manifest)
        let errors = findings.filter {
            $0.level == .error && $0.field?.contains("nats_subject") == true
        }
        #expect(!errors.isEmpty)
    }

    @Test("TP-SEIS-linter-kotoba: valid kotoba block passes lint")
    func testKotobaValidBlock() {
        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "t", project: "t", environment: "t"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "1.2.3.4",
                kotoba: KotobaBlock(
                    enabled: true,
                    nats_subject: "shikki.kotoba.obyw-one.obyw-one.prod",
                    streams: ["audio", "video"],
                    clock_sync_tier: .appLayer,
                    library: "gh:obyw-one/kotoba"
                )
            )
        )
        let findings = linter.lint(manifest)
        let kotobaErrors = findings.filter {
            $0.level == .error && $0.field?.contains("kotoba") == true
        }
        #expect(kotobaErrors.isEmpty)
    }

    @Test("TP-SEIS-linter-kotoba: invalid stream name rejected")
    func testKotobaInvalidStream() {
        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "t", project: "t", environment: "t"),
            provider: ProviderBlock(
                kind: .local,
                host: "127.0.0.1",
                kotoba: KotobaBlock(
                    enabled: true,
                    nats_subject: "shikki.kotoba.t.t.t",
                    streams: ["audio", "invalid-stream"],
                    clock_sync_tier: .appLayer
                )
            )
        )
        let findings = linter.lint(manifest)
        let streamErrors = findings.filter {
            $0.level == .error && $0.field?.contains("streams") == true
        }
        #expect(!streamErrors.isEmpty)
    }
}
