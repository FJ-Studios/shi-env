import Foundation
import ShiSecretsKit
import ShiSecretsClient

// MARK: - ConvergeOrchestrator
//
// Implements the 8-step apply flow per spec §3.3:
//
//   1. Read inventory (env=prod) → list services targeting this host
//   2. Connect SSH (via shi-secrets broker for key)
//   3. For each service: probe → planConverge → display
//   4. Confirm (unless --yes)
//   5. Execute steps in order: secrets → dpkg → systemd → Caddyfile → kurma
//   6. Re-probe + verify alignment
//   7. Record ConvergeRecord in @db
//   8. Emit shikki.env.applied event on NATS
//
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.3
// BR-SERA-01: --dry-run first invocation per target; history in ~/.shikki/run/apply-history/<host>.json
// BR-SERA-07: --apply REQUIRES --yes OR interactive confirmation
// BR-SERA-08: ConvergeRecord persisted to @db
// BR-SERA-09: Emits shikki.env.applied.<workspace>.<env>.<host> NATS event on success
// BR-SERA-11: --all requires --i-know-what-im-doing

/// Protocol for @db plan persistence (BR-SERA-08).
/// Production: MCP shikki-db `shi_save_plan`. Tests: mock.
public protocol ConvergeRecordPersistorProtocol: Sendable {
    func save(record: ConvergeRecord) async throws
    func load(host: String, limit: Int) async throws -> [ConvergeRecord]
}

/// Protocol for NATS event emission (BR-SERA-09).
/// Production: NATS client. Tests: capturing mock.
public protocol NATSEventEmitterProtocol: Sendable {
    func publish(subject: String, payload: Data) async throws
}

/// Options for an apply run.
public struct ApplyOptions: Sendable, Equatable {
    public let dryRun: Bool
    public let apply: Bool
    public let yes: Bool
    public let all: Bool
    public let iKnowWhatImDoing: Bool
    public let jsonOutput: Bool
    public let targetHost: String?
    public let env: String?

    public init(
        dryRun: Bool = false,
        apply: Bool = false,
        yes: Bool = false,
        all: Bool = false,
        iKnowWhatImDoing: Bool = false,
        jsonOutput: Bool = false,
        targetHost: String? = nil,
        env: String? = nil
    ) {
        self.dryRun = dryRun
        self.apply = apply
        self.yes = yes
        self.all = all
        self.iKnowWhatImDoing = iKnowWhatImDoing
        self.jsonOutput = jsonOutput
        self.targetHost = targetHost
        self.env = env
    }
}

// MARK: - ApplyHistory

/// Tracks per-host apply history to enforce --dry-run first invocation (BR-SERA-01).
public actor ApplyHistory {

    private let shikkiRoot: URL

    public init(shikkiRoot: URL) {
        self.shikkiRoot = shikkiRoot
    }

    private func historyFile(host: String) -> URL {
        let sanitized = host.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return shikkiRoot
            .appendingPathComponent("run/apply-history")
            .appendingPathComponent("\(sanitized).json")
    }

    public func hasPriorDryRun(host: String) -> Bool {
        let file = historyFile(host: host)
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONDecoder().decode(HostApplyHistory.self, from: data) else {
            return false
        }
        return json.hasDryRun
    }

    public func recordDryRun(host: String) throws {
        let file = historyFile(host: host)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var history = (try? JSONDecoder().decode(
            HostApplyHistory.self,
            from: Data(contentsOf: file)
        )) ?? HostApplyHistory(host: host)
        history.hasDryRun = true
        history.lastDryRunAt = ISO8601DateFormatter().string(from: Date())
        let data = try JSONEncoder().encode(history)
        try data.write(to: file, options: .atomic)
    }

    public func recordApply(host: String) throws {
        let file = historyFile(host: host)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var history = (try? JSONDecoder().decode(
            HostApplyHistory.self,
            from: Data(contentsOf: file)
        )) ?? HostApplyHistory(host: host)
        history.lastApplyAt = ISO8601DateFormatter().string(from: Date())
        let data = try JSONEncoder().encode(history)
        try data.write(to: file, options: .atomic)
    }
}

