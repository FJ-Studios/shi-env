import Foundation

// MARK: - EnvAttachCommand
//
// `shi env attach <addr>`
//
// Full multimedia attach: SSH + kotoba NATS subscription + clock-sync alignment.
//
// BR-SEV-14: REQUIRES provider.kotoba.enabled = true.
//            Refuses with clear error if kotoba not declared or disabled.
// BR-SEV-15: clock-sync via ShiTimeClient.shared.alignTo(<tier>).
//            Refuses if requested tier > current ceiling.
// BR-SEV-16: kotoba CLI shell-out fallback if Swift API not ready.
// BR-SEV-17: AttachSession tears down BOTH layers atomically —
//            NATS unsubscribe FIRST, then SSH exit.
//
// Distinct semantic from `shell` (BR-SEV-13). No sugar/shorthand between them.
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.5b

public struct EnvAttachCommand: Sendable {

    public struct Options: Sendable {
        public var clockSyncTier: String?

        public init(clockSyncTier: String? = nil) {
            self.clockSyncTier = clockSyncTier
        }
    }

    private let shikkiRoot: URL

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.shikkiRoot = shikkiRoot
    }

    public func run(
        address: String,
        options: Options = Options(),
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {

        let indexActor = MotoEnvironmentIndex(shikkiRoot: shikkiRoot)
        guard let index = try await indexActor.loadIndex() else {
            fputs("No index. Run: shi env reindex\n", stderr)
            return 1
        }

        let entries = EnvCommand.expandAddress(address, in: index)
        guard let entry = entries.first else {
            fputs("No environment matches: \(address)\n", stderr)
            return 1
        }

        let manifestURL = shikkiRoot
            .appendingPathComponent("workspaces/\(entry.workspace)/projects/\(entry.project)")
            .appendingPathComponent(entry.manifestPath.replacingOccurrences(of: ".yml", with: ".json"))

        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? EnvironmentManifest.decode(fromJSON: data) else {
            fputs("Could not load manifest for \(entry.dotAddress)\n", stderr)
            return 1
        }

        let orchestrator = AttachOrchestrator(shikkiRoot: shikkiRoot)

        do {
            return try await orchestrator.attach(
                address: address,
                manifest: manifest,
                clockSyncTier: options.clockSyncTier
            )
        } catch let attachError as AttachError {
            fputs("Error: \(attachError.localizedDescription ?? attachError.localizedDescription)\n", stderr)
            return 1
        } catch {
            fputs("Attach failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
