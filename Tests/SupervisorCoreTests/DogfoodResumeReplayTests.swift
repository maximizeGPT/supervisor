// DogfoodResumeReplayTests.swift
//
// Wave 4 headless dogfood — Scenario 2. The single worst pre-Wave-1 bug.
//
// USER STORY: I run `claude --resume` (or the session auto-compacts). The
// NEW transcript file is a full COPY of the old conversation, including a
// historical `rm -rf ~/Documents` line that ran, safely, weeks ago. Before
// Wave 1, Supervisor tailed that copy from byte 0 and re-triaged the ENTIRE
// history — firing a real SIGSTOP on the live session for a command long
// past, storming banners, and spending API budget replaying the past.
//
// Two independent defenses must make that impossible, and this proves both:
//
//   Layer 1 — fast-forward start (SessionTail): a pre-existing (old-mtime)
//   transcript is tailed from EOF, so historical lines never even parse.
//
//   Layer 2 — event-age gate (TriageEngine): even a SMALL, FRESH resume
//   file that replays from byte 0 has its historical events dropped in the
//   triage decision path, because their OWN timestamps are old.
//
// Either way the historical destructive line must produce NO flag, NO
// signal, and NO model call — while a FRESH line appended afterwards proves
// the tail is genuinely live (sessionStart emitted, new line observed).

import XCTest
import Combine
import Darwin
@testable import SupervisorCore

