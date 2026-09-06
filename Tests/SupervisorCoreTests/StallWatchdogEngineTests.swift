// StallWatchdogEngineTests.swift
//
// v0.2.0 M7 - engine-level integration for the background-task / stall watchdog.
// Drives the FULL tick path: TriageEngine.checkIdleStates -> runWatchdogPass ->
// (AsyncWorkScanner over a fixture transcript) -> StallWatchdog -> onDecision ->
// InterventionRouter -> injector / notifier. NO network: the watchdog's nudge +
// escalation are SYNTHETIC decisions (no LLM call), so these tests need no canned
// model response at all - only the bus, a real router, and a fixture JSONL the
// injected scanner points at.
//
// Covered properties:
//   - Trigger: outstanding async work + silence past the interval -> a nudge.
//   - CLEAN + LEDGERED: the nudge arrives at the injector with NO in-text
//     banner (no-stamp decision) AND is recorded in the InjectionLedger, so the
//     triage recognizes it as Supervisor's own via the ledger.
//   - The nudge text is the spec copy ("Checking in: ...").
//   - Movement resets the cycle: a worker tool call after a nudge zeroes the
//     count, so a fresh stall nudges again from 1 rather than escalating.
//   - 3 nudges -> escalate: a notify banner is posted and NO further nudge is
//     injected on later ticks (until movement).
//   - DEFAULT ON: with no disable marker the watchdog is active.
//   - Disable marker turns it off (no nudge).
//   - Global pause suppresses it (no nudge).
//   - Short-idle drive is SUPPRESSED while async work is outstanding: the wired
//     Dispatcher is NOT called.
//   - Model-aware interval is honored: a slow-model interval does not fire where
//     the default would, and a fast-model interval fires sooner.

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class StallWatchdogEngineTests: XCTestCase {

    /// Canned HTTP responses for the idle-evaluation LLM call (keyed by path). The
    /// watchdog itself makes NO LLM call, but the SHORT-IDLE drive path does
    /// (evaluateIdle), and the healthy-session control asserts that path is
    /// reachable when there is no outstanding async work. Sessions that only
    /// exercise the watchdog never depend on this.
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
        cfg.protocolClasses = [WatchdogMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// A canned record_triage idle response that fires worker_idle_post_completion
    /// (so evaluateIdle enters the idle dispatcher branch).
    private static func idleFireResponse() -> Data {
        let candidate: [String: Any] = [
            "category": "worker_idle_post_completion",
            "severity": "medium",
            "matched_command": "(idle) stop-shape: ready for next",
            "recommended_action": "continue",
            "reasoning_plain": "Worker idle; evaluating the loop.",
            "reasoning_technical": "idle fire for the watchdog suppression control.",
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

    // MARK: - Mocks

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
        private let lock = NSLock()
        private var _outcomes: [InterventionOutcome] = []
        var outcomes: [InterventionOutcome] { lock.lock(); defer { lock.unlock() }; return _outcomes }
        func post(decision: TriageDecision) async -> Notifier.Outcome { .posted }
        func postInterventionResult(decision: TriageDecision, outcome: InterventionOutcome) async -> Notifier.Outcome {
            lock.lock(); _outcomes.append(outcome); lock.unlock(); return .posted
        }
    }

    struct ConfirmedLocator: ProcessLocator {
        let handle: ProcessHandle
        func locate(targetCwd: String) -> ProcessHandle? { handle }
        func locate(bySessionId: String) -> ProcessHandle? { handle }
    }

    final class SpyDispatcher: Dispatching, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        func dispatchForIdleSession(sessionUUID: String, cwd: String?, gitBranch: String?, lastNTurns: [SupervisorEvent], priorDispatchesConsidered: Int) async -> DispatchResult {
            lock.lock(); calls += 1; lock.unlock()
            return .lowConfidence(reasoning: "spy")
        }
    }

    final class StubHumanActivityProbe: HumanActivityProbe, @unchecked Sendable {
        let idle: TimeInterval
        init(idleSeconds: TimeInterval) { idle = idleSeconds }
        func secondsSinceLastKeystroke() -> TimeInterval { idle }
    }

    // MARK: - Fixture transcript helpers

    /// Write a transcript JSONL containing an UNPAIRED background-Bash launch (so
    /// the scanner reports outstanding async work). Returns the file URL.
    private func writeOutstandingTranscript(model: String = "claude-opus-4-8") throws -> URL {
        let line: [String: Any] = [
            "type": "assistant", "sessionId": "s", "uuid": "u-bg", "timestamp": "2026-06-26T10:00:00.000Z",
            "message": ["model": model, "content": [[
                "type": "tool_use", "id": "bg-1", "name": "Bash",
                "input": ["command": "long_running_thing", "run_in_background": true]]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: line)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-fixture-\(UUID().uuidString).jsonl")
        try (String(data: data, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A transcript with NO async work (text only) -> scanner reports nothing
    /// outstanding (used for the no-suppression / healthy-session control).
    private func writeHealthyTranscript() throws -> URL {
        let line: [String: Any] = [
            "type": "assistant", "sessionId": "s", "uuid": "u-text", "timestamp": "2026-06-26T10:00:00.000Z",
            "message": ["model": "claude-opus-4-8", "content": [["type": "text", "text": "all done"]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: line)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-healthy-\(UUID().uuidString).jsonl")
        try (String(data: data, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Engine wiring

    private struct Wired {
        let engine: TriageEngine
        let bus: EventBus
        let injector: CapturingInjector
        let notifier: MockNotifier
        let ledger: InjectionLedger
        let dispatcher: SpyDispatcher
        /// The engine's own trace log, on a temp path, so a test can read it back
        /// and count emitted lines (e.g. the once-per-episode SUPPRESSED line).
        let trace: TraceLog
    }

    /// Build a wired engine. `transcript` is the fixture the injected scanner
    /// resolves for ANY session id. `policy` controls the interval. `enabledRead`
    /// drives the default-on/disable gate hermetically (no real marker).
    /// `pausedRead` drives the global-pause gate the same way — the default is
    /// "not paused" so no test here depends on (or touches) the REAL
    /// supervisor-paused.marker under ~/Library the running app reads.
    private func makeEngine(
        clock: ClockBox,
        transcript: URL?,
        policy: WatchdogPolicy = WatchdogPolicy(),
        watchdog: StallWatchdog = StallWatchdog(),
        enabledRead: @escaping @Sendable () -> Bool = { true },
        pausedRead: @escaping @Sendable () -> Bool = { false }
    ) -> Wired {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-bus-\(UUID().uuidString).log")))
        let ledger = InjectionLedger()
        let injector = CapturingInjector()
        let notifier = MockNotifier()
        let dispatcher = SpyDispatcher()
        let router = InterventionRouter(
            notifier: notifier,
            locator: ConfirmedLocator(handle: ProcessHandle(pid: 4242, execPath: "/usr/local/bin/claude", cwd: "/Users/test/supervisor")),
            signalSender: DarwinSignalSender(),
            injector: injector,
            humanActivity: StubHumanActivityProbe(idleSeconds: 999),
            injectionLedger: ledger,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("wd-router-\(UUID().uuidString).log")))

        let scanner = AsyncWorkScanner(transcriptURL: { _ in transcript })

        // The engine's own trace log, on a temp path, so the log-cadence tests can
        // read it back and count the SUPPRESSED / RESUMED lines.
        let engineTrace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-engine-\(UUID().uuidString).log"))

        let engine = TriageEngine(
            client: LLMClient(
                provider: .anthropic, apiKey: "sk-ant-test", redactor: DefaultRedactor(),
                baseURL: URL(string: "https://mock.anthropic.test")!, session: mockSession(),
                traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                    .appendingPathComponent("wd-client-\(UUID().uuidString).log"))),
            bus: bus, model: "claude-haiku-4-5-20251001", windowSize: 30, costStore: nil,
            dispatcher: dispatcher,
            // Park the planner gate OFF so the dispatcher path is the short-idle
            // drive we assert gets suppressed.
            plannerEnabled: { false },
            autoDispatchDisabledRead: { false },
            supervisorPausedRead: pausedRead,
            stallWatchdog: watchdog,
            watchdogPolicy: policy,
            asyncWorkScanner: scanner,
            watchdogEnabledRead: enabledRead,
            idleThresholdSeconds: 15,
            idleCheckIntervalSeconds: 3600,  // park the timer; we drive checkIdleStates
            injectionLedger: ledger,
            now: { clock.now },
            trace: engineTrace)
        engine.onDecision = { d in Task { @MainActor in await router.dispatch(decision: d) } }
        engine.start()
        return Wired(engine: engine, bus: bus, injector: injector, notifier: notifier, ledger: ledger, dispatcher: dispatcher, trace: engineTrace)
    }

    // MARK: - Waiting for the tick to land (2026-09-05)

    /// Wait until `condition` holds, polling every 20ms up to `timeout`.
    ///
    /// These tests drive `checkIdleStates()` synchronously but the nudge lands
    /// through an unstructured Task and the router, so every assertion below
    /// needs the work to have finished first. That used to be a flat
    /// `Task.sleep(300ms)`, which is generous on an idle machine and loses
    /// under full-suite contention: `testThreeNudgesThenEscalateAndStop` failed
    /// in CI with "nudge 2 injected: 1 != 2" and passed on its own. A poll is
    /// the same short wait when the machine is free and a longer one when it is
    /// busy, so the assertion reads settled state either way, and the fast case
    /// is now FASTER than the old fixed sleep rather than slower.
    ///
    /// Returns quietly on timeout: the assertion that follows is what reports
    /// the failure, with the message that explains what was expected.
    private func poll(
        until condition: @MainActor () -> Bool,
        timeout: TimeInterval = 5.0
    ) async {
        // Wall clock on purpose. The ClockBox the tests advance is the engine's
        // notion of time, not this deadline's.
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The common case: wait for the injector to hold at least `count` nudges.
    /// `>=` rather than `==` so an over-fire is caught by the assertion after
    /// the poll instead of being hidden by a poll that never settles.
    private func pollInjected(_ w: Wired, count: Int) async {
        await poll(until: { w.injector.texts.count >= count })
    }

    /// Count how many lines in the engine trace contain `needle`.
    private func traceLineCount(_ w: Wired, containing needle: String) -> Int {
        w.trace.sync()
        guard let contents = try? String(contentsOf: w.trace.path, encoding: .utf8) else { return 0 }
        return contents.split(separator: "\n").filter { $0.contains(needle) }.count
    }

    /// Publish a sessionStart + a stop-shaped assistant message so the session has
    /// a tracked idle state and a cwd for targeting.
    private func seedStoppedSession(_ w: Wired, _ clock: ClockBox, sessionId: String) async throws {
        w.bus.publish(.sessionStart(.init(
            sessionId: sessionId, cwd: "/Users/test/supervisor", gitBranch: "autonomous-x",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: clock.now)))
        clock.advance(by: 1)
        w.bus.publish(.assistantText(.init(
            sessionId: sessionId, text: "Kicked off the background task.", turnUUID: "u-stop", ts: clock.now)))
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - Trigger + marked/ledgered

    func testStallNudgeIsMarkedAndLedgered() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript(model: "claude-haiku-4-5-20251001")  // 20m interval
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript)
        defer { w.engine.stop() }
        let sid = "sess-nudge"
        try await seedStoppedSession(w, clock, sessionId: sid)

        // Advance past the 20m haiku interval and tick.
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        await pollInjected(w, count: 1)

        XCTAssertEqual(w.injector.texts.count, 1, "exactly one check-in nudge injected")
        let injected = try XCTUnwrap(w.injector.texts.first)
        XCTAssertFalse(injected.contains("SUPERVISOR"),
                       "no-stamp decision: the watchdog nudge reads clean (no banner)")
        XCTAssertTrue(injected.contains("Checking in:"),
                      "the nudge carries the spec check-in copy")
        XCTAssertTrue(injected.contains("background task or your sub-agents"),
                      "the nudge probes the background task / sub-agents")
        XCTAssertGreaterThan(w.ledger.entryCount(sessionId: sid), 0,
                             "the nudge must be recorded in the InjectionLedger")
        XCTAssertTrue(w.ledger.isSupervisorInjected(sessionId: sid, text: injected, asOf: Date().addingTimeInterval(1)),
                      "the ledger recognizes the nudge as Supervisor's own")
    }

    // MARK: - Movement resets the cycle

    func testMovementResetsNudgeCount() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript(model: "claude-haiku-4-5-20251001")  // 20m
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript)
        defer { w.engine.stop() }
        let sid = "sess-move"
        try await seedStoppedSession(w, clock, sessionId: sid)

        // First stall -> nudge 1.
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        await pollInjected(w, count: 1)
        XCTAssertEqual(w.injector.texts.count, 1, "nudge 1 fired")

        // Worker MOVES (a real tool call) -> resets the cycle.
        w.bus.publish(.bashToolCall(.init(
            sessionId: sid, command: "echo progress", description: nil,
            toolUseId: "tc-1", turnUUID: "u-tc", ts: clock.now)))
        try await Task.sleep(nanoseconds: 150_000_000)

        // Another full stall -> should be nudge 1 again (NOT 2), proving the reset.
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        await pollInjected(w, count: 2)
        XCTAssertEqual(w.injector.texts.count, 2, "a second nudge fired after the reset")
        // Both injects are the first-of-a-stall nudge (count shown as 1 of 3 in the
        // reasoning is internal; here we simply assert it nudged rather than skipped
        // or escalated - escalation would have posted a notify with no inject).
        XCTAssertTrue(w.notifier.outcomes.allSatisfy { if case .notifyOnly = $0 { return false } else { return true } } ||
                      w.notifier.outcomes.isEmpty,
                      "movement-reset path nudges; it does not escalate")
    }

    // MARK: - 3 nudges then escalate, no further nudge

    func testThreeNudgesThenEscalateAndStop() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript(model: "claude-haiku-4-5-20251001")  // 20m
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript)
        defer { w.engine.stop() }
        let sid = "sess-escalate"
        try await seedStoppedSession(w, clock, sessionId: sid)

        // Three successive stall intervals with NO movement -> 3 nudges. We must
        // NOT publish a real event between ticks (that would reset/refresh state);
        // instead advance the clock so each tick is a fresh interval of silence.
        // The watchdog stamps lastNudgeTime but the cycle key is nudgeCount, which
        // only the assess() result bumps, so each tick past the interval nudges.
        for i in 0..<3 {
            clock.advance(by: 21 * 60)
            w.engine.checkIdleStates()
            await pollInjected(w, count: i + 1)
            XCTAssertEqual(w.injector.texts.count, i + 1, "nudge \(i + 1) injected")
        }

        // Fourth tick: nudgeCount is now 3 (== cap) -> ESCALATE, not a 4th nudge.
        // The escalation is the .notifyOnly outcome (a nudge posts a non-
        // .notifyOnly one, so `outcomes` is already non-empty), and it is the
        // thing to wait FOR here. Waiting on it also settles the "no 4th nudge"
        // assertion: by the time the escalation has landed, a nudge from the
        // same tick would have landed too.
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        await poll(until: {
            w.notifier.outcomes.contains { if case .notifyOnly = $0 { return true } else { return false } }
        })
        XCTAssertEqual(w.injector.texts.count, 3, "no 4th nudge: the watchdog escalated instead")
        XCTAssertFalse(w.notifier.outcomes.isEmpty, "escalation posts a notify banner")

        // Fifth tick: still stalled, already escalated -> HOLD (no nudge, no second notify).
        let notifyCountAfterEscalate = w.notifier.outcomes.count
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        // Nothing to poll FOR: this asserts an absence, and a poll would return
        // on the first empty read rather than proving the tick produced nothing.
        // A fixed settle is the correct wait for a negative.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(w.injector.texts.count, 3, "still no further nudge after escalation")
        XCTAssertEqual(w.notifier.outcomes.count, notifyCountAfterEscalate,
                       "no repeat escalation notify while holding")
    }

    // MARK: - FIX 7: nudge cadence is enforced across rapid ticks

    /// The pure StallWatchdog does not know when the last nudge was sent, so at 1Hz
    /// a stalled session would get all 3 nudges + the escalate dumped within a few
    /// ticks (~3s). FIX 7 gates BOTH on lastNudgeTime + the interval. This fires the
    /// first nudge, then ticks 5 MORE times WITHOUT advancing the clock (the 1Hz
    /// production cadence) and asserts NO second nudge and NO escalation are dumped -
    /// only after a full interval elapses does the next nudge fire.
    func testNudgeCadenceHoldsAcrossRapidTicks() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript(model: "claude-haiku-4-5-20251001")  // 20m interval
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript)
        defer { w.engine.stop() }
        let sid = "sess-cadence"
        try await seedStoppedSession(w, clock, sessionId: sid)

        // First stall interval -> nudge 1.
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        await pollInjected(w, count: 1)
        XCTAssertEqual(w.injector.texts.count, 1, "nudge 1 fired after the first interval")

        // Now hammer checkIdleStates at ~1Hz WITHOUT advancing a full interval.
        for _ in 0..<5 {
            clock.advance(by: 1)  // 1s ticks, far below the 20m interval
            w.engine.checkIdleStates()
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        XCTAssertEqual(w.injector.texts.count, 1, "FIX 7: no second nudge is dumped within the interval")
        // A check-in nudge itself posts a (non-.notifyOnly) intervention result, so
        // `outcomes` is not empty after nudge 1. An ESCALATION is the .notifyOnly
        // outcome (router.postNotify); assert NONE appeared within the interval.
        XCTAssertFalse(w.notifier.outcomes.contains { if case .notifyOnly = $0 { return true } else { return false } },
                       "FIX 7: no premature escalation (notifyOnly) within the interval")

        // Once a full interval elapses since the last nudge, the next nudge fires.
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        await pollInjected(w, count: 2)
        XCTAssertEqual(w.injector.texts.count, 2, "the second nudge fires only after a full interval")
    }

    // MARK: - Default-on, disable marker, paused

    func testDefaultOnFiresWithNoMarker() async throws {
        // enabledRead defaults to { true } here, modeling "no disable marker".
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript(model: "claude-haiku-4-5-20251001")
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript, enabledRead: { true })
        defer { w.engine.stop() }
        let sid = "sess-default-on"
        try await seedStoppedSession(w, clock, sessionId: sid)
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        await pollInjected(w, count: 1)
        XCTAssertEqual(w.injector.texts.count, 1, "default-on (no marker): the watchdog nudges")
    }

    func testDisableMarkerTurnsItOff() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript(model: "claude-haiku-4-5-20251001")
        defer { try? FileManager.default.removeItem(at: transcript) }
        // enabledRead { false } models the watchdog-disabled.marker being present.
        let w = makeEngine(clock: clock, transcript: transcript, enabledRead: { false })
        defer { w.engine.stop() }
        let sid = "sess-disabled"
        try await seedStoppedSession(w, clock, sessionId: sid)
        clock.advance(by: 60 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(w.injector.texts.isEmpty, "disable marker present: NO nudge")
    }

    func testPausedSuppressesWatchdog() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript(model: "claude-haiku-4-5-20251001")
        defer { try? FileManager.default.removeItem(at: transcript) }
        // ISOLATED pause-marker dir (RuntimeToggles test seam): engaging the
        // pause here must never write the REAL ~/Library marker — that would
        // pause the live app for the duration of the test, and the cleanup
        // below would delete an owner-engaged pause on the way out.
        let pauseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-pause-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pauseDir) }
        let w = makeEngine(clock: clock, transcript: transcript, enabledRead: { true },
                           pausedRead: { RuntimeToggles.supervisorPaused(dir: pauseDir) })
        defer { w.engine.stop() }
        let sid = "sess-paused"
        try await seedStoppedSession(w, clock, sessionId: sid)

        // Engage the GLOBAL pause marker (temp-dir seam) for this tick.
        RuntimeToggles.setSupervisorPaused(true, dir: pauseDir)
        defer { RuntimeToggles.setSupervisorPaused(false, dir: pauseDir) }
        clock.advance(by: 60 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(w.injector.texts.isEmpty, "globally paused: the watchdog nudges nothing")
    }

    // MARK: - Short-idle drive suppression

    func testShortIdleDriveSuppressedWhileAsyncWorkOutstanding() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript(model: "claude-opus-4-8")  // 45m interval (won't nudge at 30m)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript)
        defer { w.engine.stop() }
        let sid = "sess-suppress"
        try await seedStoppedSession(w, clock, sessionId: sid)

        // Past the 15s short-idle floor (so the dispatch walk WOULD fire) but well
        // under the 45m watchdog interval (so no nudge yet). Async work is
        // outstanding -> the dispatch must be SUPPRESSED.
        clock.advance(by: 5 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(w.dispatcher.calls, 0,
                       "the short-idle drive must be suppressed while async work is outstanding")
        XCTAssertTrue(w.injector.texts.isEmpty, "no nudge yet either (under the model-aware interval)")
    }

    func testHealthySessionNotSuppressed() async throws {
        // A session with NO outstanding async work runs the normal short-idle
        // drive (the Dispatcher IS consulted) - the watchdog does not interfere.
        // The idle-evaluation LLM call is canned to fire so the drive reaches the
        // dispatcher; the contrast with the suppressed case (dispatcher calls == 0)
        // is what proves the suppression is scoped to outstanding async work.
        Self.canned["/v1/messages"] = (200, Self.idleFireResponse(), [:])
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeHealthyTranscript()
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript)
        defer { w.engine.stop() }
        let sid = "sess-healthy"
        try await seedStoppedSession(w, clock, sessionId: sid)

        clock.advance(by: 5 * 60)
        w.engine.checkIdleStates()
        // This path goes all the way through the canned LLM call, so it is the
        // slowest wait in the file and the one a fixed 800ms was least likely
        // to cover under load.
        await poll(until: { w.dispatcher.calls >= 1 })
        XCTAssertEqual(w.dispatcher.calls, 1,
                       "a healthy session (no outstanding async work) is NOT suppressed")
        XCTAssertTrue(w.injector.texts.isEmpty, "no watchdog nudge for a healthy session")
    }

    // MARK: - Log-cadence: SUPPRESSED is logged once per episode, not per tick

    func testSuppressionLoggedOncePerEpisodeAcrossTicks() async throws {
        // Busy-poll log-flood fix: with outstanding async work, many ticks past the
        // short-idle floor (but under the watchdog interval) must SUPPRESS the drive
        // every tick BUT emit the "short-idle drive SUPPRESSED" line only ONCE.
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript(model: "claude-opus-4-8")  // 45m interval (no nudge here)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript)
        defer { w.engine.stop() }
        let sid = "sess-log-once"
        try await seedStoppedSession(w, clock, sessionId: sid)

        // Cross the 15s short-idle floor, then tick 5 times at ~1s apart (the
        // production 1Hz cadence). Stay well under the 45m watchdog interval.
        clock.advance(by: 20)
        for _ in 0..<5 {
            w.engine.checkIdleStates()
            try await Task.sleep(nanoseconds: 120_000_000)
            clock.advance(by: 1)
        }

        // Wait for the FIRST line to reach the trace, then assert there is
        // exactly one. Polling for its arrival separates "the line has not been
        // written yet" from "the line was written twice", which a fixed sleep
        // conflates into the same failure.
        await poll(until: { traceLineCount(w, containing: "short-idle drive SUPPRESSED session=\(sid)") >= 1 })
        XCTAssertEqual(w.dispatcher.calls, 0,
                       "behavior unchanged: the drive stays suppressed every tick")
        XCTAssertEqual(traceLineCount(w, containing: "short-idle drive SUPPRESSED session=\(sid)"), 1,
                       "the SUPPRESSED line is logged ONCE per episode, not once per tick")
    }

    func testSuppressionRelogsOnNewEpisodeAfterClear() async throws {
        // After the suppressing condition clears (async work true->false) a LATER
        // suppression episode must log the SUPPRESSED line again (one per episode).
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let outstanding = try writeOutstandingTranscript(model: "claude-opus-4-8")
        let healthy = try writeHealthyTranscript()
        defer { try? FileManager.default.removeItem(at: outstanding) }
        defer { try? FileManager.default.removeItem(at: healthy) }

        // The scanner resolves whichever URL `currentTranscript` points at, so we
        // can flip a session between outstanding and cleared async work mid-test.
        final class TranscriptBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _url: URL
            init(_ u: URL) { _url = u }
            var url: URL { lock.lock(); defer { lock.unlock() }; return _url }
            func set(_ u: URL) { lock.lock(); _url = u; lock.unlock() }
        }
        let box = TranscriptBox(outstanding)

        // Build a bespoke wiring whose scanner reads `box` (the shared makeEngine
        // helper binds a single fixed transcript). Mirrors makeEngine's wiring.
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-bus-\(UUID().uuidString).log")))
        let ledger = InjectionLedger()
        let injector = CapturingInjector()
        let notifier = MockNotifier()
        let dispatcher = SpyDispatcher()
        let engineTrace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-engine-\(UUID().uuidString).log"))
        let router = InterventionRouter(
            notifier: notifier,
            locator: ConfirmedLocator(handle: ProcessHandle(pid: 4242, execPath: "/usr/local/bin/claude", cwd: "/Users/test/supervisor")),
            signalSender: DarwinSignalSender(),
            injector: injector,
            humanActivity: StubHumanActivityProbe(idleSeconds: 999),
            injectionLedger: ledger,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("wd-router-\(UUID().uuidString).log")))
        let scanner = AsyncWorkScanner(transcriptURL: { _ in box.url })
        let engine = TriageEngine(
            client: LLMClient(
                provider: .anthropic, apiKey: "sk-ant-test", redactor: DefaultRedactor(),
                baseURL: URL(string: "https://mock.anthropic.test")!, session: mockSession(),
                traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                    .appendingPathComponent("wd-client-\(UUID().uuidString).log"))),
            bus: bus, model: "claude-haiku-4-5-20251001", windowSize: 30, costStore: nil,
            dispatcher: dispatcher,
            plannerEnabled: { false },
            autoDispatchDisabledRead: { false },
            asyncWorkScanner: scanner,
            watchdogEnabledRead: { true },
            idleThresholdSeconds: 15,
            idleCheckIntervalSeconds: 3600,
            injectionLedger: ledger,
            now: { clock.now },
            trace: engineTrace)
        engine.onDecision = { d in Task { @MainActor in await router.dispatch(decision: d) } }
        engine.start()
        defer { engine.stop() }
        let w = Wired(engine: engine, bus: bus, injector: injector, notifier: notifier, ledger: ledger, dispatcher: dispatcher, trace: engineTrace)

        let sid = "sess-relog"
        try await seedStoppedSession(w, clock, sessionId: sid)

        // Episode 1: outstanding async work, a few quiet ticks -> one SUPPRESSED line.
        clock.advance(by: 20)
        for _ in 0..<3 {
            w.engine.checkIdleStates()
            try await Task.sleep(nanoseconds: 120_000_000)
            clock.advance(by: 1)
        }
        await poll(until: { traceLineCount(w, containing: "short-idle drive SUPPRESSED session=\(sid)") >= 1 })
        XCTAssertEqual(traceLineCount(w, containing: "short-idle drive SUPPRESSED session=\(sid)"), 1,
                       "episode 1 logs SUPPRESSED once")

        // Work CLEARS: point the scanner at the healthy transcript and tick. A real
        // event refreshes lastEventTs (so the session is briefly active, which clears
        // the outstanding flag + the suppression-log flag).
        box.set(healthy)
        w.bus.publish(.bashToolCall(.init(
            sessionId: sid, command: "echo done", description: nil,
            toolUseId: "tc-clear", turnUUID: "u-clear", ts: clock.now)))
        try await Task.sleep(nanoseconds: 150_000_000)
        w.engine.checkIdleStates()  // active tick clears asyncWorkOutstanding + the flag
        try await Task.sleep(nanoseconds: 120_000_000)

        // Episode 2: work resumes. New outstanding fixture, go quiet again.
        box.set(outstanding)
        // A fresh stop-shaped event so the session has a new idle baseline.
        w.bus.publish(.assistantText(.init(
            sessionId: sid, text: "Kicked off another background task.", turnUUID: "u-stop2", ts: clock.now)))
        try await Task.sleep(nanoseconds: 150_000_000)
        clock.advance(by: 20)
        for _ in 0..<3 {
            w.engine.checkIdleStates()
            try await Task.sleep(nanoseconds: 120_000_000)
            clock.advance(by: 1)
        }

        await poll(until: { traceLineCount(w, containing: "short-idle drive SUPPRESSED session=\(sid)") >= 2 })
        XCTAssertEqual(traceLineCount(w, containing: "short-idle drive SUPPRESSED session=\(sid)"), 2,
                       "a NEW suppression episode logs the SUPPRESSED line again (one per episode)")
    }

    // MARK: - Model-aware interval

    func testModelAwareIntervalHonored() async throws {
        // Opus -> 45m interval. At 31m of silence (past the 30m default but under
        // 45m) the watchdog must NOT fire, proving the model-aware interval is used
        // rather than the default.
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try writeOutstandingTranscript(model: "claude-opus-4-8")
        defer { try? FileManager.default.removeItem(at: transcript) }
        let w = makeEngine(clock: clock, transcript: transcript)
        defer { w.engine.stop() }
        let sid = "sess-model"
        try await seedStoppedSession(w, clock, sessionId: sid)

        clock.advance(by: 31 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(w.injector.texts.isEmpty,
                      "opus 45m interval: 31m silence does NOT fire (default 30m would have)")

        // Now cross 45m -> fires.
        clock.advance(by: 15 * 60)  // total 46m
        w.engine.checkIdleStates()
        await pollInjected(w, count: 1)
        XCTAssertEqual(w.injector.texts.count, 1, "past the opus 45m interval the watchdog nudges")
    }
}

/// Serves StallWatchdogEngineTests.canned responses for the (rare) idle LLM call.
private final class WatchdogMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = StallWatchdogEngineTests.canned[path] else {
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
