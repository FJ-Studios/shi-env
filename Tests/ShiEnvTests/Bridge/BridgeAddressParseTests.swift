import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SBU-01 (partial): BridgeAddress parsing

@Suite("BridgeAddress — parsing")
struct BridgeAddressParseTests {

    @Test("Bare service name defaults bridge to 'admin'")
    func testBareServiceName() {
        let addr = BridgeAddress.parse("pocketbase")
        #expect(addr.service == "pocketbase")
        #expect(addr.bridge == "admin")
    }

    @Test("Service.bridge form parsed correctly")
    func testServiceDotBridge() {
        let addr = BridgeAddress.parse("pocketbase.metrics")
        #expect(addr.service == "pocketbase")
        #expect(addr.bridge == "metrics")
    }

    @Test("'back' shorthand normalised")
    func testBackShorthand() {
        let addr = BridgeAddress.parse("back")
        #expect(addr.service == "back")
        #expect(addr.bridge == "admin")
    }
}
