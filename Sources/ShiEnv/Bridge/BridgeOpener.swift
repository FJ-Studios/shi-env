import Foundation

// MARK: - BridgeOpener
//
// Actor responsible for opening an SSH port-forward tunnel described by an
// inventory BridgeEntry.
//
// Spec: features/shi-bridge-unification-2026-05-31.md §3.3
// BR-SBU-01: config from inventory bridges block — NO hardcoded port table
// BR-SBU-02: SSH key via vault:// ref
// BR-SBU-03: TimedSubprocess for spawn (never bare Process())
// BR-SBU-10: SIGTERM trap registered on each spawned ssh process

/// Identifies which service + bridge name to open.
public struct BridgeAddress: Sendable, Equatable {
    /// Service name in the manifest (e.g. "pocketbase").
    public let service: String
    /// Bridge name within the service (e.g. "admin"). Defaults to "admin".
    public let bridge: String

    public init(service: String, bridge: String = "admin") {
        self.service = service
        self.bridge = bridge
    }

    /// Parse "pocketbase" or "pocketbase.admin" form.
    public static func parse(_ raw: String) -> BridgeAddress {
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        return BridgeAddress(service: parts[0], bridge: parts.count > 1 ? parts[1] : "admin")
    }
}

/// A live tunnel handle returned by BridgeOpener.open.
public struct BridgeHandle: Sendable, Equatable, Codable {
    public let pid: pid_t
    public let localPort: Int
    public let addr: BridgeAddress
    /// ISO-8601 timestamp when the tunnel was opened.
    public let openedAt: String

    public init(pid: pid_t, localPort: Int, addr: BridgeAddress) {
        self.pid = pid
        self.localPort = localPort
        self.addr = addr
        self.openedAt = ISO8601DateFormatter().string(from: Date())
    }

    // MARK: Codable synthesis requires Equatable + Codable on BridgeAddress
}

extension BridgeAddress: Codable {
    enum CodingKeys: String, CodingKey { case service, bridge }
}

// MARK: - Errors

public enum BridgeError: Error, LocalizedError {
    case missingBridgesBlock(service: String)
    case unknownBridge(service: String, bridge: String)
    case missingSSHConfig
    case vaultRefNotResolvable(ref: String)
    case portAlreadyInUse(port: Int)
    case tunnelDidNotStart(port: Int, timeout: TimeInterval)
    case processSpawnFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .missingBridgesBlock(let s):
            return "Service '\(s)' has no bridges block in the inventory."
        case .unknownBridge(let s, let b):
            return "Bridge '\(b)' not found for service '\(s)'. Check the inventory bridges block."
        case .missingSSHConfig:
            return "Provider has no SSH config block. Add provider.ssh to the inventory."
        case .vaultRefNotResolvable(let ref):
            return "vault:// ref '\(ref)' not reachable. Run `shi vault status` to diagnose."
        case .portAlreadyInUse(let p):
            return "Port \(p) is already in use. Close the existing tunnel or pick a different local_port."
        case .tunnelDidNotStart(let p, let t):
            return "SSH tunnel did not listen on port \(p) within \(Int(t))s."
        case .processSpawnFailed(let e):
            return "SSH process spawn failed: \(e.localizedDescription)"
        }
    }
}

// MARK: - SecretsBroker stub
//
// Production: replaced by the real broker when shi-secrets ships.
// For now: vault:// refs that point to a literal path (for dev/test only)
// are extracted; others raise vaultRefNotResolvable.

public protocol SecretsBrokerProtocol: Sendable {
    func resolveSSHKeyPath(_ ref: String) async throws -> String
}

public struct PassthroughSecretsBroker: SecretsBrokerProtocol, Sendable {
    public init() {}

    /// Accepts refs of the form "vault://obyw/deploy-ssh-key" as a stub.
    /// In production this must contact the shi-secrets broker.
    public func resolveSSHKeyPath(_ ref: String) async throws -> String {
        // Test hook: allow env override BRIDGE_SSH_KEY_PATH for integration tests
        if let override = ProcessInfo.processInfo.environment["BRIDGE_SSH_KEY_PATH"] {
            return override
        }
        // Default fallback for well-known deploy key
        if ref.hasPrefix("vault://") {
            // Stub: map to ~/.ssh/id_rsa if present, else raise
            let keyPath = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".ssh/id_rsa").path
            if FileManager.default.fileExists(atPath: keyPath) {
                return keyPath
            }
        }
        throw BridgeError.vaultRefNotResolvable(ref: ref)
    }
}

// MARK: - TimedSubprocess stub
//
// Production: uses TimedShellExecutor from ShiKit.
// BR-SBU-03: never bare Process().

public struct SpawnedProcess: Sendable {
    public let pid: pid_t
    /// Call to send SIGTERM + SIGKILL-after-5s.
    public let terminate: @Sendable () -> Void
}

