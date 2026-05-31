import Foundation

// MARK: - ManifestLoader
//
// Loads the EnvironmentManifest for a given environment name from
// ~/.shikki/moto/<workspace>/projects/<project>/<env>.json
//
// For tests, inject a custom shikkiRoot and pre-populate the fixture directory.

public struct ManifestLoader: Sendable {

    private let shikkiRoot: URL

    public init(
        shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")
    ) {
        self.shikkiRoot = shikkiRoot
    }

    // MARK: - Load from index

    /// Load the manifest for the first indexed environment matching `env`.
    public func load(env: String) async throws -> EnvironmentManifest {
        // 1. Try loading from the moto index
        let indexActor = MotoEnvironmentIndex(shikkiRoot: shikkiRoot)
        if let index = try? await indexActor.loadIndex() {
            for entry in index.entries where entry.environment == env {
                let manifestURL = shikkiRoot
                    .appendingPathComponent("moto/\(entry.workspace)/projects/\(entry.project)")
                    .appendingPathComponent(entry.manifestPath.replacingOccurrences(of: ".yml", with: ".json"))
                if let data = try? Data(contentsOf: manifestURL) {
                    return try EnvironmentManifest.decode(fromJSON: data)
                }
            }
        }
        // 2. Fallback: look for ~/.shikki/env/<env>.json directly
        let directURL = shikkiRoot.appendingPathComponent("env/\(env).json")
        if let data = try? Data(contentsOf: directURL) {
            return try EnvironmentManifest.decode(fromJSON: data)
        }
        throw ManifestLoaderError.notFound(env: env)
    }
}

public enum ManifestLoaderError: Error, LocalizedError {
    case notFound(env: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let env):
            return "No manifest found for env '\(env)'. Run `shi env reindex` to rebuild the index."
        }
    }
}
