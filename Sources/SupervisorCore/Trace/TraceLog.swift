// TraceLog.swift
//
// Rolling text log at ~/Library/Logs/Supervisor/supervisor.log.
//
// Every triage call, every Anthropic API call, every flag raised, every
// notification posted, every heartbeat write hits this log. It's a debug
// affordance: when Supervisor behaves weirdly, the first question is
// "what did it see, and what did it decide?" — and the trace log answers
// that without a debugger.
//
// Append-only, line-per-event, ISO-8601 timestamps. Auto-rotates at 10 MB
// to `supervisor.log.1` so the file never grows unbounded.

import Foundation

/// Append-only rolling log. Thread-safe; uses a serial dispatch queue for
/// writes so callers can `emit` from any thread without blocking.
public final class TraceLog: @unchecked Sendable {

    /// Process-wide default instance. Writes to
    /// `~/Library/Logs/Supervisor/supervisor.log`. Initialized lazily.
    public static let shared = TraceLog()

    /// Path the instance writes to. Public for tests and for the status-bar
    /// "open log file" affordance.
    public let path: URL

    /// Soft size cap. When the live file exceeds this, it's renamed to
    /// `<name>.1` (overwriting any previous .1) and a fresh file is started.
    private let rotateBytes: Int

    private let queue = DispatchQueue(label: "supervisor.trace", qos: .utility)

    public init(
        path: URL = TraceLog.defaultPath,
        rotateBytes: Int = 10 * 1024 * 1024
    ) {
        self.path = path
        self.rotateBytes = rotateBytes
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
    }

    /// Default location. Honors `$HOME` so test runs in temp homes don't
    /// pollute the user's real Logs directory.
    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Supervisor/supervisor.log")
    }

    /// Emit one line. Returns immediately; write happens on the trace queue.
    /// `category` is a short tag (e.g. "api", "triage", "flag", "notify",
    /// "heartbeat"). `message` is free-form prose, ideally one line.
    public func emit(_ category: String, _ message: String) {
        let ts = Self.formatter.string(from: Date())
        // One-line discipline: collapse internal newlines so each emit
        // produces exactly one log line.
        let collapsed = message.replacingOccurrences(of: "\n", with: " ⏎ ")
        let line = "\(ts) [\(category)] \(collapsed)\n"
        queue.async { [path, rotateBytes] in
            Self.writeLine(line, to: path, rotateBytes: rotateBytes)
        }
    }

    /// Drain the write queue. Tests use this to assert content is on disk
    /// before reading the file back.
    public func sync() {
        queue.sync { }
    }

    // MARK: - File I/O

    private static func writeLine(_ line: String, to path: URL, rotateBytes: Int) {
        guard let data = line.data(using: .utf8) else { return }

        // Roll over if we're past the cap. Done before write so the new
        // line lands in the fresh file.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? Int,
           size + data.count > rotateBytes {
            let rolled = path.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: rolled)
            try? FileManager.default.moveItem(at: path, to: rolled)
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }

        if let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // First write or the handle vanished; fall back to atomic write.
            try? data.write(to: path)
        }
    }

    // MARK: - Timestamp

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