public struct HostApplyHistory: Codable, Sendable {
    public var host: String
    public var hasDryRun: Bool
    public var lastDryRunAt: String?
    public var lastApplyAt: String?

    public init(host: String, hasDryRun: Bool = false) {
        self.host = host
        self.hasDryRun = hasDryRun
    }
}

// MARK: - ConvergeOrchestrator

/// Factory that creates an SSH executor given a resolved key path.
/// Tests inject a factory that returns a MockSSHExecutor regardless of keyPath.
public typealias SSHExecutorFactory = @Sendable (String) -> any SSHExecutorProtocol

public actor ConvergeOrchestrator {

    private let shikkiRoot: URL
    private let secretsResolver: any SecretsResolverProtocol
    private let recordPersistor: any ConvergeRecordPersistorProtocol
    private let natsEmitter: any NATSEventEmitterProtocol
    private let applyHistory: ApplyHistory
    private let kurmaClient: (any KurmaClientProtocol)?
    private let executorFactory: SSHExecutorFactory

    public init(
        shikkiRoot: URL,
        secretsResolver: any SecretsResolverProtocol,
        recordPersistor: any ConvergeRecordPersistorProtocol,
        natsEmitter: any NATSEventEmitterProtocol,
        kurmaClient: (any KurmaClientProtocol)? = nil,
        executorFactory: SSHExecutorFactory? = nil
    ) {
        self.shikkiRoot = shikkiRoot
        self.secretsResolver = secretsResolver
        self.recordPersistor = recordPersistor
        self.natsEmitter = natsEmitter
        self.applyHistory = ApplyHistory(shikkiRoot: shikkiRoot)
        self.kurmaClient = kurmaClient
        // Default factory creates a real TimedSSHExecutor.
        self.executorFactory = executorFactory ?? { keyPath in
            TimedSSHExecutor(sshKeyPath: keyPath)
        }
    }

    // MARK: - Main entry point

    /// Run the full converge flow for a host+manifest.
    ///
    /// - Parameters:
    ///   - manifest: The resolved environment manifest.
    ///   - host: The SSH target (IP or hostname).
    ///   - options: Apply options (dry-run, apply, yes, etc.).
    ///   - output: Output stream for plan display (inout — must be called from same isolation).
    ///             Call `runBuffered` instead when crossing actor boundaries.
    public func run(
        manifest: EnvironmentManifest,
        host: String,
        options: ApplyOptions,
        output: inout some TextOutputStream
    ) async throws -> [ConvergeResult] {

        // BR-SERA-11: --all requires --i-know-what-im-doing
        if options.all && !options.iKnowWhatImDoing {
            throw ApplyError.allFlagRequiresConfirmation
        }

        // BR-SERA-07: --apply requires --yes or interactive confirmation
        if options.apply && !options.yes {
            throw ApplyError.applyRequiresConfirmation(host: host)
        }

        // BR-SERA-01: --apply without prior --dry-run is refused
        if options.apply {
            let hasPriorRun = await applyHistory.hasPriorDryRun(host: host)
            if !hasPriorRun {
                throw ApplyError.dryRunRequired(host: host)
            }
        }

        // Step 1+2: build executor with SSH key from shi-secrets broker
        guard let ssh = manifest.provider.ssh else {
            throw ApplyError.missingSSHConfig(host: host)
        }

        let sshKeyPath = try await secretsResolver.resolveSSHKeyPath(uri: ssh.key_ref)
        let executor = executorFactory(sshKeyPath)

        // Step 3: probe + plan all services
        var plans: [ConvergePlan] = []
        let services = manifest.services ?? [:]

        for (serviceName, serviceEntry) in services.sorted(by: { $0.key < $1.key }) {
            let svcManifest = ServiceManifest.from(name: serviceName, entry: serviceEntry)
            let impl = RemoteManagedServiceImpl(
                host: host,
                sshUser: ssh.user,
                manifest: svcManifest,
                executor: executor
            )

            // Probe current state
            let probeDict = try await impl.probeRemote()
            let currentState = RemoteServiceState(
                serviceName: serviceName,
                systemdState: probeDict["systemd_state"],
                dpkgVersion: probeDict["dpkg_version"].flatMap { $0 == "not-installed" ? nil : $0 },
                kurmaRegistered: false,
                secretsInjected: false
            )

            // Plan
            let plan = try await impl.planConverge(from: currentState, to: svcManifest)
            plans.append(plan)

            // Display (BR-SERA-12)
            displayPlan(plan, output: &output)
        }

        // Record dry-run history
        if options.dryRun {
            try await applyHistory.recordDryRun(host: host)
            output.write("\n[dry-run] Plan complete. Run with --apply --yes to execute.\n")
            // Return dry-run results
            return plans.map { plan in
                ConvergeResult(
                    serviceName: plan.serviceName,
                    host: host,
                    steps: plan.steps.map { step in
                        ConvergeStep(kind: step.kind, status: .skipped, description: step.description, detail: step.detail)
                    },
                    wasDryRun: true,
                    succeeded: true
                )
            }
        }

        if !options.apply {
            return []
        }

        // Step 5: Execute in canonical order: secrets → dpkg → systemd → Caddyfile → kurma
        var results: [ConvergeResult] = []
        for plan in plans {
            let result = try await executeServicePlan(
                plan: plan,
                manifest: manifest,
                host: host,
                sshUser: ssh.user,
                executor: executor,
                dryRun: false
            )
            results.append(result)
            output.write(renderResult(result))
        }

        // Step 6: Re-probe verify alignment (best-effort)
        output.write("\n[verify] Re-probing services...\n")
        for result in results where result.succeeded {
            let probeDict = try? await executor.run(
                host: host,
                user: ssh.user,
                command: "systemctl is-active \(result.serviceName) 2>/dev/null || echo inactive"
            )
            let state = probeDict?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            output.write("  \(result.serviceName): \(state)\n")
        }

        // Step 7: Record in @db
        let record = ConvergeRecord(
            host: host,
            env: manifest.addressing.environment,
            results: results,
            wasDryRun: false
        )
        try await recordPersistor.save(record: record)
        try await applyHistory.recordApply(host: host)

        // Step 8: Emit NATS event (BR-SERA-09)
        let subject = "shikki.env.applied.\(manifest.addressing.workspace).\(manifest.addressing.environment).\(host.replacingOccurrences(of: ".", with: "-"))"
        let eventPayload = try JSONEncoder().encode(record)
        try await natsEmitter.publish(subject: subject, payload: eventPayload)

        output.write("\n[done] Apply complete. Record ID: \(record.id)\n")
        return results
    }

    // MARK: - Per-service execution

    private func executeServicePlan(
        plan: ConvergePlan,
        manifest: EnvironmentManifest,
        host: String,
        sshUser: String,
        executor: any SSHExecutorProtocol,
        dryRun: Bool
    ) async throws -> ConvergeResult {
        var executedSteps: [ConvergeStep] = []

        // Get service entry
        let serviceEntry = manifest.services?[plan.serviceName]
        let svcManifest = serviceEntry.map { ServiceManifest.from(name: plan.serviceName, entry: $0) }
            ?? ServiceManifest(name: plan.serviceName)

        // Execute in canonical order
        for step in plan.steps {
            switch step.kind {
            case .injectSecrets:
                let injector = ShiSecretsInjector(
                    resolver: secretsResolver,
                    executor: executor
                )
                let strategy: SecretInjectionStrategy = svcManifest.systemdUnit != nil
                    ? .systemdLoadCredential(unit: svcManifest.systemdUnit!)
                    : .secretsToEnvExecve
                let result = try await injector.inject(
                    secretsRefs: svcManifest.secretsRefs,
                    strategy: strategy,
                    host: host,
                    sshUser: sshUser,
                    dryRun: dryRun
                )
                executedSteps.append(result)

            case .installPackage:
                guard let pkg = svcManifest.dpkgPackage,
                      let ver = svcManifest.dpkgVersion else {
                    executedSteps.append(step)
                    continue
                }
                let mgr = DpkgPackageManager(executor: executor)
                let result = try await mgr.executeStep(
                    package: pkg,
                    desiredVersion: ver,
                    host: host,
                    user: sshUser,
                    dryRun: dryRun
                )
                executedSteps.append(result)

            case .systemdUnit:
                guard let unit = svcManifest.systemdUnit else {
                    executedSteps.append(step)
                    continue
                }
                let mgr = SystemdServiceManager(executor: executor)
                let result = try await mgr.executeStep(
                    unit: unit,
                    host: host,
                    user: sshUser,
                    dryRun: dryRun
                )
                executedSteps.append(result)

            case .syncCaddyfile:
                // Caddyfile content generation is out-of-scope for W1 (content passed as placeholder)
                let syncer = CaddyfileSyncer(executor: executor)
                let result = try await syncer.execute(
                    desiredContent: "# Generated by shi-env apply\n",
                    host: host,
                    user: sshUser,
                    dryRun: dryRun
                )
                executedSteps.append(result)

            case .kurmaRegister:
                guard let slug = svcManifest.kurmaSlug,
                      let kurmaClient = kurmaClient else {
                    executedSteps.append(step)
                    continue
                }
                let monitor = KurmaMonitor(
                    slug: slug,
                    name: "\(plan.serviceName) (\(manifest.addressing.environment))",
                    url: "https://\(host)"
                )
                let registrar = KurmaMonitorRegistrar(client: kurmaClient)
                let result = try await registrar.executeStep(monitor: monitor, dryRun: dryRun)
                executedSteps.append(result)

            case .kurmaDeregister:
                guard let slug = svcManifest.kurmaSlug,
                      let kurmaClient = kurmaClient else {
                    executedSteps.append(step)
                    continue
                }
                let registrar = KurmaMonitorRegistrar(client: kurmaClient)
                let result = try await registrar.deregister(slug: slug, dryRun: dryRun)
                executedSteps.append(result)
            }
        }

        let allSucceeded = executedSteps.allSatisfy {
            $0.status != .failed
        }

        return ConvergeResult(
            serviceName: plan.serviceName,
            host: host,
            steps: executedSteps,
            wasDryRun: dryRun,
            succeeded: allSucceeded
        )
    }

    // MARK: - Display helpers (BR-SERA-12)

    private func displayPlan(_ plan: ConvergePlan, output: inout some TextOutputStream) {
        let width = 50
        let border = String(repeating: "─", count: width)
        output.write("┌─ \(plan.serviceName) \(String(repeating: "─", count: max(0, width - plan.serviceName.count - 3)))┐\n")
        for step in plan.steps {
            let statusTag: String
            switch step.status {
            case .match:   statusTag = "MATCH  "
            case .drift:   statusTag = "DRIFT  "
            case .new:     statusTag = "NEW    "
            case .done:    statusTag = "DONE   "
            case .failed:  statusTag = "FAILED "
            case .skipped: statusTag = "SKIP   "
            }
            let detail = step.detail.map { " \($0)" } ?? ""
            output.write("│ \(statusTag) \(step.description)\(detail)\n")
        }
        output.write("└\(border)┘\n")
    }

    private func renderResult(_ result: ConvergeResult) -> String {
        var out = ""
        let allOk = result.succeeded
        out += "\n[\(allOk ? "ok" : "FAIL")] \(result.serviceName)\n"
        for step in result.steps {
            out += "  \(step.status.rawValue) \(step.description)\n"
        }
        return out
    }
}

// MARK: - ApplyError

public enum ApplyError: Error, LocalizedError, Sendable {
    case dryRunRequired(host: String)
    case applyRequiresConfirmation(host: String)
    case allFlagRequiresConfirmation
    case missingSSHConfig(host: String)
    case noServicesFound(host: String)

    public var errorDescription: String? {
        switch self {
        case .dryRunRequired(let h):
            return "First invocation must use --dry-run for host '\(h)' (BR-SERA-01). Run with --dry-run first, then --apply --yes."
        case .applyRequiresConfirmation(let h):
            return "--apply on '\(h)' requires --yes flag or interactive confirmation (BR-SERA-07)."
        case .allFlagRequiresConfirmation:
            return "--all requires --i-know-what-im-doing flag (BR-SERA-11). Multi-host blast radius: review plan carefully."
        case .missingSSHConfig(let h):
            return "Host '\(h)' has no SSH config in the inventory manifest. Add provider.ssh block."
        case .noServicesFound(let h):
            return "No services found for host '\(h)' in the inventory."
        }
    }
}
