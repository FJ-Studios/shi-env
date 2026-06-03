import Foundation
import ShiSecretsKit
import ShiSecretsClient

// MARK: - BridgeOpener
//
// Actor responsible for opening an SSH port-forward tunnel described by an
// inventory BridgeEntry.
//
// Spec: features/shi-bridge-unification-2026-05-31.md §3.3
// BR-SBU-01: config from inventory bridges block — NO hardcoded port table
// BR-SBU-02: SSH key via shi-secret:// ref via shi-secrets broker (BR-SSEC-11)
// BR-SBU-03: TimedSubprocess for spawn (never bare Process())
// BR-SBU-10: SIGTERM trap registered on each spawned ssh process
//
// v0.5.0: PassthroughSecretsBroker stub RETIRED.
// The SecretsBrokerProtocol is kept for backward-compatible test injection,
// but production now uses ProductionSecretsResolver from ShiSecretsClient.
// Callers injecting PassthroughSecretsBroker will get a deprecation note.

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

// MARK: - SecretsBroker

// BR-SSEC-11: PassthroughSecretsBroker RETIRED in v0.5.0.
// The SecretsBrokerProtocol is kept so tests can still inject a mock resolver
// via the BridgeOpener(secretsBroker:) init. Production init now uses
// ProductionSecretsResolver from ShiSecretsClient.

public protocol SecretsBrokerProtocol: Sendable {
    func resolveSSHKeyPath(_ ref: String) async throws -> String
}

// MARK: - ProductionBridgeSecretsBroker
// Adapts SecretsResolverProtocol (from ShiSecretsInjector) to SecretsBrokerProtocol.
// BridgeOpener defaults to this in production.
struct ProductionBridgeSecretsBroker: SecretsBrokerProtocol, Sendable {
    private let resolver: ProductionSecretsResolver

    init() {
        self.resolver = ProductionSecretsResolver()
    }

    func resolveSSHKeyPath(_ ref: String) async throws -> String {
        try await resolver.resolveSSHKeyPath(uri: ref)
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
        secretsBroker: (any SecretsBrokerProtocol)? = nil,
        portChecker: PortChecker = PortChecker(),
        urlOpener: URLOpenerProtocol = SystemURLOpener(),
        registry: BridgeRegistry = BridgeRegistry()
    ) {
        // BR-SSEC-11: default to ProductionBridgeSecretsBroker (shi-secrets broker),
        // NOT the retired PassthroughSecretsBroker stub.
        self.secretsBroker = secretsBroker ?? ProductionBridgeSecretsBroker()
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
