import Foundation

// MARK: - EnvOpenCommand
//
// `shi env open <addr> [<tenant>]`
//
// Opens the relevant URL/admin/log for a service.
//
// BR-SEV-07: for PB admin routes → delegates to `shi bridge open` (sub-spec #3).
//            Shim: shells to `shi bridge open` via Process (works whether or not
//            sub-spec #3 has merged). Test for bridge composition is disabled
//            until sub-spec #3 lands; see EnvOpenCommandTests.
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.1

public struct EnvOpenCommand: Sendable {

    public struct Options: Sendable {
        public var jsonOutput: Bool
        public init(jsonOutput: Bool = false) { self.jsonOutput = jsonOutput }
    }

    private let shikkiRoot: URL

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.shikkiRoot = shikkiRoot
    }

    public func run(
        address: String,
        tenant: String? = nil,
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

        // Extract service name from the 4th component of address
        let addrParts = address.split(separator: ".").map(String.init)
        let serviceName = addrParts.count >= 4 ? addrParts[3] : nil

        if let svcName = serviceName,
           let serviceEntry = manifest.services?[svcName] {
            return try await openService(svcName, entry: serviceEntry, manifest: manifest,
                                         outputStream: &outputStream)
        }

        // Open env-level URL (first public port of first service)
        if let firstService = manifest.services?.first {
            return try await openService(firstService.key, entry: firstService.value,
                                          manifest: manifest, outputStream: &outputStream)
        }

        fputs("No services found for \(address)\n", stderr)
        return 1
    }

    // MARK: - Private

    private func openService(
        _ serviceName: String,
        entry serviceEntry: ServiceEntry,
        manifest: EnvironmentManifest,
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {

        // PB admin bridge: if service has bridges.admin → delegate to shi bridge open
        if let adminBridge = serviceEntry.bridges?["admin"] {
            return try await delegateToBridgeOpen(
                serviceName: serviceName,
                bridge: adminBridge,
                manifest: manifest,
                outputStream: &outputStream
            )
        }

        // Regular URL: open first public path on first port
        if let port = serviceEntry.ports?.values.first {
            let host = manifest.provider.kind == .local ? "127.0.0.1" : manifest.provider.host
            let path = serviceEntry.public_paths?.first ?? "/"
            let url = "http://\(host):\(port)\(path)"
            return try await openURL(url, outputStream: &outputStream)
        }

        fputs("No URL found for service \(serviceName)\n", stderr)
        return 1
    }

    /// BR-SEV-07: delegate PB admin open to `shi bridge open`.
    ///
    /// Shim that shells to `shi bridge open` CLI. When sub-spec #3 BridgeOpenCommand
    /// is available as a direct Swift call, this shim is replaced. The shell-out
    /// continues to work after that replacement.
    private func delegateToBridgeOpen(
        serviceName: String,
        bridge: BridgeEntry,
        manifest: EnvironmentManifest,
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {
        outputStream.write("Opening \(serviceName) admin via shi bridge open...\n")

        // Check if shi CLI is available
        let shiPath = findShiCLI()
        if let shiPath = shiPath {
            return try await shellRun([shiPath, "bridge", "open",
                                       "\(manifest.addressing.dotAddress).\(serviceName)"])
        }

        // Fallback: open local port directly
        let localURL = "http://127.0.0.1:\(bridge.local_port)\(bridge.open_path ?? "/")"
        outputStream.write("(shi CLI not found — opening local port directly: \(localURL))\n")
        return try await openURL(localURL, outputStream: &outputStream)
    }

    private func openURL(_ url: String, outputStream: inout some TextOutputStream) async throws -> Int32 {
        outputStream.write("Opening: \(url)\n")
        #if os(macOS)
        return try await shellRun(["/usr/bin/open", url])
        #else
        return try await shellRun(["xdg-open", url])
        #endif
    }

    private func shellRun(_ args: [String]) async throws -> Int32 {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0])
            process.arguments = Array(args.dropFirst())
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func findShiCLI() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/shi",
            "/usr/local/bin/shi",
            "/opt/homebrew/bin/shi",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
