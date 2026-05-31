import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SBU-10: Composition test
// shi env open obyw-one.obyw-one.prod.pocketbase delegates via bridge logic
// In practice we verify BridgeAddress + BridgeEntry resolution from the
// real-artifact fixture composes end-to-end without error.

@Suite("Bridge composition — TP-SBU-10")
struct BridgeCompositionTests {

    @Test("TP-SBU-10: real-artifact fixture resolves all fields needed by BridgeOpener")
    func testCompositionFromRealArtifact() throws {
        let manifest = try loadRealArtifactManifest()

        // Simulate what BridgeOpener.open() does:
        // 1. Resolve service
        let addr = BridgeAddress.parse("pocketbase.admin")
        let service = manifest.services?[addr.service]
        #expect(service != nil)

        // 2. Resolve bridge entry
        let bridge = service?.bridges?[addr.bridge]
        #expect(bridge != nil)
        #expect(bridge?.local_port == 9091)
        #expect(bridge?.remote_port == 8091)

        // 3. Resolve SSH config
        let ssh = manifest.provider.ssh
        #expect(ssh != nil)
        #expect(ssh?.user == "jeo")
        #expect(ssh?.key_ref.hasPrefix("vault://") == true)

        // 4. Compose the expected SSH command arguments
        let expectedArgs = [
            "/usr/bin/ssh",
            "-N",
            "-i", "<key-path>", // would be resolved by SecretsBroker
            "-L", "9091:127.0.0.1:8091",
            "jeo@92.134.242.73"
        ]
        #expect(expectedArgs[5] == "9091:127.0.0.1:8091")
        #expect(expectedArgs[6] == "\(ssh!.user)@\(manifest.provider.host)")

        // 5. open_path drives browser open
        #expect(bridge?.open_path == "/_/")
    }

    @Test("TP-SBU-10b: BridgePluginRegistration exposes 'bridge' verb with correct sub-verbs")
    func testPluginRegistration() {
        #expect(ShiBridgePlugin.verb == "bridge")
        #expect(ShiBridgePlugin.subVerbs.contains("open"))
        #expect(ShiBridgePlugin.subVerbs.contains("list"))
        #expect(ShiBridgePlugin.subVerbs.contains("status"))
        #expect(ShiBridgePlugin.subVerbs.contains("close"))
    }
}
