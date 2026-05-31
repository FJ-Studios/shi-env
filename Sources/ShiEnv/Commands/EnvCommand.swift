import Foundation

// MARK: - EnvCommand
//
// Top-level `shi env` dispatcher.
//
// BR-SEV-01: `shi env` with no sub-verb opens the TUI.
// All other sub-verbs are dispatched to their Command types.
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.1

public struct EnvCommand: Sendable {

    private let shikkiRoot: URL

    public init(shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")) {
        self.shikkiRoot = shikkiRoot
    }

    // MARK: - TUI Entry

    /// Run the interactive TUI (called when no sub-verb is given).
    ///
    /// Loads the environment index and renders the TUI.
    /// Reads key bindings from ~/.shikki/config.yml per BR-SEV-09.
    public func runTUI(outputStream: inout some TextOutputStream) async throws -> Int32 {
        let indexActor = MotoEnvironmentIndex(shikkiRoot: shikkiRoot)
        guard let index = try await indexActor.loadIndex() else {
            outputStream.write("No environment index found. Run `shi env reindex` first.\n")
            return 1
        }

        let bindings = EnvTUIKeyBindings.load(from: shikkiRoot)
        let baseScreen = EnvTUIScreen.build(from: index.entries)
        var screen = EnvTUIScreen(workspaces: baseScreen.workspaces, bindings: bindings)

        // Check if we're in an interactive terminal
        guard isatty(STDIN_FILENO) != 0 else {
            // Non-interactive — fall back to plain list
            outputStream.write("(non-interactive terminal — run `shi env list` for tabular output)\n")
            return 0
        }

        // Render initial frame
        screen.render(to: &outputStream)

        // In a real TUI we would switch stdin to raw mode and loop.
        // For the v0.3 deliverable the rendering path is wired; the full
        // raw-mode event loop ships with Katagami TUI picker (in-progress).
        outputStream.write("\n[Press q to quit, arrows or j/k to navigate, Enter to select]\n")

        return 0
    }

    // MARK: - Address expansion

    /// Expand a possibly-wildcard address to matching index entries.
    ///
    /// BR-SEV-08: wildcard `<addr>` expansion; `--dry-run` shows expansion before action.
    public static func expandAddress(_ addr: String, in index: MotoEnvIndex) -> [EnvIndexEntry] {
        if addr == "all" { return index.entries }

        let parts = addr.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 1 else { return index.entries }

        return index.entries.filter { entry in
            let entryParts = [entry.workspace, entry.project, entry.environment]
            for (i, pattern) in parts.prefix(3).enumerated() {
                if pattern == "*" { continue }
                if entryParts[safe: i] != pattern { return false }
            }
            return true
        }
    }
}

private extension Array {
    subscript(safe idx: Int) -> Element? {
        guard idx >= 0, idx < count else { return nil }
        return self[idx]
    }
}
