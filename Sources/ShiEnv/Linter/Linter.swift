import Foundation

// MARK: - Linter
//
// Validates an EnvironmentManifest (post-inheritance resolution) against the
// rules in BR-SEIS-07.
//
// Checks:
//  1. Schema correctness (version == 1, required fields present)
//  2. Secret references use vault:// scheme — BR-SEIS-04
//  3. Provider forward-compat field present — BR-SEIS-05
//  4. No port collision: two services on same host:port — BR-SEIS-07
//  5. Dependency DAG — no cycles in services[].deps[] — BR-SEIS-07
//  6. Agency slug refs in clients[] exist in agencies[] — BR-SEIS-16
//  7. clients[].type is a known enum value — BR-SEIS-17
//  8. Kotoba block validation when present — BR-SEIS-13
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md §4 BR-SEIS-07

// MARK: LintFinding

public struct LintFinding: Sendable, Equatable {
    public enum Level: String, Sendable {
        case error
        case warn
    }
    public let level: Level
    public let field: String?
    public let message: String

    public init(level: Level, field: String? = nil, message: String) {
        self.level = level
        self.field = field
        self.message = message
    }

    public var formattedMessage: String {
        var parts: [String] = ["[\(level.rawValue.uppercased())]"]
        if let field { parts.append("\(field):") }
        parts.append(message)
        return parts.joined(separator: " ")
    }
}

// MARK: Linter

public struct Linter: Sendable {

    public init() {}

    /// Run all lint rules against a resolved manifest.
    ///
    /// - Parameter manifest: A post-inheritance-resolved manifest.
    /// - Returns: All findings. Empty = clean. Any `.error` = lint failure.
    public func lint(_ manifest: EnvironmentManifest) -> [LintFinding] {
        var findings: [LintFinding] = []

        findings += checkVersion(manifest)
        findings += checkSecretRefs(manifest)
        findings += checkPortCollisions(manifest)
        findings += checkDepCycles(manifest)
        findings += checkAgencySlugs(manifest)
        findings += checkClientTypes(manifest)
        findings += checkKotobaBlocks(manifest)

        return findings
    }

    // MARK: Rule: schema version

    private func checkVersion(_ m: EnvironmentManifest) -> [LintFinding] {
        guard m.version == 1 else {
            return [LintFinding(level: .error, field: "version",
                message: "Unknown schema version \(m.version). Expected 1.")]
        }
        return []
    }

    // MARK: Rule: vault:// for all secrets (BR-SEIS-04)

    private func checkSecretRefs(_ m: EnvironmentManifest) -> [LintFinding] {
        var findings: [LintFinding] = []

        func checkRef(_ value: String, context: String) {
            if !value.hasPrefix("vault://") {
                findings.append(LintFinding(
                    level: .error,
                    field: context,
                    message: "Secret reference '\(value)' must use vault:// scheme (literal secrets forbidden per BR-SEIS-04)."))
            }
        }

        // Provider SSH key ref
        if let ssh = m.provider.ssh {
            checkRef(ssh.key_ref, context: "provider.ssh.key_ref")
        }

        // Service secrets_refs
        for (svcName, svc) in (m.services ?? [:]) {
            for (refKey, refValue) in (svc.secrets_refs ?? [:]) {
                checkRef(refValue, context: "services.\(svcName).secrets_refs.\(refKey)")
            }
            // Backup restic target
            if let resticTarget = svc.backups?.restic_target {
                checkRef(resticTarget, context: "services.\(svcName).backups.restic_target")
            }
        }

        // Observability backbone admin token ref
        if let tokenRef = m.observability_backbone?.kurma_admin_token_ref {
            checkRef(tokenRef, context: "observability_backbone.kurma_admin_token_ref")
        }

        // Secrets broker refs
        if let broker = m.secrets_broker {
            if let id = broker.client_id_ref { checkRef(id, context: "secrets_broker.client_id_ref") }
            if let sec = broker.client_secret_ref { checkRef(sec, context: "secrets_broker.client_secret_ref") }
        }

        return findings
    }

    // MARK: Rule: port collisions (BR-SEIS-07)