@MainActor
final class DogfoodResumeReplayTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-dogfood-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CountingFailURLProtocol.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Layer 1: fast-forward skips a resumed/old transcript's history

    func testResumedOldTranscriptDoesNotReplayHistoricalDestructiveLine() async throws {
        let world = try makeWorld()
        defer { world.teardown() }

        let sessionId = "resume-ff-1"
        let file = world.projectHashDir.appendingPathComponent("\(sessionId).jsonl")

        // The `claude --resume` copy: a cwd-bearing lead-in plus a HISTORICAL
        // rm -rf. Old JSONL timestamps AND — the fast-forward trigger — an old
        // file mtime, the "Supervisor started over a pre-existing transcript"
        // shape.
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-6 * 3600))
        let history = [
            #"{"type":"queue-operation","timestamp":"\#(old)","sessionId":"\#(sessionId)","cwd":"/Users/test","gitBranch":"main"}"#,
            #"{"type":"user","timestamp":"\#(old)","sessionId":"\#(sessionId)","uuid":"u1","message":{"role":"user","content":"clean the workspace"}}"#,
            #"{"type":"assistant","timestamp":"\#(old)","sessionId":"\#(sessionId)","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf ~/Documents"}}]}}"#,
        ]
        try Data((history.joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)

        world.discovery.start()

        // sessionStart must still surface from the head (Supervisor knows the
        // session exists) — but nothing historical replays.
        try await waitUntil(within: 4.0, "sessionStart never emitted from the resumed head") {
            world.collector.hasSessionStart(cwd: "/Users/test")
        }

        // Now a FRESH, benign line lands — the resumed session is live again.
        let fresh = ISO8601DateFormatter().string(from: Date())
        try append(to: file,
            #"{"type":"assistant","timestamp":"\#(fresh)","sessionId":"\#(sessionId)","uuid":"a2","message":{"role":"assistant","content":[{"type":"text","text":"Resumed and caught up. Ready for the next task."}]}}"#)

        try await waitUntil(within: 4.0, "fresh appended line was never observed — tail not live") {
            world.collector.hasAssistantText(containing: "Resumed and caught up")
        }

        // The historical destructive line was fast-forwarded past: never parsed,
        // never flagged, never signaled, never billed.
        XCTAssertFalse(world.collector.hasBashCommand("rm -rf ~/Documents"),
                       "the historical rm -rf must never replay onto the bus")
        XCTAssertEqual(world.recorder.decisionCount, 0, "no flag may be raised for replayed history")
        XCTAssertTrue(world.sender.sent.isEmpty, "no SIGSTOP may fire for replayed history")
        XCTAssertEqual(CountingFailURLProtocol.requestCount, 0,
                       "replaying resumed history must spend zero model calls")
    }

    // MARK: - Layer 2: event-age gate drops old events in a small fresh file

    func testSmallFreshResumeFileAgeGatesHistoricalDestructiveLine() async throws {
        let world = try makeWorld()
        defer { world.teardown() }

        let sessionId = "resume-age-1"
        let file = world.projectHashDir.appendingPathComponent("\(sessionId).jsonl")

        // A SMALL, FRESH file (default thresholds → replays from byte 0, NOT
        // fast-forwarded) whose rm -rf carries an OLD timestamp. This is the
        // case Layer 1 deliberately lets through so Layer 2 can catch it: the
        // triage decision path drops the event because its own ts is stale.
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))
        let lines = [
            #"{"type":"queue-operation","timestamp":"\#(old)","sessionId":"\#(sessionId)","cwd":"/Users/test","gitBranch":"main"}"#,
            #"{"type":"assistant","timestamp":"\#(old)","sessionId":"\#(sessionId)","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf ~/Documents"}}]}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)  // fresh mtime

        world.discovery.start()

        // The historical rm IS parsed and reaches the bus (byte-0 replay) — so
        // if it produced a catch, we'd see it. It must not.
        try await waitUntil(within: 4.0, "byte-0 replay never surfaced the historical line") {
            world.collector.hasBashCommand("rm -rf ~/Documents")
        }

        // A fresh benign line proves the tail keeps running afterwards.
        let fresh = ISO8601DateFormatter().string(from: Date())
        try append(to: file,
            #"{"type":"assistant","timestamp":"\#(fresh)","sessionId":"\#(sessionId)","uuid":"a2","message":{"role":"assistant","content":[{"type":"text","text":"Nothing pending. Standing by."}]}}"#)
        try await waitUntil(within: 4.0, "fresh appended line never observed") {
            world.collector.hasAssistantText(containing: "Standing by")
        }

        // Give the engine's async evaluate() a beat to have run and been gated.
        try await Task.sleep(nanoseconds: 300_000_000)

        // The age gate dropped the historical rm BEFORE the deterministic catch
        // and BEFORE any model call: no flag, no signal, no spend.
        XCTAssertEqual(world.recorder.decisionCount, 0,
                       "a stale-timestamped rm -rf must be age-gated, not caught")
        XCTAssertTrue(world.sender.sent.isEmpty, "no SIGSTOP for an age-gated historical command")
        XCTAssertEqual(CountingFailURLProtocol.requestCount, 0,
                       "the age gate must drop the event before it reaches the model")
    }

    // MARK: - Shared harness

    private struct World {
        let projectHashDir: URL
        let discovery: SessionDiscovery
        let engine: TriageEngine
        let collector: EventCollector
        let recorder: DecisionRecorder
        let sender: CapturingSignalSender
        let teardown: () -> Void
    }

    private func makeWorld() throws -> World {
        let projectsDir = tempDir.appendingPathComponent("projects")
        let projectHashDir = projectsDir.appendingPathComponent("-Users-test")
        try FileManager.default.createDirectory(at: projectHashDir, withIntermediateDirectories: true)

        let trace = TraceLog(path: tempDir.appendingPathComponent("trace-\(UUID().uuidString).log"))
        let bus = EventBus(trace: trace)
        let collector = EventCollector()
        let sub = bus.subscribe { collector.append($0) }

        let client = LLMClient(
            provider: .anthropic,
            apiKey: "no-key",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: countingSession(),
            traceLog: trace
        )
        let engine = TriageEngine(client: client, bus: bus, windowSize: 30, trace: trace)

        let sender = CapturingSignalSender()
        let router = InterventionRouter(
            notifier: CapturingNotifier(),
            locator: StubLocator(sessionHandle: ProcessHandle(
                pid: 4242, execPath: "/usr/local/bin/claude", cwd: "/Users/test")),
            signalSender: sender,
            injector: MockInjector(),
            humanActivity: StubHumanActivityProbe(idleSeconds: 999),
            trace: trace
        )
        let recorder = DecisionRecorder()
        engine.onDecision = { decision in
            recorder.record()
            Task { @MainActor in await router.dispatch(decision: decision) }
        }
        engine.start()

        let discovery = SessionDiscovery(
            claudeProjectsDir: projectsDir,
            bus: bus,
            sessionStore: nil,
            trace: trace
        )
        return World(
            projectHashDir: projectHashDir,
            discovery: discovery,
            engine: engine,
            collector: collector,
            recorder: recorder,
            sender: sender,
            teardown: {
                discovery.stop()
                engine.stop()
                sub.cancel()
            }
        )
    }

    private func append(to file: URL, _ line: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    // MARK: - Offline transport (counts calls, always fails)

    private func countingSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CountingFailURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private final class CountingFailURLProtocol: URLProtocol {
        nonisolated(unsafe) private static var _count = 0
        private static let lock = NSLock()
        static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _count }
        static func reset() { lock.lock(); _count = 0; lock.unlock() }
        override class func canInit(with request: URLRequest) -> Bool {
            lock.lock(); _count += 1; lock.unlock(); return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        }
        override func stopLoading() {}
    }

    // MARK: - Local test doubles

    private struct StubLocator: ProcessLocator {
        var handle: ProcessHandle? = nil
        var sessionHandle: ProcessHandle? = nil
        func locate(targetCwd: String) -> ProcessHandle? { handle }
        func locate(targetCwd: String, allowDesktopFallback: Bool) -> ProcessHandle? { handle }
        func locate(bySessionId sessionId: String) -> ProcessHandle? { sessionHandle }
    }

    private final class CapturingSignalSender: SignalSender, @unchecked Sendable {
        struct Sent: Equatable { let signal: Int32; let pid: pid_t; var group: Bool = false }
        private let lock = NSLock()
        private var _sent: [Sent] = []
        var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return _sent }
        func send(_ signal: Int32, to pid: pid_t) throws {
            lock.lock(); _sent.append(Sent(signal: signal, pid: pid)); lock.unlock()
        }
        func sendToGroup(_ signal: Int32, of pid: pid_t) throws {
            lock.lock(); _sent.append(Sent(signal: signal, pid: pid, group: true)); lock.unlock()
        }
    }

    private final class CapturingNotifier: Notifying, @unchecked Sendable {
        func post(decision: TriageDecision) async -> Notifier.Outcome { .posted }
        func postInterventionResult(decision: TriageDecision, outcome: InterventionOutcome) async -> Notifier.Outcome { .posted }
    }

    private final class DecisionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var decisionCount: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func record() { lock.lock(); _count += 1; lock.unlock() }
    }

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [SupervisorEvent] = []
        func append(_ e: SupervisorEvent) { lock.lock(); events.append(e); lock.unlock() }
        private var snapshot: [SupervisorEvent] { lock.lock(); defer { lock.unlock() }; return events }
        func hasBashCommand(_ cmd: String) -> Bool {
            snapshot.contains { if case .bashToolCall(let v) = $0 { return v.command == cmd }; return false }
        }
        func hasAssistantText(containing s: String) -> Bool {
            snapshot.contains { if case .assistantText(let v) = $0 { return v.text.contains(s) }; return false }
        }
        func hasSessionStart(cwd: String) -> Bool {
            snapshot.contains { if case .sessionStart(let v) = $0 { return v.cwd == cwd }; return false }
        }
    }

    private func waitUntil(within seconds: TimeInterval, _ message: String,
                           _ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        XCTFail(message)
    }
}
