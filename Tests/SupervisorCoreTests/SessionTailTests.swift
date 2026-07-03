// SessionTailTests.swift
//
// End-to-end test of the tail: write fixture lines to a temp file, watch
// the events arrive on the bus. Verifies parser integration AND the
// kqueue handler's read-to-EOF + buffered-line behavior. SessionDiscovery
// is exercised in the same way.

import XCTest
import Combine
@testable import SupervisorCore

final class SessionTailTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Tail emits events on append

    func testTailEmitsBashToolCallOnAppend() async throws {
        let file = tempDir.appendingPathComponent("session-1.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { event in collector.append(event) }
        defer { sub.cancel() }

        let tail = SessionTail(
            sessionId: "session-1",
            path: file,
            projectHash: "-tmp",
            bus: bus,
            sessionStore: nil,
            startOffset: 0
        )
        try tail.start()
        defer { tail.stop() }

        // Append two lines: an assistant tool_use(Bash) and a tool_result.
        let lines = [
            #"{"type":"assistant","timestamp":"2026-05-21T19:36:22Z","sessionId":"session-1","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf /tmp/foo"}}]}}"#,
            #"{"type":"user","timestamp":"2026-05-21T19:36:22.5Z","sessionId":"session-1","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":""}]}}"#,
        ]
        let payload = lines.joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(payload.utf8))

        // kqueue fires async; wait briefly then assert.
        try await waitForEvents(collector: collector, count: 2, within: 2.0)

        let hasBash = collector.snapshot.contains {
            if case .bashToolCall(let v) = $0, v.command == "rm -rf /tmp/foo" { return true }
            return false
        }
        let hasResult = collector.snapshot.contains {
            if case .bashToolResult(let v) = $0, v.toolUseId == "t1" { return true }
            return false
        }
        XCTAssertTrue(hasBash, "expected bashToolCall, got: \(collector.snapshot)")
        XCTAssertTrue(hasResult, "expected bashToolResult, got: \(collector.snapshot)")
    }

    // MARK: - Tail respects start offset (resume after crash)

    func testTailResumesFromSavedOffset() async throws {
        let file = tempDir.appendingPathComponent("session-2.jsonl")
        let firstBatch = (
            #"{"type":"queue-operation","timestamp":"2026-05-21T19:36:22Z","sessionId":"session-2","cwd":"/c"}"#
            + "\n"
            + #"{"type":"assistant","timestamp":"2026-05-21T19:36:22.1Z","sessionId":"session-2","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo before-restart"}}]}}"#
            + "\n"
        )
        try Data(firstBatch.utf8).write(to: file)

        // "Crash": tail never ran for the first batch. Restart with the
        // offset pointing past those lines.
        let resumeOffset = Int64(Data(firstBatch.utf8).count)

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace2.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { event in collector.append(event) }
        defer { sub.cancel() }

        let tail = SessionTail(
            sessionId: "session-2",
            path: file,
            projectHash: "-tmp",
            bus: bus,
            sessionStore: nil,
            startOffset: resumeOffset
        )
        try tail.start()
        defer { tail.stop() }

        // Append a new line. Tail should emit ONLY this line's events,
        // not the pre-restart ones.
        let newLine = #"{"type":"assistant","timestamp":"2026-05-21T19:36:23Z","sessionId":"session-2","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"echo after-restart"}}]}}"#
            + "\n"
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(newLine.utf8))

        try await waitForEvents(collector: collector, count: 1, within: 2.0)

        let commands = collector.snapshot.compactMap { e -> String? in
            if case .bashToolCall(let v) = e { return v.command }
            return nil
        }
        XCTAssertEqual(commands, ["echo after-restart"],
                       "should not re-emit the pre-restart command")
    }

    // MARK: - Fast-forward start (backfill skip)

    /// Two-line "history" fixture: a cwd-bearing lead-in line (the parser
    /// derives sessionStart from it) plus a Bash tool_use that must NEVER
    /// replay through the bus on a fast-forward start.
    private func writeHistoryFixture(to file: URL, sessionId: String) throws {
        let history = (
            #"{"type":"queue-operation","timestamp":"2026-05-21T19:36:22Z","sessionId":"\#(sessionId)","cwd":"/c"}"#
            + "\n"
            + #"{"type":"assistant","timestamp":"2026-05-21T19:36:22.1Z","sessionId":"\#(sessionId)","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf /old/history"}}]}}"#
            + "\n"
        )
        try Data(history.utf8).write(to: file)
    }

    private func appendLiveLine(to file: URL, sessionId: String) throws {
        let newLine = #"{"type":"assistant","timestamp":"2026-05-21T19:36:23Z","sessionId":"\#(sessionId)","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"echo live-append"}}]}}"#
            + "\n"
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(newLine.utf8))
    }

    /// Pre-existing file with an old mtime + no saved offset → fast-forward:
    /// historical lines never replay, sessionStart still surfaces, and a
    /// line appended after start is tailed normally.
    func testTailFastForwardsStaleFileEmittingSessionStartButNotHistory() async throws {
        let file = tempDir.appendingPathComponent("session-ff.jsonl")
        try writeHistoryFixture(to: file, sessionId: "session-ff")
        // Age the file past the 5-minute mtime threshold — the "Supervisor
        // (re)starts over a pre-existing transcript" shape.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: file.path
        )

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace-ff.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { event in collector.append(event) }
        defer { sub.cancel() }

        let tail = SessionTail(
            sessionId: "session-ff",
            path: file,
            projectHash: "-tmp",
            bus: bus,
            sessionStore: nil,
            startOffset: 0
        )
        try tail.start()
        defer { tail.stop() }

        try appendLiveLine(to: file, sessionId: "session-ff")
        try await waitForEvents(collector: collector, count: 1, within: 2.0)

        let commands = collector.snapshot.compactMap { e -> String? in
            if case .bashToolCall(let v) = e { return v.command }
            return nil
        }
        XCTAssertEqual(commands, ["echo live-append"],
                       "historical lines must never replay on a fast-forward start")
        XCTAssertTrue(collector.snapshot.contains {
            if case .sessionStart(let v) = $0, v.cwd == "/c" { return true }
            return false
        }, "fast-forward must still emit sessionStart from the file head; got: \(collector.snapshot)")
    }

    /// The size prong: a FRESH file above the (overridden, tiny) size
    /// threshold also fast-forwards. Production default is 128 KB.
    func testTailFastForwardsLargeFileViaSizeThreshold() async throws {
        let file = tempDir.appendingPathComponent("session-big.jsonl")
        try writeHistoryFixture(to: file, sessionId: "session-big")  // ~400 bytes, fresh mtime

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace-big.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { event in collector.append(event) }
        defer { sub.cancel() }

        let tail = SessionTail(
            sessionId: "session-big",
            path: file,
            projectHash: "-tmp",
            bus: bus,
            sessionStore: nil,
            startOffset: 0,
            fastForwardSizeThresholdBytes: 64
        )
        try tail.start()
        defer { tail.stop() }

        try appendLiveLine(to: file, sessionId: "session-big")
        try await waitForEvents(collector: collector, count: 1, within: 2.0)

        let commands = collector.snapshot.compactMap { e -> String? in
            if case .bashToolCall(let v) = e { return v.command }
            return nil
        }
        XCTAssertEqual(commands, ["echo live-append"],
                       "above-size-threshold file must fast-forward, not replay")
    }

    /// Finding 5 (2026-07-03): a fast-forward whose head scan finds NO
    /// sessionStart-bearing line means cwd never resolves — pause/kill/inject
    /// degrade forever, and until now, silently. The scan must emit a loud,
    /// distinct, diagnosable trace so the failure is visible in the log.
    func testFastForwardWithNoSessionStartInHeadEmitsTrace() async throws {
        let file = tempDir.appendingPathComponent("session-nocwd.jsonl")
        // History with NO cwd-bearing lead-in line — only assistant tool_use
        // lines — so the parser derives no sessionStart from the head.
        let history = (
            #"{"type":"assistant","timestamp":"2026-05-21T19:36:22Z","sessionId":"session-nocwd","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo one"}}]}}"#
            + "\n"
            + #"{"type":"assistant","timestamp":"2026-05-21T19:36:22.1Z","sessionId":"session-nocwd","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"echo two"}}]}}"#
            + "\n"
        )
        try Data(history.utf8).write(to: file)
        // Age it past the mtime threshold so the tail fast-forwards.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: file.path
        )

        let traceURL = tempDir.appendingPathComponent("trace-nocwd.log")
        let trace = TraceLog(path: traceURL)
        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("bus-nocwd.log")))
        let tail = SessionTail(
            sessionId: "session-nocwd",
            path: file,
            projectHash: "-tmp",
            bus: bus,
            sessionStore: nil,
            startOffset: 0,
            trace: trace
        )
        // start() runs the head scan synchronously; the trace is emitted there.
        try tail.start()
        defer { tail.stop() }

        trace.sync()  // drain the write queue before reading the file back
        let traceText = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(traceText.contains("fast_forward.no_sessionstart_in_head"),
                      "a fast-forward with no sessionStart in the head must emit the diagnostic trace; got: \(traceText)")
        XCTAssertTrue(traceText.contains("session=session-nocwd"),
                      "the trace must name the affected session")
    }

    /// A small fresh pre-existing file (the common brand-new session, or a
    /// tiny fixture in tests) still replays from byte 0 — the opening
    /// context must keep flowing to Triage. Default thresholds.
    func testTailReplaysSmallFreshFileFromByteZero() async throws {
        let file = tempDir.appendingPathComponent("session-fresh.jsonl")
        try writeHistoryFixture(to: file, sessionId: "session-fresh")

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace-fresh.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { event in collector.append(event) }
        defer { sub.cancel() }

        let tail = SessionTail(
            sessionId: "session-fresh",
            path: file,
            projectHash: "-tmp",
            bus: bus,
            sessionStore: nil,
            startOffset: 0
        )
        try tail.start()
        defer { tail.stop() }

        // The existing content itself must arrive (initial drain from 0).
        try await waitForEvents(collector: collector, count: 1, within: 2.0)
        let commands = collector.snapshot.compactMap { e -> String? in
            if case .bashToolCall(let v) = e { return v.command }
            return nil
        }
        XCTAssertEqual(commands, ["rm -rf /old/history"],
                       "a small fresh file must still replay from byte 0")
        XCTAssertTrue(collector.snapshot.contains {
            if case .sessionStart(let v) = $0, v.cwd == "/c" { return true }
            return false
        })
    }

    // MARK: - SessionDiscovery picks up new files

    func testDiscoveryPicksUpNewSessionFile() async throws {
        let projectsRoot = tempDir.appendingPathComponent("projects")
        let projectHashDir = projectsRoot.appendingPathComponent("-fake-project")
        try FileManager.default.createDirectory(at: projectHashDir, withIntermediateDirectories: true)

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace3.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { event in collector.append(event) }
        defer { sub.cancel() }

        let discovery = SessionDiscovery(
            claudeProjectsDir: projectsRoot,
            bus: bus,
            sessionStore: nil
        )
        discovery.start()
        defer { discovery.stop() }

        // Create a brand-new session file (already populated so the tail
        // sees content as soon as it opens).
        let session = projectHashDir.appendingPathComponent("session-disc.jsonl")
        let line = #"{"type":"assistant","timestamp":"2026-05-21T19:36:23Z","sessionId":"session-disc","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo discovered"}}]}}"#
            + "\n"
        try Data(line.utf8).write(to: session)

        // probeNow() exists for exactly this — we don't want test flakes
        // from kqueue arming latency. In production the rescan timer
        // (default 3s) catches what kqueue misses.
        discovery.probeNow()

        try await waitForEvents(collector: collector, count: 1, within: 4.0)

        XCTAssertTrue(collector.snapshot.contains {
            if case .bashToolCall(let v) = $0, v.command == "echo discovered" { return true }
            return false
        }, "discovery should have spawned a tail and produced the bash event; got: \(collector.snapshot)")

        // Discovery's activeSessions should include it.
        let active = discovery.activeSessions()
        XCTAssertTrue(active.contains("session-disc"))
    }

    // MARK: - Helpers

    final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [SupervisorEvent] = []
        func append(_ e: SupervisorEvent) {
            lock.lock(); defer { lock.unlock() }
            events.append(e)
        }
        var snapshot: [SupervisorEvent] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
        var count: Int { snapshot.count }
    }

    /// Poll-loop wait: returns once collector has at least `count` of the
    /// observable types (bashToolCall, bashToolResult, etc.), or fails after
    /// `within` seconds. We use this instead of XCTestExpectation because
    /// counts can rise across multiple kqueue notifications and we want to
    /// keep collecting until the deadline.
    private func waitForEvents(collector: EventCollector, count target: Int, within seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let n = collector.snapshot.filter { e in
                switch e {
                case .bashToolCall, .bashToolResult, .userPrompt, .assistantText, .systemSignal:
                    return true
                case .sessionStart:
                    return false  // sessionStart is "free" — don't count it
                }
            }.count
            if n >= target { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("timed out waiting for \(target) events; got \(collector.snapshot.count): \(collector.snapshot)")
    }
}
