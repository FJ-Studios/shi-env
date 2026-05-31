import Testing
import Foundation
@testable import ShiEnv

@Suite("EnvShowCommand")
struct EnvShowCommandTests {

    /// Set up a shikkiRoot with prod + local manifests for obyw-one.obyw-one.
    func buildTestRoot() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-show-\(UUID().uuidString)")
        let envDir = tmp.appendingPathComponent("moto/obyw-one/projects/obyw-one/.shikki/env")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)

        let prodURL = Bundle.module.url(forResource: "prod", withExtension: "json", subdirectory: "Fixtures")!
        let localURL = Bundle.module.url(forResource: "local", withExtension: "json", subdirectory: "Fixtures")!

        try FileManager.default.copyItem(at: prodURL, to: envDir.appendingPathComponent("prod.json"))
        try FileManager.default.copyItem(at: localURL, to: envDir.appendingPathComponent("local.json"))

        return tmp
    }

    @Test("EnvShowCommand: shows prod manifest (exit 0)")
    func testShowProd() async throws {
        let root = try buildTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cmd = EnvShowCommand(shikkiRoot: root)
        var output = ""
        let exitCode = try await cmd.run(address: "obyw-one.obyw-one.prod", outputStream: &output)
        #expect(exitCode == 0)
        #expect(output.contains("obyw-one.obyw-one.prod"))
        #expect(output.contains("ovh-vps"))
    }

    @Test("EnvShowCommand: returns 1 on invalid address format")
    func testInvalidAddress() async throws {
        let root = try buildTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cmd = EnvShowCommand(shikkiRoot: root)
        var output = ""
        let exitCode = try await cmd.run(address: "bad-addr", outputStream: &output)
        #expect(exitCode == 1)
        #expect(output.contains("ERROR"))
    }
}
