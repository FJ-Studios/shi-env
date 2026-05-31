import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SBU-07: PublicAdminUrlInDocsCheck green on clean fixture
// MARK: - TP-SBU-08: PublicAdminUrlInDocsCheck CRIT on broken runbook
// MARK: - TP-SBU-09: --fix mode rewrites pattern + leaves warning marker

@Suite("PublicAdminUrlInDocsCheck — TP-SBU-07/08/09")
struct PublicAdminUrlInDocsCheckTests {

    /// Path to the test fixture directory (relative to this test target's bundle).
    func fixtureRoot(clean: Bool) -> URL {
        // Both fixtures live under Tests/ShiEnvTests/Bridge/Fixtures/
        // We locate them via Bundle.module — they are copied as resource via Package.swift.
        let base = Bundle.module.url(
            forResource: "BridgeFixtures",
            withExtension: nil,
            subdirectory: "Bridge"
        ) ?? Bundle.module.resourceURL!
            .appendingPathComponent("Bridge/Fixtures")
        return base
    }

    @Test("TP-SBU-07: clean runbook produces zero findings")
    func testCleanFixtureGreen() async throws {
        // Use a temp dir with only the clean runbook
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shi-env-check-clean-\(UUID().uuidString)")
        let docsDir = tmp.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cleanContent = """
        # PocketBase Admin Access

        Use `shi bridge open back` to open the PocketBase admin UI.

        The admin interface at /_/ is blocked publicly — it must be accessed via tunnel.
        """
        try cleanContent.write(
            to: docsDir.appendingPathComponent("clean-runbook.md"),
            atomically: true, encoding: .utf8
        )

        let check = PublicAdminUrlInDocsCheck(scanRoot: tmp)
        let findings = try await check.runCheck()
        #expect(findings.isEmpty, "Expected no findings on clean runbook, got: \(findings)")
    }

    @Test("TP-SBU-08: broken runbook emits CRIT finding with file+line")
    func testBrokenFixtureEmitsCrit() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shi-env-check-broken-\(UUID().uuidString)")
        let runbooksDir = tmp.appendingPathComponent("runbooks")
        try FileManager.default.createDirectory(at: runbooksDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let brokenContent = """
        # PocketBase Admin — BROKEN RUNBOOK

        Open the admin UI at: https://back.obyw.one/_/

        Also: https://vw.obyw.one/_/ for vaultwarden admin
        """
        try brokenContent.write(
            to: runbooksDir.appendingPathComponent("broken-runbook.md"),
            atomically: true, encoding: .utf8
        )

        let check = PublicAdminUrlInDocsCheck(scanRoot: tmp)
        let findings = try await check.runCheck()
        #expect(!findings.isEmpty, "Expected at least one CRIT finding")
        #expect(findings.allSatisfy { $0.severity == .crit })
        #expect(findings.first?.file?.contains("broken-runbook.md") == true)
        #expect(findings.first?.line != nil)
    }

    @Test("TP-SBU-07b: whitelisted line with <!-- pb-admin-bypass: ok --> suppressed")
    func testWhitelistedLineNotFlagged() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shi-env-check-whitelist-\(UUID().uuidString)")
        let docsDir = tmp.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let whitelisted = """
        # Why back.obyw.one/_/ Is Blocked

        The back.obyw.one/_/ path is blocked. <!-- pb-admin-bypass: ok -->
        """
        try whitelisted.write(
            to: docsDir.appendingPathComponent("whitelist.md"),
            atomically: true, encoding: .utf8
        )

        let check = PublicAdminUrlInDocsCheck(scanRoot: tmp)
        let findings = try await check.runCheck()
        #expect(findings.isEmpty, "Whitelisted line should produce no findings")
    }

    @Test("TP-SBU-09: fix() rewrites match and appends warning marker")
    func testFixModeRewritesPattern() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shi-env-check-fix-\(UUID().uuidString)")
        let docsDir = tmp.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let violationContent = "See https://back.obyw.one/_/ for admin."
        let mdFile = docsDir.appendingPathComponent("violation.md")
        try violationContent.write(to: mdFile, atomically: true, encoding: .utf8)

        let check = PublicAdminUrlInDocsCheck(scanRoot: tmp)
        let fixedCount = try check.fix()
        #expect(fixedCount > 0)

        let after = try String(contentsOf: mdFile, encoding: .utf8)
        #expect(after.contains("pb-admin-bypass: fixed"))
        #expect(after.contains("shi bridge open"))
    }
}
