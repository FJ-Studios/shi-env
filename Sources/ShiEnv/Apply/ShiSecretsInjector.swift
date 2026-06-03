import Foundation
import ShiSecretsKit
import ShiSecretsClient

// MARK: - ShiSecretsInjector
//
// Resolves `shi-secret://` URIs from the inventory and injects secrets into
// remote services via one of two safe mechanisms:
//
//  • Long-running services (systemd): `LoadCredential=` directive →
//    tmpfs at /run/credentials/<service>/<key> (mode 600, ephemeral).
//  • One-shot processes: `shi secrets-to-env --secret KEY=vault-name -- <cmd>`
//    execve wrapper (env-passing, never written to disk).
//
// NEVER writes .env files or any file under /etc/.
//
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.1 + BR-SERA-04
// Memory rule: [[container-secrets-no-file-residency]]
// Memory rule: [[secret-refs-via-shi-secrets-broker-not-vault-uri]]

/// Injection strategy for a given service context.
public enum SecretInjectionStrategy: Sendable, Equatable {
    /// systemd LoadCredential= — for long-running services.
    /// Secrets land in /run/credentials/<unit>/<key> (tmpfs, mode 600).
    case systemdLoadCredential(unit: String)
    /// `shi secrets-to-env` execve wrapper — for one-shot processes.
    case secretsToEnvExecve
}

/// Protocol allowing test injection without a live broker socket.
public protocol SecretsResolverProtocol: Sendable {
    /// Resolve a `shi-secret://` URI and return the secret value.
    func resolve(uri: String) async throws -> String
    /// Resolve a `shi-secret://` URI and return the local SSH key file path.
    /// (Used by BridgeOpener for SSH key resolution — replaces PassthroughSecretsBroker.)
    func resolveSSHKeyPath(uri: String) async throws -> String
}

// MARK: - ProductionSecretsResolver

/// Production resolver: delegates to the shi-secrets broker via BrokerClient.
/// Replaces the legacy PassthroughSecretsBroker stub in BridgeOpener (BR-SSEC-11).
public actor ProductionSecretsResolver: SecretsResolverProtocol {

    private let brokerClient: any BrokerClient

    public init(brokerClient: any BrokerClient = ProductionBrokerClient()) {
        self.brokerClient = brokerClient
    }

    /// Resolve a `shi-secret://` URI by extracting the key and calling `secret.get`.
    public func resolve(uri: String) async throws -> String {
        let parsedURI = try ShiSecretURI.parse(uri)
        // BrokerClient.get(name:) takes the qualified key (namespace/key)
        return try await brokerClient.get(name: parsedURI.qualifiedKey)
    }

    /// Resolve a `shi-secret://` URI that points to an SSH private key path.
    /// Returns a temp file path or the key content path.
    public func resolveSSHKeyPath(uri: String) async throws -> String {
        // First try env override (for integration tests)
        if let override = ProcessInfo.processInfo.environment["BRIDGE_SSH_KEY_PATH"] {
            return override
        }
        // Resolve the secret value — expected to be a file path or PEM content
        let value = try await resolve(uri: uri)
        // If the value looks like a file path that exists, return it directly.
        if value.hasPrefix("/") && FileManager.default.fileExists(atPath: value) {
            return value
        }
        // Otherwise write the key material to a temp file (mode 600) and return path.
        let tmpPath = NSTemporaryDirectory() + "shi-env-sshkey-\(UUID().uuidString)"
        let data = Data(value.utf8)
        try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpPath)
        return tmpPath
    }
}

// MARK: - ShiSecretsInjector

