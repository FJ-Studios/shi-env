import Foundation

// MARK: - BridgeRegistry
//
// Tracks open bridge handles via atomic-rename writes to
// ~/.shikki/run/bridges/<pid>.json.
//
// Spec: features/shi-bridge-unification-2026-05-31.md §3.2 + files table
// BR-SBU-10: registry used to enumerate handles for atexit cleanup

/// Persists and queries open bridge handles on disk.
///
/// Each live tunnel is recorded as a JSON file at:
///   `~/.shikki/run/bridges/<pid>.json`
///
/// Files are written via atomic-rename: write to `.tmp` then `rename()`.
/// Stale entries (where the pid no longer exists) are silently pruned on read.
public actor BridgeRegistry {

    private let bridgesDir: URL

    public init(
        shikkiRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shikki")
    ) {
        self.bridgesDir = shikkiRoot.appendingPathComponent("run/bridges")
    }

    // MARK: - Write

    /// Record a newly-opened handle.
    public func register(_ handle: BridgeHandle) async {
        try? FileManager.default.createDirectory(at: bridgesDir, withIntermediateDirectories: true)
        let dest = bridgesDir.appendingPathComponent("\(handle.pid).json")
        let tmp  = bridgesDir.appendingPathComponent("\(handle.pid).json.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(handle) else { return }
        try? data.write(to: tmp)
        try? FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Remove the handle file for a given pid.
    public func deregister(pid: pid_t) async {
        let dest = bridgesDir.appendingPathComponent("\(pid).json")
        try? FileManager.default.removeItem(at: dest)
    }

    // MARK: - Read

    /// Load all live handles, pruning stale entries for dead pids.
    public func allHandles() async -> [BridgeHandle] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: bridgesDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        var handles: [BridgeHandle] = []

        for url in contents where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let handle = try? decoder.decode(BridgeHandle.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // Prune stale entry if pid is no longer alive
            if kill(handle.pid, 0) != 0 {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            handles.append(handle)
        }
        return handles.sorted { $0.pid < $1.pid }
    }

    /// Find the handle for a specific service.bridge address, if any.
    public func handle(for addr: BridgeAddress) async -> BridgeHandle? {
        let all = await allHandles()
        return all.first { $0.addr == addr }
    }
}
