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

    public static let subVerbs: [String] = ["list", "show", "diff", "lint", "reindex"]

    public static func execute(subVerb: String, args: [String]) async throws -> Int32 {
        switch subVerb {

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
            let shikkiRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")
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
                    .appendingPathComponent("moto/\(entry.workspace)/projects/\(entry.project)")
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
            let shikkiRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")
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
