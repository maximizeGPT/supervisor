// DogfoodSessionChurnTests.swift
//
// Wave 4 headless dogfood — Scenario 3 (session lifecycle churn).
//
// SessionDiscoveryTests already covers recency-skip, inactivity-close +
// re-adopt-at-offset, and delete-then-recreate. This file adds the two
// churn shapes it does NOT cover:
//
//   (A) TRUNCATION / ROTATION — a persisted offset points PAST the file's
//       current end (the transcript was rotated or truncated smaller since
//       Supervisor last saw it). The tail must NOT sit forever past EOF; it
//       resets to byte 0 and reads the current content.
//
//   (B) ATOMIC-SAVE RENAME — a tool/editor rewrites the transcript with the
//       write-temp-then-rename dance (a NEW inode swapped in under the same
//       name). The open fd is on the OLD inode, so the tail must self-
//       terminate on the rename/delete, discovery must prune the entry, and
//       the swapped-in file must be re-tailed so its content still flows.
//
// Same style as SessionTailTests / SessionDiscoveryTests: real kqueue, real
// EventParser, temp files, bounded polling.

import XCTest
import Combine
@testable import SupervisorCore

final class DogfoodSessionChurnTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-dogfood-churn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - (A) Truncation / rotation → stale offset resets to byte 0

    /// The transcript was rotated/truncated smaller than the offset Supervisor
    /// persisted last run. Opening at that stale offset would seek past EOF and
    /// the tail would never see the (new, smaller) content. The seek policy must
    /// detect savedOffset > EOF and RESET to byte 0 so the current content is
    /// read — sessionStart and all.
    func testTruncatedTranscriptWithStaleOffsetResetsToByteZero() async throws {
        let file = tempDir.appendingPathComponent("session-rotated.jsonl")
        // The post-rotation content: small, fresh, cwd-bearing lead-in + a
        // benign command that MUST be observed.
        let payload = (
            #"{"type":"queue-operation","timestamp":"2026-05-21T19:36:22Z","sessionId":"session-rotated","cwd":"/proj"}"#
            + "\n"
            + bashLine(sessionId: "session-rotated", uuid: "a1", command: "echo after-rotation")
            + "\n"
        )
        try Data(payload.utf8).write(to: file)
        let fileSize = Int64((try Data(contentsOf: file)).count)

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { collector.append($0) }
        defer { sub.cancel() }

        // A persisted offset far PAST the current (post-truncation) EOF — the
        // "the file used to be much bigger" shape.
        let staleOffset = fileSize + 500_000
        let tail = SessionTail(
            sessionId: "session-rotated",
            path: file,
            projectHash: "-tmp",
            bus: bus,
            sessionStore: nil,
            startOffset: staleOffset
        )
        try tail.start()
        defer { tail.stop() }

        try await waitForCommand(collector, "echo after-rotation", within: 3.0)
        // The reset re-reads from byte 0, so sessionStart surfaces too.
        XCTAssertTrue(collector.hasSessionStart(cwd: "/proj"),
                      "a stale-offset reset must replay from byte 0, emitting sessionStart")
        // Exactly once — a reset is a byte-0 read, not a double read.
        XCTAssertEqual(collector.bashCommands.filter { $0 == "echo after-rotation" }.count, 1)
    }

    // MARK: - (B) Atomic-save rename → prune + re-tail the swapped-in file

    /// A tool rewrites the transcript atomically (write temp, rename over the
    /// original). The tail's fd is on the OLD inode, so the rename/delete must
    /// self-terminate the tail; discovery prunes the entry; the swapped-in file
    /// is re-tailed and its new content flows. Distinct from the existing
    /// delete-then-recreate test: here it's a single atomic inode swap.
    func testAtomicSaveRenameReTailsSwappedInFile() async throws {
        let projectsRoot = tempDir.appendingPathComponent("projects")
        let projectHashDir = projectsRoot.appendingPathComponent("-proj")
        try FileManager.default.createDirectory(at: projectHashDir, withIntermediateDirectories: true)

        let file = projectHashDir.appendingPathComponent("session-atomic.jsonl")
        try writeTranscript(to: file, sessionId: "session-atomic", command: "echo before-save")

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { collector.append($0) }
        defer { sub.cancel() }

        let discovery = SessionDiscovery(
            claudeProjectsDir: projectsRoot,
            bus: bus,
            sessionStore: nil,
            rescanInterval: 100,             // manual re-adopt via probeNow
            discoveryRecencyWindow: 100_000, // never age out during the test
            tailInactivityTimeout: 100       // isolate from the inactivity path
        )
        discovery.start()
        defer { discovery.stop() }

        try await waitForCommand(collector, "echo before-save", within: 3.0)
        XCTAssertTrue(discovery.activeSessions().contains("session-atomic"))

        // Atomic save: write the new transcript to a temp file, then swap it in
        // under the same name (a NEW inode). This is what editors and
        // `write(to:atomically:true)` do.
        let temp = tempDir.appendingPathComponent("atomic-temp-\(UUID().uuidString).jsonl")
        try Data((
            #"{"type":"queue-operation","timestamp":"2026-05-21T19:40:00Z","sessionId":"session-atomic","cwd":"/proj"}"#
            + "\n"
            + bashLine(sessionId: "session-atomic", uuid: "a2", command: "echo after-save")
            + "\n"
        ).utf8).write(to: temp)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)

        // The rename/delete on the old inode must prune the entry (not leak it).
        try await waitUntil({ !discovery.activeSessions().contains("session-atomic") }, within: 4.0,
                            "an atomic-save rename must self-terminate the tail and prune the entry")

        // The swapped-in file is re-adopted on the next scan; its content flows.
        discovery.probeNow()
        try await waitUntil({ discovery.activeSessions().contains("session-atomic") }, within: 3.0,
                            "the swapped-in transcript must be re-tailed")
        try await waitForCommand(collector, "echo after-save", within: 3.0)
    }

    // MARK: - Fixtures

    private func bashLine(sessionId: String, uuid: String, command: String) -> String {
        #"{"type":"assistant","timestamp":"2026-05-21T19:36:22Z","sessionId":"\#(sessionId)","uuid":"\#(uuid)","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(uuid)","name":"Bash","input":{"command":"\#(command)"}}]}}"#
    }

    private func writeTranscript(to file: URL, sessionId: String, command: String) throws {
        let payload = (
            #"{"type":"queue-operation","timestamp":"2026-05-21T19:36:22Z","sessionId":"\#(sessionId)","cwd":"/proj"}"#
            + "\n"
            + bashLine(sessionId: sessionId, uuid: "u-\(command.hashValue)", command: command)
            + "\n"
        )
        try Data(payload.utf8).write(to: file)
    }

    // MARK: - Helpers

    private func waitForCommand(_ collector: EventCollector, _ command: String, within seconds: TimeInterval) async throws {
        try await waitUntil({ collector.bashCommands.contains(command) }, within: seconds,
                            "timed out waiting for bash command \(command)")
    }

    private func waitUntil(_ predicate: @escaping () -> Bool, within seconds: TimeInterval, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(message)
    }

    final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [SupervisorEvent] = []
        func append(_ e: SupervisorEvent) { lock.lock(); events.append(e); lock.unlock() }
        private var snapshot: [SupervisorEvent] { lock.lock(); defer { lock.unlock() }; return events }
        var bashCommands: [String] {
            snapshot.compactMap { if case .bashToolCall(let v) = $0 { return v.command }; return nil }
        }
        func hasSessionStart(cwd: String) -> Bool {
            snapshot.contains { if case .sessionStart(let v) = $0 { return v.cwd == cwd }; return false }
        }
    }
}
