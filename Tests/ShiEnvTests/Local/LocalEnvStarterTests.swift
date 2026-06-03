import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SELP-02 + TP-SELP-03: LocalEnvStarter start/stop + idempotency

@Suite("LocalEnvStarter — TP-SELP-02 + TP-SELP-03")
struct LocalEnvStarterTests {

    // MARK: - Mock backend (no I/O)

    final class MockBackend: BackendAdapter, @unchecked Sendable {
        var startedServices: [String] = []
        var stoppedServices: [String] = []

        func start(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
            if !dryRun { startedServices.append(service) }
            return BackendResult(host: "test", serviceName: service, action: .start, success: true,
                                 output: dryRun ? "[dry-run] would start \(service)" : "started \(service)")
        }

        func stop(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
            if !dryRun { stoppedServices.append(service) }
            return BackendResult(host: "test", serviceName: service, action: .stop, success: true,
                                 output: "stopped \(service)")
        }

        func restart(service: String, serviceEntry: ServiceEntry, dryRun: Bool) async throws -> BackendResult {
            BackendResult(host: "test", serviceName: service, action: .restart, success: true, output: "")
        }

        func status(service: String, serviceEntry: ServiceEntry) async throws -> ServiceStatus {
            ServiceStatus(name: service, status: "green")
        }

        func logs(service: String, serviceEntry: ServiceEntry, follow: Bool) async throws -> String { "" }

        func plan(service: String, serviceEntry: ServiceEntry, action: BackendAction) -> PlannedAction {
            PlannedAction(host: "test", serviceName: service, action: action, description: "mock")
        }
    }

    private func buildManifest(services: [String: ServiceEntry]) -> EnvironmentManifest {
        EnvironmentManifest(
            version: 1,
            addressing: EnvAddressing(workspace: "ws", project: "proj", environment: "local"),
            provider: ProviderBlock(kind: .local, host: "127.0.0.1"),
            services: services
        )
    }

    @Test("TP-SELP-02: start invokes backend for each service; no remote calls in dry-run")
    func testStartCallsBackendPerService() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-starter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let backend = MockBackend()
        let starter = LocalEnvStarter(backend: backend, runDir: tmp)
        let manifest = buildManifest(services: [
            "pocketbase": ServiceEntry(ports: ["http": 8091]),
            "caddy": ServiceEntry(ports: ["http": 8080, "https": 8443])
        ])

        var out = ""
        let opts = LocalEnvStarter.Options(dryRun: true, skipTrustCheck: true)
        let results = try await starter.start(manifest: manifest, options: opts, outputStream: &out)

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.success })
        // dry-run: startCallCount on real backend not incremented
        #expect(backend.startedServices.isEmpty)
        #expect(out.contains("[dry-run]"))
    }

    @Test("TP-SELP-02b: start skips services already marked running (idempotency, BR-SELP-07)")
    func testIdempotencySkipsAlreadyRunning() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-starter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Pre-create running marker for "pocketbase"
        let marker = tmp.appendingPathComponent("pocketbase.running")
        try "2026-06-02T00:00:00Z".write(to: marker, atomically: true, encoding: .utf8)

        let backend = MockBackend()
        let starter = LocalEnvStarter(backend: backend, runDir: tmp)
        let manifest = buildManifest(services: [
            "pocketbase": ServiceEntry(ports: ["http": 8091])
        ])

        var out = ""
        let opts = LocalEnvStarter.Options(skipTrustCheck: true)
        let results = try await starter.start(manifest: manifest, options: opts, outputStream: &out)

        #expect(results.count == 1)
        #expect(results[0].skipped == true)
        #expect(backend.startedServices.isEmpty)
    }

    @Test("TP-SELP-03: stop halts all started services and removes markers")
    func testStopRemovesMarkersAndCallsBackend() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let markerURL = tmp.appendingPathComponent("pocketbase.running")
        try "ts".write(to: markerURL, atomically: true, encoding: .utf8)

        let backend = MockBackend()
        let starter = LocalEnvStarter(backend: backend, runDir: tmp)
        let manifest = buildManifest(services: [
            "pocketbase": ServiceEntry(ports: ["http": 8091])
        ])

        var out = ""
        let results = try await starter.stop(manifest: manifest, outputStream: &out)

        #expect(results.count == 1)
        #expect(results[0].success)
        #expect(backend.stoppedServices == ["pocketbase"])
        // Marker must be removed
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("TP-SELP-03b: stop with no services declared emits nothing and exits cleanly")
    func testStopNoServices() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shi-env-stop-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let backend = MockBackend()
        let starter = LocalEnvStarter(backend: backend, runDir: tmp)
        let manifest = buildManifest(services: [:])

        var out = ""
        let results = try await starter.stop(manifest: manifest, outputStream: &out)
        #expect(results.isEmpty)
    }
}
