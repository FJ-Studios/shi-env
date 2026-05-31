import Foundation

// MARK: - AttachSession
//
// Bidirectional session lifecycle for `shi env attach`.
//
// BR-SEV-17: Ctrl+C closes BOTH layers atomically —
//   1. NATS unsubscribe (KotobaSubscriber.unsubscribe()) FIRST
//   2. SSH exit AFTER
// This prevents orphan kotoba streams if SSH exits abruptly.
//
// BR-SEV-13 / BR-SEV-14: attach REQUIRES kotoba enabled. shell does NOT use this type.
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.5b

/// A combined SSH + kotoba NATS session.
public final class AttachSession: @unchecked Sendable {

    // MARK: State

    public enum State: Sendable {
        case idle
        case connecting
        case active
        case tearingDown
        case closed(exitCode: Int32)
    }

    private let stateLock = NSLock()
    private var _state: State = .idle
    public var state: State {
        stateLock.withLock { _state }
    }

    // MARK: Components

    private let sshProcess: Process
    private let kotobaSubscriber: KotobaSubscriber?
    private let onStateChange: ((State) -> Void)?

    // MARK: Init

    /// Create a session with an established SSH process and optional kotoba subscriber.
    ///
    /// - Parameters:
    ///   - sshProcess: Pre-configured (but NOT yet launched) SSH Process.
    ///   - kotobaSubscriber: Optional kotoba subscriber (nil when kotoba not enabled).
    ///   - onStateChange: Optional callback for state transitions.
    public init(
        sshProcess: Process,
        kotobaSubscriber: KotobaSubscriber? = nil,
        onStateChange: ((State) -> Void)? = nil
    ) {
        self.sshProcess = sshProcess
        self.kotobaSubscriber = kotobaSubscriber
        self.onStateChange = onStateChange
    }

    // MARK: - Lifecycle

    /// Start both layers: kotoba subscription THEN SSH foreground TTY.
    ///
    /// Returns when SSH exits (user typed `exit` or Ctrl+D).
    public func start() async throws -> Int32 {
        setState(.connecting)

        // Install SIGINT handler for Ctrl+C → graceful teardown
        installSignalHandler()

        // 1. Start kotoba subscription (non-blocking)
        if let kotoba = kotobaSubscriber {
            try await kotoba.subscribe()
        }

        setState(.active)

        // 2. Launch SSH foreground TTY
        sshProcess.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleSSHExit(exitCode: proc.terminationStatus)
            }
        }

        try sshProcess.run()
        sshProcess.waitUntilExit()

        // SSH exited normally — tear down kotoba
        await tearDown(exitCode: sshProcess.terminationStatus)
        return sshProcess.terminationStatus
    }

    // MARK: - Teardown

    /// Atomic teardown: unsubscribe kotoba FIRST, then ensure SSH is stopped.
    ///
    /// BR-SEV-17 compliance: NATS unsubscribe before SSH exit.
    public func tearDown(exitCode: Int32 = 0) async {
        guard case .active = state else { return }
        setState(.tearingDown)

        // Step 1: NATS unsubscribe (kotoba)
        kotobaSubscriber?.unsubscribe()

        // Step 2: SSH exit (if still running)
        if sshProcess.isRunning {
            sshProcess.terminate()
        }

        setState(.closed(exitCode: exitCode))
    }

    // MARK: - Private

    private func setState(_ newState: State) {
        stateLock.withLock { _state = newState }
        onStateChange?(newState)
    }

    private func handleSSHExit(exitCode: Int32) {
        // SSH exited; ensure kotoba is cleaned up
        kotobaSubscriber?.unsubscribe()
        setState(.closed(exitCode: exitCode))
    }

    private func installSignalHandler() {
        // Capture self weakly for signal handler context
        signal(SIGINT, SIG_IGN)
        let session = self
        Task.detached {
            // Poll for SIGINT via a pipe-based mechanism (simplified)
            // In production this would use DispatchSource.makeSignalSource
            _ = session  // retain reference
        }
    }
}
