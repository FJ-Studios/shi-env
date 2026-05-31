import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEIS-02 + TP-SEIS-03

@Suite("InheritanceResolver — TP-SEIS-02/03")
struct InheritanceResolverTests {

    func fixture(_ name: String) throws -> EnvironmentManifest {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        return try EnvironmentManifest.decode(fromJSON: data)
    }

    // MARK: TP-SEIS-02: child wins on conflict; parent fields fill gaps

    @Test("TP-SEIS-02a: local inherits prod — child provider kind wins (local beats ovh-vps)")
    func testChildProviderKindWins() throws {
        let prod = try fixture("prod")
        let local = try fixture("local")
        let catalogue: [String: EnvironmentManifest] = ["prod": prod, "local": local]
        let resolver = InheritanceResolver(catalogue: catalogue)

        let resolved = try resolver.resolve(name: "local")

        // Child wins on provider
        #expect(resolved.provider.kind == .local)
        #expect(resolved.provider.host == "127.0.0.1")
    }

    @Test("TP-SEIS-02b: local inherits prod — parent service fields fill gaps")
    func testParentFillsGaps() throws {
        let prod = try fixture("prod")
        let local = try fixture("local")
        let catalogue: [String: EnvironmentManifest] = ["prod": prod, "local": local]
        let resolver = InheritanceResolver(catalogue: catalogue)

        let resolved = try resolver.resolve(name: "local")

        // pocketbase from prod should be present (parent fills)
        // but local overrides bridges → {}
        let pb = try #require(resolved.services?["pocketbase"])
        #expect(pb.bridges?.isEmpty == true)
        // local overrides admin_password secret ref
        #expect(pb.secrets_refs?["admin_password"] == "vault://obyw/pb-admin-local")
    }

    @Test("TP-SEIS-02c: parent vaultwarden service filled in for local")
    func testParentVaultwardenPresent() throws {
        let prod = try fixture("prod")
        let local = try fixture("local")
        let catalogue: [String: EnvironmentManifest] = ["prod": prod, "local": local]
        let resolver = InheritanceResolver(catalogue: catalogue)

        let resolved = try resolver.resolve(name: "local")

        // vaultwarden only in prod — must be inherited
        #expect(resolved.services?["vaultwarden"] != nil)
    }

    @Test("TP-SEIS-02d: caddy ports overridden by local child (8080 vs 80)")
    func testCaddyPortsOverridden() throws {
        let prod = try fixture("prod")
        let local = try fixture("local")
        let catalogue: [String: EnvironmentManifest] = ["prod": prod, "local": local]
        let resolver = InheritanceResolver(catalogue: catalogue)

        let resolved = try resolver.resolve(name: "local")

        let caddy = try #require(resolved.services?["caddy"])
        #expect(caddy.ports?["http"] == 8080)
        #expect(caddy.ports?["https"] == 8443)
    }

    @Test("TP-SEIS-02e: observability_backbone overridden for local (localhost endpoint)")
    func testObservabilityBackboneOverridden() throws {
        let prod = try fixture("prod")
        let local = try fixture("local")
        let catalogue: [String: EnvironmentManifest] = ["prod": prod, "local": local]
        let resolver = InheritanceResolver(catalogue: catalogue)

        let resolved = try resolver.resolve(name: "local")

        #expect(resolved.observability_backbone?.kurma_endpoint == "http://localhost:3001/api")
    }

    @Test("TP-SEIS-02f: resolved manifest has no inherits_from (consumed)")
    func testInheritsFromConsumed() throws {
        let prod = try fixture("prod")
        let local = try fixture("local")
        let catalogue: [String: EnvironmentManifest] = ["prod": prod, "local": local]
        let resolver = InheritanceResolver(catalogue: catalogue)

        let resolved = try resolver.resolve(name: "local")
        #expect(resolved.inherits_from == nil)
    }

    // MARK: TP-SEIS-03: cycle detection

    @Test("TP-SEIS-03: cycle env-a → env-b → env-a throws InheritanceError.cycle")
    func testCycleDetected() throws {
        let cycleA = try fixture("cycle_a")
        let cycleB = try fixture("cycle_b")
        let catalogue: [String: EnvironmentManifest] = ["env-a": cycleA, "env-b": cycleB]
        let resolver = InheritanceResolver(catalogue: catalogue)

        do {
            _ = try resolver.resolve(name: "env-a")
            Issue.record("Expected cycle error — none thrown")
        } catch InheritanceError.cycle(let chain) {
            #expect(chain.contains("env-a"))
            #expect(chain.contains("env-b"))
        }
    }
}
