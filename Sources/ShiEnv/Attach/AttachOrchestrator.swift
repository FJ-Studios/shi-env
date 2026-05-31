import Foundation

// MARK: - AttachOrchestrator
//
// Composes SshSession + KotobaSubscriber + ShiTimeClient clock-sync alignment
// for `shi env attach <addr>`.
//
// Flow (per spec §3.5b):
//   1. Resolve addr → host + kotoba capability from inventory
//   2. Probe host capabilities (kotoba enabled? streams? clock-sync tier?)
//   3. Establish clock sync via ShiTimeClient.shared.alignTo(<tier>)
//   4. Open SSH session (foreground TTY)
//   5. Subscribe to NATS shikki.kotoba.<workspace>.<project>.<env>
//   6. Multiplex streams
//   7. Ctrl+C → unsubscribe FIRST, then SSH exit (AttachSession)
//
// BR-SEV-14: refuses when kotoba.enabled = false
// BR-SEV-15: refuses if requested sync tier > current ceiling
// BR-SEV-16: fallback to kotoba CLI shell-out
// BR-SEV-17: AttachSession handles atomic teardown
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.5b

public enum AttachError: Error, LocalizedError {
    case kotobaNotDeclared(host: String)
    case kotobaNotEnabled(host: String)
    case clockSyncTierUnavailable(requested: String, available: String)
    case sshConfigMissing(host: String)

    public var errorDescription: String? {
        switch self {
        case .kotobaNotDeclared(let host):
            return "kotoba not declared for \(host); use `shi env shell` for plain SSH"
        case .kotobaNotEnabled(let host):
            return "kotoba.enabled = false for \(host); use `shi env shell` for plain SSH"
        case .clockSyncTierUnavailable(let requested, let available):
            return "requested clock-sync tier '\(requested)' unavailable; current ceiling = '\(available)'"
        case .sshConfigMissing(let host):
            return "no SSH configuration for host \(host)"
        }
    }
}

/// Orchestrates the full multimedia attach session.
public struct AttachOrchestrator: Sendable {

    private let shikkiRoot: URL

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.shikkiRoot = shikkiRoot
    }

    // MARK: - Attach

    /// Run a full multimedia attach session to `address`.
    ///
    /// - Parameters:
    ///   - address: Dot-separated address (e.g. "obyw-one.obyw-one.prod.pocketbase")
    ///   - manifest: Resolved environment manifest
    ///   - clockSyncTier: Override; if nil, uses the tier declared in kotoba block
    /// - Returns: SSH exit code
    @discardableResult
    public func attach(
        address: String,
        manifest: EnvironmentManifest,
        clockSyncTier: String? = nil
    ) async throws -> Int32 {

        let provider = manifest.provider

        // BR-SEV-14: kotoba block must exist and be enabled
        guard let kotoba = provider.kotoba else {
            throw AttachError.kotobaNotDeclared(host: provider.host)
        }
        guard kotoba.enabled else {
            throw AttachError.kotobaNotEnabled(host: provider.host)
        }

        // BR-SEV-15: clock-sync tier check
        let requestedTier = clockSyncTier ?? kotoba.clock_sync_tier.rawValue
        try checkClockSyncTier(requested: requestedTier, declared: kotoba.clock_sync_tier.rawValue)

        // Step 3: clock-sync alignment
        // ShiTimeClient.shared.alignTo(<tier>) — called via shell stub since
        // ShiTimeClient is in the shikki monorepo (not a dep of shi-env plugin).
        // When shi-time-sync ships as a standalone SPM package, replace with direct import.
        await alignClockSync(tier: requestedTier)

        // Step 4+5: build SSH process + kotoba subscriber
        let ssh = manifest.provider.ssh
        guard let sshConfig = ssh else {
            throw AttachError.sshConfigMissing(host: provider.host)
        }

        let sshProcess = buildSSHProcess(host: provider.host, user: sshConfig.user,
                                         workingDir: nil)

        let kotobaSubscriber = KotobaSubscriber(subject: kotoba.nats_subject, streams: kotoba.streams)

        // Step 6+7: run session (AttachSession handles teardown order)
        let session = AttachSession(sshProcess: sshProcess, kotobaSubscriber: kotobaSubscriber) { state in
            switch state {
            case .active:
                fputs("  kotoba streams active: \(kotoba.streams.joined(separator: ", "))\n", stderr)
            case .tearingDown:
                fputs("  tearing down kotoba subscription...\n", stderr)
            case .closed(let code):
                fputs("  session closed (exit \(code))\n", stderr)
            default:
                break
            }
        }

        fputs("Attaching to \(address)\n", stderr)
        fputs("  host:        \(provider.host)\n", stderr)
        fputs("  kotoba:      \(kotoba.nats_subject)\n", stderr)
        fputs("  streams:     \(kotoba.streams.joined(separator: ", "))\n", stderr)
        fputs("  clock-sync:  \(requestedTier)\n", stderr)
        fputs("Press Ctrl+C to detach.\n\n", stderr)

        return try await session.start()
    }

    // MARK: - Private

    private func checkClockSyncTier(requested: String, declared: String) throws {
        // Tier ordering: unsynced < app_layer < ntp_lstratum < gptp
        let tierOrder = ["unsynced", "app_layer", "ntp_lstratum", "gptp"]
        let requestedIdx = tierOrder.firstIndex(of: requested) ?? 0
        let declaredIdx = tierOrder.firstIndex(of: declared) ?? 0
        if requestedIdx > declaredIdx {
            throw AttachError.clockSyncTierUnavailable(requested: requested, available: declared)
        }
    }

    private func alignClockSync(tier: String) async {
        // ShiTimeClient stub — replace with direct import when shi-time-sync
        // ships as a standalone SPM package. Today: best-effort no-op that
        // logs the requested alignment.
        fputs("  [clock-sync] aligning to tier: \(tier)\n", stderr)
        // If shikki-cli is available, delegate:
        // await shell(["shi", "time", "align", "--tier", tier])
    }

    private func buildSSHProcess(host: String, user: String, workingDir: String?) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args = ["-t",  // force TTY allocation
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=15",
                    "\(user)@\(host)"]
        if let cwd = workingDir {
            args.append("cd \(cwd) && exec $SHELL -l")
        }
        proc.arguments = args
        return proc
    }
}
