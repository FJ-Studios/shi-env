import Foundation

// MARK: - EnvApplyCommand
//
// Implements `shi env apply --target <host> [--dry-run | --apply] [--yes] [--all]`
//
// BR-SERA-01: --dry-run mandatory first invocation per target
// BR-SERA-07: --apply requires --yes or interactive confirmation
// BR-SERA-11: --all requires --i-know-what-im-doing
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.2

public struct EnvApplyCommand {

    public struct Options: Sendable, Equatable {
        public let dryRun: Bool
        public let apply: Bool
        public let yes: Bool
        public let all: Bool
        public let iKnowWhatImDoing: Bool
        public let jsonOutput: Bool
        public let target: String?
        public let env: String?

        public init(
            dryRun: Bool = false,
            apply: Bool = false,
            yes: Bool = false,
            all: Bool = false,
            iKnowWhatImDoing: Bool = false,
            jsonOutput: Bool = false,
            target: String? = nil,
            env: String? = nil
        ) {
            self.dryRun = dryRun
            self.apply = apply
            self.yes = yes
            self.all = all
            self.iKnowWhatImDoing = iKnowWhatImDoing
            self.jsonOutput = jsonOutput
            self.target = target
            self.env = env
        }
    }

    private let shikkiRoot: URL
    private let orchestrator: ConvergeOrchestrator

    public init(
        shikkiRoot: URL,
        orchestrator: ConvergeOrchestrator
    ) {
        self.shikkiRoot = shikkiRoot
        self.orchestrator = orchestrator
    }

    public func run(
        manifest: EnvironmentManifest,
        options: Options,
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {
        // Validate mutually-exclusive flags
        if options.dryRun && options.apply {
            fputs("Error: --dry-run and --apply are mutually exclusive.\n", stderr)
            return 1
        }

        if !options.dryRun && !options.apply {
            fputs("Usage: shi env apply --target <host> --dry-run | --apply [--yes]\n", stderr)
            fputs("  --dry-run   Plan + display, no mutation (required first)\n", stderr)
            fputs("  --apply     Execute the plan (requires prior --dry-run)\n", stderr)
            return 1
        }

        // BR-SERA-11: --all requires --i-know-what-im-doing
        if options.all && !options.iKnowWhatImDoing {
            fputs("Error: --all requires --i-know-what-im-doing (BR-SERA-11).\n", stderr)
            fputs("  Multi-host blast radius — review plan carefully before executing.\n", stderr)
            return 1
        }

        let host = options.target ?? manifest.provider.host
        let applyOptions = ApplyOptions(
            dryRun: options.dryRun,
            apply: options.apply,
            yes: options.yes,
            all: options.all,
            iKnowWhatImDoing: options.iKnowWhatImDoing,
            jsonOutput: options.jsonOutput,
            targetHost: host,
            env: options.env ?? manifest.addressing.environment
        )

        // Use a buffered output to avoid Sendable inout-capture issues with actor calls.
        var buffer = BufferedOutputStream()

        do {
            let results = try await orchestrator.run(
                manifest: manifest,
                host: host,
                options: applyOptions,
                output: &buffer
            )

            // Forward buffered output to caller's stream
            outputStream.write(buffer.buffer)

            if options.jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(results),
                   let json = String(data: data, encoding: .utf8) {
                    outputStream.write(json + "\n")
                }
            }

            let allOk = results.allSatisfy { $0.succeeded }
            return allOk ? 0 : 1

        } catch let err as ApplyError {
            outputStream.write(buffer.buffer)
            fputs("Error: \(err.localizedDescription)\n", stderr)
            return 1
        } catch {
            outputStream.write(buffer.buffer)
            fputs("Apply failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

// MARK: - BufferedOutputStream

/// A TextOutputStream that accumulates output into a String buffer.
/// Used to avoid inout-across-actor-boundary issues in Swift 6.
struct BufferedOutputStream: TextOutputStream {
    var buffer: String = ""
    mutating func write(_ string: String) {
        buffer += string
    }
}
