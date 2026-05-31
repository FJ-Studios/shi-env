import Foundation

// MARK: - BridgeStatusCommand
//
// Implements `shi bridge status`
//
// Lists all currently-open tunnels by cross-referencing BridgeRegistry
// (known pids) with lsof (which ports are listening).
//
// Spec: features/shi-bridge-unification-2026-05-31.md §3.2
// BR-SBU-04: lsof -nP -iTCP:<port> (read-only)

public struct BridgeStatusCommand: Sendable {

    private let registry: BridgeRegistry
    private let status: BridgeStatus

    public init(
        registry: BridgeRegistry = BridgeRegistry(),
        status: BridgeStatus = BridgeStatus()
    ) {
        self.registry = registry
        self.status = status
    }

    public func run(outputStream: inout some TextOutputStream) async throws -> Int32 {
        let handles = await registry.allHandles()

        if handles.isEmpty {
            outputStream.write("No open tunnels.\n")
            return 0
        }

        // Cross-reference with lsof to confirm port is listening
        let col = (svc: 22, br: 12, lp: 10, pid: 8, ts: 26)
        let header = pad("SERVICE.BRIDGE", col.svc) + pad("LOCAL", col.lp)
            + pad("PID", col.pid) + "OPENED"
        outputStream.write(header + "\n")
        outputStream.write(String(repeating: "-", count: header.count + col.ts) + "\n")

        for handle in handles {
            let isListening = await status.info(port: handle.localPort) != nil
            let listeningMark = isListening ? "" : " [NOT LISTENING]"
            let addrStr = "\(handle.addr.service).\(handle.addr.bridge)"
            let line = pad(addrStr, col.svc)
                + pad(":\(handle.localPort)", col.lp)
                + pad("\(handle.pid)", col.pid)
                + handle.openedAt + listeningMark
            outputStream.write(line + "\n")
        }
        return 0
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.count < width ? s + String(repeating: " ", count: width - s.count) : s + " "
    }
}
