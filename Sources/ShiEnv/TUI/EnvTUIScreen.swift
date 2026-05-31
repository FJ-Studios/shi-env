import Foundation

// MARK: - EnvTUIScreen
//
// Katagami-rendered interactive TUI for `shi env` (no args).
//
// BR-SEV-01: `shi env` no-args = TUI entry-point.
// BR-SEV-05: uses Katagami primitives — no parallel TUI lib.
// BR-SEV-09: key bindings from ~/.shikki/config.yml `tui.bindings.env`.
//
// NOTE: Katagami TUI rendering is in-progress per
// [[katagami-storybook-swiftqc-plugin-vision]]. This implementation
// provides the full navigation state machine + ASCII fallback rendering
// that will be backed by Katagami primitives when the plugin ships.
// The data model and navigation contract are stable; only the rendering
// layer changes on Katagami integration.
//
// TUI shape (spec §3.2):
//   ┌─ shi env (interactive) ─────────────────────────────────────────┐
//   │ Workspace:  ▶ obyw-one        fj-studio        cliff-tech       │
//   │ Project:    ▶ obyw-one        shikki           moto             │
//   │ Env:        ▶ prod  preprod   local                             │
//   │                                                                  │
//   │ Services in obyw-one.obyw-one.prod:                             │
//   │   ▶ pocketbase   ●  green   :8091   bridge ready                │
//   │     caddy        ●  green   :80,:443                            │
//   │                                                                  │
//   │ Actions: [Enter] open · [s] status · [l] logs · [r] restart     │
//   │          [b] bridge open · [a] apply · [q] quit                 │
//   └──────────────────────────────────────────────────────────────────┘
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.2

// MARK: - TUI Navigation State

/// The 4-level navigation hierarchy.
public enum TUINavigationLevel: Sendable, Equatable {
    case workspace
    case project
    case environment
    case service
}

/// The selection state of the TUI.
public struct TUISelection: Sendable, Equatable {
    public var level: TUINavigationLevel
    public var workspaceIdx: Int
    public var projectIdx: Int
    public var envIdx: Int
    public var serviceIdx: Int

    public init(
        level: TUINavigationLevel = .workspace,
        workspaceIdx: Int = 0,
        projectIdx: Int = 0,
        envIdx: Int = 0,
        serviceIdx: Int = 0
    ) {
        self.level = level
        self.workspaceIdx = workspaceIdx
        self.projectIdx = projectIdx
        self.envIdx = envIdx
        self.serviceIdx = serviceIdx
    }
}

// MARK: - Key Bindings

/// Configurable TUI key bindings (per BR-SEV-09, loaded from config.yml `tui.bindings.env`).
public struct EnvTUIKeyBindings: Sendable {
    public var quit: Character
    public var open: Character         // Enter / o
    public var status: Character
    public var logs: Character
    public var restart: Character
    public var bridgeOpen: Character
    public var apply: Character
    public var up: Character           // k
    public var down: Character         // j
    public var back: Character         // Escape / b
    public var enter: Character        // Enter / right-arrow action

    public static let `default` = EnvTUIKeyBindings(
        quit: "q",
        open: "o",
        status: "s",
        logs: "l",
        restart: "r",
        bridgeOpen: "b",
        apply: "a",
        up: "k",
        down: "j",
        back: Character(UnicodeScalar(27)),  // ESC
        enter: "\r"
    )

    public init(
        quit: Character, open: Character, status: Character, logs: Character,
        restart: Character, bridgeOpen: Character, apply: Character,
        up: Character, down: Character, back: Character, enter: Character
    ) {
        self.quit = quit
        self.open = open
        self.status = status
        self.logs = logs
        self.restart = restart
        self.bridgeOpen = bridgeOpen
        self.apply = apply
        self.up = up
        self.down = down
        self.back = back
        self.enter = enter
    }

