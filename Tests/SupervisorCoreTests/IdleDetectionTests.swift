// IdleDetectionTests.swift
//
// v0.4.0 Part A — tests for the timer-driven idle-detection path in
// TriageEngine. Mirrors TriageEngineTests' URLProtocol mock pattern so
// the engine's call into the LLM client is observable end-to-end; the
// engine's injected `now` closure lets each test drive its own clock.
//
// Acceptance set (per Mohammed's v0.4.0 Part A spec):
//   A4-1: idle detection fires after stop-shape + 15s of silence.
//   A4-2: no fire while events keep flowing (silence gate).
//   A4-3: a user message clears the stop-shape (rubric deference test for
//         the "recent user message" don't-fire condition exercised at the
//         engine state-machine level).
//   A4-4: a new tool_use clears the stop-shape (worker resumed).
//   A4-5: rubric returns no-fire (all-clear) → engine emits no decision —
//         covers the rubric-body responsibility for branch-name /
//         user_question_pending / hard-stop conditions (ED-4).
//
// Plus unit coverage of `detectStopShape(in:)` on the ED-3 phrase list.

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class IdleDetectionTests: XCTestCase {

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]
    // Capture every URL request the engine fires so tests can assert
    // whether an idle call was dispatched at all (timing gate tests need
    // "no call was made", not just "no flag was produced").
    nonisolated(unsafe) static var requestCount: Int = 0

    override func setUp() async throws {
        try await super.setUp()
        // Wait for any in-flight Tasks from the previous test to settle.
        // The idle path dispatches an unstructured `Task { await
        // self.evaluateIdle(sessionId:) }` whose HTTP call can outlive
        // the test that scheduled it; without this drain, that call's
        // requestCount bleeds into the NEXT test's counter via the
        // file-static `requestCount` the URLProtocol mock updates.
        try await Task.sleep(nanoseconds: 200_000_000)
        Self.canned.removeAll()
        Self.requestCount = 0
    }

    override func tearDown() async throws {
        // Symmetric drain: wait for this test's in-flight Tasks to
        // finish (HTTP calls scheduled by evaluateIdle / evaluateAssistantText)
        // before the next test resets `requestCount`. Pair with setUp's
        // pre-reset wait — both are needed because the engine holds the
        // URLSession alive after `stop()` cancels the bus subscription.
        try await Task.sleep(nanoseconds: 200_000_000)
        try await super.tearDown()
    }

    // MARK: - Harness

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [IdleMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// Tunable harness — each test picks its own clock + thresholds.
    /// The clock is a closure over a mutable `Date` so the test can
    /// advance time without `Task.sleep`. The background timer is
    /// effectively disabled (3600s interval) so tests can ONLY trigger
    /// idle checks via explicit `engine.checkIdleStates()` calls — this
    /// removes scheduler-interleaving flake from the assertions.
    private func makeEngine(
        clock: @escaping @MainActor () -> Date,
        idleThresholdSeconds: TimeInterval = 15,
        idleReTriageIntervalSeconds: TimeInterval = 60,
        idleCheckIntervalSeconds: TimeInterval = 3600
    ) -> (TriageEngine, EventBus, TriageEngineTests.CapturedDecisions) {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("idle-tests-\(UUID().uuidString).log")))
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("idle-client-\(UUID().uuidString).log"))
        )
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            idleThresholdSeconds: idleThresholdSeconds,
            idleReTriageIntervalSeconds: idleReTriageIntervalSeconds,
            idleCheckIntervalSeconds: idleCheckIntervalSeconds,
            now: clock
        )
        let captured = TriageEngineTests.CapturedDecisions()
        engine.onDecision = { d in captured.append(d) }
        engine.start()
        return (engine, bus, captured)
    }

    /// Canned Haiku response — fires worker_idle_post_completion with
    /// confidence=high and a next_task_proposal, so the engine emits a
    /// flag with action=continue.
    private static func haikuIdleFlagResponse(
        confidence: String = "high",
        action: String = "continue",
        nextTask: String = "Continue refactoring TriageEngine — Part B dispatcher."
    ) -> Data {
        let candidate: [String: Any] = [
            "category": "worker_idle_post_completion",
            "severity": "medium",
            "matched_command": "(idle) stop-shape: ready for next",
            "recommended_action": action,
            "reasoning_plain": "Claude Code finished its task and is idle. I'm proposing the next task so the autonomous loop keeps moving.",
            "reasoning_technical": "worker_idle_post_completion fired on stop_shape='ready for next' + 15s silence on autonomous branch with no pending user question.",
            "confidence": confidence,
            "next_task_proposal": nextTask,
        ]
        let body: [String: Any] = [
            "id": "msg_idle",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_idle",
                "name": "record_triage",
                "input": ["candidates": [candidate]],
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 600, "output_tokens": 100],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// Canned Haiku response — empty candidates. The rubric body
    /// decided not to fire (branch=main, user_question_pending pending,
    /// recent user message, etc.).
    private static func haikuAllClearResponse() -> Data {
        let body: [String: Any] = [
            "id": "msg_clear",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_clear",
                "name": "record_triage",
                "input": ["candidates": [] as [Any]],
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 580, "output_tokens": 10],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func publishAutonomousSessionStart(_ bus: EventBus, sessionId: String = "s-idle", branch: String = "autonomous-20260525T193906Z", at ts: Date) {
        bus.publish(.sessionStart(.init(
            sessionId: sessionId,
            cwd: "/Users/test/supervisor",
            gitBranch: branch,
            projectHash: "-tmp",
            jsonlPath: "/tmp/x.jsonl",
            ts: ts
        )))
    }

    // MARK: - A4-1: positive path

    func testIdleDetectionFiresAfterStopShapePlusFifteenSeconds() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuIdleFlagResponse(), [:])

        // Mutable clock — start at t0, advance manually in steps.
        let clockBox = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, captured) = makeEngine(clock: { clockBox.now })
        defer { engine.stop() }

        // t=0: session starts on an autonomous branch.
        publishAutonomousSessionStart(bus, at: clockBox.now)

        // t=1: assistant message with a stop-shaped phrase lands.
        clockBox.advance(by: 1)
        bus.publish(.assistantText(.init(
            sessionId: "s-idle",
            text: "All done — ready for next. Let me know if you want changes.",
            turnUUID: "u-stop",
            ts: clockBox.now
        )))

        // Give the engine a moment to process the event before we tick.
        try await Task.sleep(nanoseconds: 100_000_000)

        // t=16: 15s past the stop event. Idle check fires.
        clockBox.advance(by: 15)
        engine.checkIdleStates()

        try await captured.waitFor(count: 1, within: 3.0)
        let decision = try XCTUnwrap(captured.snapshot.first)
        XCTAssertEqual(decision.candidate.category, "worker_idle_post_completion")
        XCTAssertEqual(decision.candidate.action, .continue)
        XCTAssertEqual(decision.candidate.confidence, "high")
        XCTAssertEqual(decision.candidate.severity, .medium)
        XCTAssertEqual(decision.candidate.nextTaskProposal, "Continue refactoring TriageEngine — Part B dispatcher.")
        XCTAssertEqual(decision.cwd, "/Users/test/supervisor",
                       "decision.cwd must populate from sessionBranch+sessionCwd cache")
        XCTAssertEqual(Self.requestCount, 1, "engine should have dispatched exactly one idle triage call")
    }

    // MARK: - A4-2: silence gate — no fire while events flow

    func testIdleDetectionDoesNotFireWhileEventsStillFlowing() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuIdleFlagResponse(), [:])
        let clockBox = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, captured) = makeEngine(clock: { clockBox.now })
        defer { engine.stop() }

        publishAutonomousSessionStart(bus, at: clockBox.now)

        // Stop-shaped assistant message lands at t=1.
        clockBox.advance(by: 1)
        bus.publish(.assistantText(.init(
            sessionId: "s-idle",
            text: "All done — ready for next.",
            turnUUID: "u-stop-2",
            ts: clockBox.now
        )))

        // Then a stream of non-clearing events keeps the lastEventTs
        // moving forward. assistantText without a stop-phrase does NOT
        // clear lastStopShapedTs by design (multi-paragraph completions),
        // but it DOES move lastEventTs — so the silence gate stays shut.
        for i in 0..<10 {
            clockBox.advance(by: 2) // 2s between events
            bus.publish(.assistantText(.init(
                sessionId: "s-idle",
                text: "still talking #\(i)",
                turnUUID: "u-talk-\(i)",
                ts: clockBox.now
            )))
        }

        // 21s elapsed total, but only 2s of silence since the last event.
        // Idle check should NOT fire.
        try await Task.sleep(nanoseconds: 200_000_000)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(captured.snapshot.count, 0,
                       "idle check must not fire while events keep arriving")
        XCTAssertEqual(Self.requestCount, 0,
                       "engine must not even dispatch the idle call when silence threshold isn't met")
    }

    // MARK: - A4-3: a new userPrompt clears the stop-shape

    func testUserPromptClearsStopShape() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuIdleFlagResponse(), [:])
        let clockBox = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, captured) = makeEngine(clock: { clockBox.now })
        defer { engine.stop() }

        publishAutonomousSessionStart(bus, at: clockBox.now)

        // Stop-shape at t=1.
        clockBox.advance(by: 1)
        bus.publish(.assistantText(.init(
            sessionId: "s-idle",
            text: "Ship it. Ready for next.",
            turnUUID: "u-stop-3",
            ts: clockBox.now
        )))

        // User message at t=5 — must reset lastStopShapedTs to nil.
        clockBox.advance(by: 4)
        bus.publish(.userPrompt(.init(
            sessionId: "s-idle",
            text: "wait, also do X",
            ts: clockBox.now
        )))

        try await Task.sleep(nanoseconds: 100_000_000)

        // Even after another 20s of silence, the idle check should not
        // fire because the user just spoke.
        clockBox.advance(by: 20)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(captured.snapshot.count, 0,
                       "user prompt must clear stop-shape so idle check doesn't fire")
        XCTAssertEqual(Self.requestCount, 0)
    }

    // MARK: - A4-4: a new tool_use clears the stop-shape

    func testToolUseClearsStopShape() async throws {
        // All-clear response — the bash tool call will still trigger a
        // primary triage call (the engine evaluates every bashToolCall),
        // and we want that path to emit no flag so the assertion
        // ("no idle flag fired") can be unambiguous. If checkIdleStates
        // were to wrongly dispatch a triage call here, it'd ALSO hit
        // this all-clear path; the contract we're really testing is the
        // ENGINE STATE — that `lastStopShapedTs` was cleared by the
        // tool_use, so the timer's silence gate stays shut.
        Self.canned["/v1/messages"] = (200, Self.haikuAllClearResponse(), [:])
        let clockBox = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, captured) = makeEngine(clock: { clockBox.now })
        defer { engine.stop() }

        publishAutonomousSessionStart(bus, at: clockBox.now)

        // Stop-shape at t=1.
        clockBox.advance(by: 1)
        bus.publish(.assistantText(.init(
            sessionId: "s-idle",
            text: "Complete — let me know if you need changes.",
            turnUUID: "u-stop-4",
            ts: clockBox.now
        )))

        // Worker fires another bash tool call at t=3. Stop-shape is
        // cleared by updateIdleState's bashToolCall handler.
        clockBox.advance(by: 2)
        bus.publish(.bashToolCall(.init(
            sessionId: "s-idle",
            command: "ls /tmp",
            description: nil,
            toolUseId: "t-resumed",
            turnUUID: "u-resumed",
            ts: clockBox.now
        )))

        // Let consume + the bash-path triage settle.
        try await Task.sleep(nanoseconds: 300_000_000)
        let requestsAfterBashCall = Self.requestCount

        // 20s of silence after tool call. Stop-shape was cleared by the
        // tool call → idle check must not even DISPATCH (gate closed
        // because lastStopShapedTs is nil).
        clockBox.advance(by: 20)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(captured.snapshot.count, 0,
                       "tool_use must clear stop-shape so no flag fires anywhere; got: \(captured.snapshot.map { $0.candidate.category })")
        XCTAssertEqual(Self.requestCount, requestsAfterBashCall,
                       "checkIdleStates must not dispatch any new request after tool_use cleared the stop-shape")
    }

    // MARK: - A4-5: rubric returns all-clear

    func testIdleDetectionRespectsRubricNoFire() async throws {
        // The rubric body decides not to fire (e.g. branch != autonomous,
        // user_question_pending pending). The engine's job is to surface
        // the candidate to the rubric and respect the verdict — per ED-4
        // safety defers to the rubric. We canned an all-clear response
        // here; engine must emit no decision.
        Self.canned["/v1/messages"] = (200, Self.haikuAllClearResponse(), [:])
        let clockBox = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, captured) = makeEngine(clock: { clockBox.now })
        defer { engine.stop() }

        // Notice: branch=main here — the rubric body should reject this
        // on the non-autonomous-branch don't-fire condition. The engine
        // still asks the rubric (sends the idle call) because the engine
        // doesn't gate on branch-name — that's a rubric-body concern.
        publishAutonomousSessionStart(bus, sessionId: "s-main", branch: "main", at: clockBox.now)

        clockBox.advance(by: 1)
        bus.publish(.assistantText(.init(
            sessionId: "s-main",
            text: "All done — ready for next.",
            turnUUID: "u-stop-5",
            ts: clockBox.now
        )))

        try await Task.sleep(nanoseconds: 100_000_000)

        clockBox.advance(by: 15)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(captured.snapshot.count, 0,
                       "engine must emit no decision when the rubric body returns empty candidates")
        XCTAssertEqual(Self.requestCount, 1,
                       "but the engine MUST have asked the rubric — branch-name is a rubric-body responsibility, not an engine gate (ED-4)")
    }

    // MARK: - Background idle-loop liveness (honest-health engine-progress seam)

    /// The ONE test that intentionally runs the real `startIdleCheckLoop`
    /// background Task end-to-end (every other suite parks the interval at
    /// 3600s, passes runIdleLoop:false, or no-ops the recorder). It drives the
    /// loop with a SHORT interval and an injected recorder that (1) bumps an
    /// in-memory counter and (2) exercises the REAL EngineProgress writer
    /// against a TEMP-dir ConfigPaths — never the global token. Asserts:
    ///   (a) sleep-first: no tick fires at start — the count is 0 synchronously
    ///       after start() (the @MainActor loop Task cannot have run before we
    ///       suspend), and the FIRST observed tick lands at least ~one interval
    ///       after start (Task.sleep never undersleeps, so a slow CI runner can
    ///       only widen this gap, never shrink it below the interval).
    ///   (b) alive + recording: within a generous 5s deadline (expected
    ///       ~0.15-0.25s at a 50ms interval) the counter reaches >= 3 and the
    ///       temp engine-progress token exists and parses.
    ///   (c) stop() cancels: after engine.stop() the counter never advances
    ///       again (asserted across a 300ms wait, >= 6 intervals).
    func testBackgroundLoopSleepsFirstTicksWhileRunningAndStopsOnStop() async throws {
        // Temp-dir ConfigPaths: the injected recorder points the REAL writer
        // here, proving the seam composes with EngineProgress.recordTick(paths:)
        // without ever touching ~/Library/Application Support/Supervisor.
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("idle-loop-home-\(UUID().uuidString)", isDirectory: true)
        let tempPaths = ConfigPaths(home: tempHome)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let ticks = TickBox()
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("idle-loop-tests-\(UUID().uuidString).log")))
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("idle-loop-client-\(UUID().uuidString).log"))
        )
        let interval: TimeInterval = 0.05
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            // No sessions are ever published, so each loop cycle's
            // checkIdleStates() walks an empty map and dispatches nothing —
            // the cycles under test are pure timer ticks.
            idleThresholdSeconds: 9999,
            idleReTriageIntervalSeconds: 9999,
            idleCheckIntervalSeconds: interval,
            recordEngineProgress: {
                ticks.record(at: Date())
                _ = EngineProgress.recordTick(paths: tempPaths)
            }
        )

        let startedAt = Date()
        engine.start()

        // (a) sleep-first, part 1: no synchronous tick at start. We have not
        // suspended since start(), and the loop Task is @MainActor, so it
        // cannot have run yet — deterministic, cannot flake.
        XCTAssertEqual(ticks.count, 0,
                       "sleep-first: start() must not fire an immediate tick")

        // (b) loop alive: poll (generously — expected ~0.2s) until >= 3 ticks.
        let deadline = Date().addingTimeInterval(5.0)
        while ticks.count < 3 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(ticks.count, 3,
                                    "background loop must tick repeatedly (~every \(interval)s); got \(ticks.count) within 5s")

        // (a) sleep-first, part 2: the FIRST tick landed at least ~one interval
        // after start. Task.sleep(nanoseconds:) never returns early, so a slow
        // runner only increases this gap; 0.8x margin absorbs clock granularity.
        let firstTickAt = try XCTUnwrap(ticks.firstTickAt, "at least one tick was recorded above")
        XCTAssertGreaterThanOrEqual(firstTickAt.timeIntervalSince(startedAt), interval * 0.8,
                                    "sleep-first: the first tick must come AFTER one full interval of sleep, not immediately at start")

        // (b) recording: the injected recorder drove the REAL writer against the
        // temp paths — the token exists there and parses.
        let token = try HeartbeatFile(path: tempPaths.engineProgressPath).read()
        XCTAssertNotNil(token,
                        "the injected recorder must have stamped the TEMP engine-progress token via EngineProgress.recordTick(paths:)")

        // (c) stop() cancels the loop: no tick may land after stop(). stop()
        // runs on the MainActor the loop is isolated to, so no cycle can be
        // mid-flight while we snapshot; the loop's post-sleep cancellation
        // guards ensure the next wakeup breaks instead of ticking.
        engine.stop()
        let countAtStop = ticks.count
        try await Task.sleep(nanoseconds: 300_000_000)  // >= 6 intervals of headroom
        XCTAssertEqual(ticks.count, countAtStop,
                       "no tick may fire after stop() — cancellation must silence the loop")
    }

    // MARK: - detectWorkerStopped unit coverage

    func testDetectWorkerStoppedReturnsTrueForTextOnlyAssistant() {
        let events: [SupervisorEvent] = [
            .userPrompt(.init(sessionId: "s1", text: "do the thing", ts: Date())),
            .assistantText(.init(sessionId: "s1", text: "All done.", turnUUID: "u1", ts: Date())),
        ]
        XCTAssertTrue(TriageEngine.detectWorkerStopped(in: events))
    }

    func testDetectWorkerStoppedReturnsFalseWhenToolCallFollows() {
        let events: [SupervisorEvent] = [
            .assistantText(.init(sessionId: "s1", text: "Running tests.", turnUUID: "u1", ts: Date())),
            .bashToolCall(.init(sessionId: "s1", command: "swift test", description: nil, toolUseId: "t1", turnUUID: "u1", ts: Date())),
        ]
        XCTAssertFalse(TriageEngine.detectWorkerStopped(in: events))
    }

    func testDetectWorkerStoppedReturnsFalseForEmptyWindow() {
        XCTAssertFalse(TriageEngine.detectWorkerStopped(in: []))
    }
}

// MARK: - Tick-counter helper (background-loop liveness test)

/// MainActor-isolated tick counter for the injected engine-progress recorder —
/// the recorder closure is `@MainActor () -> Void`, so accesses are serialized
/// on the main actor (no locking needed). Records the first tick's wall-clock
/// time so the sleep-first property can be asserted as a latency lower bound.
@MainActor
final class TickBox {
    private(set) var count = 0
    private(set) var firstTickAt: Date?
    func record(at time: Date) {
        if count == 0 { firstTickAt = time }
        count += 1
    }
}

// MARK: - Mutable-clock helper

/// Small ref-typed clock so tests can advance time deterministically.
@MainActor
final class ClockBox {
    private(set) var now: Date
    init(initial: Date) { self.now = initial }
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

// MARK: - URLProtocol mock (counts requests for the silence-gate test)

private final class IdleMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        IdleDetectionTests.requestCount += 1
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = IdleDetectionTests.canned[path] else {
            let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable)
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
