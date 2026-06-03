import Foundation

// MARK: - EnvMirrorCommand
//
// Handles: shi env mirror sync [--dry-run] [--source-root <path>] [--dest-root <path>]
//
// Wraps MirrorSync.sync() for CLI invocation.
// One-way prod→local only (BR-SELP-04).
// Atomic per-file (BR-SELP-09).
//
// Spec: features/shi-env-local-prod-parity-2026-05-31.md §3.3 (mirror sync row) + §5 TP-SELP-08

public struct EnvMirrorCommand: Sendable {

    public struct Options: Sendable {
        public var dryRun: Bool
        /// Override for prod project root (default: ~/.shikki/workspaces/obyw-one/projects/obyw-one)
        public var sourceRoot: URL?
        /// Override for local PB instance directory (default: ~/.shikki/run/local)
        public var destinationRoot: URL?
        public var jsonOutput: Bool

        public init(
            dryRun: Bool = false,
            sourceRoot: URL? = nil,
            destinationRoot: URL? = nil,
            jsonOutput: Bool = false
        ) {
            self.dryRun = dryRun
            self.sourceRoot = sourceRoot
            self.destinationRoot = destinationRoot
            self.jsonOutput = jsonOutput
        }
    }

    private let shikkiRoot: URL
    private let syncer: MirrorSync

    public init(
        shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki"),
        syncer: MirrorSync = MirrorSync()
    ) {
        self.shikkiRoot = shikkiRoot
        self.syncer = syncer
    }

    @discardableResult
    public func run(
        subVerb: String,
        options: Options,
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {
        guard subVerb == "sync" else {
            fputs("Usage: shi env mirror sync [--dry-run]\n", stderr)
            return 1
        }

        let sourceRoot = options.sourceRoot
            ?? shikkiRoot.appendingPathComponent("workspaces/obyw-one/projects/obyw-one")
        let destRoot = options.destinationRoot
            ?? shikkiRoot.appendingPathComponent("run/local")

        let syncOpts = MirrorSync.Options(
            dryRun: options.dryRun,
            sourceRoot: sourceRoot,
            destinationRoot: destRoot
        )

        let results = try syncer.sync(options: syncOpts)

        if options.jsonOutput {
            let obj = results.map { r -> [String: String] in
                var d = ["path": r.path, "action": r.action.rawValue, "success": r.success ? "true" : "false"]
                if let detail = r.detail { d["detail"] = detail }
                return d
            }
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                outputStream.write(str + "\n")
            }
        } else {
            let prefix = options.dryRun ? "[dry-run] " : ""
            if results.isEmpty {
                outputStream.write("\(prefix)Nothing to sync (source paths absent or empty).\n")
            } else {
                for r in results {
                    let icon = r.success ? "✓" : "✗"
                    outputStream.write("\(icon) \(prefix)\(r.action.rawValue): \(r.path)\n")
                }
                let copied = results.filter { $0.action == .copied }.count
                let skipped = results.filter { $0.action == .skipped }.count
                outputStream.write("\nSync complete: \(copied) copied, \(skipped) skipped.\n")
            }
        }

        return 0
    }
}
