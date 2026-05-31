import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEIS-01: EnvironmentManifest parses §3.2 example YAML round-trip

@Suite("EnvironmentManifest — TP-SEIS-01 (parse + round-trip)")
struct EnvironmentManifestTests {

    /// Load fixture JSON from the test bundle.
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    @Test("TP-SEIS-01a: parses prod.json with all fields")
    func testParseProdFixture() throws {
        let data = try fixture("prod")
        let m = try EnvironmentManifest.decode(fromJSON: data)

        #expect(m.version == 1)
        #expect(m.addressing.workspace == "obyw-one")
        #expect(m.addressing.project == "obyw-one")
        #expect(m.addressing.environment == "prod")
        #expect(m.provider.kind == .ovhVps)
        #expect(m.provider.host == "92.134.242.73")
        #expect(m.provider.ssh?.user == "jeo")
        #expect(m.provider.ssh?.key_ref == "vault://obyw/deploy-ssh-key")
        #expect(m.services?["pocketbase"] != nil)
        #expect(m.services?["caddy"] != nil)
        #expect(m.services?["vaultwarden"] != nil)
        #expect(m.services?["pocketbase"]?.ports?["http"] == 8091)
        #expect(m.services?["pocketbase"]?.bridges?["admin"]?.local_port == 9091)
        #expect(m.services?["pocketbase"]?.bridges?["admin"]?.remote_port == 8091)
        #expect(m.agencies?.count == 2)
        #expect(m.clients?.first?.slug == "sigma-analytics")
        #expect(m.clients?.first?.type == .agencyClient)
        #expect(m.observability_backbone?.kurma_endpoint == "https://status.obyw.one/api")
    }

    @Test("TP-SEIS-01b: JSON round-trip (encode then decode produces equal manifest)")
    func testRoundTrip() throws {
        let data = try fixture("prod")
        let original = try EnvironmentManifest.decode(fromJSON: data)
        let encoded = try original.encodeToJSON()
        let decoded = try EnvironmentManifest.decode(fromJSON: encoded)
        #expect(original == decoded)
    }

    @Test("TP-SEIS-01c: addressing dot-address helper")
    func testDotAddress() throws {
        let data = try fixture("prod")
        let m = try EnvironmentManifest.decode(fromJSON: data)
        #expect(m.addressing.dotAddress == "obyw-one.obyw-one.prod")
    }

    @Test("TP-SEIS-01d: local.json inherits_from field present")
    func testLocalInheritsFrom() throws {
        let data = try fixture("local")
        let m = try EnvironmentManifest.decode(fromJSON: data)
        #expect(m.inherits_from == "prod")
        #expect(m.provider.kind == .local)
        #expect(m.provider.host == "127.0.0.1")
    }
}
