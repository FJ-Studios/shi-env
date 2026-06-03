import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SELP-01: local.yml inherits prod.yml; merged manifest correct

@Suite("LocalInheritance — TP-SELP-01")
struct LocalInheritanceTests {

    @Test("TP-SELP-01: local env merged with prod yields correct service map")
    func testLocalInheritsFromProd() throws {
        let local = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "local"),
            inherits_from: "prod",
            provider: ProviderBlock(kind: .local, host: "127.0.0.1"),
            services: [
                "pocketbase": ServiceEntry(bridges: [:]),   // override: no bridges locally
                "caddy": ServiceEntry(ports: ["http": 8080, "https": 8443])
            ]
        )

        let prod = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "92.134.242.73",
                ssh: ProviderSSH(user: "jeo", key_ref: "shi-secret://obyw/deploy-ssh-key")
            ),
            services: [
                "pocketbase": ServiceEntry(
                    image: "pocketbase@v0.22",
                    ports: ["http": 8091],
                    bridges: [
                        "admin": BridgeEntry(local_port: 9091, remote_port: 8091, auth: "ssh-key",
                                             open_path: "/_/")
                    ]
                ),
                "caddy": ServiceEntry(ports: ["http": 80, "https": 443])
            ]
        )

        let resolver = InheritanceResolver(catalogue: ["local": local, "prod": prod])
        let merged = try resolver.resolve(name: "local")

        // Provider should be local (child wins)
        #expect(merged.provider.kind == .local)
        #expect(merged.provider.host == "127.0.0.1")

        // pocketbase: bridges should be empty (child explicit override wins)
        let pb = merged.services?["pocketbase"]
        #expect(pb != nil)
        #expect(pb?.bridges?.isEmpty == true)

        // pocketbase: image + port inherited from prod
        #expect(pb?.image == "pocketbase@v0.22")
        #expect(pb?.ports?["http"] == 8091)

        // caddy: local ports override prod
        let caddy = merged.services?["caddy"]
        #expect(caddy?.ports?["http"] == 8080)
        #expect(caddy?.ports?["https"] == 8443)
    }

    @Test("TP-SELP-01b: merged manifest carries no inherits_from (consumed by resolver)")
    func testMergedManifestHasNoInheritsFrom() throws {
        let local = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "local"),
            inherits_from: "prod",
            provider: ProviderBlock(kind: .local, host: "127.0.0.1")
        )
        let prod = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "prod"),
            provider: ProviderBlock(kind: .ovhVps, host: "1.2.3.4")
        )

        let resolver = InheritanceResolver(catalogue: ["local": local, "prod": prod])
        let merged = try resolver.resolve(name: "local")
        #expect(merged.inherits_from == nil)
    }

    @Test("TP-SELP-01c: clients[] inherited from prod when local has none")
    func testClientsInheritedFromProd() throws {
        let local = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "local"),
            inherits_from: "prod",
            provider: ProviderBlock(kind: .local, host: "127.0.0.1")
        )
        let prod = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "prod"),
            provider: ProviderBlock(kind: .ovhVps, host: "1.2.3.4"),
            clients: [
                ClientEntry(slug: "sigma-analytics", operating_agency: "obyw-one",
                            type: .agencyClient, phase: .pending,
                            scopes: ["storybook", "api"])
            ]
        )

        let resolver = InheritanceResolver(catalogue: ["local": local, "prod": prod])
        let merged = try resolver.resolve(name: "local")
        #expect(merged.clients?.count == 1)
        #expect(merged.clients?.first?.slug == "sigma-analytics")
    }
}
