import Foundation

// MARK: - ConvergePlan
//
// Types describing the declarative plan to bring a remote host into
// alignment with its inventory manifest.
//
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.3 + BR-SERA-08
// All step kinds mirror the apply flow order: secrets → dpkg → systemd →
// Caddyfile → kurma.

// MARK: - RemoteServiceState

/// Read-only snapshot of one service's current state on the remote host.
/// Produced by each service-manager's probe step.
public struct RemoteServiceState: Sendable, Equatable {
    public let serviceName: String
    /// systemd active state, e.g. "active", "inactive", "failed".
    public let systemdState: String?
    /// Installed dpkg version, nil if not installed.
    public let dpkgVersion: String?
    /// SHA-256 hex of the current Caddyfile on the remote, nil if absent.
    public let caddyfileSHA: String?
    /// Whether kurma monitor is registered.
    public let kurmaRegistered: Bool
    /// Whether secrets are injected (LoadCredential path exists).
    public let secretsInjected: Bool
    /// Arbitrary key/value probe data.
    public let metadata: [String: String]

    public init(
        serviceName: String,
        systemdState: String? = nil,
        dpkgVersion: String? = nil,
        caddyfileSHA: String? = nil,
        kurmaRegistered: Bool = false,
        secretsInjected: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.serviceName = serviceName
        self.systemdState = systemdState
        self.dpkgVersion = dpkgVersion
        self.caddyfileSHA = caddyfileSHA
        self.kurmaRegistered = kurmaRegistered
        self.secretsInjected = secretsInjected
        self.metadata = metadata
    }
}

// MARK: - ConvergeStepKind

/// The kind of a single converge step in execution order.
/// Order is canonical: secrets → dpkg → systemd → caddyfile → kurma.
public enum ConvergeStepKind: String, Sendable, Equatable, CaseIterable, Codable {
    case injectSecrets   = "inject_secrets"
    case installPackage  = "install_package"
    case systemdUnit     = "systemd_unit"
    case syncCaddyfile   = "sync_caddyfile"
    case kurmaRegister   = "kurma_register"
    case kurmaDeregister = "kurma_deregister"
}

// MARK: - ConvergeStepStatus

public enum ConvergeStepStatus: String, Sendable, Equatable, Codable {
    /// Current state matches desired — no-op.
    case match  = "MATCH"
    /// Drift detected — step will run.
    case drift  = "DRIFT"
    /// Resource is new and will be created.
    case new    = "NEW"
    /// Step completed successfully.
    case done   = "DONE"
    /// Step failed.
    case failed = "FAILED"
    /// Skipped (dry-run or pre-condition not met).
    case skipped = "SKIPPED"
}

// MARK: - ConvergeStep

/// A single plannable/executable unit of work.
public struct ConvergeStep: Sendable, Equatable, Codable {
    public let kind: ConvergeStepKind
    public let status: ConvergeStepStatus
    /// Human-readable description for plan display (BR-SERA-12).
    public let description: String
    /// Optional detail, e.g. "v0.21 → v0.22" for dpkg upgrade.
    public let detail: String?

    public init(
        kind: ConvergeStepKind,
        status: ConvergeStepStatus,
        description: String,
        detail: String? = nil
    ) {
        self.kind = kind
        self.status = status
        self.description = description
        self.detail = detail
    }
}

// MARK: - ConvergePlan

/// The complete plan for one service on one host.
public struct ConvergePlan: Sendable, Equatable, Codable {
    public let serviceName: String
    public let host: String
    public let steps: [ConvergeStep]
    /// ISO-8601 timestamp when this plan was computed.
    public let plannedAt: String

    public init(serviceName: String, host: String, steps: [ConvergeStep]) {
        self.serviceName = serviceName
        self.host = host
        self.steps = steps
        self.plannedAt = ISO8601DateFormatter().string(from: Date())
    }

    /// True when all steps are MATCH — no work to do.
    public var isAligned: Bool {
        steps.allSatisfy { $0.status == .match }
    }

    /// Steps that require mutation (DRIFT or NEW).
    public var actionableSteps: [ConvergeStep] {
        steps.filter { $0.status == .drift || $0.status == .new }
    }
}

// MARK: - ConvergeResult

/// Outcome of executing (or dry-running) a ConvergePlan.
public struct ConvergeResult: Sendable, Equatable, Codable {
    public let serviceName: String
    public let host: String
    public let steps: [ConvergeStep]
    /// True when called with dryRun=true.
    public let wasDryRun: Bool
    /// ISO-8601 completion timestamp.
    public let completedAt: String
    /// True if all actionable steps succeeded.
    public let succeeded: Bool

    public init(
        serviceName: String,
        host: String,
        steps: [ConvergeStep],
        wasDryRun: Bool,
        succeeded: Bool
    ) {
        self.serviceName = serviceName
        self.host = host
        self.steps = steps
        self.wasDryRun = wasDryRun
        self.completedAt = ISO8601DateFormatter().string(from: Date())
        self.succeeded = succeeded
    }
}

// MARK: - ConvergeRecord

/// Persisted record of one completed apply run (BR-SERA-08).
/// Stored in @db and returned by `shi env converge-history`.
public struct ConvergeRecord: Sendable, Equatable, Codable {
    public let id: String
    public let host: String
    public let env: String
    public let results: [ConvergeResult]
    public let wasDryRun: Bool
    public let completedAt: String
    public let triggeredBy: String

    public init(
        host: String,
        env: String,
        results: [ConvergeResult],
        wasDryRun: Bool,
        triggeredBy: String = "shi-env"
    ) {
        self.id = UUID().uuidString
        self.host = host
        self.env = env
        self.results = results
        self.wasDryRun = wasDryRun
        self.completedAt = ISO8601DateFormatter().string(from: Date())
        self.triggeredBy = triggeredBy
    }
}
