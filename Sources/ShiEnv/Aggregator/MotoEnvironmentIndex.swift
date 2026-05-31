import Foundation

// MARK: - MotoEnvironmentIndex
//
// Reads per-project `.moto` [environment.*] blocks from all workspaces and
// builds ~/.shikki/moto/.index.json.
//
// Write is atomic-rename per BR-SEIS-10 / [[macos-bsd-flock-same-process-reacquisition-gotcha]].
// Regen is event-triggered, NEVER timer-based (BR-SEIS-06 / [[event-driven-never-cyclic-refresh]]).
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md §3.5

// MARK: Index Types

/// A single environment entry in the cross-workspace index.
public struct EnvIndexEntry: Codable, Sendable, Equatable {
    public let workspace: String
    public let project: String
    public let environment: String
    public let providerKind: String
    public let host: String
    public let serviceCount: Int
    public let manifestPath: String
    public let inheritsFrom: String?
    public let lastEventTs: String?

    public init(
        workspace: String,
        project: String,
        environment: String,
        providerKind: String,
        host: String,
        serviceCount: Int,
        manifestPath: String,
        inheritsFrom: String? = nil,
        lastEventTs: String? = nil
    ) {
        self.workspace = workspace
        self.project = project
        self.environment = environment
        self.providerKind = providerKind
        self.host = host
        self.serviceCount = serviceCount
        self.manifestPath = manifestPath
        self.inheritsFrom = inheritsFrom
        self.lastEventTs = lastEventTs
    }

    /// Dot-address (e.g. "obyw-one.obyw-one.prod").
    public var dotAddress: String { "\(workspace).\(project).\(environment)" }
}

/// The cross-workspace environment index written to `~/.shikki/moto/.index.json`.
public struct MotoEnvIndex: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let entries: [EnvIndexEntry]

    public init(entries: [EnvIndexEntry], generatedAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.schemaVersion = 1
        self.generatedAt = generatedAt
        self.entries = entries
    }
}

// MARK: MotoEnvironmentIndex

/// Builds and reads the cross-workspace environment index.
public actor MotoEnvironmentIndex {

    private let shikkiRoot: URL

    /// - Parameter shikkiRoot: Path to `~/.shikki/` (injectable for tests).
    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.shikkiRoot = shikkiRoot
    }

    private var indexURL: URL {
        shikkiRoot.appendingPathComponent("moto/.index.json")
    }

    // MARK: Read

    /// Load the current index from disk. Returns nil if not yet generated.
    public func loadIndex() throws -> MotoEnvIndex? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode(MotoEnvIndex.self, from: data)
    }

    // MARK: Write (atomic rename per BR-SEIS-10)

    /// Persist `index` to `~/.shikki/moto/.index.json` using atomic rename.
    public func writeIndex(_ index: MotoEnvIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)

        let dir = indexURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmpURL = dir.appendingPathComponent(".index.json.\(UUID().uuidString).tmp")
        try data.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: tmpURL)
    }

    // MARK: Reindex

    /// Scan `workspacesRoot` for workspace directories → per-project `.moto` files
    /// → `[environment.*]` TOML blocks → build + persist the index.
    ///
    /// This is the event-triggered reindex path (called by the plugin on
    /// `moto.file.changed` event, per BR-SEIS-06).
    ///
    /// - Parameter workspacesRoot: Path to `~/.shikki/workspaces/` (injectable for tests).
    public func reindex(workspacesRoot: URL) throws -> MotoEnvIndex {
        var entries: [EnvIndexEntry] = []

        let fm = FileManager.default
        guard let workspaceDirs = try? fm.contentsOfDirectory(
            at: workspacesRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return MotoEnvIndex(entries: [])
        }

        for workspaceDir in workspaceDirs {
            guard (try? workspaceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let workspace = workspaceDir.lastPathComponent

            // Scan projects/ subdirectory
            let projectsDir = workspaceDir.appendingPathComponent("projects")
            guard let projectDirs = try? fm.contentsOfDirectory(
                at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for projectDir in projectDirs {
                guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let project = projectDir.lastPathComponent

                // Look for .moto file
                let motoFile = projectDir.appendingPathComponent(".moto")
                guard fm.fileExists(atPath: motoFile.path) else { continue }

                // Parse [environment.*] blocks from .moto (TOML-like block scanner)
                let envEntries = try parseEnvBlocksFromMoto(
                    motoFile: motoFile,
                    workspace: workspace,
                    project: project,
                    projectDir: projectDir
                )
                entries.append(contentsOf: envEntries)
            }
        }

        let index = MotoEnvIndex(entries: entries)
        try writeIndex(index)
        return index
    }

    // MARK: Private — .moto parser

    /// Minimal parser for `[environment.<name>]` blocks in a .moto TOML file.
    private func parseEnvBlocksFromMoto(
        motoFile: URL,
        workspace: String,
        project: String,
        projectDir: URL
    ) throws -> [EnvIndexEntry] {
        let content = try String(contentsOf: motoFile, encoding: .utf8)
        var entries: [EnvIndexEntry] = []

        // Match [environment.<name>] blocks
        let lines = content.components(separatedBy: "\n")
        var currentEnvName: String? = nil
        var blockProps: [String: String] = [:]

        func flushBlock() {
            guard let envName = currentEnvName else { return }
            let manifestPath = blockProps["path"] ?? ".shikki/env/\(envName).yml"
            let inheritsFrom = blockProps["inherits_from"]
            let lastEventTs = blockProps["last_event_ts"]

            // Try to load manifest for richer info
            var providerKind = "unknown"
            var host = "unknown"
            var serviceCount = 0

            let manifestURL = projectDir.appendingPathComponent(manifestPath)
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? EnvironmentManifest.decode(fromJSON: data) {
                providerKind = manifest.provider.kind.rawValue
                host = manifest.provider.host
                serviceCount = manifest.services?.count ?? 0
            }

            entries.append(EnvIndexEntry(
                workspace: workspace,
                project: project,
                environment: envName,
                providerKind: providerKind,
                host: host,
                serviceCount: serviceCount,
                manifestPath: manifestPath,
                inheritsFrom: inheritsFrom,
                lastEventTs: lastEventTs
            ))

            currentEnvName = nil
            blockProps = [:]
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect section header [environment.<name>]
            if trimmed.hasPrefix("[environment.") && trimmed.hasSuffix("]") {
                flushBlock()
                let inner = String(trimmed.dropFirst(13).dropLast(1))
                currentEnvName = inner
                continue
            }

            // Stop at next non-environment section
            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[environment.") {
                flushBlock()
                continue
            }

            // Parse key = value
            if currentEnvName != nil, trimmed.contains("=") {
                let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2 {
                    let key = parts[0]
                    var value = parts[1]
                    // Strip surrounding quotes
                    if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                       (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    blockProps[key] = value
                }
            }
        }

        flushBlock()
        return entries
    }
}
