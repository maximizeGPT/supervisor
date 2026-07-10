// CodexSessionDiscoveryTests.swift
//
// End-to-end proof of the live wiring: a Codex rollout in the ~/.codex-style
// date tree is discovered, tailed as it grows, and its events reach the SAME
// EventBus — where the EXISTING safety rubric flags a Codex command. Uses the
// hardened SessionTail (via CodexSessionDiscovery) with an injected
// CodexRolloutParser. No dependency on the codex binary, so it is deterministic
// and CI-safe; a real `codex exec` is exercised separately by the QA loop.

import XCTest
@testable import SupervisorCore

final class CodexSessionDiscoveryTests: XCTestCase {

    private var sessionsDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-disc-\(UUID().uuidString)/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sessionsDir.deletingLastPathComponent())
        try await super.tearDown()
    }

    // A rollout is discovered in the YYYY/MM/DD tree, its session_meta cwd is
    // surfaced, its exec_command flows to the bus, and a command APPENDED after
    // the tail is live is picked up too (real kqueue tailing), then flagged by
    // the existing DeterministicCatch — proving one rubric supervises Codex.
    func testDiscoversTailsAndFlagsCodexRolloutLive() async throws {
        let uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let dayDir = sessionsDir.appendingPathComponent("2026/07/05", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent("rollout-2026-07-05T10-00-00-\(uuid).jsonl")

        // Initial content: session_meta (cwd) + one safe exec_command.
        try Data((sessionMeta(cwd: "/private/tmp/demo-repo") + "\n"
                  + execCommand(callId: "c1", cmd: "swift build") + "\n").utf8).write(to: file)

        let bus = EventBus(trace: TraceLog(path: sessionsDir.appendingPathComponent("t.log")))
        let collector = EventCollector()
        let sub = bus.subscribe { collector.append($0) }
        defer { sub.cancel() }

        let discovery = CodexSessionDiscovery(
            codexSessionsDir: sessionsDir, bus: bus, sessionStore: nil,
            rescanInterval: 0.2,
            trace: TraceLog(path: sessionsDir.appendingPathComponent("t.log")))
        discovery.start()
        defer { discovery.stop() }

        // Initial content observed: sessionStart cwd + the safe command.
        try await waitUntil({ collector.cwds.contains("/private/tmp/demo-repo") }, within: 3.0,
                            "sessionStart cwd not surfaced")
        try await waitUntil({ collector.commands.contains("swift build") }, within: 3.0,
                            "initial exec_command not observed")

        // Append a dangerous command AFTER the tail is live.
        try append(execCommand(callId: "c2", cmd: "git reset --hard HEAD~3"), to: file)
        try await waitUntil({ collector.commands.contains("git reset --hard HEAD~3") }, within: 3.0,
                            "appended command not tailed live")

        // The existing rubric flags the Codex-sourced command, unchanged.
        let flagged = collector.commands.compactMap { DeterministicCatch.match($0) }
        XCTAssertTrue(flagged.contains { $0.pattern.contains("git reset --hard") },
                      "DeterministicCatch should flag the Codex git reset --hard")
    }

    // Config toggle parses correctly and defaults to auto (nil).
    func testSuperviseCodexConfigToggle() {
        XCTAssertNil(UserConfig.parse("known_terminals:\n  - com.apple.Terminal").superviseCodex)
        XCTAssertEqual(UserConfig.parse("supervise_codex: false").superviseCodex, false)
        XCTAssertEqual(UserConfig.parse("supervise_codex: true  # on").superviseCodex, true)
    }

    // MARK: - Fixtures

    private func sessionMeta(cwd: String) -> String {
        ##"{"timestamp":"2026-07-05T10:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"\##(cwd)","originator":"Codex Desktop","git":{"branch":"main"}}}"##
    }

    private func execCommand(callId: String, cmd: String) -> String {
        ##"{"timestamp":"2026-07-05T10:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"\##(callId)","arguments":"{\"cmd\":\"\##(cmd)\"}"}}"##
    }

    private func append(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
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
        var commands: [String] {
            lock.lock(); defer { lock.unlock() }
            return events.compactMap { if case .bashToolCall(let v) = $0 { return v.command }; return nil }
        }
        var cwds: [String] {
            lock.lock(); defer { lock.unlock() }
            return events.compactMap { if case .sessionStart(let v) = $0 { return v.cwd }; return nil }
        }
    }
}
