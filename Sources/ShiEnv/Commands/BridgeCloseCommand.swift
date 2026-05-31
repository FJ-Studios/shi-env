import Foundation

// MARK: - BridgeCloseCommand
//
// Implements `shi bridge close <site>[.<bridge>]`
//
// Sends SIGTERM to the SSH pid for the named tunnel; SIGKILL after 5s.
//
// Spec: features/shi-bridge-unification-2026-05-31.md §3.2
// BR-SBU-05: SIGTERM first; SIGKILL after 5s if still alive

public struct BridgeCloseCommand: Sendable {

    private let registry: BridgeRegistry

    public init(registry: BridgeRegistry = BridgeRegistry()) {
        self.registry = registry
    }

    public func run(
        address: String,
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {
        let addr = BridgeAddress.parse(address)

        guard let handle = await registry.handle(for: addr) else {
            outputStream.write("No open tunnel for '\(addr.service).\(addr.bridge)'.\n")
            return 1
        }

        outputStream.write("Closing tunnel: \(addr.service).\(addr.bridge) (pid \(handle.pid))\n")

        // BR-SBU-05: SIGTERM first
        kill(handle.pid, SIGTERM)

        // Wait up to 5s for graceful exit
        var waited = 0.0
        let step = 0.2
        while waited < 5.0 {
            if kill(handle.pid, 0) != 0 { break }
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            waited += step
        }

        // SIGKILL if still alive
        if kill(handle.pid, 0) == 0 {
            kill(handle.pid, SIGKILL)
            outputStream.write("Sent SIGKILL after 5s (process did not exit gracefully).\n")
        }

        await registry.deregister(pid: handle.pid)
        outputStream.write("Tunnel closed.\n")
        return 0
    }
}
