import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SBU-01: BridgeOpener resolves port+host from fixture manifest; ssh command composed correctly
// MARK: - TP-SBU-02: BridgeOpener fails fast when bridges block missing
// MARK: - TP-SBU-03: BridgeOpener resolves vault:// auth via SecretsBroker mock

// MARK: - Mock SecretsBroker

struct MockSecretsBroker: SecretsBrokerProtocol, Sendable {
    let resolvedPath: String

    func resolveSSHKeyPath(_ ref: String) async throws -> String {
        guard ref.hasPrefix("vault://") else {
            throw BridgeError.vaultRefNotResolvable(ref: ref)
        }
        return resolvedPath
    }
}

struct FailingSecretsBroker: SecretsBrokerProtocol, Sendable {
    func resolveSSHKeyPath(_ ref: String) async throws -> String {
        throw BridgeError.vaultRefNotResolvable(ref: ref)
    }
}

// MARK: - Mock PortChecker (never listening)
struct MockPortChecker: Sendable {
    let isListeningResult: Bool
    func isListening(port: Int) async -> Bool { isListeningResult }
}

// MARK: - Mock URLOpener

actor MockURLOpener: URLOpenerProtocol {
    var openedURLs: [String] = []
    func open(_ urlString: String) async {
        openedURLs.append(urlString)
    }
    func capturedURLs() -> [String] { openedURLs }
}

// MARK: - Fixture helper

func loadRealArtifactManifest() throws -> EnvironmentManifest {
    let url = Bundle.module.url(
        forResource: "back-obyw-one-pocketbase",
        withExtension: "json",
        subdirectory: "Fixtures/real-artifacts"
    )!
    let data = try Data(contentsOf: url)
    return try EnvironmentManifest.decode(fromJSON: data)
}

// MARK: - Tests

@Suite("BridgeOpener — TP-SBU-01/02/03")
struct BridgeOpenerTests {

    @Test("TP-SBU-01: resolves local_port=9091, remote_port=8091 from real-artifact fixture")
    func testBridgeEntryResolvedFromFixture() throws {
        let manifest = try loadRealArtifactManifest()

        // Verify the bridge entry is present as expected by BR-SBU-01
        let bridge = manifest.services?["pocketbase"]?.bridges?["admin"]
        #expect(bridge != nil)
        #expect(bridge?.local_port == 9091)
        #expect(bridge?.remote_port == 8091)
        #expect(bridge?.auth == "ssh-key")
        #expect(bridge?.open_path == "/_/")
        #expect(manifest.provider.host == "92.134.242.73")
        #expect(manifest.provider.ssh?.user == "jeo")
        #expect(manifest.provider.ssh?.key_ref == "vault://obyw/deploy-ssh-key")
    }

    @Test("TP-SBU-02: fails fast with BridgeError.missingBridgesBlock when service has no bridges")
    func testMissingBridgesBlock() async throws {
        // Build a manifest with a service that has no bridges block
        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "test", project: "test", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "1.2.3.4",
                ssh: ProviderSSH(user: "jeo", key_ref: "vault://test/key")
            ),
            services: [
                "caddy": ServiceEntry()  // no bridges
            ]
        )

        let broker = MockSecretsBroker(resolvedPath: "/tmp/test_key")
        let urlOpener = MockURLOpener()
        let opener = BridgeOpener(
            secretsBroker: broker,
            urlOpener: urlOpener
        )

        let addr = BridgeAddress(service: "caddy", bridge: "admin")
        do {
            _ = try await opener.open(addr: addr, manifest: manifest)
            #expect(Bool(false), "Expected error")
        } catch BridgeError.missingBridgesBlock(let service) {
            #expect(service == "caddy")
        }
    }

    @Test("TP-SBU-02b: fails fast when bridge name not found")
    func testUnknownBridge() async throws {
        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "test", project: "test", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "1.2.3.4",
                ssh: ProviderSSH(user: "jeo", key_ref: "vault://test/key")
            ),
            services: [
                "pocketbase": ServiceEntry(
                    bridges: [
                        "admin": BridgeEntry(local_port: 9091, remote_port: 8091, auth: "ssh-key")
                    ]
                )
            ]
        )

        let broker = MockSecretsBroker(resolvedPath: "/tmp/test_key")
        let urlOpener = MockURLOpener()
        let opener = BridgeOpener(
            secretsBroker: broker,
            urlOpener: urlOpener
        )

        let addr = BridgeAddress(service: "pocketbase", bridge: "metrics")
        do {
            _ = try await opener.open(addr: addr, manifest: manifest)
            #expect(Bool(false), "Expected error")
        } catch BridgeError.unknownBridge(let service, let bridge) {
            #expect(service == "pocketbase")
            #expect(bridge == "metrics")
        }
    }

    @Test("TP-SBU-03: BridgeError.vaultRefNotResolvable raised when broker fails")
    func testVaultRefResolutionFails() async throws {
        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "test", project: "test", environment: "prod"),
            provider: ProviderBlock(
                kind: .ovhVps,
                host: "1.2.3.4",
                ssh: ProviderSSH(user: "jeo", key_ref: "vault://obyw/deploy-ssh-key")
            ),
            services: [
                "pocketbase": ServiceEntry(
                    bridges: [
                        "admin": BridgeEntry(local_port: 9091, remote_port: 8091, auth: "ssh-key")
                    ]
                )
            ]
        )

        let broker = FailingSecretsBroker()
        let urlOpener = MockURLOpener()
        let opener = BridgeOpener(
            secretsBroker: broker,
            urlOpener: urlOpener
        )

        do {
            _ = try await opener.open(addr: BridgeAddress(service: "pocketbase"), manifest: manifest)
            #expect(Bool(false), "Expected error")
        } catch BridgeError.vaultRefNotResolvable(let ref) {
            #expect(ref == "vault://obyw/deploy-ssh-key")
        }
    }
}
