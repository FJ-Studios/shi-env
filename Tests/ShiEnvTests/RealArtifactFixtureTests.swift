import Testing
import Foundation
@testable import ShiEnv

// MARK: - §6 W4: Real-artifact fixture validation
//
// Converts existing artifacts (sites.yml back entry, pb-admin.sh ports, local-dev.sh
// host map) into EnvironmentManifest schema and verifies linter accepts them.
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md §6 W4

@Suite("Real-artifact fixtures — §6 W4 validation")
struct RealArtifactFixtureTests {

    func realArtifact(_ name: String) throws -> Data {
        let url = Bundle.module.url(
            forResource: name, withExtension: "json",
            subdirectory: "Fixtures/real-artifacts"
        )!
        return try Data(contentsOf: url)
    }

    // MARK: Fixture 1: back.obyw.one → PocketBase prod service

    @Test("W4-01: back-obyw-one-pocketbase.json parses without errors")
    func testBackObywOnePocketbaseParses() throws {
        let data = try realArtifact("back-obyw-one-pocketbase")
        // Decode ignoring _comment / _source_files / _conversion_notes keys via a
        // lenient wrapper — the canonical schema ignores unknown keys.
        let m = try EnvironmentManifest.decode(fromJSON: data)
        #expect(m.provider.kind == .ovhVps)
        #expect(m.provider.host == "92.134.242.73")
        #expect(m.services?["pocketbase"]?.bridges?["admin"]?.local_port == 9091)
        #expect(m.services?["pocketbase"]?.bridges?["admin"]?.remote_port == 8091)
        #expect(m.services?["pocketbase"]?.public_paths?.contains("/api/*") == true)
        #expect(m.services?["pocketbase"]?.blocked_paths?.contains("/_/*") == true)
    }

    @Test("W4-01b: back-obyw-one-pocketbase.json passes linter (no errors)")
    func testBackObywOnePocketbaseLinterClean() throws {
        let data = try realArtifact("back-obyw-one-pocketbase")
        let m = try EnvironmentManifest.decode(fromJSON: data)
        let findings = Linter().lint(m)
        let errors = findings.filter { $0.level == .error }
        if !errors.isEmpty {
            // Surface schema gaps to operator
            let msgs = errors.map(\.formattedMessage).joined(separator: "\n  ")
            Issue.record("Schema gap(s) in back-obyw-one-pocketbase fixture:\n  \(msgs)")
        }
        #expect(errors.isEmpty)
    }

    // MARK: Fixture 2: local-dev.sh host mappings → local env

    @Test("W4-02: local-dev-host-mappings.json parses (inherits_from=prod)")
    func testLocalDevHostMappingsParses() throws {
        let data = try realArtifact("local-dev-host-mappings")
        let m = try EnvironmentManifest.decode(fromJSON: data)
        #expect(m.provider.kind == .local)
        #expect(m.provider.host == "127.0.0.1")
        #expect(m.inherits_from == "prod")
        #expect(m.services?["pocketbase"]?.bridges?.isEmpty == true)
        #expect(m.services?["caddy"]?.ports?["http"] == 8080)
    }

    @Test("W4-02b: local-dev-host-mappings.json passes linter (no errors)")
    func testLocalDevHostMappingsLinterClean() throws {
        let data = try realArtifact("local-dev-host-mappings")
        let m = try EnvironmentManifest.decode(fromJSON: data)
        let findings = Linter().lint(m)
        let errors = findings.filter { $0.level == .error }
        if !errors.isEmpty {
            let msgs = errors.map(\.formattedMessage).joined(separator: "\n  ")
            Issue.record("Schema gap(s) in local-dev-host-mappings fixture:\n  \(msgs)")
        }
        #expect(errors.isEmpty)
    }

    // MARK: Schema gap surface
    // If any fixture fails lint, the test above surfaces it with Issue.record().
    // This is the W4 mechanism: schema is wrong OR fixture conversion is wrong —
    // either way operator sees the gap explicitly per spec §8 (risk/rollback).
}
