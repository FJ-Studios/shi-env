import Foundation

// MARK: - CaddyTrustChecker
//
// Checks whether Caddy Local Authority root CA is installed in the system trust store.
// On macOS: `security find-certificate -c "Caddy Local Authority" /Library/Keychains/System.keychain`.
// First-run: prompts operator for one-time `sudo caddy trust` (BR-SELP-15, §3.8).
//
// Spec: features/shi-env-local-prod-parity-2026-05-31.md §3.8 + BR-SELP-15

public struct CaddyTrustChecker: Sendable {

    public enum TrustCheckError: Error, LocalizedError {
        case declinedByOperator
        case sudoCaddyTrustFailed(String)

        public var errorDescription: String? {
            switch self {
            case .declinedByOperator:
                return "Operator declined Caddy trust setup. Local HTTPS unavailable."
            case .sudoCaddyTrustFailed(let detail):
                return "sudo caddy trust failed: \(detail)"
            }
        }
    }

    private let securityBinary: String
    private let caddyBinary: String
    private let keychainPath: String

    public init(
        securityBinary: String = "/usr/bin/security",
        caddyBinary: String = "/usr/local/bin/caddy",
        keychainPath: String = "/Library/Keychains/System.keychain"
    ) {
        self.securityBinary = securityBinary
        self.caddyBinary = caddyBinary
        self.keychainPath = keychainPath
    }

    /// Returns true if "Caddy Local Authority" is in the system keychain.
    public func isCAInstalled() async throws -> Bool {
        let result = await run(
            binary: securityBinary,
            args: ["find-certificate", "-c", "Caddy Local Authority", keychainPath]
        )
        return result.exitCode == 0
    }

    /// Emit the one-time trust prompt string (caller handles I/O for testability).
    public func trustPrompt() -> String {
        "Caddy Local Authority is not trusted. Run:\n  sudo caddy trust\nthen re-run shi env up local."
    }

    // MARK: Private

    private struct ShellResult {
        let exitCode: Int32
        let output: String
        let error: String
    }

    private func run(binary: String, args: [String]) async -> ShellResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { _ in }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ShellResult(exitCode: 127, output: "", error: error.localizedDescription))
                return
            }

            Task.detached {
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                continuation.resume(returning: ShellResult(exitCode: process.terminationStatus, output: out, error: err))
            }
        }
    }
}
