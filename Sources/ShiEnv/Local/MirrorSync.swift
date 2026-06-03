import Foundation

// MARK: - MirrorSync
//
// One-way prod→local file sync (BR-SELP-04 — never local→prod).
// Atomic per-file via write-to-tmp + rename (BR-SELP-09).
// Event-triggered: FSEvents watches pb_migrations/, pb_hooks/, sites.yml
// (BR-SELP-10, per [[event-driven-never-cyclic-refresh]]).
//
// Spec: features/shi-env-local-prod-parity-2026-05-31.md §3.3 (mirror sync row)

public struct MirrorSync: Sendable {

    public struct Options: Sendable {
        /// When true, log each file action but perform no writes.
        public var dryRun: Bool
        /// Source root (prod project root, e.g. path to obyw-one).
        public var sourceRoot: URL
        /// Destination root (local PB instance directory).
        public var destinationRoot: URL
        /// Extra content paths beyond the canonical set.
        public var extraPaths: [String]

        public init(
            dryRun: Bool = false,
            sourceRoot: URL,
            destinationRoot: URL,
            extraPaths: [String] = []
        ) {
            self.dryRun = dryRun
            self.sourceRoot = sourceRoot
            self.destinationRoot = destinationRoot
            self.extraPaths = extraPaths
        }
    }

    public struct SyncResult: Sendable {
        public let path: String
        public let action: SyncAction
        public let success: Bool
        public let detail: String?

        public init(path: String, action: SyncAction, success: Bool, detail: String? = nil) {
            self.path = path
            self.action = action
            self.success = success
            self.detail = detail
        }
    }

    public enum SyncAction: String, Sendable {
        case copied
        case skipped   // dest already up-to-date (same modification date + size)
        case deleted   // source removed
        case dryRun
    }

    // Canonical subdirectory names mirrored by default.
    public static let canonicalPaths = ["pb_migrations", "pb_hooks"]

    // FileManager is not Sendable in Swift 6; the struct is otherwise pure,
    // so we keep `nonisolated(unsafe)` here and treat the FM as effectively
    // immutable (we only call its query/copy/remove methods which are
    // thread-safe on Darwin's underlying implementation).
    nonisolated(unsafe) private let fm: FileManager

    public init(fileManager: FileManager = .default) {
        self.fm = fileManager
    }

    /// Perform a one-shot sync of all canonical + extra paths.
    ///
    /// Returns one SyncResult per file inspected.
    @discardableResult
    public func sync(options: Options) throws -> [SyncResult] {
        var results: [SyncResult] = []

        let paths = Self.canonicalPaths + options.extraPaths

        for rel in paths {
            let src = options.sourceRoot.appendingPathComponent(rel)
            guard fm.fileExists(atPath: src.path) else { continue }

            let dst = options.destinationRoot.appendingPathComponent(rel)

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                let children = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                for child in children {
                    let childDst = dst.appendingPathComponent(child.lastPathComponent)
                    let r = try syncFile(from: child, to: childDst, dryRun: options.dryRun)
                    results.append(r)
                }
            } else {
                let r = try syncFile(from: src, to: dst, dryRun: options.dryRun)
                results.append(r)
            }
        }

        return results
    }

    // MARK: Private

    private func syncFile(from src: URL, to dst: URL, dryRun: Bool) throws -> SyncResult {
        let relPath = src.lastPathComponent

        if dryRun {
            return SyncResult(path: relPath, action: .dryRun, success: true,
                              detail: "[dry-run] would copy \(src.path)")
        }

        // Check if dest already matches (mtime + size equality for speed)
        if fm.fileExists(atPath: dst.path) {
            let srcAttrs  = try fm.attributesOfItem(atPath: src.path)
            let dstAttrs  = try fm.attributesOfItem(atPath: dst.path)
            let srcSize   = srcAttrs[.size] as? Int ?? -1
            let dstSize   = dstAttrs[.size] as? Int ?? -2
            let srcMod    = srcAttrs[.modificationDate] as? Date ?? .distantPast
            let dstMod    = dstAttrs[.modificationDate] as? Date ?? .distantFuture
            if srcSize == dstSize && srcMod <= dstMod {
                return SyncResult(path: relPath, action: .skipped, success: true)
            }
        }

        // Atomic: write to .tmp sibling then rename
        let tmp = dst.deletingLastPathComponent()
                     .appendingPathComponent(".\(dst.lastPathComponent).tmp")

        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)

        return SyncResult(path: relPath, action: .copied, success: true)
    }
}

// MARK: - MirrorSyncWatcher

/// FSEvents-based watcher that triggers MirrorSync when observed paths change.
/// Satisfies BR-SELP-10 (event-driven, never cyclic refresh).
///
/// Usage: create, call `start()`, then `stop()` when done.
public final class MirrorSyncWatcher: @unchecked Sendable {

    public struct Config: Sendable {
        /// Paths under `sourceRoot` to watch (e.g. "pb_migrations").
        public var watchedPaths: [String]
        public var options: MirrorSync.Options
        /// Debounce interval — consolidates burst events from a single save.
        public var debounceSeconds: Double

        public init(
            watchedPaths: [String] = MirrorSync.canonicalPaths,
            options: MirrorSync.Options,
            debounceSeconds: Double = 0.5
        ) {
            self.watchedPaths = watchedPaths
            self.options = options
            self.debounceSeconds = debounceSeconds
        }
    }

    private let config: Config
    private let syncer: MirrorSync
    private var stream: FSEventStreamRef?
    private var debounceTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "one.obyw.shi-env.mirror-sync-watcher")

    public init(config: Config, syncer: MirrorSync = MirrorSync()) {
        self.config = config
        self.syncer = syncer
    }

    deinit { stop() }

    /// Start watching. Safe to call multiple times (idempotent).
    public func start() {
        guard stream == nil else { return }

        let watchURLs = config.watchedPaths.map {
            config.options.sourceRoot.appendingPathComponent($0).path as CFString
        }
        let pathsToWatch = watchURLs as CFArray

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { Unmanaged<MirrorSyncWatcher>.fromOpaque($0!).release() },
            copyDescription: nil
        )

        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<MirrorSyncWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleSync()
        }

        stream = FSEventStreamCreate(
            nil, cb, &ctx,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            config.debounceSeconds,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let s = stream {
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
        }
    }

    /// Stop watching and cancel any pending sync.
    public func stop() {
        debounceTimer?.cancel()
        debounceTimer = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    // MARK: Private

    private func scheduleSync() {
        debounceTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + config.debounceSeconds)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            _ = try? self.syncer.sync(options: self.config.options)
        }
        t.resume()
        debounceTimer = t
    }
}
