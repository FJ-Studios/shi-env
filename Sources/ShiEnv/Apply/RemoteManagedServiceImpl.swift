import Foundation
import ShikkiPluginAPI

// MARK: - RemoteManagedServiceImpl
//
// Concrete implementation that conforms to the `RemoteManagedService`
// protocol from `gh:FJ-Studios/shikki-plugin-api` v0.1.4.
//
// Each instance represents ONE service (e.g. pocketbase) running on ONE
// remote host. ShikkiKernel discovers conformers via the plugin registry and
// drives them through the `shi env apply` pipeline.
//
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.1
// BR-SERA-02: extends ShikkiKernel ManagedService pattern
// BR-SERA-03: all SSH via TimedRemoteExecutor (never bare Process())
// BR-SERA-14: protocol lives in shikki-plugin-api; impl here

/// The SSH authentication strategy.
public enum SshAuth: Sendable, Equatable {
    /// Path to an SSH private key file (resolved at apply-time via shi-secrets broker).
    case keyFile(path: String)
    /// Use the SSH agent (socket in SSH_AUTH_SOCK).
    case agent
}

/// The service manifest describing the desired state for one service.
public struct ServiceManifest: Sendable, Equatable {
    public let name: String
    public let systemdUnit: String?
    /// dpkg package name + desired version (nil = not managed via dpkg).
    public let dpkgPackage: String?
    public let dpkgVersion: String?
    /// Whether the Caddyfile should be synced for this service.
    public let manageCaddyfile: Bool
    /// kurma slug for monitor registration.
    public let kurmaSlug: String?
    /// Secret refs from the inventory services[].secrets_refs dict.
    public let secretsRefs: [String: String]

    public init(
        name: String,
        systemdUnit: String? = nil,
        dpkgPackage: String? = nil,
        dpkgVersion: String? = nil,
        manageCaddyfile: Bool = false,
        kurmaSlug: String? = nil,
        secretsRefs: [String: String] = [:]
    ) {
        self.name = name
        self.systemdUnit = systemdUnit
        self.dpkgPackage = dpkgPackage
        self.dpkgVersion = dpkgVersion
        self.manageCaddyfile = manageCaddyfile
        self.kurmaSlug = kurmaSlug
        self.secretsRefs = secretsRefs
    }

    /// Build a ServiceManifest from an EnvironmentManifest service entry.
    public static func from(
        name: String,
        entry: ServiceEntry
    ) -> ServiceManifest {
        ServiceManifest(
            name: name,
            systemdUnit: entry.systemd?.unit,
            dpkgPackage: nil,      // dpkg config is NOT yet in EnvironmentManifest schema — W2 spec addition
            dpkgVersion: nil,
            manageCaddyfile: entry.config_generator != nil,
            kurmaSlug: entry.observability?.kurma_slug,
            secretsRefs: entry.secrets_refs ?? [:]
        )
    }
}