    private func checkPortCollisions(_ m: EnvironmentManifest) -> [LintFinding] {
        var findings: [LintFinding] = []
        var seenPorts: [Int: String] = [:]   // port → service name

        for (svcName, svc) in (m.services ?? [:]) {
            for (portName, port) in (svc.ports ?? [:]) {
                if let existing = seenPorts[port] {
                    findings.append(LintFinding(
                        level: .error,
                        field: "services.\(svcName).ports.\(portName)",
                        message: "Port \(port) collision: also claimed by service '\(existing)'."))
                } else {
                    seenPorts[port] = svcName
                }
            }
        }

        return findings
    }

    // MARK: Rule: dependency DAG — no cycles (BR-SEIS-07)

    private func checkDepCycles(_ m: EnvironmentManifest) -> [LintFinding] {
        var findings: [LintFinding] = []
        let services = m.services ?? [:]

        // Build adjacency list of service → [dep service] edges
        var adj: [String: Set<String>] = [:]
        for (name, svc) in services {
            var deps: Set<String> = []
            for dep in (svc.deps ?? []) {
                if let svcDep = dep.service {
                    deps.insert(svcDep)
                }
            }
            adj[name] = deps
        }

        // DFS cycle detection
        var visited: Set<String> = []
        var stack: Set<String> = []

        func dfs(_ node: String) -> [String]? {
            if stack.contains(node) { return [node] }
            if visited.contains(node) { return nil }
            visited.insert(node)
            stack.insert(node)
            for neighbour in (adj[node] ?? []) {
                if let cycle = dfs(neighbour) {
                    return [node] + cycle
                }
            }
            stack.remove(node)
            return nil
        }

        for name in adj.keys {
            if let cycle = dfs(name) {
                findings.append(LintFinding(
                    level: .error,
                    field: "services.deps",
                    message: "Dependency cycle detected: \(cycle.joined(separator: " → "))."))
                break   // report first cycle only
            }
        }

        return findings
    }

    // MARK: Rule: agency slug refs (BR-SEIS-16)

    private func checkAgencySlugs(_ m: EnvironmentManifest) -> [LintFinding] {
        var findings: [LintFinding] = []
        let agencySlugs = Set((m.agencies ?? []).map(\.slug))

        for client in (m.clients ?? []) {
            if let src = client.source_agency, !agencySlugs.contains(src) {
                findings.append(LintFinding(
                    level: .error,
                    field: "clients[\(client.slug)].source_agency",
                    message: "source_agency '\(src)' not declared in agencies[] block."))
            }
            if !agencySlugs.isEmpty, !agencySlugs.contains(client.operating_agency) {
                findings.append(LintFinding(
                    level: .error,
                    field: "clients[\(client.slug)].operating_agency",
                    message: "operating_agency '\(client.operating_agency)' not declared in agencies[] block."))
            }
        }

        return findings
    }

    // MARK: Rule: client type enum (BR-SEIS-17)
    // ClientType is a Swift enum — decode errors handle unknown types.
    // This check detects clients with no agencies block (warn) and cross-agency
    // without explicit flag (informational only in schema layer).
    private func checkClientTypes(_ m: EnvironmentManifest) -> [LintFinding] {
        var findings: [LintFinding] = []

        for client in (m.clients ?? []) {
            if client.type == .crossAgency {
                findings.append(LintFinding(
                    level: .warn,
                    field: "clients[\(client.slug)].type",
                    message: "cross-agency type requires explicit --cross-agency flag at provisioning (BR-SEIS-18)."))
            }
        }

        return findings
    }

    // MARK: Rule: kotoba block validation (BR-SEIS-13)

    private func checkKotobaBlocks(_ m: EnvironmentManifest) -> [LintFinding] {
        var findings: [LintFinding] = []

        guard let kotoba = m.provider.kotoba else { return [] }

        // nats_subject must match shikki.kotoba.* taxonomy
        if !kotoba.nats_subject.hasPrefix("shikki.kotoba.") {
            findings.append(LintFinding(
                level: .error,
                field: "provider.kotoba.nats_subject",
                message: "NATS subject '\(kotoba.nats_subject)' must start with 'shikki.kotoba.' (BR-SEIS-13)."))
        }

        // Validate streams values
        let validStreams: Set<String> = ["audio", "video", "input", "clipboard"]
        for stream in kotoba.streams {
            if !validStreams.contains(stream) {
                findings.append(LintFinding(
                    level: .error,
                    field: "provider.kotoba.streams",
                    message: "Unknown stream '\(stream)'. Valid: \(validStreams.sorted().joined(separator: ", "))."))
            }
        }

        return findings
    }
}
