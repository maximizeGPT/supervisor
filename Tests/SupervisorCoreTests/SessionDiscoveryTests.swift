// SessionDiscoveryTests.swift
//
// Tail-lifecycle coverage for the audit-H4 fix (Wave 3): recency-filtered
// discovery, inactivity-closed tails that free their fd, re-adoption at the
// saved offset (a resume, NOT a fast-forward), and delete/rename cleanup so a
// recreated same-id session is re-tailable.
//
// Same style as SessionTailTests: real kqueue, real EventParser, temp files,
// mtime driven with FileManager.setAttributes and short injected windows.

import XCTest
import Combine
@testable import SupervisorCore

final class SessionDiscoveryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-disc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Recency filter: skip stale, tail fresh

    func testDiscoverySkipsStaleTranscriptButTailsFreshOne() async throws {
        let projectsRoot = tempDir.appendingPathComponent("projects")
        let projectHashDir = projectsRoot.appendingPathComponent("-fake-project")
        try FileManager.default.createDirectory(at: projectHashDir, withIntermediateDirectories: true)

        // Old transcript: real content, but mtime well past the injected window.
        let oldFile = projectHashDir.appendingPathComponent("session-old.jsonl")
        try writeBash(to: oldFile, sessionId: "session-old", command: "echo old-history")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: oldFile.path
        )

        // Fresh transcript: current mtime → inside the window.
        let freshFile = projectHashDir.appendingPathComponent("session-fresh.jsonl")
        try writeBash(to: freshFile, sessionId: "session-fresh", command: "echo fresh-live")

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { collector.append($0) }
        defer { sub.cancel() }

        let discovery = SessionDiscovery(
            claudeProjectsDir: projectsRoot,
            bus: bus,
            sessionStore: nil,
            rescanInterval: 100,               // don't auto-rescan during asserts
            discoveryRecencyWindow: 120        // 2 min window; old (3600s) is out
        )
        discovery.start()
        defer { discovery.stop() }

        try await waitForCommands(collector, contains: "echo fresh-live", within: 3.0)

        let active = discovery.activeSessions()
        XCTAssertTrue(active.contains("session-fresh"), "fresh transcript must be tailed")
        XCTAssertFalse(active.contains("session-old"), "stale transcript must be skipped")

        XCTAssertFalse(commands(collector).contains("echo old-history"),
                       "stale transcript content must never replay")
    }

    // MARK: - A skipped file that gets written is adopted on the next scan

    func testSkippedFileIsAdoptedOnceWrittenTo() async throws {
        let projectsRoot = tempDir.appendingPathComponent("projects")
        let projectHashDir = projectsRoot.appendingPathComponent("-fake-project")
        try FileManager.default.createDirectory(at: projectHashDir, withIntermediateDirectories: true)

        let file = projectHashDir.appendingPathComponent("session-adopt.jsonl")
        try writeBash(to: file, sessionId: "session-adopt", command: "echo dormant")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: file.path
        )

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { collector.append($0) }
        defer { sub.cancel() }

        let discovery = SessionDiscovery(
            claudeProjectsDir: projectsRoot,
            bus: bus,
            sessionStore: nil,
            rescanInterval: 100,
            discoveryRecencyWindow: 120
        )
        discovery.start()
        defer { discovery.stop() }

        // First scan: skipped for age.
        XCTAssertFalse(discovery.activeSessions().contains("session-adopt"),
                       "old-mtime file should not be tailed on the first scan")

        // Now it becomes active: append a live line and bump the mtime into
        // the window (a `claude --resume` write).
        try appendBash(to: file, sessionId: "session-adopt", command: "echo now-active")
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: file.path
        )

        discovery.probeNow()

        try await waitUntil({ discovery.activeSessions().contains("session-adopt") }, within: 3.0,
                            "previously-skipped file must be adopted once written to")
        try await waitForCommands(collector, contains: "echo now-active", within: 3.0)
    }

    // MARK: - Inactivity close frees the entry; re-scan resumes at saved offset

    func testInactiveTailIsClosedThenReadoptedAtSavedOffset() async throws {
        let projectsRoot = tempDir.appendingPathComponent("projects")
        let projectHashDir = projectsRoot.appendingPathComponent("-fake-project")
        try FileManager.default.createDirectory(at: projectHashDir, withIntermediateDirectories: true)

        // Real store so the tail can persist an offset and the re-adopt can
        // read it back.
        let db = try SupervisorDatabase(path: tempDir.appendingPathComponent("supervisor.sqlite"))
        let store = SessionStore(database: db)

        let file = projectHashDir.appendingPathComponent("session-inact.jsonl")
        try writeBash(to: file, sessionId: "session-inact", command: "echo original")

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { collector.append($0) }
        defer { sub.cancel() }

        let discovery = SessionDiscovery(
            claudeProjectsDir: projectsRoot,
            bus: bus,
            sessionStore: store,
            rescanInterval: 100,               // manual re-adopt via probeNow
            discoveryRecencyWindow: 100_000,   // never age out during the test
            tailInactivityTimeout: 0.4,        // close quickly when quiet
            tailOffsetPersistInterval: 0.15    // and check/persist often
        )
        discovery.start()
        defer { discovery.stop() }

        // Tail comes up and replays the small fresh file from byte 0.
        try await waitForCommands(collector, contains: "echo original", within: 3.0)
        XCTAssertTrue(discovery.activeSessions().contains("session-inact"))

        // No further writes → the tail closes for inactivity and the entry is
        // pruned. The map shrinks back to empty.
        try await waitUntil({ !discovery.activeSessions().contains("session-inact") }, within: 4.0,
                            "an inactive tail must close and its entry be removed")
        XCTAssertTrue(discovery.activeSessions().isEmpty, "tails map must shrink after inactivity close")

        // The offset was flushed before close, so it is > 0 (the whole file was read).
        let savedOffset = try store.fetch(id: "session-inact")?.jsonlOffset
        XCTAssertNotNil(savedOffset)
        XCTAssertGreaterThan(savedOffset ?? 0, 0, "inactive close must persist a non-zero offset")

        // A later write re-activates the file; re-scan re-adopts it. Because
        // savedOffset > 0, the seek policy RESUMES from there — it does not
        // fast-forward and does not reset to byte 0. Proof: "echo original"
        // never replays a second time; only the new line arrives.
        try appendBash(to: file, sessionId: "session-inact", command: "echo second")
        discovery.probeNow()

        try await waitUntil({ discovery.activeSessions().contains("session-inact") }, within: 3.0,
                            "a written-to file must be re-adopted after an inactivity close")
        try await waitForCommands(collector, contains: "echo second", within: 3.0)

        let originalCount = commands(collector).filter { $0 == "echo original" }.count
        XCTAssertEqual(originalCount, 1,
                       "re-open must RESUME at the saved offset — the original line must not replay (that would mean a wrong byte-0/fast-forward re-open)")
    }

    // MARK: - Delete/rename prunes the entry; recreated same-id is re-tailed

    func testDeletePrunesEntryAndRecreatedSessionIsReTailed() async throws {
        let projectsRoot = tempDir.appendingPathComponent("projects")
        let projectHashDir = projectsRoot.appendingPathComponent("-fake-project")
        try FileManager.default.createDirectory(at: projectHashDir, withIntermediateDirectories: true)

        let file = projectHashDir.appendingPathComponent("session-recreate.jsonl")
        try writeBash(to: file, sessionId: "session-recreate", command: "echo first-life")

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { collector.append($0) }
        defer { sub.cancel() }

        let discovery = SessionDiscovery(
            claudeProjectsDir: projectsRoot,
            bus: bus,
            sessionStore: nil,
            rescanInterval: 100,
            discoveryRecencyWindow: 100_000,
            tailInactivityTimeout: 100        // isolate the delete path from inactivity
        )
        discovery.start()
        defer { discovery.stop() }

        try await waitForCommands(collector, contains: "echo first-life", within: 3.0)
        XCTAssertTrue(discovery.activeSessions().contains("session-recreate"))

        // Delete the file. The tail's delete handler must self-terminate and
        // SessionDiscovery must prune the entry (previously leaked).
        try FileManager.default.removeItem(at: file)
        try await waitUntil({ !discovery.activeSessions().contains("session-recreate") }, within: 4.0,
                            "delete must prune the tails[id] entry, not leak it")

        // Recreate a NEW file under the SAME session id. It must be re-tailed
        // (the stale entry would previously have blocked scanProjectHashDir).
        try writeBash(to: file, sessionId: "session-recreate", command: "echo second-life")
        discovery.probeNow()

        try await waitUntil({ discovery.activeSessions().contains("session-recreate") }, within: 3.0,
                            "a recreated same-id session must be re-tailable")
        try await waitForCommands(collector, contains: "echo second-life", within: 3.0)
    }

    // MARK: - Fixtures

    private func bashLine(sessionId: String, uuid: String, command: String) -> String {
        #"{"type":"assistant","timestamp":"2026-05-21T19:36:22Z","sessionId":"\#(sessionId)","uuid":"\#(uuid)","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(uuid)","name":"Bash","input":{"command":"\#(command)"}}]}}"#
    }

    /// Write a cwd-bearing lead-in (so sessionStart resolves) plus one Bash line.
    private func writeBash(to file: URL, sessionId: String, command: String) throws {
        let payload = (
            #"{"type":"queue-operation","timestamp":"2026-05-21T19:36:22Z","sessionId":"\#(sessionId)","cwd":"/c"}"#
            + "\n"
            + bashLine(sessionId: sessionId, uuid: "u-\(command.hashValue)", command: command)
            + "\n"
        )
        try Data(payload.utf8).write(to: file)
    }

    private func appendBash(to file: URL, sessionId: String, command: String) throws {
        let line = bashLine(sessionId: sessionId, uuid: "u-\(command.hashValue)", command: command) + "\n"
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    // MARK: - Helpers

    private func commands(_ collector: EventCollector) -> [String] {
        collector.snapshot.compactMap { e -> String? in
            if case .bashToolCall(let v) = e { return v.command }
            return nil
        }
    }

    private func waitForCommands(_ collector: EventCollector, contains command: String, within seconds: TimeInterval) async throws {
        try await waitUntil({ self.commands(collector).contains(command) }, within: seconds,
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
        func append(_ e: SupervisorEvent) {
            lock.lock(); defer { lock.unlock() }
            events.append(e)
        }
        var snapshot: [SupervisorEvent] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }
}
