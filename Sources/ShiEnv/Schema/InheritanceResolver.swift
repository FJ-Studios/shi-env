import Foundation

// MARK: - InheritanceResolver
//
// Merges a child EnvironmentManifest into its parent, with child fields winning
// on conflicts. Arrays REPLACE by default (no concat).
//
// Cycle detection is mandatory (BR-SEIS-03).
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md §3.3

/// Errors thrown during inheritance resolution.
public enum InheritanceError: Error, Sendable, Equatable {
    /// A cycle was detected in the inheritance chain (e.g. a → b → a).
    case cycle(chain: [String])
    /// The environment named in `inherits_from` is not in the provided catalogue.
    case parentNotFound(name: String, in: String)
}

/// Resolves `inherits_from` chains and produces a fully-merged manifest.
public struct InheritanceResolver: Sendable {

    /// Catalogue: environment name → manifest (for the same workspace.project).
    private let catalogue: [String: EnvironmentManifest]

    public init(catalogue: [String: EnvironmentManifest]) {
        self.catalogue = catalogue
    }

    /// Resolve the manifest named `name`, merging with all ancestors.
    ///
    /// - Parameter name: Environment name (e.g. `"local"`).
    /// - Returns: Fully-merged manifest with all inherited fields applied.
    /// - Throws: ``InheritanceError`` on cycle or missing parent.
    public func resolve(name: String) throws -> EnvironmentManifest {
        try resolved(name: name, visited: [])
    }

    // MARK: Private

    private func resolved(name: String, visited: [String]) throws -> EnvironmentManifest {
        var chain = visited
        // Cycle detection
        if chain.contains(name) {
            throw InheritanceError.cycle(chain: chain + [name])
        }
        chain.append(name)

        guard let manifest = catalogue[name] else {
            throw InheritanceError.parentNotFound(name: name, in: visited.first ?? "<root>")
        }

        guard let parentName = manifest.inherits_from else {
            // Base case — no parent.
            return manifest
        }

        let parent = try resolved(name: parentName, visited: chain)
        return merge(child: manifest, parent: parent)
    }

    /// Merge parent into child. Child fields win on conflict.
    /// Spec §3.3: arrays REPLACE (child array completely replaces parent).
    internal static func merge(
        child: EnvironmentManifest,
        parent: EnvironmentManifest
    ) -> EnvironmentManifest {
        EnvironmentManifest(
            version: child.version,
            addressing: child.addressing,
            inherits_from: nil,           // consumed — merged result has no parent
            provider: mergeProvider(child: child.provider, parent: parent.provider),
            services: mergeServices(child: child.services, parent: parent.services),
            agencies: child.agencies ?? parent.agencies,
            clients: child.clients ?? parent.clients,
            observability_backbone: child.observability_backbone ?? parent.observability_backbone,
            secrets_broker: child.secrets_broker ?? parent.secrets_broker
        )
    }

    private static func mergeProvider(
        child: ProviderBlock,
        parent: ProviderBlock
    ) -> ProviderBlock {
        ProviderBlock(
            kind: child.kind,
            host: child.host,
            region: child.region ?? parent.region,
            capabilities: child.capabilities ?? parent.capabilities,
            resolver_plugin: child.resolver_plugin ?? parent.resolver_plugin,
            ssh: child.ssh ?? parent.ssh,
            kotoba: child.kotoba ?? parent.kotoba
        )
    }

    private static func mergeServices(
        child: [String: ServiceEntry]?,
        parent: [String: ServiceEntry]?
    ) -> [String: ServiceEntry]? {
        guard let parent else { return child }
        guard let child else { return parent }

        var merged = parent
        for (name, childEntry) in child {
            if let parentEntry = parent[name] {
                merged[name] = mergeService(child: childEntry, parent: parentEntry)
            } else {
                merged[name] = childEntry
            }
        }
        return merged
    }

    private static func mergeService(
        child: ServiceEntry,
        parent: ServiceEntry
    ) -> ServiceEntry {
        ServiceEntry(
            image: child.image ?? parent.image,
            ports: child.ports ?? parent.ports,
            // Empty dict in child means "no bridges" (explicit override for local)
            bridges: child.bridges,   // always take child — nil means inherit
            public_paths: child.public_paths ?? parent.public_paths,
            blocked_paths: child.blocked_paths ?? parent.blocked_paths,
            secrets_refs: mergeStringDicts(child: child.secrets_refs, parent: parent.secrets_refs),
            observability: child.observability ?? parent.observability,
            systemd: child.systemd ?? parent.systemd,
            deps: child.deps ?? parent.deps,
            backups: child.backups ?? parent.backups,
            config_generator: child.config_generator ?? parent.config_generator,
            upstream_services: child.upstream_services ?? parent.upstream_services
        )
    }

    private static func mergeStringDicts(
        child: [String: String]?,
        parent: [String: String]?
    ) -> [String: String]? {
        guard let parent else { return child }
        guard let child else { return parent }
        return parent.merging(child) { _, c in c }
    }

    // Internal wrapper for tests
    func merge(child: EnvironmentManifest, parent: EnvironmentManifest) -> EnvironmentManifest {
        Self.merge(child: child, parent: parent)
    }
}
