import Foundation

// MARK: - BridgeOpenCommand
//
// Implements `shi bridge open <site>[.<bridge>] [--env <env>]`
//
// Opens an SSH tunnel from the inventory bridges block and (if open_path is
// set) opens the local URL in the browser.
//
// Spec: features/shi-bridge-unification-2026-05-31.md §3.2
// BR-SBU-01: no hardcoded port table — derives from inventory

public struct BridgeOpenCommand: Sendable {

    public struct Options: Sendable {
        /// Environment name to use (default: "prod").
        public var env: String
        /// If true, skip browser open even when open_path is set.
        public var noBrowser: Bool

        public init(env: String = "prod", noBrowser: Bool = false) {
            self.env = env
            self.noBrowser = noBrowser
        }
    }

    private let manifestLoader: ManifestLoader
    private let opener: BridgeOpener

    public init(
        manifestLoader: ManifestLoader = ManifestLoader(),
        opener: BridgeOpener = BridgeOpener()
    ) {
        self.manifestLoader = manifestLoader
        self.opener = opener
    }

    /// Run the command.
    ///
    /// - Parameter address: e.g. "back", "back.admin", "pocketbase", "pocketbase.admin"
    public func run(
        address: String,
        options: Options = Options(),
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {
        let bridgeAddr = BridgeAddress.parse(address)

        let manifest: EnvironmentManifest
        do {
            manifest = try await manifestLoader.load(env: options.env)
        } catch {
            outputStream.write("Error loading manifest for env '\(options.env)': \(error.localizedDescription)\n")
            return 1
        }

        outputStream.write("Opening tunnel: \(bridgeAddr.service).\(bridgeAddr.bridge) [env=\(options.env)]\n")

        let handle: BridgeHandle
        do {
            handle = try await opener.open(addr: bridgeAddr, manifest: manifest)
        } catch let err as BridgeError {
            outputStream.write("Bridge error: \(err.localizedDescription)\n")
            return 1
        }

        let bridgeEntry = manifest.services?[bridgeAddr.service]?.bridges?[bridgeAddr.bridge]
        let localPath = bridgeEntry?.open_path ?? "/"
        outputStream.write("Tunnel open: http://localhost:\(handle.localPort)\(localPath)\n")
        outputStream.write("Press Ctrl+C to close.\n")

        // Block until SIGINT/SIGTERM (foreground mode)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            signal(SIGINT) { _ in }
            signal(SIGTERM) { _ in }
            // Wait for process to die or user interrupt
            let checkInterval: UInt64 = 500_000_000 // 0.5s
            Task {
                while kill(handle.pid, 0) == 0 {
                    try? await Task.sleep(nanoseconds: checkInterval)
                }
                continuation.resume()
            }
        }

        outputStream.write("\nTunnel closed.\n")
        return 0
    }
}
