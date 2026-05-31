import Foundation

// MARK: - BackendAdapter
//
// Protocol: abstracts local (launchd/systemctl) vs remote (SSH+bash today;
// shi env apply in sub-spec #5) service mutations.
//
// BR-SEV-04: backend adapter shape allows swap without verb-surface change.
// BR-SEV-03: mandatory --dry-run first invocation per target; state persisted
//             in ~/.shikki/run/env-apply-history/<host>.json.
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.3

// MARK: - Types

/// Result of a backend operation.
public struct BackendResult: Sendable {
    public let host: String
    public let serviceName: String
    public let action: BackendAction
    public let success: Bool
    public let output: String
    public let error: String?

    public init(host: String, serviceName: String, action: BackendAction, success: Bool, output: String, error: String? = nil) {
        self.host = host
        self.serviceName = serviceName
        self.action = action
        self.success = success
        self.output = output
        self.error = error
    }
}

public enum BackendAction: String, Sendable {
    case start
    case stop
    case restart
    case status
    case logs
}

/// Dry-run description of a planned action.
public struct PlannedAction: Sendable {
    public let host: String
    public let serviceName: String
    public let action: BackendAction
    public let description: String

    public init(host: String, serviceName: String, action: BackendAction, description: String) {
        self.host = host
        self.serviceName = serviceName
        self.action = action
        self.description = description
    }
}

/// Per-service status.
public struct ServiceStatus: Sendable, Codable {
    public let name: String
    public let status: String     // "green" | "red" | "unknown"
    public let probePath: String?
    public let probeLatencyMs: Double?
    public let detail: String?

    public init(name: String, status: String, probePath: String? = nil, probeLatencyMs: Double? = nil, detail: String? = nil) {
        self.name = name
        self.status = status
        self.probePath = probePath
        self.probeLatencyMs = probeLatencyMs
        self.detail = detail
    }
}

// MARK: - DryRunHistory

/// Tracks whether a `--dry-run` has been performed for a given target host,
/// satisfying BR-SEV-03 (mandatory dry-run before first --apply).
public struct DryRunHistory: Sendable {

    private let runDir: URL

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.runDir = shikkiRoot.appendingPathComponent("run/env-apply-history")
    }

    private func historyURL(host: String) -> URL {
        let safeHost = host.replacingOccurrences(of: "/", with: "_")
        return runDir.appendingPathComponent("\(safeHost).json")
    }

    /// Returns true if a dry-run has been recorded for `host`.
    public func hasDryRun(host: String) -> Bool {
        FileManager.default.fileExists(atPath: historyURL(host: host).path)
    }

    /// Record that a dry-run was performed for `host`.
    public func recordDryRun(host: String) throws {
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let record = ["host": host, "dry_run_at": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
        try data.write(to: historyURL(host: host), options: .atomic)
    }
}

// MARK: - BackendAdapter Protocol

/// Abstracts local vs remote service lifecycle operations.
///
/// Both `LocalBackend` and `RemoteSshBackend` conform to this protocol.
/// The verb commands accept a `BackendAdapter` so the backend can be swapped
/// (e.g. by sub-spec #5) without changing verb code.
public protocol BackendAdapter: Sendable {

