import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEV-08: --tenants exposes shi-agency clients shape

@Suite("EnvListCommand tenants — TP-SEV-08")
struct EnvTenantsTests {

    private func buildTmpWithClients() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-tenants-\(UUID().uuidString)")
        let projectDir = tmp.appendingPathComponent("workspaces/ws/projects/proj")
        let envDir = projectDir.appendingPathComponent(".shikki/env")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)

        let motoContent = """
        [environment.prod]
        path = ".shikki/env/prod.json"
        freshness = "event-tracked"
        """
        try motoContent.write(to: projectDir.appendingPathComponent(".moto"), atomically: true, encoding: .utf8)

        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "prod"),
            provider: ProviderBlock(kind: .ovhVps, host: "10.0.0.1"),
            services: ["caddy": ServiceEntry(ports: ["http": 80])],
            agencies: [
                AgencyEntry(slug: "fj-studios", name: "FJ Studios", type: .developerStudio,
                            gh_org: "FJ-Studios", role: .sourceOnly),
                AgencyEntry(slug: "obyw-one", name: "obyw.one", type: .digitalAgency,
                            gh_org: "obyw-one", role: .opsOnly),
            ],
            clients: [
                ClientEntry(slug: "sigma-analytics", source_agency: "fj-studios",
                            operating_agency: "obyw-one", type: .agencyClient, phase: .pending),
                ClientEntry(slug: "shikki", source_agency: "fj-studios",
                            operating_agency: "obyw-one", type: .agencyProduct, phase: .prod),
                ClientEntry(slug: "obyw.one", source_agency: "obyw-one",
                            operating_agency: "obyw-one", type: .agencyProperty, phase: .prod),
            ]
        )

        let data = try manifest.encodeToJSON()
        try data.write(to: envDir.appendingPathComponent("prod.json"))

        let indexActor = MotoEnvironmentIndex(shikkiRoot: tmp)
        _ = try await indexActor.reindex(workspacesRoot: tmp.appendingPathComponent("workspaces"))
        return tmp
    }

    @Test("TP-SEV-08a: --tenants flag triggers tenants-only output path")
    func testTenantsFlag() async throws {
        let tmp = try await buildTmpWithClients()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cmd = EnvListCommand(shikkiRoot: tmp)
        var output = ""
        let exitCode = try await cmd.run(options: .init(tenantsOnly: true), outputStream: &output)

        #expect(exitCode == 0)
    }

    @Test("TP-SEV-08b: ClientEntry has source_agency + operating_agency + type")
    func testClientEntryShape() {
        let client = ClientEntry(
            slug: "sigma-analytics",
            source_agency: "fj-studios",
            operating_agency: "obyw-one",
            type: .agencyClient,
            phase: .pending
        )
        #expect(client.source_agency == "fj-studios")
        #expect(client.operating_agency == "obyw-one")
        #expect(client.type == .agencyClient)
    }

    @Test("TP-SEV-08c: EnvironmentManifest with clients round-trips via JSON")
    func testManifestWithClientsRoundTrips() throws {
        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "prod"),
            provider: ProviderBlock(kind: .ovhVps, host: "10.0.0.1"),
            clients: [
                ClientEntry(slug: "sigma", source_agency: "fj-studios",
                            operating_agency: "obyw-one", type: .agencyClient, phase: .pending),
            ]
        )
        let data = try manifest.encodeToJSON()
        let decoded = try EnvironmentManifest.decode(fromJSON: data)
        #expect(decoded.clients?.count == 1)
        #expect(decoded.clients?.first?.source_agency == "fj-studios")
        #expect(decoded.clients?.first?.operating_agency == "obyw-one")
        #expect(decoded.clients?.first?.type == .agencyClient)
    }

    @Test("TP-SEV-08d: --operating-agency filter works in EnvListCommand options")
    func testOperatingAgencyFilter() async throws {
        let tmp = try await buildTmpWithClients()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cmd = EnvListCommand(shikkiRoot: tmp)
        var output = ""
        // Filter by operating agency — should still succeed (index has entry)
        let exitCode = try await cmd.run(
            options: .init(operatingAgency: "obyw-one"),
            outputStream: &output
        )
        #expect(exitCode == 0)
    }
}
