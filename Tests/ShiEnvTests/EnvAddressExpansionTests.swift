import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEV-07: Wildcard addr expansion

@Suite("EnvCommand address expansion — TP-SEV-07")
struct EnvAddressExpansionTests {

    private func makeIndex() -> MotoEnvIndex {
        MotoEnvIndex(entries: [
            EnvIndexEntry(workspace: "ws-a", project: "proj-a", environment: "prod",
                          providerKind: "ovh-vps", host: "10.0.0.1", serviceCount: 2,
                          manifestPath: ".shikki/env/prod.json"),
            EnvIndexEntry(workspace: "ws-a", project: "proj-a", environment: "local",
                          providerKind: "local", host: "127.0.0.1", serviceCount: 1,
                          manifestPath: ".shikki/env/local.json"),
            EnvIndexEntry(workspace: "ws-b", project: "proj-b", environment: "prod",
                          providerKind: "hetzner-vps", host: "10.0.0.2", serviceCount: 3,
                          manifestPath: ".shikki/env/prod.json"),
            EnvIndexEntry(workspace: "ws-c", project: "proj-c", environment: "local",
                          providerKind: "local", host: "127.0.0.1", serviceCount: 1,
                          manifestPath: ".shikki/env/local.json"),
        ])
    }

    @Test("TP-SEV-07a: exact address returns single entry")
    func testExactAddress() {
        let index = makeIndex()
        let result = EnvCommand.expandAddress("ws-a.proj-a.prod", in: index)
        #expect(result.count == 1)
        #expect(result[0].environment == "prod")
        #expect(result[0].workspace == "ws-a")
    }

    @Test("TP-SEV-07b: wildcard *.*.local.* returns all local envs")
    func testWildcardLocalEnvs() {
        let index = makeIndex()
        let result = EnvCommand.expandAddress("*.*.local", in: index)
        #expect(result.count == 2)
        for entry in result {
            #expect(entry.environment == "local")
        }
    }

    @Test("TP-SEV-07c: wildcard *.*.prod returns all prod envs")
    func testWildcardProdEnvs() {
        let index = makeIndex()
        let result = EnvCommand.expandAddress("*.*.prod", in: index)
        #expect(result.count == 2)
        for entry in result {
            #expect(entry.environment == "prod")
        }
    }

    @Test("TP-SEV-07d: workspace prefix ws-a.* matches ws-a only")
    func testWorkspacePrefix() {
        let index = makeIndex()
        let result = EnvCommand.expandAddress("ws-a.*.*", in: index)
        #expect(result.count == 2)
        for entry in result {
            #expect(entry.workspace == "ws-a")
        }
    }

    @Test("TP-SEV-07e: 'all' keyword returns all entries")
    func testAllKeyword() {
        let index = makeIndex()
        let result = EnvCommand.expandAddress("all", in: index)
        #expect(result.count == 4)
    }

    @Test("TP-SEV-07f: non-matching address returns empty array")
    func testNonMatchingAddress() {
        let index = makeIndex()
        let result = EnvCommand.expandAddress("ws-z.proj-z.prod", in: index)
        #expect(result.isEmpty)
    }
}
