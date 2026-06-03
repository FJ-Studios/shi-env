import Foundation

// MARK: - TailscaleProviderResolver
//
// Resolves `tailscale-overlay` provider kind (BR-SELP-14, §3.7).
// Reads `tailscale status --json` via a subprocess and maps
// `services[].target_host` (Tailscale MagicDNS name) → overlay IP.
//
// Falls back to single-host 127.0.0.1 if Tailscale is unavailable
// (per §3.7: "Falls back to single-host local-loopback if Tailscale unavailable").
//
// Spec: features/shi-env-local-prod-parity-2026-05-31.md §3.7

public struct TailscaleProviderResolver: Sendable {

    public struct TailscaleHost: Sendable, Equatable {
        public let name: String
        public let ip: String

        public init(name: String, ip: String) {
            self.name = name
            self.ip = ip
        }
    }

    public struct ResolutionResult: Sendable {
        /// Map of Tailscale MagicDNS hostname → overlay IP.
        public let hostToIP: [String: String]
        /// True if Tailscale was available and responded.
        public let tailscaleAvailable: Bool
        /// Detail message (e.g. error description when unavailable).
        public let detail: String?

        public init(hostToIP: [String: String], tailscaleAvailable: Bool, detail: String? = nil) {
            self.hostToIP = hostToIP
            self.tailscaleAvailable = tailscaleAvailable
            self.detail = detail
        }
    }

    // MARK: - StatusOutput (decoded from `tailscale status --json`)

    /// Minimal shape of `tailscale status --json` output.
    private struct StatusOutput: Decodable {
        struct Peer: Decodable {
            let HostName: String
            let TailscaleIPs: [String]
        }
        let Self_: Peer?
        let Peer: [String: Peer]?

        enum CodingKeys: String, CodingKey {
            case Self_ = "Self"
            case Peer
        }
    }

    private let tailscaleBinary: String

    /// - Parameter tailscaleBinary: Path to `tailscale` CLI. Override in tests.
    public init(tailscaleBinary: String = "/usr/local/bin/tailscale") {
        self.tailscaleBinary = tailscaleBinary
    }

    /// Resolve all Tailscale hostnames to IPs from `tailscale status --json`.
    public func resolve() async -> ResolutionResult {
        let result = await runTailscale(["status", "--json"])
        guard result.exitCode == 0, !result.output.isEmpty else {
            return ResolutionResult(
                hostToIP: [:],
                tailscaleAvailable: false,
                detail: result.error.isEmpty ? "tailscale binary not found or daemon not running" : result.error
            )
        }

        guard let data = result.output.data(using: .utf8) else {
            return ResolutionResult(hostToIP: [:], tailscaleAvailable: false, detail: "failed to decode tailscale output")
        }

        do {
            let decoder = JSONDecoder()
            let status = try decoder.decode(StatusOutput.self, from: data)
            var map: [String: String] = [:]

            if let selfNode = status.Self_, let ip = selfNode.TailscaleIPs.first {
                map[selfNode.HostName] = ip
            }
            for (_, peer) in (status.Peer ?? [:]) {
                if let ip = peer.TailscaleIPs.first {
                    map[peer.HostName] = ip
                }
            }
            return ResolutionResult(hostToIP: map, tailscaleAvailable: true)
        } catch {
            return ResolutionResult(
                hostToIP: [:],
                tailscaleAvailable: false,
                detail: "parse error: \(error.localizedDescription)"
            )
        }
    }

    /// Resolve a specific set of MagicDNS hostnames to IPs.
    /// Missing names fall back to 127.0.0.1 (single-host fallback per §3.7).
    public func resolveHosts(_ names: [String]) async -> [String: String] {
        let all = await resolve()
        var result: [String: String] = [:]
        for name in names {
            result[name] = all.hostToIP[name] ?? "127.0.0.1"
        }
        return result
    }

    // MARK: Private

    private struct ShellResult {
        let exitCode: Int32
        let output: String
        let error: String
    }

    private func runTailscale(_ args: [String]) async -> ShellResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tailscaleBinary)
            process.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // terminationHandler BEFORE run() per subprocess-bug-onion rule
            process.terminationHandler = { _ in }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ShellResult(exitCode: 127, output: "", error: error.localizedDescription))
                return
            }

            // Drain pipes in parallel (prevent >64KB deadlock)
            Task.detached {
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                continuation.resume(returning: ShellResult(exitCode: process.terminationStatus, output: out, error: err))
            }
        }
    }
}
