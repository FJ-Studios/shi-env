import Foundation
import ShikkiPluginAPI

// MARK: - PluginRegistration
//
// Conforms ShiEnv to PluginCLISurface from shikki-plugin-api, registering the
// "env" verb and its sub-verbs with shikki-cli.
//
// shikki-cli discovers this type at startup via the plugin loader
// (PluginRegistry.shared.discover()) and routes:
//   shi env list   → EnvListCommand
//   shi env show   → EnvShowCommand
//   shi env diff   → EnvDiffCommand
//   shi env lint   → EnvLintCommand
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md BR-SEIS-12
// Umbrella: features/shi-env-umbrella-vision-2026-05-31.md BR-SEUV-13

public struct ShiEnvPlugin: PluginCLISurface {

    public static let verb: String = "env"

    public static let subVerbs: [String] = [
        "list", "show", "diff", "lint", "reindex",
        "up", "down", "status", "open", "restart", "logs", "shell", "attach"
    ]

    public static func execute(subVerb: String, args: [String]) async throws -> Int32 {
        let shikkiRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")

        switch subVerb {

        case "up":
            guard let address = args.first(where: { !$0.hasPrefix("-") }) else {
                fputs("Usage: shi env up <addr> [--dry-run | --apply]\n", stderr)
                return 1
            }
            let opts = EnvUpCommand.Options(
                dryRun: args.contains("--dry-run"),
                apply: args.contains("--apply"),
                jsonOutput: args.contains("--json")
            )
            var stdout = StandardOutputStream()
            let cmd = EnvUpCommand(shikkiRoot: shikkiRoot)
            return try await cmd.run(address: address, options: opts, outputStream: &stdout)

        case "down":
            guard let address = args.first(where: { !$0.hasPrefix("-") }) else {
                fputs("Usage: shi env down <addr> [--dry-run | --apply]\n", stderr)
                return 1
            }
            let opts = EnvDownCommand.Options(
                dryRun: args.contains("--dry-run"),
                apply: args.contains("--apply"),
                jsonOutput: args.contains("--json")
            )
            var stdout = StandardOutputStream()
            let cmd = EnvDownCommand(shikkiRoot: shikkiRoot)
            return try await cmd.run(address: address, options: opts, outputStream: &stdout)

        case "status":
            let address = args.first(where: { !$0.hasPrefix("-") })
            let opts = EnvStatusCommand.Options(jsonOutput: args.contains("--json"))
            var stdout = StandardOutputStream()
            let cmd = EnvStatusCommand(shikkiRoot: shikkiRoot)
            return try await cmd.run(address: address, options: opts, outputStream: &stdout)

        case "open":
            guard let address = args.first(where: { !$0.hasPrefix("-") }) else {
                fputs("Usage: shi env open <addr> [<tenant>]\n", stderr)
                return 1
            }
            let positional = args.filter { !$0.hasPrefix("-") }
            let tenant = positional.count >= 2 ? positional[1] : nil
            let opts = EnvOpenCommand.Options(jsonOutput: args.contains("--json"))
            var stdout = StandardOutputStream()
            let cmd = EnvOpenCommand(shikkiRoot: shikkiRoot)
            return try await cmd.run(address: address, tenant: tenant, options: opts, outputStream: &stdout)

        case "restart":
            guard let address = args.first(where: { !$0.hasPrefix("-") }) else {
                fputs("Usage: shi env restart <addr> [--dry-run | --apply]\n", stderr)
                return 1
            }
            let opts = EnvRestartCommand.Options(
                dryRun: args.contains("--dry-run"),
                apply: args.contains("--apply"),
                jsonOutput: args.contains("--json")
            )
            var stdout = StandardOutputStream()
            let cmd = EnvRestartCommand(shikkiRoot: shikkiRoot)
            return try await cmd.run(address: address, options: opts, outputStream: &stdout)

        case "logs":
            guard let address = args.first(where: { !$0.hasPrefix("-") }) else {
                fputs("Usage: shi env logs <addr> [--follow]\n", stderr)
                return 1
            }
            let opts = EnvLogsCommand.Options(
                follow: args.contains("--follow"),
                jsonOutput: args.contains("--json")
            )
            var stdout = StandardOutputStream()
            let cmd = EnvLogsCommand(shikkiRoot: shikkiRoot)
            return try await cmd.run(address: address, options: opts, outputStream: &stdout)

        case "shell":
            guard let address = args.first(where: { !$0.hasPrefix("-") }) else {
                fputs("Usage: shi env shell <addr>\n", stderr)
                return 1
            }
            let workingDir = argValue(args, flag: "--cwd")
            let opts = EnvShellCommand.Options(workingDir: workingDir)
            var stdout = StandardOutputStream()
            let cmd = EnvShellCommand(shikkiRoot: shikkiRoot)
            return try await cmd.run(address: address, options: opts, outputStream: &stdout)

        case "attach":
            guard let address = args.first(where: { !$0.hasPrefix("-") }) else {
                fputs("Usage: shi env attach <addr>\n", stderr)
                return 1
            }
            let opts = EnvAttachCommand.Options(clockSyncTier: argValue(args, flag: "--clock-sync-tier"))
            var stdout = StandardOutputStream()
            let cmd = EnvAttachCommand(shikkiRoot: shikkiRoot)
            return try await cmd.run(address: address, options: opts, outputStream: &stdout)

        case "list":
            let opts = EnvListCommand.Options(
                jsonOutput: args.contains("--json"),
                tenantsOnly: args.contains("--tenants"),
                operatingAgency: argValue(args, flag: "--operating-agency"),
                sourceAgency: argValue(args, flag: "--source-agency")
            )
            var stdout = StandardOutputStream()
            let cmd = EnvListCommand()
            return try await cmd.run(options: opts, outputStream: &stdout)

        case "show":
            guard let address = args.first(where: { !$0.hasPrefix("-") }) else {
                fputs("Usage: shi env show <workspace>.<project>.<env>\n", stderr)
                return 1
            }
            let opts = EnvShowCommand.Options(jsonOutput: args.contains("--json"))
            var stdout = StandardOutputStream()
            let cmd = EnvShowCommand()
            return try await cmd.run(address: address, options: opts, outputStream: &stdout)

        case "diff":
            let positional = args.filter { !$0.hasPrefix("-") }
            guard positional.count >= 2 else {
                fputs("Usage: shi env diff <env1> <env2>\n", stderr)
                return 1
            }
            var stdout = StandardOutputStream()
            let cmd = EnvDiffCommand()
            return try await cmd.run(addr1: positional[0], addr2: positional[1], outputStream: &stdout)

        case "lint":
            let address = args.first(where: { !$0.hasPrefix("-") }) ?? "all"
            let opts = EnvLintCommand.Options(
                strict: args.contains("--strict"),
                jsonOutput: args.contains("--json")
            )
            // For the CLI entrypoint we scan the index for all addresses when "all"
            let indexActor = MotoEnvironmentIndex(shikkiRoot: shikkiRoot)
            guard let index = try await indexActor.loadIndex() else {
                fputs("No index. Run: shi env reindex\n", stderr)
                return 1
            }

            var stdout = StandardOutputStream()
            var overallExit: Int32 = 0
            let cmd = EnvLintCommand(shikkiRoot: shikkiRoot)

            let entriesToLint = address == "all"
                ? index.entries
                : index.entries.filter { $0.dotAddress == address }

            for entry in entriesToLint {
                let manifestURL = shikkiRoot
                    .appendingPathComponent("workspaces/\(entry.workspace)/projects/\(entry.project)")
                    .appendingPathComponent(entry.manifestPath.replacingOccurrences(of: ".yml", with: ".json"))
                guard let data = try? Data(contentsOf: manifestURL) else {
                    stdout.write("\(entry.dotAddress): WARN manifest file not found at \(manifestURL.path)\n")
                    continue
                }
                let exitCode = try cmd.run(
                    address: entry.dotAddress,
                    manifestData: data,
                    options: opts,
                    outputStream: &stdout
                )
                if exitCode != 0 { overallExit = exitCode }
            }
            return overallExit

        case "reindex":
            let workspacesRoot = shikkiRoot.appendingPathComponent("workspaces")
            let indexActor = MotoEnvironmentIndex(shikkiRoot: shikkiRoot)
            let index = try await indexActor.reindex(workspacesRoot: workspacesRoot)
            print("Reindexed \(index.entries.count) environment(s).")
            return 0

        default:
            fputs("Unknown shi env sub-verb: \(subVerb). Available: \(subVerbs.joined(separator: ", "))\n", stderr)
            return 1
        }
    }

    // MARK: Helpers

    private static func argValue(_ args: [String], flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), args.index(after: idx) < args.endIndex else { return nil }
        return args[args.index(after: idx)]
    }
}

// MARK: - StandardOutputStream

/// Simple TextOutputStream writing to stdout.
struct StandardOutputStream: TextOutputStream {
    mutating func write(_ string: String) {
        print(string, terminator: "")
    }
}
