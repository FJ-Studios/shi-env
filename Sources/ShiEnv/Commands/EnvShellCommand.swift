import Foundation

// MARK: - EnvShellCommand
//
// `shi env shell <addr>`
//
// SSH-only TTY into the service's host. NEVER opens kotoba subscription.
//
// BR-SEV-13: distinct semantic from `attach`. No kotoba pipeline.
// Use case: quick debug, log peek, restart a service.
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.5b

public struct EnvShellCommand: Sendable {

    public struct Options: Sendable {
        public var workingDir: String?
        public init(workingDir: String? = nil) { self.workingDir = workingDir }
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

        guard manifest.provider.kind != .local else {
            outputStream.write("Host is local (127.0.0.1) — no SSH needed. Spawning local shell...\n")
            return try await spawnLocalShell()
        }

        guard let ssh = manifest.provider.ssh else {
            fputs("No SSH config for \(manifest.provider.host)\n", stderr)
            return 1
        }

        outputStream.write("Connecting: \(ssh.user)@\(manifest.provider.host)\n")
        outputStream.write("(kotoba NOT active — use `shi env attach` for multimedia session)\n\n")

        return try await sshConnect(
            host: manifest.provider.host,
            user: ssh.user,
            workingDir: options.workingDir
        )
    }

    // MARK: - Private

    private func sshConnect(host: String, user: String, workingDir: String?) async throws -> Int32 {
        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

            // -t: force TTY; TimedSubprocess-style setup per [[shi-cli-startup-timeout-hardening]]
            var args = [
                "-t",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=15",
                "\(user)@\(host)"
            ]
            if let cwd = workingDir {
                args.append("cd \(cwd) && exec $SHELL -l")
            }
            proc.arguments = args

            // Attach stdio directly to the terminal (foreground TTY)
            proc.standardInput  = FileHandle.standardInput
            proc.standardOutput = FileHandle.standardOutput
            proc.standardError  = FileHandle.standardError

            proc.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }

            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func spawnLocalShell() async throws -> Int32 {
        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-l"]
            proc.standardInput  = FileHandle.standardInput
            proc.standardOutput = FileHandle.standardOutput
            proc.standardError  = FileHandle.standardError
            proc.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
