import Foundation

// MARK: - KurmaMonitorRegistrar
//
// Registers and deregisters Uptime-Kuma (kurma) monitors via the kurma admin
// HTTP API. Called as the final step in the apply flow — after the service is up.
//
// Per BR-SERA-06: reg/dereg is atomic with service up/down. On registration
// failure after service up: deregister attempt + log; service stays up
// (operational > observability).
//
// Per [[kurma-uptime-kuma-nuc-dev]]: kurma is the observability backbone.
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.1

/// Protocol allowing test injection without a live kurma instance.
public protocol KurmaClientProtocol: Sendable {
    func registerMonitor(_ monitor: KurmaMonitor) async throws
    func deregisterMonitor(slug: String) async throws
    func isRegistered(slug: String) async throws -> Bool
}

/// Shape of a kurma monitor to register.
public struct KurmaMonitor: Sendable, Equatable, Codable {
    public let slug: String
    /// Human-readable name, e.g. "pocketbase (obyw-prod)".
    public let name: String
    /// URL to probe (HTTP/HTTPS/TCP/etc.).
    public let url: String
    /// Probe type: "http", "tcp", "ping".
    public let type: String
    /// Interval in seconds.
    public let interval: Int
    /// Max retries before alerting.
    public let maxRetries: Int

    public init(
        slug: String,
        name: String,
        url: String,
        type: String = "http",
        interval: Int = 60,
        maxRetries: Int = 3
    ) {
        self.slug = slug
        self.name = name
        self.url = url
        self.type = type
        self.interval = interval
        self.maxRetries = maxRetries
    }
}

// MARK: - HTTPKurmaClient

/// Production kurma client using the Uptime Kuma admin API.
public actor HTTPKurmaClient: KurmaClientProtocol {

    private let adminEndpoint: URL
    /// Resolved API token (from shi-secrets broker at construction time).
    private let apiToken: String

    public init(adminEndpoint: URL, apiToken: String) {
        self.adminEndpoint = adminEndpoint
        self.apiToken = apiToken
    }

    public func isRegistered(slug: String) async throws -> Bool {
        let url = adminEndpoint.appendingPathComponent("api/v1/monitors")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        return json.contains { ($0["slug"] as? String) == slug }
    }

    public func registerMonitor(_ monitor: KurmaMonitor) async throws {
        let url = adminEndpoint.appendingPathComponent("api/v1/monitors")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(monitor)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw KurmaError.registrationFailed(slug: monitor.slug, httpStatus: code)
        }
    }

    public func deregisterMonitor(slug: String) async throws {
        let url = adminEndpoint.appendingPathComponent("api/v1/monitors/\(slug)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        // 404 is acceptable (monitor already gone)
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 404 && !(200...299).contains(httpResponse.statusCode) {
            throw KurmaError.deregistrationFailed(slug: slug, httpStatus: httpResponse.statusCode)
        }
    }
}

// MARK: - KurmaMonitorRegistrar

public actor KurmaMonitorRegistrar {

    private let client: any KurmaClientProtocol

    public init(client: any KurmaClientProtocol) {
        self.client = client
    }

    // MARK: - Plan

    public func planStep(
        slug: String,
        isRegistered: Bool
    ) -> ConvergeStep {
        ConvergeStep(
            kind: .kurmaRegister,
            status: isRegistered ? .match : .new,
            description: "kurma monitor \(slug)",
            detail: isRegistered ? nil : "register → \(slug)"
        )
    }

    // MARK: - Execute

    public func executeStep(
        monitor: KurmaMonitor,
        dryRun: Bool
    ) async throws -> ConvergeStep {
        let isRegistered = try await client.isRegistered(slug: monitor.slug)
        let planned = planStep(slug: monitor.slug, isRegistered: isRegistered)

        if planned.status == .match {
            return planned
        }

        if dryRun {
            return ConvergeStep(
                kind: .kurmaRegister,
                status: .skipped,
                description: planned.description,
                detail: "(dry-run) would register monitor \(monitor.slug)"
            )
        }

        do {
            try await client.registerMonitor(monitor)
        } catch {
            // BR-SERA-06: service stays up on kurma failure — log and return partial failure
            return ConvergeStep(
                kind: .kurmaRegister,
                status: .failed,
                description: "kurma monitor \(monitor.slug)",
                detail: "registration failed: \(error.localizedDescription) — service remains up"
            )
        }

        return ConvergeStep(
            kind: .kurmaRegister,
            status: .done,
            description: "kurma monitor \(monitor.slug)",
            detail: "registered"
        )
    }

    public func deregister(slug: String, dryRun: Bool) async throws -> ConvergeStep {
        if dryRun {
            return ConvergeStep(
                kind: .kurmaDeregister,
                status: .skipped,
                description: "kurma monitor \(slug)",
                detail: "(dry-run) would deregister"
            )
        }
        try await client.deregisterMonitor(slug: slug)
        return ConvergeStep(
            kind: .kurmaDeregister,
            status: .done,
            description: "kurma monitor \(slug)",
            detail: "deregistered"
        )
    }
}

// MARK: - KurmaError

public enum KurmaError: Error, LocalizedError, Sendable {
    case registrationFailed(slug: String, httpStatus: Int)
    case deregistrationFailed(slug: String, httpStatus: Int)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let slug, let code):
            return "kurma registration failed for '\(slug)' (HTTP \(code))."
        case .deregistrationFailed(let slug, let code):
            return "kurma deregistration failed for '\(slug)' (HTTP \(code))."
        }
    }
}
