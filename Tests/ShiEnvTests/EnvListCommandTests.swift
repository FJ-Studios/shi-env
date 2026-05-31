import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEIS-08: shi env list against 3-workspace fixture

@Suite("EnvListCommand — TP-SEIS-08")
struct EnvListCommandTests {

    func buildAndIndexThreeWorkspaces() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-list-\(UUID().uuidString)")

        let workspaces = ["ws-one", "ws-two", "ws-three"]
        let fm = FileManager.default

        for ws in workspaces {
            let projectDir = tmp.appendingPathComponent("workspaces/\(ws)/projects/proj-\(ws)")
            let envDir = projectDir.appendingPathComponent(".shikki/env")
            try fm.createDirectory(at: envDir, withIntermediateDirectories: true)

            let motoContent = """
            [plugin]
            id = "test/\(ws)"

            [environment.prod]
            path = ".shikki/env/prod.json"
            freshness = "event-tracked"
            schema = "shi-env-environment-v1"
            owner_plugin = "gh:FJ-Studios/shi-env"
            """
            try motoContent.write(to: projectDir.appendingPathComponent(".moto"), atomically: true, encoding: .utf8)

            let manifest = EnvironmentManifest(
                version: 1,
                addressing: EnvAddressing(workspace: ws, project: "proj-\(ws)", environment: "prod"),
                provider: ProviderBlock(kind: .ovhVps, host: "10.0.0.\(workspaces.firstIndex(of: ws)! + 1)"),
                services: [
                    "svc-a": ServiceEntry(ports: ["http": 8080]),
                    "svc-b": ServiceEntry(ports: ["http": 8081])
                ]
            )
            let data = try manifest.encodeToJSON()
            try data.write(to: envDir.appendingPathComponent("prod.json"))
        }

        // Build index
        let indexActor = MotoEnvironmentIndex(shikkiRoot: tmp)
        _ = try await indexActor.reindex(workspacesRoot: tmp.appendingPathComponent("workspaces"))
        return tmp
    }

    @Test("TP-SEIS-08a: shi env list exits 0 and prints header + 3 rows")
    func testListExitsZero() async throws {
        let shikkiRoot = try await buildAndIndexThreeWorkspaces()
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let cmd = EnvListCommand(shikkiRoot: shikkiRoot)
        var output = ""
        let exitCode = try await cmd.run(options: .init(), outputStream: &output)

        #expect(exitCode == 0)

        // Header present
        #expect(output.contains("WORKSPACE"))
        #expect(output.contains("ENV"))
        #expect(output.contains("PROVIDER"))

        // All 3 workspaces listed
        #expect(output.contains("ws-one"))
        #expect(output.contains("ws-two"))
        #expect(output.contains("ws-three"))
    }

    @Test("TP-SEIS-08b: --json flag produces valid JSON array")
    func testListJsonOutput() async throws {
        let shikkiRoot = try await buildAndIndexThreeWorkspaces()
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let cmd = EnvListCommand(shikkiRoot: shikkiRoot)
        var output = ""
        let exitCode = try await cmd.run(options: .init(jsonOutput: true), outputStream: &output)

        #expect(exitCode == 0)
        let data = try #require(output.data(using: .utf8))
        let parsed = try JSONDecoder().decode([EnvIndexEntry].self, from: data)
        #expect(parsed.count == 3)
    }

    @Test("TP-SEIS-08c: returns 1 when no index file present")
    func testListNoIndexReturnsError() async throws {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-empty-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        let cmd = EnvListCommand(shikkiRoot: emptyRoot)
        var output = ""
        let exitCode = try await cmd.run(options: .init(), outputStream: &output)
        #expect(exitCode == 1)
    }
}
