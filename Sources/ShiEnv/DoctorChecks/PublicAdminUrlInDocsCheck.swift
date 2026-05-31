import Foundation
import ShikkiPluginAPI

// MARK: - PublicAdminUrlInDocsCheck
//
// Greps docs/**/*.md, runbooks/**/*.md, and *README*.md for patterns
// that reference a publicly-blocked admin URL (*.obyw.one/_/).
//
// Emits CRIT for each match. Whitelisted by <!-- pb-admin-bypass: ok --> comment.
//
// Spec: features/shi-bridge-unification-2026-05-31.md §3.5 + BR-SBU-08 + BR-SBU-09
// BR-SBU-08: grep docs for *.obyw.one/_/ patterns; CRIT on hit
// BR-SBU-09: --fix mode rewrites to `shi bridge open <site>` + warning marker
// BR-SBU-12: lives in shi-env plugin, registered via PluginDoctorRegistrar

/// Patterns that indicate a publicly-blocked admin URL being used directly.
private let blockedURLPatterns: [String] = [
    // Specific known blocked subdomains
    #"https?://(back|api|admin|status|s3|vw|umami)\.obyw\.one/_"#,
    // Generic *.obyw.one/_/ pattern
    #"[a-z][a-z0-9.-]+\.obyw\.one/_/"#,
]

private let whitelistMarker = "pb-admin-bypass: ok"

/// The suggested replacement text emitted by --fix mode.
private let fixSuggestion = "<!-- pb-admin-bypass: fixed --> Use: `shi bridge open <site>` instead"

public struct PublicAdminUrlInDocsCheck: PluginDoctorRegistrar, Sendable {

    public static let checkName = "public-admin-url-in-docs"
    public static let severity: DoctorSeverity = .crit

    // Scan root (defaults to CWD; override for tests).
    public let scanRoot: URL

    public init(scanRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.scanRoot = scanRoot
    }

    public static func run() async throws -> [DoctorFinding] {
        return try await PublicAdminUrlInDocsCheck().runCheck()
    }

    /// Non-static entry point so tests can inject scanRoot.
    public func runCheck() async throws -> [DoctorFinding] {
        let files = findMarkdownFiles(under: scanRoot)
        var findings: [DoctorFinding] = []
        for url in files {
            findings += try checkFile(url)
        }
        return findings
    }

    /// Apply --fix: rewrite matches in-place and return what was changed.
    public func fix() throws -> Int {
        let files = findMarkdownFiles(under: scanRoot)
        var fixCount = 0
        for url in files {
            if let changed = try fixFile(url) {
                try changed.write(to: url, atomically: true, encoding: .utf8)
                fixCount += 1
            }
        }
        return fixCount
    }

    // MARK: - Private

    private func relativePath(_ url: URL, to root: URL) -> String {
        // Resolve symlinks (e.g. /var/folders → /private/var/folders on macOS).
        let rootPath = root.resolvingSymlinksInPath().path
        let filePath = url.resolvingSymlinksInPath().path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        // Fallback: return last path component
        return url.lastPathComponent
    }

    private func findMarkdownFiles(under root: URL) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let relPath = relativePath(url, to: root)
            if isDocPath(relPath) {
                results.append(url)
            }
        }
        return results
    }

    /// Returns true if the relative path matches docs/**, runbooks/**, or *README*.md
    private func isDocPath(_ relPath: String) -> Bool {
        let lower = relPath.lowercased()
        return lower.hasPrefix("docs/")
            || lower.hasPrefix("runbooks/")
            || lower.contains("readme")
    }

    private func checkFile(_ url: URL) throws -> [DoctorFinding] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let relPath = relativePath(url, to: scanRoot)

        // File-level bypass: if the file contains the whitelist marker anywhere,
        // suppress all findings. This is the common case for explanatory docs
        // whose entire purpose is to describe the blocked path.
        if content.contains(whitelistMarker) { return [] }

        var findings: [DoctorFinding] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (idx, line) in lines.enumerated() {
            for pattern in blockedURLPatterns {
                if lineMatches(line: line, pattern: pattern) {
                    findings.append(DoctorFinding(
                        file: relPath,
                        line: idx + 1,
                        message: "Public admin URL in docs: '\(line.trimmingCharacters(in: .whitespaces))'. "
                            + "Use `shi bridge open <site>` instead, or add `<!-- \(whitelistMarker) -->` to suppress.",
                        severity: .crit
                    ))
                    break // one finding per line
                }
            }
        }
        return findings
    }

    private func fixFile(_ url: URL) throws -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // File-level bypass: don't rewrite whitelisted files
        if content.contains(whitelistMarker) { return nil }
        var changed = false
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var newLines = lines
        for (idx, line) in lines.enumerated() {
            for pattern in blockedURLPatterns {
                if lineMatches(line: line, pattern: pattern) {
                    // Append fix suggestion as a trailing comment on the same line
                    newLines[idx] = line + "  <!-- \(fixSuggestion) -->"
                    changed = true
                    break
                }
            }
        }
        return changed ? newLines.joined(separator: "\n") : nil
    }

    private func lineMatches(line: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }
        let range = NSRange(line.startIndex..., in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }
}
