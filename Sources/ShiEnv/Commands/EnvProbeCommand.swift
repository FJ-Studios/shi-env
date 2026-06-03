import Foundation

// MARK: - EnvProbeCommand
//
// Implements `shi env probe --target <host>` — read-only state probe.
// Called internally by apply; also available standalone for diagnosis.
//
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.2

public struct EnvProbeCommand {

    public struct Options: Sendable, Equatable {
        public let jsonOutput: Bool

        public init(jsonOutput: Bool = false) {
            self.jsonOutput = jsonOutput
        }
    }

    private let shikkiRoot: URL

    public init(shikkiRoot: URL) {
        self.shikkiRoot = shikkiRoot
    }

    public func run(
        manifest: EnvironmentManifest,
        target: String,
        options: Options,
        outputStream: inout some TextOutputStream,
        secretsResolver: any SecretsResolverProtocol
    ) async throws -> Int32 {
        guard let ssh = manifest.provider.ssh else {
            fputs("Error: No SSH config for host '\(target)' in inventory.\n", stderr)
            return 1
        }

        let sshKeyPath = try await secretsResolver.resolveSSHKeyPath(uri: ssh.key_ref)
        let executor = TimedSSHExecutor(sshKeyPath: sshKeyPath)

        let services = manifest.services ?? [:]
        var probeResults: [String: [String: String]] = [:]

        for (name, entry) in services.sorted(by: { $0.key < $1.key }) {
            let svcManifest = ServiceManifest.from(name: name, entry: entry)
            let impl = RemoteManagedServiceImpl(
                host: target,
                sshUser: ssh.user,
                manifest: svcManifest,
                executor: executor
            )
            do {
                let state = try await impl.probeRemote()
                probeResults[name] = state
            } catch {
                probeResults[name] = ["error": error.localizedDescription]
            }
        }

        if options.jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(probeResults),
               let json = String(data: data, encoding: .utf8) {
                outputStream.write(json + "\n")
            }
        } else {
            outputStream.write("Probe: \(target)\n")
            for (name, state) in probeResults.sorted(by: { $0.key < $1.key }) {
                outputStream.write("  \(name):\n")
                for (k, v) in state.sorted(by: { $0.key < $1.key }) {
                    outputStream.write("    \(k): \(v)\n")
                }
            }
        }

        return 0
    }
}
