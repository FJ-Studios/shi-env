import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEIS-09: shi env diff local prod

@Suite("EnvDiffCommand — TP-SEIS-09")
struct EnvDiffCommandTests {

    func loadFixture(_ name: String) throws -> EnvironmentManifest {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        return try EnvironmentManifest.decode(fromJSON: data)
    }

    @Test("TP-SEIS-09a: diff local vs prod shows provider.kind change (local vs ovh-vps)")
    func testDiffShowsProviderKindChange() throws {
        let prod = try loadFixture("prod")
        let local = try loadFixture("local")

        // Resolve local first
        let catalogue: [String: EnvironmentManifest] = ["prod": prod, "local": local]
        let resolver = InheritanceResolver(catalogue: catalogue)
        let resolvedLocal = try resolver.resolve(name: "local")

        let cmd = EnvDiffCommand()
        let entries = cmd.diff(resolvedLocal, prod)

        let providerKindChange = entries.first {
            $0.field == "provider.kind" && $0.kind == .changed
        }
        #expect(providerKindChange != nil)
        #expect(providerKindChange?.left == "local")
        #expect(providerKindChange?.right == "ovh-vps")
    }

    @Test("TP-SEIS-09b: diff local vs prod shows host change")
    func testDiffShowsHostChange() throws {
        let prod = try loadFixture("prod")
        let local = try loadFixture("local")

        let catalogue: [String: EnvironmentManifest] = ["prod": prod, "local": local]
        let resolver = InheritanceResolver(catalogue: catalogue)
        let resolvedLocal = try resolver.resolve(name: "local")

        let cmd = EnvDiffCommand()
        let entries = cmd.diff(resolvedLocal, prod)

        let hostChange = entries.first { $0.field == "provider.host" && $0.kind == .changed }
        #expect(hostChange != nil)
        #expect(hostChange?.left == "127.0.0.1")
        #expect(hostChange?.right == "92.134.242.73")
    }

    @Test("TP-SEIS-09c: diff local vs prod shows caddy port change (8080 vs 80)")
    func testDiffShowsCaddyPortChange() throws {
        let prod = try loadFixture("prod")
        let local = try loadFixture("local")

        let catalogue: [String: EnvironmentManifest] = ["prod": prod, "local": local]
        let resolver = InheritanceResolver(catalogue: catalogue)
        let resolvedLocal = try resolver.resolve(name: "local")

        let cmd = EnvDiffCommand()
        let entries = cmd.diff(resolvedLocal, prod)

        let portChange = entries.first {
            $0.field.contains("caddy") && $0.field.contains("http")
        }
        #expect(portChange != nil)
        #expect(portChange?.left == "8080")
        #expect(portChange?.right == "80")
    }

    @Test("TP-SEIS-09d: diff local vs prod shows pocketbase secret_ref change")
    func testDiffShowsSecretRefChange() throws {
        let prod = try loadFixture("prod")
        let local = try loadFixture("local")

        let catalogue: [String: EnvironmentManifest] = ["prod": prod, "local": local]
        let resolver = InheritanceResolver(catalogue: catalogue)
        let resolvedLocal = try resolver.resolve(name: "local")

        let cmd = EnvDiffCommand()
        let entries = cmd.diff(resolvedLocal, prod)

        let secretChange = entries.first {
            $0.field.contains("pocketbase") && $0.field.contains("admin_password")
        }
        #expect(secretChange != nil)
        #expect(secretChange?.left?.contains("local") == true)
        #expect(secretChange?.right?.contains("local") == false)
    }

    @Test("TP-SEIS-09e: diff identical manifests produces empty list")
    func testDiffIdenticalProducesEmpty() throws {
        let prod = try loadFixture("prod")
        let cmd = EnvDiffCommand()
        let entries = cmd.diff(prod, prod)
        #expect(entries.isEmpty)
    }
}
