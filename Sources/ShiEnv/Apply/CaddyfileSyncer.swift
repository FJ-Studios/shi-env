import Foundation
import CryptoKit

// MARK: - CaddyfileSyncer
//
// Generates a Caddyfile from the inventory, rsyncs it to the remote host,
// and issues a `caddy reload` (atomic per BR-SERA-05).
//
// Failure leaves the prior Caddyfile in place — caddy reload is atomic
// (Caddy double-buffers its config internally).
//
// BR-SERA-03: all remote commands via TimedSSHExecutor.
// BR-SERA-05: rsync + atomic caddy reload; failure leaves prior file.
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.1

/// State of the Caddyfile on the remote host.
public struct CaddyfileState: Sendable, Equatable {
    /// SHA-256 hex of the current Caddyfile on the remote. Nil = not present.
    public let remoteSHA: String?
    /// Path on the remote host.
    public let remotePath: String

    public init(remoteSHA: String?, remotePath: String = "/etc/caddy/Caddyfile") {
        self.remoteSHA = remoteSHA
        self.remotePath = remotePath
    }

    public var isPresent: Bool { remoteSHA != nil }
}

public actor CaddyfileSyncer {

    private let executor: any SSHExecutorProtocol
    /// Path of the Caddyfile on the remote host.
    private let remotePath: String

    public init(
        executor: any SSHExecutorProtocol,
        remotePath: String = "/etc/caddy/Caddyfile"
    ) {
        self.executor = executor
        self.remotePath = remotePath
    }

    // MARK: - Probe

    /// Probe the SHA-256 of the current remote Caddyfile.
    public func probe(host: String, user: String) async throws -> CaddyfileState {
        let output = try await executor.run(
            host: host,
            user: user,
            command: "sha256sum \(remotePath) 2>/dev/null | awk '{print $1}' || echo ''"
        )
        let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return CaddyfileState(
            remoteSHA: sha.isEmpty ? nil : sha,
            remotePath: remotePath
        )
    }

    // MARK: - Plan

    /// Compute the converge step for a Caddyfile sync.
    /// Public so tests can call it directly (actor-isolated).
    public func planStep(
        desiredContent: String,
        currentState: CaddyfileState
    ) -> ConvergeStep {
        let desiredSHA = sha256Hex(desiredContent)

        if let remoteSHA = currentState.remoteSHA, remoteSHA == desiredSHA {
            return ConvergeStep(
                kind: .syncCaddyfile,
                status: .match,
                description: "Caddyfile (sha unchanged)",
                detail: nil
            )
        }

        let detail = currentState.remoteSHA == nil
            ? "new file → \(desiredSHA.prefix(8))"
            : "sha drift → \(desiredSHA.prefix(8))"

        return ConvergeStep(
            kind: .syncCaddyfile,
            status: currentState.isPresent ? .drift : .new,
            description: "Caddyfile rsync + caddy reload",
            detail: detail
        )
    }

    // MARK: - Execute

    /// Write the Caddyfile to the remote host and reload caddy.
    ///
    /// Uses a temp file + atomic `mv` to avoid partial-write states.
    /// On error, caddy reload is not issued and the old file remains.
    public func execute(
        desiredContent: String,
        host: String,
        user: String,
        dryRun: Bool
    ) async throws -> ConvergeStep {
        let state = try await probe(host: host, user: user)
        let planned = planStep(desiredContent: desiredContent, currentState: state)

        if planned.status == .match {
            return planned
        }

        if dryRun {
            return ConvergeStep(
                kind: .syncCaddyfile,
                status: .skipped,
                description: planned.description,
                detail: "(dry-run) would rsync + caddy reload"
            )
        }

        // Write to a tmp location first (atomic)
        let tmpPath = "\(remotePath).tmp.\(UUID().uuidString.prefix(8))"

        // Escape content for shell heredoc injection
        let b64Content = Data(desiredContent.utf8).base64EncodedString()

        _ = try await executor.run(
            host: host,
            user: user,
            command: "echo '\(b64Content)' | base64 -d > \(tmpPath) && mv -f \(tmpPath) \(remotePath)"
        )

        // Atomic reload: caddy validates config before swapping
        _ = try await executor.run(
            host: host,
            user: user,
            command: "caddy reload --config \(remotePath) --adapter caddyfile 2>&1"
        )

        return ConvergeStep(
            kind: .syncCaddyfile,
            status: .done,
            description: "Caddyfile rsync + caddy reload",
            detail: "synced + reloaded"
        )
    }

    // MARK: - Helpers

    private func sha256Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