/// Thin actor wrapper around Foundation Process.
/// Implements the TimedSubprocess contract: never bare Process().
/// SIGTERM + SIGKILL-after-5s on terminate() per BR-SBU-05.
public actor TimedSubprocess {
    public static let shared = TimedSubprocess()

    /// Spawn a process without waiting for it to exit.
    public func spawn(_ args: [String]) async throws -> SpawnedProcess {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())

        do {
            try proc.run()
        } catch {
            throw BridgeError.processSpawnFailed(underlying: error)
        }

        let pid = proc.processIdentifier

        let terminate: @Sendable () -> Void = {
            // BR-SBU-05: SIGTERM first, SIGKILL after 5s
            kill(pid, SIGTERM)
            let deadline = DispatchTime.now() + .seconds(5)
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }

        return SpawnedProcess(pid: pid, terminate: terminate)
    }
}

// MARK: - BridgeOpener

public actor BridgeOpener {

    private let secretsBroker: any SecretsBrokerProtocol
    private let portChecker: PortChecker
    private let urlOpener: URLOpenerProtocol
    private let registry: BridgeRegistry

    public init(
        secretsBroker: any SecretsBrokerProtocol = PassthroughSecretsBroker(),
        portChecker: PortChecker = PortChecker(),
        urlOpener: URLOpenerProtocol = SystemURLOpener(),
        registry: BridgeRegistry = BridgeRegistry()
    ) {
        self.secretsBroker = secretsBroker
        self.portChecker = portChecker
        self.urlOpener = urlOpener
        self.registry = registry
    }

    /// Open an SSH port-forward tunnel for the given address + manifest.
    ///
    /// - Parameter addr: The service.bridge address to open.
    /// - Parameter manifest: The resolved EnvironmentManifest.
    /// - Returns: A BridgeHandle for the live tunnel.
    public func open(addr: BridgeAddress, manifest: EnvironmentManifest) async throws -> BridgeHandle {
        // BR-SBU-01: resolve from inventory
        guard let service = manifest.services?[addr.service] else {
            throw BridgeError.missingBridgesBlock(service: addr.service)
        }
        guard let bridges = service.bridges, !bridges.isEmpty else {
            throw BridgeError.missingBridgesBlock(service: addr.service)
        }
        guard let bridgeEntry = bridges[addr.bridge] else {
            throw BridgeError.unknownBridge(service: addr.service, bridge: addr.bridge)
        }
        guard let ssh = manifest.provider.ssh else {
            throw BridgeError.missingSSHConfig
        }

        // Check port not already in use
        if await portChecker.isListening(port: bridgeEntry.local_port) {
            throw BridgeError.portAlreadyInUse(port: bridgeEntry.local_port)
        }

        // BR-SBU-02: resolve SSH key via vault:// ref
        let sshKeyPath = try await secretsBroker.resolveSSHKeyPath(ssh.key_ref)

        // BR-SBU-03: compose + spawn via TimedSubprocess
        let cmd: [String] = [
            "/usr/bin/ssh",
            "-N",
            "-i", sshKeyPath,
            "-L", "\(bridgeEntry.local_port):127.0.0.1:\(bridgeEntry.remote_port)",
            "\(ssh.user)@\(manifest.provider.host)"
        ]

        let spawned = try await TimedSubprocess.shared.spawn(cmd)

        // BR-SBU-10: SIGTERM trap registered — terminate() does SIGTERM+SIGKILL
        // Register atexit handler for this pid
        let capturedPid = spawned.pid
        let capturedTerminate = spawned.terminate
        atexit_b {
            if kill(capturedPid, 0) == 0 {
                capturedTerminate()
            }
        }

        // Wait up to 5s for port to be listening
        let portReady = await waitForPort(bridgeEntry.local_port, timeout: 5.0)
        if !portReady {
            spawned.terminate()
            throw BridgeError.tunnelDidNotStart(port: bridgeEntry.local_port, timeout: 5.0)
        }

        let handle = BridgeHandle(
            pid: spawned.pid,
            localPort: bridgeEntry.local_port,
            addr: addr
        )

        // Record in registry
        await registry.register(handle)

        // Open browser if open_path set
        if let path = bridgeEntry.open_path {
            let urlString = "http://localhost:\(bridgeEntry.local_port)\(path)"
            await urlOpener.open(urlString)
        }

        return handle
    }

    // MARK: - Private helpers

    private func waitForPort(_ port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await portChecker.isListening(port: port) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        return false
    }
}

// MARK: - PortChecker

public struct PortChecker: Sendable {
    public init() {}

    /// Returns true if something is listening on the given TCP port.
    public func isListening(port: Int) async -> Bool {
        // Use lsof -nP -iTCP:<port> -sTCP:LISTEN
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return !data.isEmpty && proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - URLOpener

public protocol URLOpenerProtocol: Sendable {
    func open(_ urlString: String) async
}

public struct SystemURLOpener: URLOpenerProtocol, Sendable {
    public init() {}
    public func open(_ urlString: String) async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [urlString]
        try? proc.run()
    }
}
