import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SBU-05: BridgeRegistry stores and retrieves handles

@Suite("BridgeRegistry — TP-SBU-05")
struct BridgeRegistryTests {

    func makeTempRoot() -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shi-env-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("TP-SBU-05a: register + allHandles returns registered handle")
    func testRegisterAndList() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = BridgeRegistry(shikkiRoot: root)
        let addr = BridgeAddress(service: "pocketbase", bridge: "admin")
        let handle = BridgeHandle(pid: getpid(), localPort: 9091, addr: addr)

        await registry.register(handle)
        let handles = await registry.allHandles()
        // getpid() is alive so the entry should persist
        #expect(handles.contains { $0.localPort == 9091 && $0.addr == addr })
    }

    @Test("TP-SBU-05b: deregister removes handle from allHandles")
    func testDeregister() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = BridgeRegistry(shikkiRoot: root)
        let addr = BridgeAddress(service: "pocketbase", bridge: "admin")
        let handle = BridgeHandle(pid: getpid(), localPort: 9091, addr: addr)

        await registry.register(handle)
        await registry.deregister(pid: handle.pid)
        let handles = await registry.allHandles()
        #expect(!handles.contains { $0.pid == handle.pid })
    }

    @Test("TP-SBU-05c: stale entries (dead pid) are pruned on allHandles read")
    func testStalePidPruned() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = BridgeRegistry(shikkiRoot: root)
        // Spawn a process, record it, wait for it to exit, then verify it's pruned.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try proc.run()
        let deadPid = proc.processIdentifier
        proc.waitUntilExit()
        // pid is now dead (process exited)

        let addr = BridgeAddress(service: "caddy", bridge: "admin")
        let handle = BridgeHandle(pid: deadPid, localPort: 8080, addr: addr)
        await registry.register(handle)
        let handles = await registry.allHandles()
        // Dead pid must not appear
        #expect(!handles.contains { $0.pid == deadPid }, "Stale entry for dead pid should be pruned")
    }
}