    /// Load from ~/.shikki/config.yml `tui.bindings.env` block.
    /// Returns `.default` if config is absent (fail-safe).
    public static func load(from configDir: URL) -> EnvTUIKeyBindings {
        // Minimal TOML/YAML reader for the bindings block.
        // Full config parsing is in ShiKit; use defaults until integrated.
        let configURL = configDir.appendingPathComponent("config.yml")
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .default
        }
        var bindings = EnvTUIKeyBindings.default
        let lines = content.components(separatedBy: "\n")
        var inBindingsBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "tui:" { continue }
            if trimmed == "bindings:" { continue }
            if trimmed == "env:" { inBindingsBlock = true; continue }
            if inBindingsBlock {
                if trimmed.hasPrefix("-") || (trimmed.hasPrefix("[") && !trimmed.contains(":")) { break }
                let parts = trimmed.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let ch = parts[1].first else { continue }
                switch parts[0] {
                case "quit":        bindings.quit = ch
                case "open":        bindings.open = ch
                case "status":      bindings.status = ch
                case "logs":        bindings.logs = ch
                case "restart":     bindings.restart = ch
                case "bridge_open": bindings.bridgeOpen = ch
                case "apply":       bindings.apply = ch
                case "up":          bindings.up = ch
                case "down":        bindings.down = ch
                default: break
                }
            }
        }
        return bindings
    }
}

// MARK: - TUI Action

public enum TUIAction: Sendable {
    case quit
    case openSelected
    case statusSelected
    case logsSelected
    case restartSelected
    case bridgeOpenSelected
    case applySelected
    case navigateUp
    case navigateDown
    case navigateBack
    case navigateEnter
    case unknown
}

// MARK: - EnvTUIScreen

/// The interactive shi env TUI screen.
///
/// Manages navigation state and renders to a TextOutputStream.
/// Katagami rendering primitives will be wired in when the plugin ships;
/// today uses ASCII-art rendering that matches the spec §3.2 mockup.
public struct EnvTUIScreen: Sendable {

    // MARK: Data model

    public struct WorkspaceNode: Sendable {
        public let name: String
        public let projects: [ProjectNode]
        public init(name: String, projects: [ProjectNode]) {
            self.name = name
            self.projects = projects
        }
    }

    public struct ProjectNode: Sendable {
        public let name: String
        public let environments: [EnvNode]
        public init(name: String, environments: [EnvNode]) {
            self.name = name
            self.environments = environments
        }
    }

    public struct EnvNode: Sendable {
        public let name: String
        public let services: [ServiceNode]
        public init(name: String, services: [ServiceNode]) {
            self.name = name
            self.services = services
        }
    }

    public struct ServiceNode: Sendable {
        public let name: String
        public let status: String    // "green" | "red" | "unknown"
        public let ports: [Int]
        public let bridgeReady: Bool
        public init(name: String, status: String, ports: [Int], bridgeReady: Bool = false) {
            self.name = name
            self.status = status
            self.ports = ports
            self.bridgeReady = bridgeReady
        }
    }

    // MARK: Properties

    public let workspaces: [WorkspaceNode]
    public var selection: TUISelection
    public let bindings: EnvTUIKeyBindings

    public init(workspaces: [WorkspaceNode], bindings: EnvTUIKeyBindings = .default) {
        self.workspaces = workspaces
        self.selection = TUISelection()
        self.bindings = bindings
    }

    // MARK: - Rendering

