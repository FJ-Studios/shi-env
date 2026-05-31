import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEV-05: shi env status — per-service color + JSON output valid

@Suite("EnvStatusCommand — TP-SEV-05")
struct EnvStatusCommandTests {

    /// A test backend that returns a fixed status.
    struct MockBackend: BackendAdapter {
        let statusColor: String

        func start(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
            BackendResult(host: "test", serviceName: service, action: .start, success: true, output: "")
        }
        func stop(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
            BackendResult(host: "test", serviceName: service, action: .stop, success: true, output: "")
        }
        func restart(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
            BackendResult(host: "test", serviceName: service, action: .restart, success: true, output: "")
        }
        func status(service: String, serviceEntry: ServiceEntry) async throws -> ServiceStatus {
            ServiceStatus(name: service, status: statusColor, probeLatencyMs: 12.0)
        }
        func logs(service: String, serviceEntry: ServiceEntry, follow: Bool) async throws -> String { "" }
        func plan(service: String, serviceEntry: ServiceEntry, action: BackendAction) -> PlannedAction {
            PlannedAction(host: "test", serviceName: service, action: action, description: "mock plan")
        }
    }

    private func buildTmpWithIndex() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-status-\(UUID().uuidString)")
        let projectDir = tmp.appendingPathComponent("workspaces/ws/projects/proj")
        let envDir = projectDir.appendingPathComponent(".shikki/env")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)

        let motoContent = """
        [environment.prod]
        path = ".shikki/env/prod.json"
        freshness = "event-tracked"
        """
        try motoContent.write(to: projectDir.appendingPathComponent(".moto"), atomically: true, encoding: .utf8)

        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "prod"),
            provider: ProviderBlock(kind: .local, host: "127.0.0.1"),
            services: [
                "web": ServiceEntry(ports: ["http": 3000],
                                    observability: ObservabilityEntry(kurma_slug: "web-prod", probes: ["/health"])),
                "api": ServiceEntry(ports: ["http": 4000],
                                    observability: ObservabilityEntry(kurma_slug: "api-prod", probes: ["/api/health"])),
            ]
        )
        let data = try manifest.encodeToJSON()
        try data.write(to: envDir.appendingPathComponent("prod.json"))

        let indexActor = MotoEnvironmentIndex(shikkiRoot: tmp)
        _ = try await indexActor.reindex(workspacesRoot: tmp.appendingPathComponent("workspaces"))
        return tmp
    }

    @Test("TP-SEV-05a: status with mock backend returns exit 0")
    func testStatusExitsZero() async throws {
        let tmp = try await buildTmpWithIndex()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cmd = EnvStatusCommand(shikkiRoot: tmp)
        var output = ""
        let exitCode = try await cmd.run(
            address: "ws.proj.prod",
            options: .init(),
            outputStream: &output,
            backendOverride: MockBackend(statusColor: "green")
        )
        #expect(exitCode == 0)
        #expect(output.contains("ws.proj.prod"))
        #expect(output.contains("green"))
    }

    @Test("TP-SEV-05b: --json output is valid JSON with required shape")
    func testStatusJSONOutputValid() async throws {
        let tmp = try await buildTmpWithIndex()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cmd = EnvStatusCommand(shikkiRoot: tmp)
        var output = ""
        let exitCode = try await cmd.run(
            address: "ws.proj.prod",
            options: .init(jsonOutput: true),
            outputStream: &output,
            backendOverride: MockBackend(statusColor: "green")
        )
        #expect(exitCode == 0)

        // Validate JSON
        let data = try #require(output.data(using: .utf8))
        let parsed = try JSONDecoder().decode([EnvStatusCommand.EnvStatusResult].self, from: data)
        #expect(parsed.count == 1)
        #expect(parsed[0].env == "prod")
        #expect(parsed[0].services.count == 2)
        // All services should have a status field
        for svc in parsed[0].services {
            #expect(!svc.status.isEmpty)
        }
    }

    @Test("TP-SEV-05c: status with no index returns exit 1")
    func testStatusNoIndexReturnsError() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-status-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: empty) }

        let cmd = EnvStatusCommand(shikkiRoot: empty)
        var output = ""
        let exitCode = try await cmd.run(options: .init(), outputStream: &output)
        #expect(exitCode == 1)
    }
}
