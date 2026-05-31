import Foundation

// MARK: - BridgeStatus
//
// lsof-based wrapper to query which local ports are currently listening.
// Used by `shi bridge status` to surface active tunnels.
//
// Spec: features/shi-bridge-unification-2026-05-31.md §3.2 + BR-SBU-04
// BR-SBU-04: shi bridge status uses lsof -nP -iTCP:<port> (read-only)

/// Information about a single listening port as reported by lsof.
public struct ListeningPortInfo: Sendable, Equatable {
    public let port: Int
    public let pid: pid_t
    public let command: String

    public init(port: Int, pid: pid_t, command: String) {
        self.port = port
        self.pid = pid
        self.command = command
    }
}

/// Queries lsof to find all listening TCP ports.
public struct BridgeStatus: Sendable {

    public init() {}

    /// Returns all ports that are currently in TCP LISTEN state.
    public func allListeningPorts() async -> [ListeningPortInfo] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return parseLsofOutput(output)
    }

    /// Returns listening info for a specific port, or nil if not listening.
    public func info(port: Int) async -> ListeningPortInfo? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return parseLsofOutput(output).first
    }

    // MARK: - Private

    /// Parse lsof output.
    ///
    /// Example line (fields: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME):
    /// ```
    /// ssh     12345 jeo   3u  IPv4 0x...  0t0  TCP 127.0.0.1:9091 (LISTEN)
    /// ```
    private func parseLsofOutput(_ output: String) -> [ListeningPortInfo] {
        var results: [ListeningPortInfo] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.dropFirst() { // skip header
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 9 else { continue }
            let command = fields[0]
            guard let pid = pid_t(fields[1]) else { continue }
            let name = fields[8] // e.g. "127.0.0.1:9091" or "*:9091"
            guard let portStr = name.split(separator: ":").last,
                  let port = Int(portStr) else { continue }
            results.append(ListeningPortInfo(port: port, pid: pid, command: command))
        }
        return results
    }
}
