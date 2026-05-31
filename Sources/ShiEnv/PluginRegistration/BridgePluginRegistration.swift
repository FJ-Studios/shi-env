import Foundation
import ShikkiPluginAPI

// MARK: - BridgePluginRegistration
//
// Conforms ShiEnv bridge functionality to PluginCLISurface, registering the
// "bridge" top-level verb with shikki-cli.
//
// This is a NEW file separate from PluginRegistration.swift (which owns the
// "env" verb). The two are independent PluginCLISurface conformances.
//
// Spec: features/shi-bridge-unification-2026-05-31.md BR-SBU-11 + BR-SBU-12
// BR-SBU-11: all bridge code in shi-env plugin repo
// BR-SBU-12: doctor check registered via PluginDoctorRegistrar

public struct ShiBridgePlugin: PluginCLISurface {

    public static let verb: String = "bridge"

    public static let subVerbs: [String] = ["open", "list", "status", "close"]

    public static func execute(subVerb: String, args: [String]) async throws -> Int32 {
        switch subVerb {

        case "open":
            guard let address = args.first(where: { !$0.hasPrefix("-") }) else {
                fputs("Usage: shi bridge open <service>[.<bridge>] [--env <env>]\n", stderr)
                return 1
            }
            let env = argValue(args, flag: "--env") ?? "prod"
            let opts = BridgeOpenCommand.Options(
                env: env,
                noBrowser: args.contains("--no-browser")
            )
            var stdout = StandardOutputStream()
            let cmd = BridgeOpenCommand()
            return try await cmd.run(address: address, options: opts, outputStream: &stdout)

        case "list":
            let env = argValue(args, flag: "--env") ?? "prod"
            let opts = BridgeListCommand.Options(
                env: env,
                jsonOutput: args.contains("--json")
            )
            var stdout = StandardOutputStream()
            let cmd = BridgeListCommand()
            return try await cmd.run(options: opts, outputStream: &stdout)

        case "status":
            var stdout = StandardOutputStream()
            let cmd = BridgeStatusCommand()
            return try await cmd.run(outputStream: &stdout)

        case "close":
            guard let address = args.first(where: { !$0.hasPrefix("-") }) else {
                fputs("Usage: shi bridge close <service>[.<bridge>]\n", stderr)
                return 1
            }
            var stdout = StandardOutputStream()
            let cmd = BridgeCloseCommand()
            return try await cmd.run(address: address, outputStream: &stdout)

        default:
            fputs("Unknown shi bridge sub-verb: \(subVerb). Available: \(subVerbs.joined(separator: ", "))\n", stderr)
            return 1
        }
    }

    // MARK: Helpers

    private static func argValue(_ args: [String], flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), args.index(after: idx) < args.endIndex else { return nil }
        return args[args.index(after: idx)]
    }
}
