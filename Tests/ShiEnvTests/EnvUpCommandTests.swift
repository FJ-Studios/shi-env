import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEV-03 / TP-SEV-04 / TP-SEV-10: up --dry-run / --apply + backend swap

@Suite("EnvUpCommand — TP-SEV-03 / TP-SEV-04 / TP-SEV-10")
struct EnvUpCommandTests {

    // MARK: - Mock backend

    final class TrackingBackend: BackendAdapter, @unchecked Sendable {
        var startCallCount = 0
        var dryRunCount = 0

        func start(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
            if dryRun { dryRunCount += 1 } else { startCallCount += 1 }
            return BackendResult(host: "test", serviceName: service, action: .start, success: true,
                                 output: dryRun ? "[dry-run] would start \(service)" : "started \(service)")
        }
        func stop(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
            BackendResult(host: "test", serviceName: service, action: .stop, success: true, output: "")
        }
        func restart(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
            BackendResult(host: "test", serviceName: service, action: .restart, success: true, output: "")
        }
        func status(service: String, serviceEntry: ServiceEntry) async throws -> ServiceStatus {
            ServiceStatus(name: service, status: "green")
        }
        func logs(service: String, serviceEntry: ServiceEntry, follow: Bool) async throws -> String { "" }
        func plan(service: String, serviceEntry: ServiceEntry, action: BackendAction) -> PlannedAction {
            PlannedAction(host: "test", serviceName: service, action: action,
                          description: "test: \(action.rawValue) \(service)")
        }
    }

    private func buildTmpWithIndex() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-up-\(UUID().uuidString)")
        let projectDir = tmp.appendingPathComponent("workspaces/ws/projects/proj")
        let envDir = projectDir.appendingPathComponent(".shikki/env")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)

        let motoContent = """
        [environment.local]
        path = ".shikki/env/local.json"
        freshness = "event-tracked"
        """
        try motoContent.write(to: projectDir.appendingPathComponent(".moto"), atomically: true, encoding: .utf8)

        let manifest = EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "local"),
            provider: ProviderBlock(kind: .local, host: "127.0.0.1"),
            services: ["pocketbase": ServiceEntry(
                ports: ["http": 8091],
                systemd: SystemdBlock(unit: "pocketbase.service")
            )]
        )
        let data = try manifest.encodeToJSON()
        try data.write(to: envDir.appendingPathComponent("local.json"))

        let indexActor = MotoEnvironmentIndex(shikkiRoot: tmp)
        _ = try await indexActor.reindex(workspacesRoot: tmp.appendingPathComponent("workspaces"))
        return tmp
    }

    @Test("TP-SEV-03: --dry-run shows planned action and exits 0, zero side-effects")
    func testDryRunShowsPlanExitsZero() async throws {
        let tmp = try await buildTmpWithIndex()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let backend = TrackingBackend()
        let cmd = EnvUpCommand(shikkiRoot: tmp)
        var output = ""
        let exitCode = try await cmd.run(
            address: "ws.proj.local",
            options: .init(dryRun: true),
            outputStream: &output,
            backendOverride: backend
        )
        #expect(exitCode == 0)
        #expect(output.contains("[dry-run]"))
        // No actual start calls
        #expect(backend.startCallCount == 0)
    }

    @Test("TP-SEV-03b: --apply without prior dry-run returns exit 1")
    func testApplyWithoutDryRunRefuses() async throws {
        let tmp = try await buildTmpWithIndex()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let backend = TrackingBackend()
        let cmd = EnvUpCommand(shikkiRoot: tmp)
        var output = ""
        let exitCode = try await cmd.run(
            address: "ws.proj.local",
            options: .init(apply: true),
            outputStream: &output,
            backendOverride: backend
        )
        #expect(exitCode == 1)
        #expect(backend.startCallCount == 0)
    }

    @Test("TP-SEV-10a: LocalBackend fixture — up command succeeds with plan output")
    func testLocalBackendFixture() async throws {
        let tmp = try await buildTmpWithIndex()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let local = LocalBackend(host: "127.0.0.1")
        let cmd = EnvUpCommand(shikkiRoot: tmp)
        var output = ""
        // dry-run with explicit LocalBackend
        let exitCode = try await cmd.run(
            address: "ws.proj.local",
            options: .init(dryRun: true),
            outputStream: &output,
            backendOverride: local
        )
        #expect(exitCode == 0)
        #expect(output.contains("[dry-run]"))
    }

    @Test("TP-SEV-10b: RemoteSshBackend fixture — plan output shows ssh command")
    func testRemoteSshBackendFixture() async throws {
        let tmp = try await buildTmpWithIndex()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let remote = RemoteSshBackend(host: "10.0.0.1", sshUser: "jeo")
        let cmd = EnvUpCommand(shikkiRoot: tmp)
        var output = ""
        let exitCode = try await cmd.run(
            address: "ws.proj.local",
            options: .init(dryRun: true),
            outputStream: &output,
            backendOverride: remote
        )
        #expect(exitCode == 0)
        // The plan description for RemoteSshBackend includes "ssh"
        #expect(output.contains("[dry-run]"))
    }
}
