import Foundation

// MARK: - EnvShowCommand
//
// Implements `shi env show <workspace>.<project>.<env>`.
// Pretty-prints the resolved (post-inheritance) manifest.
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md §3.6

public struct EnvShowCommand: Sendable {

    public struct Options: Sendable {
        public var jsonOutput: Bool
        public init(jsonOutput: Bool = false) { self.jsonOutput = jsonOutput }
    }

    private let shikkiRoot: URL

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.shikkiRoot = shikkiRoot
    }

    /// - Parameter address: Dot-separated address (e.g. "obyw-one.obyw-one.prod").
    public func run(
        address: String,
        options: Options = Options(),
        outputStream: inout some TextOutputStream
    ) async throws -> Int32 {
        let parts = address.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            outputStream.write("ERROR: address must be <workspace>.<project>.<env>, got: \(address)\n")
            return 1
        }
        let (workspace, project, env) = (parts[0], parts[1], parts[2])

        let projectDir = shikkiRoot
            .appendingPathComponent("moto")
            .appendingPathComponent(workspace)
            .appendingPathComponent("projects")
            .appendingPathComponent(project)

        let envDir = projectDir.appendingPathComponent(".shikki/env")
        let manifestURL = envDir.appendingPathComponent("\(env).json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            outputStream.write("ERROR: manifest not found at \(manifestURL.path)\n")
            return 1
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try EnvironmentManifest.decode(fromJSON: data)

        // Load catalogue for inheritance resolution
        var catalogue: [String: EnvironmentManifest] = [env: manifest]
        if let parentName = manifest.inherits_from {
            let parentURL = envDir.appendingPathComponent("\(parentName).json")
            if let parentData = try? Data(contentsOf: parentURL),
               let parent = try? EnvironmentManifest.decode(fromJSON: parentData) {
                catalogue[parentName] = parent
            }
        }

        let resolver = InheritanceResolver(catalogue: catalogue)
        let resolved = try resolver.resolve(name: env)

        if options.jsonOutput {
            let jsonData = try resolved.encodeToJSON()
            outputStream.write(String(data: jsonData, encoding: .utf8) ?? "")
            outputStream.write("\n")
        } else {
            outputStream.write(prettyPrint(resolved))
        }

        return 0
    }

    private func prettyPrint(_ m: EnvironmentManifest) -> String {
        var lines: [String] = []
        lines.append("Environment: \(m.addressing.dotAddress)")
        lines.append("Provider: \(m.provider.kind.rawValue)@\(m.provider.host)")
        if let services = m.services, !services.isEmpty {
            lines.append("Services (\(services.count)):")
            for (name, svc) in services.sorted(by: { $0.key < $1.key }) {
                let ports = svc.ports?.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ", ") ?? "(none)"
                lines.append("  \(name): ports=[\(ports)]")
            }
        }
        if let clients = m.clients, !clients.isEmpty {
            lines.append("Clients (\(clients.count)):")
            for client in clients {
                lines.append("  \(client.slug) [\(client.type.rawValue)] phase=\(client.phase.rawValue)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