    /// Start a service.
    func start(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult

    /// Stop a service.
    func stop(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult

    /// Restart a service.
    func restart(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult

    /// Probe health.
    func status(service: String, serviceEntry: ServiceEntry) async throws -> ServiceStatus

    /// Stream logs. Returns output lines via the returned AsyncStream.
    func logs(service: String, serviceEntry: ServiceEntry, follow: Bool) async throws -> String

    /// Preview planned action without executing.
    func plan(service: String, serviceEntry: ServiceEntry, action: BackendAction) -> PlannedAction
}

// MARK: - LocalBackend

/// Backend implementation for local services (macOS launchd / Linux systemctl).
public struct LocalBackend: BackendAdapter {

    private let host: String

    public init(host: String = "127.0.0.1") {
        self.host = host
    }

    public func start(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
        if dryRun {
            return BackendResult(host: host, serviceName: service, action: .start, success: true,
                                 output: "[dry-run] Would start \(service) on local host")
        }
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        let result = try await runLocalServicectl(unit: unit, verb: "start")
        return BackendResult(host: host, serviceName: service, action: .start,
                             success: result.exitCode == 0, output: result.output, error: result.error)
    }

    public func stop(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
        if dryRun {
            return BackendResult(host: host, serviceName: service, action: .stop, success: true,
                                 output: "[dry-run] Would stop \(service) on local host")
        }
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        let result = try await runLocalServicectl(unit: unit, verb: "stop")
        return BackendResult(host: host, serviceName: service, action: .stop,
                             success: result.exitCode == 0, output: result.output, error: result.error)
    }

    public func restart(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
        if dryRun {
            return BackendResult(host: host, serviceName: service, action: .restart, success: true,
                                 output: "[dry-run] Would restart \(service) on local host")
        }
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        let result = try await runLocalServicectl(unit: unit, verb: "restart")
        return BackendResult(host: host, serviceName: service, action: .restart,
                             success: result.exitCode == 0, output: result.output, error: result.error)
    }

    public func status(service: String, serviceEntry: ServiceEntry) async throws -> ServiceStatus {
        // Try HTTP probe first
        if let probes = serviceEntry.observability?.probes, let firstProbe = probes.first {
            let port = serviceEntry.ports?.values.first
            let baseURL = port.map { "http://127.0.0.1:\($0)" } ?? "http://127.0.0.1"
            let probeURL = baseURL + firstProbe
            let start = Date()
            if let url = URL(string: probeURL) {
                do {
                    let (_, response) = try await URLSession.shared.data(from: url)
                    let latency = Date().timeIntervalSince(start) * 1000
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let isGreen = (200..<300).contains(statusCode)
                    return ServiceStatus(name: service, status: isGreen ? "green" : "red",
                                        probePath: firstProbe, probeLatencyMs: latency,
                                        detail: "HTTP \(statusCode)")
                } catch {
                    return ServiceStatus(name: service, status: "red", probePath: firstProbe,
                                        detail: "probe failed: \(error.localizedDescription)")
                }
            }
        }
        return ServiceStatus(name: service, status: "unknown", detail: "no probe configured")
    }

    public func logs(service: String, serviceEntry: ServiceEntry, follow: Bool) async throws -> String {
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        #if os(Linux)
        var args = ["journalctl", "-u", unit, "--no-pager", "-n", "100"]
        if follow { args.append("-f") }
        let result = try await shell(args)
        return result.output
        #else
        return "[local logs] journalctl not available on macOS — use: log show --predicate 'subsystem == \"\(unit)\"'"
        #endif
    }

    public func plan(service: String, serviceEntry: ServiceEntry, action: BackendAction) -> PlannedAction {
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        return PlannedAction(host: host, serviceName: service, action: action,
                             description: "local: \(action.rawValue) \(unit)")
    }

    // MARK: Private

    private struct ShellResult {
        let exitCode: Int32
        let output: String
        let error: String
    }

    private func runLocalServicectl(unit: String, verb: String) async throws -> ShellResult {
        #if os(Linux)
        return try await shell(["systemctl", verb, unit])
        #else
        // macOS — try launchctl bootstrap/bootout for user agents, or just report not supported
        return ShellResult(exitCode: 1, output: "",
                           error: "systemctl not available on macOS. Use launchctl for \(unit).")
        #endif
    }

    private func shell(_ args: [String]) async throws -> ShellResult {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // O_CLOEXEC: set via Pipe() on Darwin; set terminationHandler BEFORE launch
            process.terminationHandler = { _ in }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
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

// MARK: - RemoteSshBackend

/// Backend for remote services via SSH + bash wrappers (today's impl).
/// Sub-spec #5 (shi env apply) will swap the internals; the protocol surface stays identical.
public struct RemoteSshBackend: BackendAdapter {

    public let host: String
    public let sshUser: String
    public let sshKeyPath: String?

    public init(host: String, sshUser: String = "root", sshKeyPath: String? = nil) {
        self.host = host
        self.sshUser = sshUser
        self.sshKeyPath = sshKeyPath
    }

    public func start(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        if dryRun {
            return BackendResult(host: host, serviceName: service, action: .start, success: true,
                                 output: "[dry-run] Would ssh \(sshUser)@\(host): systemctl start \(unit)")
        }
        let result = try await sshRun("systemctl start \(unit)")
        return BackendResult(host: host, serviceName: service, action: .start,
                             success: result.exitCode == 0, output: result.output, error: result.error)
    }

    public func stop(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        if dryRun {
            return BackendResult(host: host, serviceName: service, action: .stop, success: true,
                                 output: "[dry-run] Would ssh \(sshUser)@\(host): systemctl stop \(unit)")
        }
        let result = try await sshRun("systemctl stop \(unit)")
        return BackendResult(host: host, serviceName: service, action: .stop,
                             success: result.exitCode == 0, output: result.output, error: result.error)
    }

    public func restart(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        if dryRun {
            return BackendResult(host: host, serviceName: service, action: .restart, success: true,
                                 output: "[dry-run] Would ssh \(sshUser)@\(host): systemctl restart \(unit)")
        }
        let result = try await sshRun("systemctl restart \(unit)")
        return BackendResult(host: host, serviceName: service, action: .restart,
                             success: result.exitCode == 0, output: result.output, error: result.error)
    }

    public func status(service: String, serviceEntry: ServiceEntry) async throws -> ServiceStatus {
        // Probe via SSH curl to loopback on the remote host
        if let probes = serviceEntry.observability?.probes, let firstProbe = probes.first {
            let port = serviceEntry.ports?.values.first ?? 80
            let curlCmd = "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:\(port)\(firstProbe)"
            let start = Date()
            let result = try await sshRun(curlCmd)
            let latency = Date().timeIntervalSince(start) * 1000
            let code = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let isGreen = code.hasPrefix("2")
            return ServiceStatus(name: service, status: isGreen ? "green" : "red",
                                 probePath: firstProbe, probeLatencyMs: latency, detail: "HTTP \(code)")
        }
        // Fallback: systemctl is-active
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        let result = try await sshRun("systemctl is-active \(unit)")
        let active = result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "active"
        return ServiceStatus(name: service, status: active ? "green" : "red",
                             detail: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func logs(service: String, serviceEntry: ServiceEntry, follow: Bool) async throws -> String {
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        let cmd = follow
            ? "journalctl -u \(unit) -f -n 100"
            : "journalctl -u \(unit) --no-pager -n 100"
        let result = try await sshRun(cmd)
        return result.output
    }

    public func plan(service: String, serviceEntry: ServiceEntry, action: BackendAction) -> PlannedAction {
        let unit = serviceEntry.systemd?.unit ?? "\(service).service"
        return PlannedAction(host: host, serviceName: service, action: action,
                             description: "ssh \(sshUser)@\(host): systemctl \(action.rawValue) \(unit)")
    }

    // MARK: Private

    private struct SshResult {
        let exitCode: Int32
        let output: String
        let error: String
    }

    private func sshRun(_ command: String) async throws -> SshResult {
        return try await withCheckedThrowingContinuation { continuation in
            var args = ["/usr/bin/ssh"]
            if let keyPath = sshKeyPath { args += ["-i", keyPath] }
            args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                     "\(sshUser)@\(host)", command]

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Array(args.dropFirst())

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { _ in }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            Task.detached {
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                continuation.resume(returning: SshResult(exitCode: process.terminationStatus, output: out, error: err))
            }
        }
    }
}

// MARK: - BackendFactory

/// Creates the appropriate backend from a resolved `EnvironmentManifest`.
public enum BackendFactory {

    public static func make(for manifest: EnvironmentManifest) -> any BackendAdapter {
        switch manifest.provider.kind {
        case .local:
            return LocalBackend(host: manifest.provider.host)
        default:
            let ssh = manifest.provider.ssh
            return RemoteSshBackend(
                host: manifest.provider.host,
                sshUser: ssh?.user ?? "root",
                sshKeyPath: nil   // key loaded from vault at runtime; nil = ssh-agent
            )
        }
    }
}