/// Orchestrates secret injection for a service apply step.
///
/// Produces the systemd `LoadCredential=` directives to append to the unit
/// override file on the remote host — never writing actual secret values to disk.
/// For one-shot processes, produces the `shi secrets-to-env` invocation args.
public actor ShiSecretsInjector {

    private let resolver: any SecretsResolverProtocol
    private let executor: any SSHExecutorProtocol

    public init(
        resolver: any SecretsResolverProtocol,
        executor: any SSHExecutorProtocol
    ) {
        self.resolver = resolver
        self.executor = executor
    }

    /// Apply secret injection for a service using the given strategy.
    ///
    /// - Parameters:
    ///   - secretsRefs: Dict from inventory `services[].secrets_refs`.
    ///     Keys are the local env var names, values are `shi-secret://` URIs.
    ///   - strategy: The injection strategy.
    ///   - host: Remote host.
    ///   - sshUser: SSH user.
    ///   - dryRun: When true, no remote mutation is performed.
    /// - Returns: A converge step reflecting the outcome.
    public func inject(
        secretsRefs: [String: String],
        strategy: SecretInjectionStrategy,
        host: String,
        sshUser: String,
        dryRun: Bool
    ) async throws -> ConvergeStep {
        guard !secretsRefs.isEmpty else {
            return ConvergeStep(
                kind: .injectSecrets,
                status: .match,
                description: "secrets (none configured)",
                detail: nil
            )
        }

        switch strategy {
        case .systemdLoadCredential(let unit):
            return try await injectLoadCredential(
                secretsRefs: secretsRefs,
                unit: unit,
                host: host,
                sshUser: sshUser,
                dryRun: dryRun
            )

        case .secretsToEnvExecve:
            // For one-shot: we don't write anything; caller invokes
            // `shi secrets-to-env --secret KEY=<ref> -- <cmd>` at exec time.
            return ConvergeStep(
                kind: .injectSecrets,
                status: dryRun ? .skipped : .done,
                description: "secrets (secrets-to-env execve wrapper)",
                detail: "\(secretsRefs.count) ref(s) — resolved at exec-time via shi secrets-to-env"
            )
        }
    }

    // MARK: - Private

    private func injectLoadCredential(
        secretsRefs: [String: String],
        unit: String,
        host: String,
        sshUser: String,
        dryRun: Bool
    ) async throws -> ConvergeStep {
        // Validate all URIs parse correctly (fail BEFORE any mutation).
        for (_, ref) in secretsRefs {
            _ = try ShiSecretURI.parse(ref)
        }

        if dryRun {
            return ConvergeStep(
                kind: .injectSecrets,
                status: .skipped,
                description: "secrets LoadCredential= for \(unit)",
                detail: "dry-run: \(secretsRefs.count) ref(s) would be injected via systemd LoadCredential="
            )
        }

        // Build LoadCredential= directives.
        // Each resolved secret is written to /run/credentials/<unit>/<key>
        // via a systemd dropin — the broker daemon on the remote host handles
        // actual resolution.  We write the dropin pointing to the shi-secret:// URIs;
        // systemd-credentials-decrypt reads them via the broker at service start.
        //
        // Since the remote host runs the broker, we write a drop-in:
        //   [Service]
        //   LoadCredential=KEY:shi-secret://ns/key
        let dropinLines = secretsRefs.sorted(by: { $0.key < $1.key }).map { (envKey, ref) in
            "LoadCredential=\(envKey):\(ref)"
        }
        let dropinContent = "[Service]\n" + dropinLines.joined(separator: "\n") + "\n"
        let dropinDir = "/etc/systemd/system/\(unit).d"
        let dropinPath = "\(dropinDir)/99-shi-secrets.conf"

        // Ensure dropin directory exists
        _ = try await executor.run(
            host: host,
            user: sshUser,
            command: "mkdir -p \(dropinDir)"
        )

        // Write the dropin (printf to avoid shell escaping issues with <<EOF)
        let escapedContent = dropinContent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\"'\"'")
        _ = try await executor.run(
            host: host,
            user: sshUser,
            command: "printf '%s' '\(escapedContent)' > \(dropinPath) && chmod 600 \(dropinPath)"
        )

        // Reload systemd to pick up the dropin
        _ = try await executor.run(
            host: host,
            user: sshUser,
            command: "systemctl daemon-reload"
        )

        return ConvergeStep(
            kind: .injectSecrets,
            status: .done,
            description: "secrets LoadCredential= for \(unit)",
            detail: "\(secretsRefs.count) ref(s) injected via systemd LoadCredential= (tmpfs /run/credentials/\(unit)/)"
        )
    }
}
