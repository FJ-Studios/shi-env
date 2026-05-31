import Testing
import Foundation
@testable import ShiEnv

// MARK: - TP-SEV-01: TUI smoke test — init + navigate + close

@Suite("EnvTUIScreen — TP-SEV-01 / TP-SEV-09")
struct EnvTUIScreenTests {

    private func makeSampleScreen() -> EnvTUIScreen {
        let workspaces = [
            EnvTUIScreen.WorkspaceNode(name: "ws-a", projects: [
                EnvTUIScreen.ProjectNode(name: "proj-a", environments: [
                    EnvTUIScreen.EnvNode(name: "prod", services: [
                        EnvTUIScreen.ServiceNode(name: "pocketbase", status: "green", ports: [8091], bridgeReady: true),
                        EnvTUIScreen.ServiceNode(name: "caddy", status: "green", ports: [80, 443]),
                    ]),
                    EnvTUIScreen.EnvNode(name: "local", services: [
                        EnvTUIScreen.ServiceNode(name: "pocketbase", status: "green", ports: [8091]),
                    ]),
                ]),
            ]),
            EnvTUIScreen.WorkspaceNode(name: "ws-b", projects: [
                EnvTUIScreen.ProjectNode(name: "proj-b", environments: [
                    EnvTUIScreen.EnvNode(name: "prod", services: []),
                ]),
            ]),
        ]
        return EnvTUIScreen(workspaces: workspaces)
    }

    @Test("TP-SEV-01a: TUI initialises at workspace level")
    func testTUIInitialisesAtWorkspaceLevel() {
        let screen = makeSampleScreen()
        #expect(screen.selection.level == .workspace)
        #expect(screen.selection.workspaceIdx == 0)
    }

    @Test("TP-SEV-01b: TUI renders without crash — output is non-empty")
    func testTUIRendersWithoutCrash() {
        let screen = makeSampleScreen()
        var output = ""
        screen.render(to: &output)
        #expect(!output.isEmpty)
        #expect(output.contains("shi env"))
        #expect(output.contains("ws-a"))
    }

    @Test("TP-SEV-01c: quit key returns .quit action")
    func testQuitKeyReturnsQuit() {
        let screen = makeSampleScreen()
        let (action, _) = screen.handleKey("q")
        #expect(action == .quit)
    }

    @Test("TP-SEV-09a: navigate workspace → project on Enter")
    func testEnterNavigatesToProject() {
        let screen = makeSampleScreen()
        let (action, updated) = screen.handleKey("\r")
        #expect(action == .navigateEnter)
        #expect(updated.selection.level == .project)
    }

    @Test("TP-SEV-09b: navigate project → env on Enter")
    func testEnterNavigatesToEnv() {
        var screen = makeSampleScreen()
        // Navigate into workspace first
        let (_, ws) = screen.handleKey("\r")
        screen = ws
        // Then into project
        let (action, updated) = screen.handleKey("\r")
        #expect(action == .navigateEnter)
        #expect(updated.selection.level == .environment)
    }

    @Test("TP-SEV-09c: navigate env → service on Enter")
    func testEnterNavigatesToService() {
        var screen = makeSampleScreen()
        for _ in 0..<3 {
            let (_, next) = screen.handleKey("\r")
            screen = next
        }
        #expect(screen.selection.level == .service)
    }

    @Test("TP-SEV-09d: back key navigates from service → env → project → workspace")
    func testBackNavigatesUp() {
        var screen = makeSampleScreen()
        // Navigate down to service
        for _ in 0..<3 {
            let (_, next) = screen.handleKey("\r")
            screen = next
        }
        #expect(screen.selection.level == .service)

        // Back from service → env
        let (_, fromSvc) = screen.handleKey(Character(UnicodeScalar(27)))
        #expect(fromSvc.selection.level == .environment)

        // Back from env → project
        let (_, fromEnv) = fromSvc.handleKey(Character(UnicodeScalar(27)))
        #expect(fromEnv.selection.level == .project)

        // Back from project → workspace
        let (_, fromProj) = fromEnv.handleKey(Character(UnicodeScalar(27)))
        #expect(fromProj.selection.level == .workspace)

        // Back at workspace — stays at workspace
        let (_, atWs) = fromProj.handleKey(Character(UnicodeScalar(27)))
        #expect(atWs.selection.level == .workspace)
    }

    @Test("TP-SEV-09e: down/up navigation changes index")
    func testUpDownChangesIndex() {
        let screen = makeSampleScreen()

        let (_, afterDown) = screen.handleKey("j")
        #expect(afterDown.selection.workspaceIdx == 1)

        let (_, afterUp) = afterDown.handleKey("k")
        #expect(afterUp.selection.workspaceIdx == 0)
    }

    @Test("TP-SEV-01d: TUI built from index entries — smoke")
    func testTUIBuiltFromIndexEntries() {
        let entries = [
            EnvIndexEntry(workspace: "ws-one", project: "proj-one", environment: "prod",
                          providerKind: "ovh-vps", host: "10.0.0.1", serviceCount: 2,
                          manifestPath: ".shikki/env/prod.json"),
            EnvIndexEntry(workspace: "ws-one", project: "proj-one", environment: "local",
                          providerKind: "local", host: "127.0.0.1", serviceCount: 1,
                          manifestPath: ".shikki/env/local.json"),
        ]
        let screen = EnvTUIScreen.build(from: entries)
        #expect(screen.workspaces.count == 1)
        #expect(screen.workspaces[0].projects.count == 1)
        #expect(screen.workspaces[0].projects[0].environments.count == 2)
    }
}
