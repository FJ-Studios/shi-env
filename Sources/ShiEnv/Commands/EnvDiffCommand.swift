import Foundation

// MARK: - EnvDiffCommand
//
// Implements `shi env diff <env1> <env2>`.
// Diffs two resolved manifests (typically local vs prod).
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md §3.6

public struct EnvDiffCommand: Sendable {

    public struct DiffEntry: Sendable, Equatable {
        public enum Kind: String, Sendable { case added, removed, changed }
        public let kind: Kind
        public let field: String
        public let left: String?
        public let right: String?
    }

    private let shikkiRoot: URL

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.shikkiRoot = shikkiRoot
    }

    /// Load a resolved manifest by dot-address.
    func loadResolved(address: String) throws -> EnvironmentManifest? {
        let parts = address.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        let (workspace, project, env) = (parts[0], parts[1], parts[2])

        let envDir = shikkiRoot
            .appendingPathComponent("moto/\(workspace)/projects/\(project)/.shikki/env")
        let manifestURL = envDir.appendingPathComponent("\(env).json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }

        let data = try Data(contentsOf: manifestURL)
        var manifest = try EnvironmentManifest.decode(fromJSON: data)

        if let parentName = manifest.inherits_from {
            let parentURL = envDir.appendingPathComponent("\(parentName).json")
            if let parentData = try? Data(contentsOf: parentURL),
               let parent = try? EnvironmentManifest.decode(fromJSON: parentData) {
                let catalogue: [String: EnvironmentManifest] = [env: manifest, parentName: parent]
                manifest = try InheritanceResolver(catalogue: catalogue).resolve(name: env)
            }
        }

        return manifest
    }

    public func diff(_ lhs: EnvironmentManifest, _ rhs: EnvironmentManifest) -> [DiffEntry] {
        var entries: [DiffEntry] = []

        // Provider fields
        if lhs.provider.kind != rhs.provider.kind {
            entries.append(.init(kind: .changed, field: "provider.kind",
                left: lhs.provider.kind.rawValue, right: rhs.provider.kind.rawValue))
        }
        if lhs.provider.host != rhs.provider.host {
            entries.append(.init(kind: .changed, field: "provider.host",
                left: lhs.provider.host, right: rhs.provider.host))
        }

        // Service-level port diffs
        let lhsServices = lhs.services ?? [:]
        let rhsServices = rhs.services ?? [:]
        let allServiceNames = Set(lhsServices.keys).union(rhsServices.keys)

        for svcName in allServiceNames.sorted() {
            let lhsSvc = lhsServices[svcName]
            let rhsSvc = rhsServices[svcName]

            if lhsSvc == nil {
                entries.append(.init(kind: .added, field: "services.\(svcName)", left: nil, right: "(present)"))
                continue
            }
            if rhsSvc == nil {
                entries.append(.init(kind: .removed, field: "services.\(svcName)", left: "(present)", right: nil))
                continue
            }

            // Port diffs
            let lhsPorts = lhsSvc?.ports ?? [:]
            let rhsPorts = rhsSvc?.ports ?? [:]
            let allPortNames = Set(lhsPorts.keys).union(rhsPorts.keys)
            for portName in allPortNames.sorted() {
                let lv = lhsPorts[portName].map(String.init)
                let rv = rhsPorts[portName].map(String.init)
                if lv != rv {
                    entries.append(.init(kind: .changed,
                        field: "services.\(svcName).ports.\(portName)", left: lv, right: rv))
                }
            }

            // Secret ref diffs
            let lhsRefs = lhsSvc?.secrets_refs ?? [:]
            let rhsRefs = rhsSvc?.secrets_refs ?? [:]
            let allRefKeys = Set(lhsRefs.keys).union(rhsRefs.keys)
            for refKey in allRefKeys.sorted() {
                let lv = lhsRefs[refKey]
                let rv = rhsRefs[refKey]
                if lv != rv {
                    entries.append(.init(kind: .changed,
                        field: "services.\(svcName).secrets_refs.\(refKey)", left: lv, right: rv))
                }
            }
        }

        // Observability backbone endpoint
        if lhs.observability_backbone?.kurma_endpoint != rhs.observability_backbone?.kurma_endpoint {
            entries.append(.init(kind: .changed, field: "observability_backbone.kurma_endpoint",
                left: lhs.observability_backbone?.kurma_endpoint,
                right: rhs.observability_backbone?.kurma_endpoint))
        }

        return entries
    }

    public func run(
        addr1: String,
        addr2: String,
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {
        guard let lhs = try loadResolved(address: addr1) else {
            outputStream.write("ERROR: could not load \(addr1)\n"); return 1
        }
        guard let rhs = try loadResolved(address: addr2) else {
            outputStream.write("ERROR: could not load \(addr2)\n"); return 1
        }

        let entries = diff(lhs, rhs)
        if entries.isEmpty {
            outputStream.write("No differences between \(addr1) and \(addr2).\n")
            return 0
        }

        outputStream.write("diff \(addr1) → \(addr2)\n")
        for e in entries {
            switch e.kind {
            case .changed:
                outputStream.write("~ \(e.field): \(e.left ?? "(nil)") → \(e.right ?? "(nil)")\n")
            case .added:
                outputStream.write("+ \(e.field)\n")
            case .removed:
                outputStream.write("- \(e.field)\n")
            }
        }
        return 0
    }
}
