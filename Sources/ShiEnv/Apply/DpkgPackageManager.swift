import Foundation

// MARK: - DpkgPackageManager
//
// Manages Debian packages on a remote host via SSH + apt.
// Operations: probe installed version, install/upgrade to a specific version.
//
// BR-SERA-03: all SSH via TimedSSHExecutor.
// Spec: features/shi-env-remote-apply-2026-05-31.md §3.1

/// Installed state of a single package.
public struct DpkgPackageState: Sendable, Equatable {
    /// The installed version, e.g. "0.22.7". Nil = not installed.
    public let installedVersion: String?
    /// e.g. "install ok installed", "deinstall ok config-files"
    public let status: String

    public init(installedVersion: String?, status: String = "install ok installed") {
        self.installedVersion = installedVersion
        self.status = status
    }

    public var isInstalled: Bool { installedVersion != nil }
}

public actor DpkgPackageManager {

    private let executor: any SSHExecutorProtocol

    public init(executor: any SSHExecutorProtocol) {
        self.executor = executor
    }

    // MARK: - Probe

    /// Query the installed version for a package on the remote host.
    public func probe(
        package: String,
        host: String,
        user: String
    ) async throws -> DpkgPackageState {
        let output = try await executor.run(
            host: host,
            user: user,
            command: "dpkg-query -W -f='${Version}\\t${Status}' \(package) 2>/dev/null || echo 'not-installed\\tnot-installed ok not-installed'"
        )
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\t")
        let version = parts.first.flatMap { v -> String? in
            let t = v.trimmingCharacters(in: .whitespaces)
            return (t.isEmpty || t == "not-installed") ? nil : t
        }
        let status = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "unknown"
        return DpkgPackageState(installedVersion: version, status: status)
    }

    // MARK: - Plan

    /// Return a ConvergeStep describing whether a package install/upgrade is needed.
    public func planStep(
        package: String,
        desiredVersion: String,
        currentState: DpkgPackageState
    ) -> ConvergeStep {
        if currentState.installedVersion == desiredVersion {
            return ConvergeStep(
                kind: .installPackage,
                status: .match,
                description: "dpkg \(package) \(desiredVersion)",
                detail: nil
            )
        }
        let currentVer = currentState.installedVersion ?? "not-installed"
        return ConvergeStep(
            kind: .installPackage,
            status: currentState.isInstalled ? .drift : .new,
            description: "dpkg \(package)",
            detail: "\(currentVer) → \(desiredVersion)"
        )
    }

    // MARK: - Execute

    /// Install or upgrade a package to the desired version.
    /// Uses `apt-get install <pkg>=<ver> -y --no-install-recommends`.
    public func executeStep(
        package: String,
        desiredVersion: String,
        host: String,
        user: String,
        dryRun: Bool
    ) async throws -> ConvergeStep {
        let state = try await probe(package: package, host: host, user: user)
        let planned = planStep(package: package, desiredVersion: desiredVersion, currentState: state)

        if planned.status == .match {
            return planned
        }

        if dryRun {
            return ConvergeStep(
                kind: .installPackage,
                status: .skipped,
                description: planned.description,
                detail: "(dry-run) would install \(package)=\(desiredVersion)"
            )
        }

        // Pin via apt-get (DEBIAN_FRONTEND=noninteractive for non-interactive CI-safe install)
        _ = try await executor.run(
            host: host,
            user: user,
            command: "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \(package)=\(desiredVersion) 2>&1",
            timeout: 120
        )

        return ConvergeStep(
            kind: .installPackage,
            status: .done,
            description: "dpkg \(package)",
            detail: "installed \(desiredVersion)"
        )
    }
}
