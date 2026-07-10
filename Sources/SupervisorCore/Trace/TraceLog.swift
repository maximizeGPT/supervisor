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

    /// Default location, used by `TraceLog.shared` (the fallback every
    /// component reaches for when no explicit trace is injected).
    ///
    /// Resolution order (launch-audit fix, 2026-07):
    ///   1. `$SUPERVISOR_LOG_DIR` — explicit override; the file is
    ///      `supervisor.log` inside that directory.
    ///   2. Under XCTest — a per-user temp directory. `swift test` runs were
    ///      writing synthetic sessions (sess-longrun, s-idle, …) into the REAL
    ///      ~/Library/Logs/Supervisor/supervisor.log whenever a component fell
    ///      back to `.shared`; `homeDirectoryForCurrentUser` resolves the true
    ///      home regardless of a stubbed `$HOME`, so temp-home isolation never
    ///      covered this path.
    ///   3. Production — `~/Library/Logs/Supervisor/supervisor.log`.
    public static var defaultPath: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["SUPERVISOR_LOG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent("supervisor.log")
        }
        if isRunningUnderXCTest {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("SupervisorTests/Logs", isDirectory: true)
                .appendingPathComponent("supervisor.log")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Supervisor/supervisor.log")
    }

    /// True when the process is an XCTest run. The env var is what Xcode /
    /// `swift test` set for the test host; the class probe is the
    /// belt-and-suspenders for runners that don't (the test bundle links
    /// XCTest, production binaries never do).
    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
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
