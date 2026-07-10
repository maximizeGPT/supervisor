// TraceLogTests.swift
//
// Verifies the trace log writes lines, appends across multiple emits,
// preserves ISO-8601 timestamps, collapses internal newlines, and rolls
// over at the configured size cap.

import XCTest
@testable import SupervisorCore

final class TraceLogTests: XCTestCase {

    private var tempDir: URL!
    private var logPath: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-tracelog-tests-\(UUID().uuidString)")
        logPath = tempDir.appendingPathComponent("supervisor.log")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testEmitWritesOneLine() throws {
        let log = TraceLog(path: logPath)
        log.emit("test", "hello world")
        log.sync()

        let contents = try String(contentsOf: logPath)
        XCTAssertTrue(contents.contains("[test] hello world"))
        XCTAssertEqual(contents.components(separatedBy: "\n").count - 1, 1)
    }

    func testEmitAppends() throws {
        let log = TraceLog(path: logPath)
        log.emit("a", "first")
        log.emit("b", "second")
        log.emit("c", "third")
        log.sync()

        let contents = try String(contentsOf: logPath)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("first"))
        XCTAssertTrue(lines[1].contains("second"))
        XCTAssertTrue(lines[2].contains("third"))
    }

    func testEmitCollapsesNewlines() throws {
        let log = TraceLog(path: logPath)
        log.emit("api", "request:\nmodel=haiku\nmax_tokens=1024")
        log.sync()

        let contents = try String(contentsOf: logPath)
        // Exactly one trailing newline from the line-ending; internal newlines
        // are replaced with the ⏎ marker.
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.filter { !$0.isEmpty }.count, 1)
        XCTAssertTrue(contents.contains("⏎"))
    }

    func testTimestampIsISO8601() throws {
        let log = TraceLog(path: logPath)
        log.emit("test", "x")
        log.sync()

        let contents = try String(contentsOf: logPath)
        // Format: 2026-05-21T16:14:46.960Z [test] x
        let prefix = String(contents.prefix(24))
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(f.date(from: prefix),
                        "expected ISO-8601 timestamp prefix, got: '\(prefix)'")
    }

    func testRollsOverAtSizeCap() throws {
        // Small cap so we can trip it cheaply.
        let log = TraceLog(path: logPath, rotateBytes: 256)
        let chunk = String(repeating: "x", count: 60)
        for i in 0..<10 {
            log.emit("burst", "\(i) \(chunk)")
        }
        log.sync()

        let liveExists = FileManager.default.fileExists(atPath: logPath.path)
        let rolledExists = FileManager.default.fileExists(atPath: logPath.appendingPathExtension("1").path)

        XCTAssertTrue(liveExists, "live log should still exist after rollover")
        XCTAssertTrue(rolledExists, "rolled .1 file should be present")
    }

    // MARK: - defaultPath resolution (launch-audit fix: test log bleed)

    func testDefaultPathHonorsSupervisorLogDirOverride() throws {
        setenv("SUPERVISOR_LOG_DIR", tempDir.path, 1)
        defer { unsetenv("SUPERVISOR_LOG_DIR") }

        XCTAssertEqual(
            TraceLog.defaultPath.path,
            tempDir.appendingPathComponent("supervisor.log").path,
            "$SUPERVISOR_LOG_DIR must fully determine the default log location"
        )
    }

    /// The bleed this guards against: components that fall back to
    /// `TraceLog.shared` during `swift test` were writing synthetic sessions
    /// into the REAL ~/Library/Logs/Supervisor/supervisor.log
    /// (`homeDirectoryForCurrentUser` ignores a stubbed $HOME, so temp-home
    /// isolation never covered this path).
    func testDefaultPathUnderXCTestNeverTargetsRealUserLogs() throws {
        unsetenv("SUPERVISOR_LOG_DIR")

        XCTAssertTrue(TraceLog.isRunningUnderXCTest,
                      "this test IS an XCTest run; the probe must say so")

        let realLogsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Supervisor").path
        XCTAssertFalse(TraceLog.defaultPath.path.hasPrefix(realLogsDir),
                       "under XCTest the default trace path must never resolve into the user's real Logs dir, got: \(TraceLog.defaultPath.path)")
    }

    func testConcurrentEmitsDoNotCorrupt() throws {
        let log = TraceLog(path: logPath)
        let group = DispatchGroup()
        let queue = DispatchQueue.global()
        for i in 0..<100 {
            group.enter()
            queue.async {
                log.emit("c", "msg \(i)")
                group.leave()
            }
        }
        group.wait()
        log.sync()

        let contents = try String(contentsOf: logPath)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 100, "all 100 emits should be present, got \(lines.count)")
        for line in lines {
            XCTAssertTrue(line.contains("[c]"),
                          "line missing category, got: '\(line)'")
        }
    }
}
