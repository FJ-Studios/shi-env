import Foundation

// MARK: - KotobaSubscriber
//
// Wraps gh:obyw-one/kotoba L1 lib for NATS stream subscription.
//
// BR-SEV-16: If kotoba Swift API is not ready, shells to `kotoba attach <subject>`
//            CLI as fallback.
//
// The kotoba L1 lib (gh:obyw-one/kotoba) is portable with zero shikki dep
// per [[shikki-tool-sovereignty-three-layer]]. This subscriber shims the
// CLI interface until a Swift Package is available for direct import.
//
// Spec: features/shi-env-verbs-2026-05-31.md §3.5b

/// NATS subscription state for a kotoba subject.
public enum KotobaSubscriptionState: Sendable {
    case connecting
    case active(subject: String, streams: [String])
    case degraded(reason: String)
    case closed
}

/// Delegate to receive kotoba stream events.
public protocol KotobaSubscriberDelegate: AnyObject, Sendable {
    func kotobaSubscriber(_ subscriber: KotobaSubscriber, didReceiveEvent event: String, on subject: String)
    func kotobaSubscriber(_ subscriber: KotobaSubscriber, didChangeState state: KotobaSubscriptionState)
}

/// Manages a kotoba NATS subscription for a given subject.
///
/// Day-1: shells out to `kotoba attach <subject>` CLI (fallback path per BR-SEV-16).
/// When gh:obyw-one/kotoba ships a Swift Package, the shell-out is replaced
/// with a direct import — no caller changes required.
public final class KotobaSubscriber: @unchecked Sendable {

    public let subject: String
    public let streams: [String]
    private weak var delegate: (any KotobaSubscriberDelegate)?

    private var process: Process?
    private let stateLock = NSLock()
    private var _state: KotobaSubscriptionState = .closed

    public var state: KotobaSubscriptionState {
        stateLock.withLock { _state }
    }

    public init(subject: String, streams: [String], delegate: (any KotobaSubscriberDelegate)? = nil) {
        self.subject = subject
        self.streams = streams
        self.delegate = delegate
    }

    // MARK: - Subscribe

    /// Begin subscribing to the kotoba NATS subject.
    ///
    /// Checks for `kotoba` CLI on PATH; if found, launches it and reads events.
    /// If not found, returns `.degraded`.
    public func subscribe() async throws {
        setState(.connecting)

        // Check if kotoba CLI is available
        guard let kotobaPath = findKotobaCLI() else {
            let reason = "kotoba CLI not found on PATH — install gh:obyw-one/kotoba"
            setState(.degraded(reason: reason))
            return
        }

        // Launch: kotoba attach <subject> [--streams audio,video,input,clipboard]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: kotobaPath)
        var args = ["attach", subject]
        if !streams.isEmpty {
            args += ["--streams", streams.joined(separator: ",")]
        }
        proc.arguments = args

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        // terminationHandler BEFORE run() per [[subprocess-bug-onion-fix-all-layers]]
        proc.terminationHandler = { [weak self] _ in
            self?.setState(.closed)
        }

        try proc.run()
        self.process = proc

        setState(.active(subject: subject, streams: streams))

        // Read events asynchronously
        Task.detached { [weak self] in
            guard let self else { return }
            let handle = outPipe.fileHandleForReading
            var buffer = Data()
            while self.process?.isRunning == true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                // Emit line-delimited events
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[buffer.startIndex...newline]
                    if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                       !line.isEmpty {
                        self.delegate?.kotobaSubscriber(self, didReceiveEvent: line, on: self.subject)
                    }
                    buffer = buffer[buffer.index(after: newline)...]
                }
            }
        }
    }

    // MARK: - Unsubscribe

    /// Gracefully unsubscribe — SIGTERM the kotoba process.
    ///
    /// BR-SEV-17: called FIRST in AttachSession teardown, before SSH exit.
    public func unsubscribe() {
        guard let proc = process, proc.isRunning else {
            setState(.closed)
            return
        }
        proc.terminate()
        process = nil
        setState(.closed)
    }

    // MARK: - Private

    private func setState(_ newState: KotobaSubscriptionState) {
        stateLock.withLock { _state = newState }
        delegate?.kotobaSubscriber(self, didChangeState: newState)
    }

    private func findKotobaCLI() -> String? {
        // Common install locations
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/kotoba",
            "/usr/local/bin/kotoba",
            "/opt/homebrew/bin/kotoba",
            "/usr/bin/kotoba",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Try `which kotoba`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["kotoba"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        proc.terminationHandler = { _ in }
        try? proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
    }
}
