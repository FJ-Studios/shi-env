import Foundation
@testable import ShiEnv

// MARK: - MockSSHExecutor
//
// Test double for SSHExecutorProtocol. Records commands and returns canned responses.
// Shared across all Apply tests.

final class MockSSHExecutor: SSHExecutorProtocol, @unchecked Sendable {

    // Recorded calls: (host, user, command)
    private(set) var calls: [(host: String, user: String, command: String)] = []

    // Canned responses: command-prefix → output
    private var responses: [String: String] = [:]

    // If set, every call throws this error
    var forcedError: Error?

    // Write commands (anything that is not a probe/read)
    private(set) var writeCommands: [String] = []

    func stub(prefix: String, response: String) {
        responses[prefix] = response
    }

    func run(host: String, user: String, command: String) async throws -> String {
        calls.append((host: host, user: user, command: command))
        if let error = forcedError { throw error }
        // Track mutating write commands (exclude read-only redirects like 2>/dev/null in probe commands)
        let isMutating = command.contains("systemctl start")
            || command.contains("systemctl enable")
            || command.contains("apt-get install")
            || command.contains("mkdir -p")
            || (command.contains(" > ") && !command.contains("2>/dev/null"))
            || command.contains("mv -f")
            || command.contains("caddy reload")
        if isMutating {
            writeCommands.append(command)
        }
        for (prefix, response) in responses {
            if command.hasPrefix(prefix) || command.contains(prefix) {
                return response
            }
        }
        return ""
    }

    func run(host: String, user: String, command: String, timeout: TimeInterval) async throws -> String {
        try await run(host: host, user: user, command: command)
    }
}

// MARK: - MockSecretsResolver

final class MockSecretsResolver: SecretsResolverProtocol, @unchecked Sendable {
    var keyPath: String
    var secretValues: [String: String] = [:]
    var shouldFail: Bool = false

    init(keyPath: String = "/tmp/test-ssh-key") {
        self.keyPath = keyPath
    }

    func resolve(uri: String) async throws -> String {
        if shouldFail { throw MockError.resolverFailed }
        return secretValues[uri] ?? "test-secret-value"
    }

    func resolveSSHKeyPath(uri: String) async throws -> String {
        if shouldFail { throw MockError.resolverFailed }
        return keyPath
    }
}

// MARK: - MockConvergeRecordPersistor

actor MockConvergeRecordPersistor: ConvergeRecordPersistorProtocol {
    private(set) var savedRecords: [ConvergeRecord] = []
    private var storedRecords: [ConvergeRecord] = []

    func save(record: ConvergeRecord) async throws {
        savedRecords.append(record)
        storedRecords.append(record)
    }

    func load(host: String, limit: Int) async throws -> [ConvergeRecord] {
        storedRecords.filter { $0.host == host }.suffix(limit).map { $0 }
    }
}

// MARK: - MockNATSEmitter

actor MockNATSEmitter: NATSEventEmitterProtocol {
    private(set) var published: [(subject: String, payload: Data)] = []

    func publish(subject: String, payload: Data) async throws {
        published.append((subject: subject, payload: payload))
    }
}

// MARK: - MockKurmaClient

actor MockKurmaClient: KurmaClientProtocol {
    private(set) var registeredMonitors: [KurmaMonitor] = []
    private(set) var deregisteredSlugs: [String] = []
    var shouldFailRegistration: Bool = false

    func isRegistered(slug: String) async throws -> Bool {
        registeredMonitors.contains { $0.slug == slug }
    }

    func registerMonitor(_ monitor: KurmaMonitor) async throws {
        if shouldFailRegistration { throw KurmaError.registrationFailed(slug: monitor.slug, httpStatus: 500) }
        registeredMonitors.append(monitor)
    }

    func deregisterMonitor(slug: String) async throws {
        deregisteredSlugs.append(slug)
        registeredMonitors.removeAll { $0.slug == slug }
    }
}

// MARK: - MockError

enum MockError: Error, Equatable {
    case resolverFailed
    case brokerUnavailable
}
