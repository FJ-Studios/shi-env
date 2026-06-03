import Foundation

// MARK: - SystemdServiceManager
//
// Manages systemd units on a remote host via SSH.
// Operations: start / stop / status / enable / reload.
//
// BR-SERA-03: all SSH via TimedSSHExecutor (never bare Process()).
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.1

/// Result of a systemd probe.
public struct SystemdUnitState: Sendable, Equatable {
    /// e.g. "active", "inactive", "failed", "activating"
    public let activeState: String
    /// e.g. "running", "dead", "exited"
    public let subState: String
    /// Whether the unit is enabled (starts on boot).
    public let enabled: Bool

    public init(activeState: String, subState: String, enabled: Bool) {
        self.activeState = activeState
        self.subState = subState
        self.enabled = enabled
    }

    public var isActive: Bool { activeState == "active" }
}

public actor SystemdServiceManager {

    private let executor: any SSHExecutorProtocol

    public init(executor: any SSHExecutorProtocol) {
        self.executor = executor
    }

    // MARK: - Probe

    /// Probe a unit's current state without mutation.
    public func probe(
        unit: String,
        host: String,
        user: String
    ) async throws -> SystemdUnitState {
        let activeOutput = try await executor.run(
            host: host,
            user: user,
            command: "systemctl show \(unit) -p ActiveState,SubState,UnitFileState --value 2>/dev/null || echo 'inactive\ndead\ndisabled'"
        )
        let lines = activeOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let activeState = lines.count > 0 ? lines[0] : "inactive"
        let subState    = lines.count > 1 ? lines[1] : "dead"
        let unitFileState = lines.count > 2 ? lines[2] : "disabled"

        return SystemdUnitState(
            activeState: activeState.isEmpty ? "inactive" : activeState,
            subState: subState.isEmpty ? "dead" : subState,
            enabled: unitFileState.hasPrefix("enabled")
        )
    }

    // MARK: - Mutations

    public func start(unit: String, host: String, user: String) async throws {
        _ = try await executor.run(host: host, user: user, command: "systemctl start \(unit)")
    }

    public func stop(unit: String, host: String, user: String) async throws {
        _ = try await executor.run(host: host, user: user, command: "systemctl stop \(unit)")
    }

    public func enable(unit: String, host: String, user: String) async throws {
        _ = try await executor.run(host: host, user: user, command: "systemctl enable \(unit)")
    }

    public func reload(unit: String, host: String, user: String) async throws {
        _ = try await executor.run(host: host, user: user, command: "systemctl reload \(unit) 2>/dev/null || systemctl restart \(unit)")
    }

    public func daemonReload(host: String, user: String) async throws {
        _ = try await executor.run(host: host, user: user, command: "systemctl daemon-reload")
    }

    // MARK: - Plan + Execute converge step

    /// Plan whether systemd state needs to change.
    public func planStep(
        unit: String,
        currentState: SystemdUnitState
    ) -> ConvergeStep {
        if currentState.isActive {
            return ConvergeStep(
                kind: .systemdUnit,
                status: .match,
                description: "systemd unit \(unit)",
                detail: nil
            )
        }
        return ConvergeStep(
            kind: .systemdUnit,
            status: .drift,
            description: "systemd unit \(unit)",
            detail: "\(currentState.activeState) → active"
        )
    }

    /// Execute the systemd converge step (enable + start if not active).
    public func executeStep(
        unit: String,
        host: String,
        user: String,
        dryRun: Bool
    ) async throws -> ConvergeStep {
        let state = try await probe(unit: unit, host: host, user: user)
        let planned = planStep(unit: unit, currentState: state)

        if planned.status == .match {
            return planned
        }

        if dryRun {
            return ConvergeStep(
                kind: .systemdUnit,
                status: .skipped,
                description: planned.description,
                detail: "(dry-run) would enable+start \(unit)"
            )
        }

        if !state.enabled {
            try await enable(unit: unit, host: host, user: user)
        }
        try await start(unit: unit, host: host, user: user)

        return ConvergeStep(
            kind: .systemdUnit,
            status: .done,
            description: "systemd unit \(unit)",
            detail: "enabled + started"
        )
    }
}
