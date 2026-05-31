import Foundation

// MARK: - EnvLintCommand
//
// Implements `shi env lint [<workspace>.<project>.<env>]`.
// Validates schema, secret refs, dep DAG, port collisions, agency slugs, kotoba.
//
// Exit code 0 = clean, 1 = errors found (warns only = still 0).
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md §3.6 + BR-SEIS-07

public struct EnvLintCommand: Sendable {

    public struct Options: Sendable {
        /// Promote warnings to errors.
        public var strict: Bool
        public var jsonOutput: Bool

        public init(strict: Bool = false, jsonOutput: Bool = false) {
            self.strict = strict
            self.jsonOutput = jsonOutput
        }
    }

    private let shikkiRoot: URL
    private let linter: Linter

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.shikkiRoot = shikkiRoot
        self.linter = Linter()
    }

    /// Lint a single manifest by dot-address.
    public func run(
        address: String,
        manifestData: Data,
        options: Options = Options(),
        outputStream: inout some TextOutputStream
    ) throws -> Int32 {
        let manifest = try EnvironmentManifest.decode(fromJSON: manifestData)
        let findings = linter.lint(manifest)
        return output(findings: findings, address: address, options: options, stream: &outputStream)
    }

    /// Lint a pre-loaded manifest.
    public func run(
        address: String,
        manifest: EnvironmentManifest,
        options: Options = Options(),
        outputStream: inout some TextOutputStream
    ) -> Int32 {
        let findings = linter.lint(manifest)
        return output(findings: findings, address: address, options: options, stream: &outputStream)
    }

    // MARK: Private

    private func output(
        findings: [LintFinding],
        address: String,
        options: Options,
        stream: inout some TextOutputStream
    ) -> Int32 {
        if options.jsonOutput {
            let json = findings.map { f -> [String: String] in
                var d: [String: String] = ["level": f.level.rawValue, "message": f.message]
                if let field = f.field { d["field"] = field }
                return d
            }
            if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                stream.write(str + "\n")
            }
        } else {
            if findings.isEmpty {
                stream.write("\(address): OK\n")
            } else {
                for f in findings {
                    stream.write("\(address): \(f.formattedMessage)\n")
                }
            }
        }

        let errorFindings = findings.filter { f in
            f.level == .error || (options.strict && f.level == .warn)
        }
        return errorFindings.isEmpty ? 0 : 1
    }
}