    /// Render the full TUI frame to the output stream.
    ///
    /// This is the ASCII fallback. When Katagami primitives are available,
    /// this function calls `Katagami.render(EnvTUIComponent(...))` instead.
    public func render(to output: inout some TextOutputStream) {
        let width = 72
        let border = String(repeating: "─", count: width - 2)

        output.write("┌─ shi env (interactive) \(String(repeating: "─", count: width - 26))┐\n")

        // Workspace row
        let wsRow = buildSelectionRow(
            label: "Workspace:",
            items: workspaces.map(\.name),
            selectedIdx: selection.workspaceIdx,
            isActive: selection.level == .workspace
        )
        output.write("│ \(padTo(wsRow, width - 4)) │\n")

        // Project row
        let ws = workspaces[safe: selection.workspaceIdx]
        let projectRow = buildSelectionRow(
            label: "Project: ",
            items: ws?.projects.map(\.name) ?? [],
            selectedIdx: selection.projectIdx,
            isActive: selection.level == .project
        )
        output.write("│ \(padTo(projectRow, width - 4)) │\n")

        // Env row
        let proj = ws?.projects[safe: selection.projectIdx]
        let envRow = buildSelectionRow(
            label: "Env:     ",
            items: proj?.environments.map(\.name) ?? [],
            selectedIdx: selection.envIdx,
            isActive: selection.level == .environment
        )
        output.write("│ \(padTo(envRow, width - 4)) │\n")
        output.write("│ \(padTo("", width - 4)) │\n")

        // Services list
        let env = proj?.environments[safe: selection.envIdx]
        let wsName = ws?.name ?? "?"
        let projName = proj?.name ?? "?"
        let envName = env?.name ?? "?"
        output.write("│ \(padTo("Services in \(wsName).\(projName).\(envName):", width - 4)) │\n")

        let services = env?.services ?? []
        for (idx, svc) in services.enumerated() {
            let cursor = (selection.level == .service && idx == selection.serviceIdx) ? "▶ " : "  "
            let dot = svc.status == "green" ? "●" : (svc.status == "red" ? "○" : "·")
            let portStr = svc.ports.map { ":\($0)" }.joined(separator: ",")
            let bridge = svc.bridgeReady ? "  bridge ready" : ""
            let line = "\(cursor)\(padName(svc.name, 14)) \(dot)  \(padTo(svc.status, 7))  \(padTo(portStr, 12))\(bridge)"
            output.write("│   \(padTo(line, width - 6)) │\n")
        }
        if services.isEmpty {
            output.write("│   \(padTo("(no services)", width - 6)) │\n")
        }

        output.write("│ \(padTo("", width - 4)) │\n")

        // Actions row
        output.write("│ \(padTo("Actions: [Enter] open · [s] status · [l] logs · [r] restart", width - 4)) │\n")
        output.write("│ \(padTo("         [b] bridge open · [a] apply · [q] quit", width - 4)) │\n")
        output.write("└\(border)┘\n")
    }

    // MARK: - Input handling

    /// Process a single keypress. Returns a TUIAction and updated selection.
    public func handleKey(_ key: Character) -> (action: TUIAction, updated: EnvTUIScreen) {
        var updated = self

        if key == bindings.quit {
            return (.quit, updated)
        }
        if key == bindings.status { return (.statusSelected, updated) }
        if key == bindings.logs   { return (.logsSelected, updated) }
        if key == bindings.restart { return (.restartSelected, updated) }
        if key == bindings.bridgeOpen { return (.bridgeOpenSelected, updated) }
        if key == bindings.apply  { return (.applySelected, updated) }

        if key == bindings.up {
            updated.selection = updated.moveUp()
            return (.navigateUp, updated)
        }
        if key == bindings.down {
            updated.selection = updated.moveDown()
            return (.navigateDown, updated)
        }
        if key == bindings.back || key == Character(UnicodeScalar(27)) {
            updated.selection = updated.navigateBack()
            return (.navigateBack, updated)
        }
        if key == bindings.enter || key == "\r" || key == "\n" {
            let (action, sel) = updated.navigateEnter()
            updated.selection = sel
            return (action, updated)
        }

        return (.unknown, updated)
    }

    // MARK: - Navigation

    private func moveUp() -> TUISelection {
        var sel = selection
        switch sel.level {
        case .workspace:
            if sel.workspaceIdx > 0 { sel.workspaceIdx -= 1 }
        case .project:
            if sel.projectIdx > 0 { sel.projectIdx -= 1 }
        case .environment:
            if sel.envIdx > 0 { sel.envIdx -= 1 }
        case .service:
            if sel.serviceIdx > 0 { sel.serviceIdx -= 1 }
        }
        return sel
    }

