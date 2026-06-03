import Foundation

// MARK: - HostsGenerator
//
// Emits /etc/hosts entries from `host_mappings` + `clients[]` per-tenant (BR-SELP-13).
// `--apply` requires explicit flag + sudo confirmation (BR-SELP-06).
// Iterates `manifest.clients[]` to derive <slug>.dev entries from prod hosts.
//
// Spec: features/shi-env-local-prod-parity-2026-05-31.md §3.5 + §3.6

public struct HostsGenerator: Sendable {

    public struct Options: Sendable {
        /// Write to /etc/hosts (requires sudo). When false, only emits lines.
        public var apply: Bool
        /// Omit per-tenant client entries (--no-per-tenant flag, BR-SELP-13 opt-out).
        public var skipPerTenant: Bool

        public init(apply: Bool = false, skipPerTenant: Bool = false) {
            self.apply = apply
            self.skipPerTenant = skipPerTenant
        }
    }

    public struct GeneratedEntry: Sendable, Equatable {
        public let ip: String
        public let hostname: String
        public let comment: String?

        public init(ip: String, hostname: String, comment: String? = nil) {
            self.ip = ip
            self.hostname = hostname
            self.comment = comment
        }

        public var hostsLine: String {
            if let c = comment {
                return "\(ip)\t\(hostname)\t# \(c)"
            }
            return "\(ip)\t\(hostname)"
        }
    }

    public struct GenerationResult: Sendable {
        public let entries: [GeneratedEntry]
        /// The full block that would be written to /etc/hosts.
        public let block: String
        /// Whether the block was written (only true when options.apply == true
        /// and the sudo prompt succeeded).
        public var applied: Bool

        public init(entries: [GeneratedEntry], block: String, applied: Bool = false) {
            self.entries = entries
            self.block = block
            self.applied = applied
        }
    }

    // Marker comments bounding the managed block in /etc/hosts.
    static let beginMarker = "# BEGIN shi-env managed"
    static let endMarker   = "# END shi-env managed"

    private let hostsPath: String

    public init(hostsPath: String = "/etc/hosts") {
        self.hostsPath = hostsPath
    }

    /// Generate /etc/hosts entries from a resolved manifest.
    ///
    /// - Parameter manifest: A fully-resolved `EnvironmentManifest` (inherits_from applied).
    /// - Parameter options: Generation options.
    /// - Returns: `GenerationResult` with the entries + optional write outcome.
    @discardableResult
    public func generate(
        manifest: EnvironmentManifest,
        options: Options = Options()
    ) throws -> GenerationResult {
        var entries: [GeneratedEntry] = []

        let providerIP = manifest.provider.host == "127.0.0.1"
            ? "127.0.0.1"
            : manifest.provider.host

        // 1. Emit from explicit host_mappings in the manifest (extended field — stored as provider host alias)
        //    For now we derive from the manifest's environment name conventions.
        //    When host_mappings is added to EnvironmentManifest, iterate it here.

        // 2. Derive per-service .dev hostnames
        for (svcName, _) in (manifest.services ?? [:]).sorted(by: { $0.key < $1.key }) {
            let hostname = "\(svcName).dev"
            entries.append(GeneratedEntry(ip: "127.0.0.1", hostname: hostname,
                                         comment: "shi-env: \(svcName) local"))
        }

        // Standard home.dev entry
        entries.insert(GeneratedEntry(ip: "127.0.0.1", hostname: "home.dev",
                                     comment: "shi-env: local hub"), at: 0)

        // 3. Per-tenant entries from clients[] (BR-SELP-13)
        if !options.skipPerTenant {
            for client in (manifest.clients ?? []) {
                let hostname = "\(client.slug).dev"
                // Avoid duplicate
                if !entries.contains(where: { $0.hostname == hostname }) {
                    entries.append(GeneratedEntry(
                        ip: "127.0.0.1",
                        hostname: hostname,
                        comment: "shi-env: \(client.slug) tenant (provider: \(providerIP))"
                    ))
                }
            }
        }

        let lines = entries.map(\.hostsLine).joined(separator: "\n")
        let block = """
        \(Self.beginMarker)
        \(lines)
        \(Self.endMarker)
        """

        var result = GenerationResult(entries: entries, block: block, applied: false)

        if options.apply {
            try writeBlock(block)
            result.applied = true
        }

        return result
    }

    // MARK: Private

    private func writeBlock(_ block: String) throws {
        let existing = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        let updated = replaceOrAppendBlock(in: existing, with: block)
        let tmpPath = hostsPath + ".shi-env.tmp"
        try updated.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        // Atomic replace — caller responsible for sudo elevation
        try FileManager.default.moveItem(atPath: tmpPath, toPath: hostsPath)
    }

    private func replaceOrAppendBlock(in content: String, with block: String) -> String {
        var lines = content.components(separatedBy: "\n")
        if let beginIdx = lines.firstIndex(of: Self.beginMarker),
           let endIdx   = lines.firstIndex(of: Self.endMarker),
           beginIdx < endIdx {
            lines.replaceSubrange(beginIdx...endIdx, with: block.components(separatedBy: "\n"))
            return lines.joined(separator: "\n")
        }
        // Append
        return content + "\n" + block + "\n"
    }
}
