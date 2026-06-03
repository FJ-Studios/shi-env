import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SELP-04 + TP-SELP-05: RuntimeDriftDetector version drift + exit codes

@Suite("RuntimeDriftDetector — TP-SELP-04 + TP-SELP-05")
struct RuntimeDriftDetectorTests {

    // MARK: - Helpers

    private func makeManifest(
        env: String,
        pbImage: String? = nil,
        pbPort: Int = 8091,
        clients: [ClientEntry] = []
    ) -> EnvironmentManifest {
        EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: env),
            provider: env == "local"
                ? ProviderBlock(kind: .local, host: "127.0.0.1")
                : ProviderBlock(kind: .ovhVps, host: "1.2.3.4"),
            services: [
                "pocketbase": ServiceEntry(
                    image: pbImage,
                    ports: ["http": pbPort],
                    observability: env == "prod"
                        ? ObservabilityEntry(kurma_slug: "pocketbase-obyw-prod", probes: ["/api/health"])
                        : nil
                )
            ],
            clients: clients.isEmpty ? nil : clients
        )
    }

    // Lightweight state provider for tests — no network
    private func stubProvider(
        version: String?,
        status: String = "green",
        kurmaMonitored: Bool = false
    ) -> RuntimeDriftDetector.StateProvider {
        return { service, _ in
            RuntimeDriftDetector.ServiceState(
                serviceName: service,
                version: version,
                status: status,
                kurmaMonitored: kurmaMonitored
            )
        }
    }

    private func stubMigrationCount(_ n: Int) -> RuntimeDriftDetector.MigrationCounter {
        return { _ in n }
    }

    @Test("TP-SELP-04: version mismatch (prod=v0.22, local=v0.21) reported as versionMismatch drift")
    func testVersionMismatchDetected() async throws {
        let local = makeManifest(env: "local", pbImage: "pocketbase@v0.21")
        let prod  = makeManifest(env: "prod",  pbImage: "pocketbase@v0.22")

        let detector = RuntimeDriftDetector(
            localStateProvider: stubProvider(version: "v0.21"),
            prodStateProvider:  stubProvider(version: "v0.22"),
            localMigrationCount: stubMigrationCount(10),
            prodMigrationCount:  stubMigrationCount(10)
        )

        let report = try await detector.detect(local: local, prod: prod)
        let versionItems = report.driftItems.filter { $0.kind == .versionMismatch }
        #expect(!versionItems.isEmpty)
        let item = try #require(versionItems.first)
        #expect(item.service == "pocketbase")
        #expect(item.message.contains("v0.22"))
        #expect(item.message.contains("v0.21"))
    }

    @Test("TP-SELP-05: exit code is 1 when drift detected")
    func testExitCode1OnDrift() async throws {
        let local = makeManifest(env: "local", pbImage: "pocketbase@v0.21")
        let prod  = makeManifest(env: "prod",  pbImage: "pocketbase@v0.22")

        let detector = RuntimeDriftDetector(
            localStateProvider: stubProvider(version: "v0.21"),
            prodStateProvider:  stubProvider(version: "v0.22"),
            localMigrationCount: stubMigrationCount(10),
            prodMigrationCount:  stubMigrationCount(10)
        )

        let report = try await detector.detect(local: local, prod: prod)
        #expect(report.exitCode == 1)
    }

    @Test("TP-SELP-05: exit code is 0 when fully aligned")
    func testExitCode0WhenAligned() async throws {
        let local = makeManifest(env: "local", pbImage: "pocketbase@v0.22")
        let prod  = makeManifest(env: "prod",  pbImage: "pocketbase@v0.22")

        let detector = RuntimeDriftDetector(
            localStateProvider: stubProvider(version: "v0.22"),
            prodStateProvider:  stubProvider(version: "v0.22"),
            localMigrationCount: stubMigrationCount(12),
            prodMigrationCount:  stubMigrationCount(12)
        )

        let report = try await detector.detect(local: local, prod: prod)
        #expect(report.exitCode == 0)
        #expect(report.driftItems.isEmpty)
    }

    @Test("TP-SELP-04b: missing local service reported as missingLocalMirror")
    func testMissingLocalService() async throws {
        let local = makeManifest(env: "local")
        // Prod has kuma which local doesn't
        var prodManifest = makeManifest(env: "prod")
        var prodServices = prodManifest.services ?? [:]
        prodServices["kuma"] = ServiceEntry(ports: ["http": 3001])
        prodManifest = EnvironmentManifest(
            version: 1,
            addressing: prodManifest.addressing,
            provider: prodManifest.provider,
            services: prodServices
        )

        let detector = RuntimeDriftDetector(
            localStateProvider: stubProvider(version: "v0.22"),
            prodStateProvider:  stubProvider(version: "v0.22"),
            localMigrationCount: stubMigrationCount(5),
            prodMigrationCount:  stubMigrationCount(5)
        )

        let report = try await detector.detect(local: local, prod: prodManifest)
        let missing = report.driftItems.filter { $0.kind == .missingLocalMirror }
        #expect(!missing.isEmpty)
        #expect(missing.contains(where: { $0.service == "kuma" }))
    }

    @Test("TP-SELP-04c: migrations drift reported when prod count > local count")
    func testMigrationsDriftDetected() async throws {
        let local = makeManifest(env: "local", pbImage: "pocketbase@v0.22")
        let prod  = makeManifest(env: "prod",  pbImage: "pocketbase@v0.22")

        let detector = RuntimeDriftDetector(
            localStateProvider: stubProvider(version: "v0.22"),
            prodStateProvider:  stubProvider(version: "v0.22"),
            localMigrationCount: stubMigrationCount(11),
            prodMigrationCount:  stubMigrationCount(12)
        )

        let report = try await detector.detect(local: local, prod: prod)
        let migItems = report.driftItems.filter { $0.kind == .migrationsDrift }
        #expect(!migItems.isEmpty)
        #expect(report.exitCode == 1)
    }

    @Test("TP-SELP-04d: formatReport emits DRIFT DETECTED header on drift")
    func testFormatReportContainsDriftHeader() async throws {
        let local = makeManifest(env: "local", pbImage: "pocketbase@v0.21")
        let prod  = makeManifest(env: "prod",  pbImage: "pocketbase@v0.22")

        let detector = RuntimeDriftDetector(
            localStateProvider: stubProvider(version: "v0.21"),
            prodStateProvider:  stubProvider(version: "v0.22"),
            localMigrationCount: stubMigrationCount(10),
            prodMigrationCount:  stubMigrationCount(10)
        )

        let report = try await detector.detect(local: local, prod: prod)
        let text = report.formatReport()
        #expect(text.contains("DRIFT"))
    }

    @Test("TP-SELP-05b: prod client absent in local produces missingLocalMirror with suggestion")
    func testProdClientAbsentInLocalReported() async throws {
        let sigmaClient = ClientEntry(
            slug: "sigma-analytics", operating_agency: "obyw-one",
            type: .agencyClient, phase: .pending
        )
        let local = makeManifest(env: "local")  // no clients
        let prod  = makeManifest(env: "prod", clients: [sigmaClient])

        let detector = RuntimeDriftDetector(
            localStateProvider: stubProvider(version: "v0.22"),
            prodStateProvider:  stubProvider(version: "v0.22"),
            localMigrationCount: stubMigrationCount(5),
            prodMigrationCount:  stubMigrationCount(5)
        )

        let report = try await detector.detect(local: local, prod: prod)
        let missing = report.driftItems.filter { $0.kind == .missingLocalMirror }
        #expect(missing.contains(where: { $0.message.contains("sigma-analytics") }))
        #expect(missing.first?.suggestion != nil)
    }
}
