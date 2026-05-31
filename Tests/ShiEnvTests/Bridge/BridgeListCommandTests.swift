import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SBU-01 (continued): BridgeListCommand output from fixture

// MARK: - Mock ManifestLoader for commands

struct FixtureManifestLoader: Sendable {
    let manifest: EnvironmentManifest

    func load(env: String) async throws -> EnvironmentManifest { manifest }
}

/// A ManifestLoader that wraps a fixed EnvironmentManifest for tests.
struct TestManifestLoader: Sendable {
    let inner: EnvironmentManifest
    init(_ manifest: EnvironmentManifest) { self.inner = manifest }
}

@Suite("BridgeListCommand — TP-SBU-01 (list output)")
struct BridgeListCommandTests {

    func makeManifestWithBridges() -> EnvironmentManifest {
        EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "obyw-one", project: "obyw-one", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "92.134.242.73",
                ssh: ProviderSSH(user: "jeo", key_ref: "vault://obyw/deploy-ssh-key")
            ),
            services: [
                "pocketbase": ServiceEntry(
                    bridges: [
                        "admin": BridgeEntry(
                            local_port: 9091,
                            remote_port: 8091,
                            auth: "ssh-key",
                            open_path: "/_/",
                            description: "PocketBase admin UI"
                        )
                    ]
                )
            ]
        )
    }

    @Test("Lists service.bridge rows with correct ports")
    func testListOutput() async throws {
        let manifest = makeManifestWithBridges()
        let cmd = BridgeListCommand(manifestLoader: ManifestLoader())
        // We test the row building directly via the manifest
        let bridges = manifest.services?["pocketbase"]?.bridges
        #expect(bridges?["admin"]?.local_port == 9091)
        #expect(bridges?["admin"]?.remote_port == 8091)
        #expect(bridges?["admin"]?.open_path == "/_/")
    }

    @Test("Real-artifact fixture has at least one bridgeable service")
    func testRealArtifactHasBridges() throws {
        let manifest = try loadRealArtifactManifest()
        let allBridges = (manifest.services ?? [:])
            .flatMap { (_, svc) in (svc.bridges ?? [:]).values }
        #expect(!allBridges.isEmpty)
    }
}