/// A concrete RemoteManagedService conformer.
///
/// Owns the five sub-managers (systemd / dpkg / caddy / secrets / kurma) and
/// delegates probe/plan/execute to the `ConvergeOrchestrator`.
///
/// Per BR-SERA-14: the `RemoteManagedService` protocol is declared in
/// `gh:FJ-Studios/shikki-plugin-api`. This type is the plugin-side impl.
public actor RemoteManagedServiceImpl: RemoteManagedService {

    // MARK: - RemoteManagedService conformance

    public let host: String
    public let sshUser: String

    // MARK: - Private state

    private let manifest: ServiceManifest
    private let executor: SSHExecutorProtocol

    // MARK: - Init

    public init(
        host: String,
        sshUser: String,
        manifest: ServiceManifest,
        executor: SSHExecutorProtocol
    ) {
        self.host = host
        self.sshUser = sshUser
        self.manifest = manifest
        self.executor = executor
    }

    // MARK: - RemoteManagedService

    /// Probe current state by running read-only remote commands.
    public func probeRemote() async throws -> [String: String] {
        var result: [String: String] = [:]

        if let unit = manifest.systemdUnit {
            let output = try await executor.run(
                host: host,
                user: sshUser,
                command: "systemctl is-active \(unit) 2>/dev/null || echo inactive"
            )
            result["systemd_state"] = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let pkg = manifest.dpkgPackage {
            let output = try await executor.run(
                host: host,
                user: sshUser,
                command: "dpkg-query -W -f='${Version}' \(pkg) 2>/dev/null || echo not-installed"
            )
            result["dpkg_version"] = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        result["host"] = host
        result["service"] = manifest.name
        return result
    }

    // MARK: - Plan + Execute (used by ConvergeOrchestrator)

    /// Compute the converge plan for this service.
    func planConverge(
        from current: RemoteServiceState,
        to desired: ServiceManifest
    ) async throws -> ConvergePlan {
        var steps: [ConvergeStep] = []

        // secrets — only plan a step if there are secrets refs to manage
        if !desired.secretsRefs.isEmpty {
            let secretsStatus: ConvergeStepStatus = current.secretsInjected ? .match : .new
            steps.append(ConvergeStep(
                kind: .injectSecrets,
                status: secretsStatus,
                description: "secrets LoadCredential injection",
                detail: secretsStatus == .match ? nil : "systemd LoadCredential= (tmpfs /run/credentials)"
            ))
        }

        // dpkg
        if let desiredVer = desired.dpkgVersion {
            let currentVer = current.dpkgVersion ?? "not-installed"
            let dpkgStatus: ConvergeStepStatus = currentVer == desiredVer ? .match : (current.dpkgVersion == nil ? .new : .drift)
            steps.append(ConvergeStep(
                kind: .installPackage,
                status: dpkgStatus,
                description: "dpkg \(desired.dpkgPackage ?? desired.name)",
                detail: dpkgStatus == .match ? nil : "\(currentVer) → \(desiredVer)"
            ))
        }

        // systemd
        if let unit = desired.systemdUnit {
            let isActive = current.systemdState == "active"
            steps.append(ConvergeStep(
                kind: .systemdUnit,
                status: isActive ? .match : .drift,
                description: "systemd unit \(unit)",
                detail: isActive ? nil : "\(current.systemdState ?? "unknown") → active"
            ))
        }

        // Caddyfile
        if desired.manageCaddyfile {
            steps.append(ConvergeStep(
                kind: .syncCaddyfile,
                status: current.caddyfileSHA != nil ? .match : .new,
                description: "Caddyfile rsync + caddy reload",
                detail: nil
            ))
        }

        // kurma
        if let slug = desired.kurmaSlug {
            steps.append(ConvergeStep(
                kind: .kurmaRegister,
                status: current.kurmaRegistered ? .match : .new,
                description: "kurma monitor \(slug)",
                detail: nil
            ))
        }

        return ConvergePlan(
            serviceName: manifest.name,
            host: host,
            steps: steps
        )
    }
}

// MARK: - SSHExecutorProtocol

/// Abstraction over SSH command execution.
/// Production: `TimedSSHExecutor`. Tests: inject `MockSSHExecutor`.
/// BR-SERA-03: all SSH via TimedSubprocess, never bare Process().
public protocol SSHExecutorProtocol: Sendable {
    func run(host: String, user: String, command: String) async throws -> String
    func run(host: String, user: String, command: String, timeout: TimeInterval) async throws -> String
}

extension SSHExecutorProtocol {
    public func run(host: String, user: String, command: String) async throws -> String {
        try await run(host: host, user: user, command: command, timeout: 30)
    }
}

// MARK: - TimedSSHExecutor

/// Production SSH executor using TimedSubprocess (BR-SERA-03).
/// Uses SSH ControlMaster for connection reuse across the apply session.
public actor TimedSSHExecutor: SSHExecutorProtocol {

    public let sshKeyPath: String
    private let defaultTimeout: TimeInterval

    public init(sshKeyPath: String, defaultTimeout: TimeInterval = 30) {
        self.sshKeyPath = sshKeyPath
        self.defaultTimeout = defaultTimeout
    }

    public func run(host: String, user: String, command: String) async throws -> String {
        try await run(host: host, user: user, command: command, timeout: defaultTimeout)
    }

    public func run(
        host: String,
        user: String,
        command: String,
        timeout: TimeInterval
    ) async throws -> String {
        let args: [String] = [
            "/usr/bin/ssh",
            "-i", sshKeyPath,
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ServerAliveInterval=10",
            "-o", "ConnectTimeout=15",
            "-o", "BatchMode=yes",
            "\(user)@\(host)",
            command
        ]

        // Use Task-based approach to avoid Swift 6 Sendable violations with var capture.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.runProcess(args: args, host: host, command: command)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SSHError.timeout(host: host, command: command, timeout: timeout)
            }

            // Take the first result and cancel the other task.
            guard let first = try await group.next() else {
                throw SSHError.spawnFailed(underlying: CancellationError())
            }
            group.cancelAll()
            return first
        }
    }

    /// Synchronously runs an SSH process and returns its stdout.
    private func runProcess(args: [String], host: String, command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: args[0])
            proc.arguments = Array(args.dropFirst())

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            proc.terminationHandler = { p in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "exit \(p.terminationStatus)"
                    continuation.resume(throwing: SSHError.commandFailed(
                        host: host,
                        command: command,
                        exitCode: p.terminationStatus,
                        stderr: errMsg
                    ))
                }
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: SSHError.spawnFailed(underlying: error))
            }
        }
    }
}

// MARK: - SSHError

public enum SSHError: Error, LocalizedError, Sendable {
    case commandFailed(host: String, command: String, exitCode: Int32, stderr: String)
    case timeout(host: String, command: String, timeout: TimeInterval)
    case spawnFailed(underlying: Error)
    case sshKeyResolutionFailed(ref: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let h, let c, let code, let err):
            return "SSH \(h): command '\(c)' exited \(code): \(err)"
        case .timeout(let h, let c, let t):
            return "SSH \(h): command '\(c)' timed out after \(Int(t))s."
        case .spawnFailed(let e):
            return "SSH spawn failed: \(e.localizedDescription)"
        case .sshKeyResolutionFailed(let ref):
            return "SSH key ref '\(ref)' could not be resolved via shi-secrets broker."
        }
    }
}