    private func moveDown() -> TUISelection {
        var sel = selection
        let ws = workspaces[safe: sel.workspaceIdx]
        let proj = ws?.projects[safe: sel.projectIdx]
        let env = proj?.environments[safe: sel.envIdx]
        switch sel.level {
        case .workspace:
            if sel.workspaceIdx < workspaces.count - 1 { sel.workspaceIdx += 1 }
        case .project:
            if sel.projectIdx < (ws?.projects.count ?? 1) - 1 { sel.projectIdx += 1 }
        case .environment:
            if sel.envIdx < (proj?.environments.count ?? 1) - 1 { sel.envIdx += 1 }
        case .service:
            if sel.serviceIdx < (env?.services.count ?? 1) - 1 { sel.serviceIdx += 1 }
        }
        return sel
    }

    private func navigateBack() -> TUISelection {
        var sel = selection
        switch sel.level {
        case .workspace: break
        case .project:   sel.level = .workspace
        case .environment: sel.level = .project
        case .service:   sel.level = .environment
        }
        return sel
    }

    private func navigateEnter() -> (TUIAction, TUISelection) {
        var sel = selection
        switch sel.level {
        case .workspace:
            sel.level = .project
            sel.projectIdx = 0
            return (.navigateEnter, sel)
        case .project:
            sel.level = .environment
            sel.envIdx = 0
            return (.navigateEnter, sel)
        case .environment:
            sel.level = .service
            sel.serviceIdx = 0
            return (.navigateEnter, sel)
        case .service:
            return (.openSelected, sel)
        }
    }

    // MARK: - Render helpers

    private func buildSelectionRow(label: String, items: [String], selectedIdx: Int, isActive: Bool) -> String {
        var parts = [label + " "]
        for (idx, item) in items.enumerated() {
            let cursor = (isActive && idx == selectedIdx) ? "▶ " : "  "
            parts.append(cursor + item)
        }
        return parts.joined(separator: "  ")
    }

    private func padTo(_ s: String, _ width: Int) -> String {
        let visible = s.count
        if visible >= width { return String(s.prefix(width)) }
        return s + String(repeating: " ", count: width - visible)
    }

    private func padName(_ s: String, _ width: Int) -> String {
        padTo(s, width)
    }
}

// MARK: - Collection helpers

private extension Array {
    subscript(safe idx: Int) -> Element? {
        guard idx >= 0, idx < count else { return nil }
        return self[idx]
    }
}

// MARK: - EnvTUIScreen + Factory

extension EnvTUIScreen {

    /// Build a TUIScreen from an env index.
    public static func build(
        from entries: [EnvIndexEntry],
        statuses: [String: [ServiceStatus]] = [:]
    ) -> EnvTUIScreen {
        // Group by workspace → project → env
        var wsMap: [String: [String: [String: [ServiceNode]]]] = [:]
        for entry in entries {
            var projMap = wsMap[entry.workspace] ?? [:]
            var envMap = projMap[entry.project] ?? [:]
            let services = (statuses[entry.dotAddress] ?? []).map { svc in
                ServiceNode(name: svc.name, status: svc.status, ports: [], bridgeReady: false)
            }
            envMap[entry.environment] = services
            projMap[entry.project] = envMap
            wsMap[entry.workspace] = projMap
        }

        let workspaceNodes = wsMap.sorted(by: { $0.key < $1.key }).map { wsName, projMap in
            WorkspaceNode(
                name: wsName,
                projects: projMap.sorted(by: { $0.key < $1.key }).map { projName, envMap in
                    ProjectNode(
                        name: projName,
                        environments: envMap.sorted(by: { $0.key < $1.key }).map { envName, services in
                            EnvNode(name: envName, services: services)
                        }
                    )
                }
            )
        }
        return EnvTUIScreen(workspaces: workspaceNodes)
    }
}
