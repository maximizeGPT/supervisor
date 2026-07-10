// DormantSessionDriveTests.swift
//
// Fix-queue #9 ("discover before fix"): Supervisor injected a dispatch into a
// chat the operator had abandoned for DAYS. The remaining defect was NOT bad
// targeting (the DesktopConversationTargeter M8 fix already hardens the
// two-similar-titles collision): it was that NOTHING bounded the auto-drive by
// the session's REAL last-activity age. LoopController.canDispatch resets only on
// its own `lastSeenAt`, which is refreshed every tick, so a days-idle session was
// driven forever until the unrelated 24h watchdog eviction.
//
// These tests drive the FULL tick path (TriageEngine.checkIdleStates ->
// runWatchdogPass + the short-idle dispatch walk) through the dormant gate, with
// an injectable clock and a small `dormantSessionSilenceSeconds` so they are
// deterministic. They mirror StallWatchdogEngineTests' wiring (real router,
// SpyDispatcher, CapturingInjector, fixture transcript) and cover:
//   a. active recently -> drives as before (Dispatcher consulted).
//   b. past the dormant bound -> NOT driven (no dispatch, no nudge); the
//      `drive.skipped reason=session_dormant` decision is observable in the trace.
//   c. after dormant, a fresh real event -> the next tick drives again (dormancy
//      clears on real activity; no sticky state).
//   d. a long-running but ACTIVE session (events keep arriving) is never dormant.

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class DormantSessionDriveTests: XCTestCase {

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]

    override func setUp() async throws {
        try await super.setUp()
        try await Task.sleep(nanoseconds: 100_000_000)
        Self.canned.removeAll()
    }
    override func tearDown() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        try await super.tearDown()
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [DormantMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// A canned record_triage idle response that fires worker_idle_post_completion
    /// so evaluateIdle reaches the idle dispatcher branch (and thus the Dispatcher).
    private static func idleFireResponse() -> Data {
        let candidate: [String: Any] = [
            "category": "worker_idle_post_completion",
            "severity": "medium",
            "matched_command": "(idle) stop-shape: ready for next",
            "recommended_action": "continue",
            "reasoning_plain": "Worker idle; evaluating the loop.",
            "reasoning_technical": "idle fire for the dormant-gate drive control.",
            "confidence": "low",
            "next_task_proposal": "",
        ]
        let body: [String: Any] = [
            "id": "msg_idle", "type": "message", "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [["type": "tool_use", "id": "toolu_idle", "name": "record_triage",
                         "input": ["candidates": [candidate]]]],
            "stop_reason": "tool_use", "stop_sequence": NSNull(),
            "usage": ["input_tokens": 600, "output_tokens": 100],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Mocks (mirrors StallWatchdogEngineTests)

    final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ initial: Date) { _now = initial }
        var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
        func advance(by s: TimeInterval) { lock.lock(); _now = _now.addingTimeInterval(s); lock.unlock() }
    }

    final class CapturingInjector: Injector, @unchecked Sendable {
        private let lock = NSLock()
        private var _texts: [String] = []
        var texts: [String] { lock.lock(); defer { lock.unlock() }; return _texts }
        func inject(text: String, claudeCodePID: pid_t, targetWindowTitle: String? = nil) async throws -> Int {
            lock.lock(); _texts.append(text); lock.unlock(); return text.utf8.count
        }
    }

    final class MockNotifier: Notifying, @unchecked Sendable {
        func post(decision: TriageDecision) async -> Notifier.Outcome { .posted }
        func postInterventionResult(decision: TriageDecision, outcome: InterventionOutcome) async -> Notifier.Outcome { .posted }
    }

    struct ConfirmedLocator: ProcessLocator {
        let handle: ProcessHandle
        func locate(targetCwd: String) -> ProcessHandle? { handle }
        func locate(bySessionId: String) -> ProcessHandle? { handle }
    }

    final class SpyDispatcher: Dispatching, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func dispatchForIdleSession(sessionUUID: String, cwd: String?, gitBranch: String?, lastNTurns: [SupervisorEvent], priorDispatchesConsidered: Int) async -> DispatchResult {
            lock.lock(); _calls += 1; lock.unlock()
            return .lowConfidence(reasoning: "spy")
        }
    }

    final class StubHumanActivityProbe: HumanActivityProbe, @unchecked Sendable {
        func secondsSinceLastKeystroke() -> TimeInterval { 999 }
    }

    // MARK: - Fixtures

    /// A transcript with NO async work -> scanner reports nothing outstanding, so
    /// the short-idle drive is not suppressed by the watchdog (it can only be
    /// suppressed by the dormant gate under test).
    private func writeHealthyTranscript() throws -> URL {
        let line: [String: Any] = [
            "type": "assistant", "sessionId": "s", "uuid": "u-text", "timestamp": "2026-06-26T10:00:00.000Z",
            "message": ["model": "claude-opus-4-8", "content": [["type": "text", "text": "all done"]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: line)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dormant-healthy-\(UUID().uuidString).jsonl")
        try (String(data: data, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A transcript with an UNPAIRED background-Bash launch -> scanner reports
    /// outstanding async work, so the watchdog WOULD nudge once past the interval.
    /// Used to prove the dormant gate suppresses the nudge too.
    private func writeOutstandingTranscript(model: String = "claude-haiku-4-5-20251001") throws -> URL {
        let line: [String: Any] = [
            "type": "assistant", "sessionId": "s", "uuid": "u-bg", "timestamp": "2026-06-26T10:00:00.000Z",
            "message": ["model": model, "content": [[
                "type": "tool_use", "id": "bg-1", "name": "Bash",
                "input": ["command": "long_running_thing", "run_in_background": true]]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: line)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dormant-outstanding-\(UUID().uuidString).jsonl")
        try (String(data: data, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Engine wiring

    private struct Wired {
        let engine: TriageEngine
        let bus: EventBus
        let injector: CapturingInjector
        let dispatcher: SpyDispatcher
    }

    /// `dormantSeconds` is small so the tests run fast; the gate logic is identical
    /// to production. `transcript` is the fixture the injected scanner resolves.
    private func makeEngine(clock: ClockBox, transcript: URL?, dormantSeconds: TimeInterval = 3600) -> Wired {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("dormant-bus-\(UUID().uuidString).log")))
        let ledger = InjectionLedger()
        let injector = CapturingInjector()
        let dispatcher = SpyDispatcher()
        let router = InterventionRouter(
            notifier: MockNotifier(),
            locator: ConfirmedLocator(handle: ProcessHandle(pid: 4242, execPath: "/usr/local/bin/claude", cwd: "/Users/test/supervisor")),
            signalSender: DarwinSignalSender(),
            injector: injector,
            humanActivity: StubHumanActivityProbe(),
            injectionLedger: ledger,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("dormant-router-\(UUID().uuidString).log")))

        let scanner = AsyncWorkScanner(transcriptURL: { _ in transcript })

        let engine = TriageEngine(
            client: LLMClient(
                provider: .anthropic, apiKey: "sk-ant-test", redactor: DefaultRedactor(),
                baseURL: URL(string: "https://mock.anthropic.test")!, session: mockSession(),
                traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                    .appendingPathComponent("dormant-client-\(UUID().uuidString).log"))),
            bus: bus, model: "claude-haiku-4-5-20251001", windowSize: 30, costStore: nil,
            dispatcher: dispatcher,
            plannerEnabled: { false },
            autoDispatchDisabledRead: { false },
            asyncWorkScanner: scanner,
            watchdogEnabledRead: { true },
            idleThresholdSeconds: 15,
            idleCheckIntervalSeconds: 3600,  // park the timer; we drive checkIdleStates by hand
            dormantSessionSilenceSeconds: dormantSeconds,
            injectionLedger: ledger,
            now: { clock.now })
        engine.onDecision = { d in Task { @MainActor in await router.dispatch(decision: d) } }
        engine.start()
        return Wired(engine: engine, bus: bus, injector: injector, dispatcher: dispatcher)
    }

    /// sessionStart + a stop-shaped assistant message so the session has a tracked
    /// idle state, a cwd for targeting, and a `lastEventTs` to age off of.
    private func seedStoppedSession(_ w: Wired, _ clock: ClockBox, sessionId: String) async throws {
        w.bus.publish(.sessionStart(.init(
            sessionId: sessionId, cwd: "/Users/test/supervisor", gitBranch: "autonomous-x",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: clock.now)))
        clock.advance(by: 1)
        w.bus.publish(.assistantText(.init(
            sessionId: sessionId, text: "All set; ready for the next task.", turnUUID: "u-stop", ts: clock.now)))
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - a. Active recently -> drives as before

    func testRecentlyActiveSessionStillDrives() async throws {
        Self.canned["/v1/messages"] = (200, Self.idleFireResponse(), [:])
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeHealthyTranscript()
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript, dormantSeconds: 3600)
        defer { w.engine.stop() }
        try await seedStoppedSession(w, clock, sessionId: "sess-active")

        // Past the 15s short-idle floor but WELL under the 1h dormant bound.
        clock.advance(by: 5 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(w.dispatcher.calls, 1,
                       "a recently-active idle session drives exactly as before the gate")
    }

    // MARK: - b. Past the dormant bound -> NOT driven (no dispatch, no nudge)

    func testDormantSessionIsNotDriven() async throws {
        // Canned to FIRE if the drive path were reached; the assertion is that it
        // is NOT reached. Outstanding transcript so the watchdog WOULD nudge too -
        // proving the gate suppresses both the drive AND the nudge.
        Self.canned["/v1/messages"] = (200, Self.idleFireResponse(), [:])
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript()  // 20m haiku interval
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript, dormantSeconds: 3600)
        defer { w.engine.stop() }
        try await seedStoppedSession(w, clock, sessionId: "sess-dormant")

        // Age past BOTH the 1h dormant bound and the 20m watchdog interval.
        clock.advance(by: 90 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(w.dispatcher.calls, 0,
                       "a dormant session is NOT auto-driven (no idle dispatch)")
        XCTAssertTrue(w.injector.texts.isEmpty,
                      "a dormant session gets NO watchdog check-in nudge either")
    }

    // MARK: - c. After dormant, a fresh real event -> next tick drives again

    func testFreshEventClearsDormancyAndResumesDrive() async throws {
        Self.canned["/v1/messages"] = (200, Self.idleFireResponse(), [:])
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeHealthyTranscript()
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript, dormantSeconds: 3600)
        defer { w.engine.stop() }
        try await seedStoppedSession(w, clock, sessionId: "sess-resume")

        // Go dormant: no drive.
        clock.advance(by: 90 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(w.dispatcher.calls, 0, "dormant: not driven")

        // The worker produces a REAL event (lastEventTs refreshes -> not dormant).
        w.bus.publish(.assistantText(.init(
            sessionId: "sess-resume", text: "Back at it; finished the next chunk.", turnUUID: "u-back", ts: clock.now)))
        try await Task.sleep(nanoseconds: 150_000_000)

        // A normal short idle later, the very next tick drives again.
        clock.advance(by: 5 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(w.dispatcher.calls, 1,
                       "a fresh real event clears dormancy; the next tick drives again (no sticky state)")
    }

    // MARK: - d. Long-running but ACTIVE session is never dormant

    func testLongRunningActiveSessionNeverDormant() async throws {
        Self.canned["/v1/messages"] = (200, Self.idleFireResponse(), [:])
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeHealthyTranscript()
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript, dormantSeconds: 3600)
        defer { w.engine.stop() }
        let sid = "sess-longrun"
        try await seedStoppedSession(w, clock, sessionId: sid)

        // Simulate a long session that keeps producing events, each well within the
        // dormant bound. Total elapsed (~4 * 50m = 200m) far exceeds the 1h bound,
        // but no single gap does, so it is never dormant and keeps driving.
        var expectedDrives = 0
        for i in 0..<4 {
            // A real worker tool call keeps lastEventTs fresh (and clears stop-shape).
            w.bus.publish(.bashToolCall(.init(
                sessionId: sid, command: "step \(i)", description: nil,
                toolUseId: "tc-\(i)", turnUUID: "u-tc-\(i)", ts: clock.now)))
            try await Task.sleep(nanoseconds: 100_000_000)
            // Then a stop-shape so the idle path is eligible.
            w.bus.publish(.assistantText(.init(
                sessionId: sid, text: "Done step \(i); ready for next.", turnUUID: "u-stop-\(i)", ts: clock.now)))
            try await Task.sleep(nanoseconds: 100_000_000)

            // Idle 50 minutes (under the 60m dormant bound) then tick.
            clock.advance(by: 50 * 60)
            w.engine.checkIdleStates()
            try await Task.sleep(nanoseconds: 500_000_000)
            expectedDrives += 1
            XCTAssertEqual(w.dispatcher.calls, expectedDrives,
                           "iteration \(i): an active long-running session is never treated as dormant")
        }
    }
}

/// Serves DormantSessionDriveTests.canned responses for the idle LLM call.
private final class DormantMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = DormantSessionDriveTests.canned[path] else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
