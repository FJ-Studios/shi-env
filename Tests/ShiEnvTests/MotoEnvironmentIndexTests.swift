import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEIS-07: MotoEnvironmentIndex aggregates 3-workspace fixture

@Suite("MotoEnvironmentIndex — TP-SEIS-07")
struct MotoEnvironmentIndexTests {

    // Build a temp ~/.shikki/ tree with 3 workspaces and run reindex.
    func buildThreeWorkspaceTree() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-test-\(UUID().uuidString)")

        let workspaces = ["ws-alpha", "ws-beta", "ws-gamma"]
        let fm = FileManager.default

        for ws in workspaces {
            let projectDir = tmp.appendingPathComponent("workspaces/\(ws)/projects/proj-\(ws)")
            let envDir = projectDir.appendingPathComponent(".shikki/env")
            try fm.createDirectory(at: envDir, withIntermediateDirectories: true)

            // Write a minimal .moto file with one [environment.prod] block
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

            // Write a minimal prod.json manifest
            let manifest = EnvironmentManifest(
                version: 1,
                addressing: EnvAddressing(workspace: ws, project: "proj-\(ws)", environment: "prod"),
                provider: ProviderBlock(kind: .local, host: "127.0.0.\(workspaces.firstIndex(of: ws)! + 1)")
            )
            let data = try manifest.encodeToJSON()
            try data.write(to: envDir.appendingPathComponent("prod.json"))
        }

        return tmp
    }

    @Test("TP-SEIS-07: reindex collects all 3 workspace entries into .index.json")
    func testReindexThreeWorkspaces() async throws {
        let shikkiRoot = try buildThreeWorkspaceTree()
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let indexActor = MotoEnvironmentIndex(shikkiRoot: shikkiRoot)
        let workspacesRoot = shikkiRoot.appendingPathComponent("workspaces")
        let index = try await indexActor.reindex(workspacesRoot: workspacesRoot)

        #expect(index.entries.count == 3)
        #expect(index.schemaVersion == 1)

        let workspaceNames = Set(index.entries.map(\.workspace))
        #expect(workspaceNames.contains("ws-alpha"))
        #expect(workspaceNames.contains("ws-beta"))
        #expect(workspaceNames.contains("ws-gamma"))
    }

    @Test("TP-SEIS-07b: .index.json is written atomically and readable back")
    func testIndexWrittenAndReadable() async throws {
        let shikkiRoot = try buildThreeWorkspaceTree()
        defer { try? FileManager.default.removeItem(at: shikkiRoot) }

        let indexActor = MotoEnvironmentIndex(shikkiRoot: shikkiRoot)
        let workspacesRoot = shikkiRoot.appendingPathComponent("workspaces")
        let written = try await indexActor.reindex(workspacesRoot: workspacesRoot)

        let read = try await indexActor.loadIndex()
        let readIndex = try #require(read)
        #expect(readIndex.entries.count == written.entries.count)
        #expect(readIndex.schemaVersion == 1)
    }

    @Test("TP-SEIS-07c: loadIndex returns nil when no index exists")
    func testLoadNilWhenNoIndex() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let indexActor = MotoEnvironmentIndex(shikkiRoot: tmpDir)
        let result = try await indexActor.loadIndex()
        #expect(result == nil)
    }
}
