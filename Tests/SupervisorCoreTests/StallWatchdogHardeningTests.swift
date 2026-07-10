// StallWatchdogHardeningTests.swift
//
// v0.2.0 M7 hardening - covers the two adversarial-review findings, with the
// safety invariants left untouched (still marked + ledgered, escalate-stops,
// default-on, never auto-kills - those stay asserted in StallWatchdogEngineTests).
//
// Finding 1a (caching): the watchdog must not re-read + re-parse a session's
// transcript on every 1Hz tick when the file has not changed. Two consecutive
// ticks over an UNCHANGED transcript parse exactly once; a tick after the file's
// size/mtime changes parses again.
//
// Finding 1b (pruning): a session that has gone silent past the stale-eviction
// bound is removed from the per-session watchdog maps on the next tick, so the
// maps cannot grow unbounded over a long run (there is no session-end event).
//
// Finding 2 (completion reset): a session that reached escalation (3 nudges, then
// stopped) whose outstanding async work then COMPLETES (the scanner flips
// outstanding true -> false) has its nudge count + escalate-hold cleared, so a
// later, separate stall starts fresh and nudges again rather than staying held.
//
// NO network: the watchdog's nudge/escalation are synthetic decisions. The one
// canned LLM path (short-idle drive) is never reached by these tests.

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class StallWatchdogHardeningTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    override func tearDown() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        try await super.tearDown()
    }

    // MARK: - Mocks (mirror StallWatchdogEngineTests)

    final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ initial: Date) { _now = initial }
        var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
        func advance(by s: TimeInterval) { lock.lock(); _now = _now.addingTimeInterval(s); lock.unlock() }
    }

    /// Thread-safe counter for AsyncWorkScanner.onScanParse - one tick of an
    /// actual tail-read + parse increments it; a cache hit does not.
    final class ParseCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _n }
        func bump() { lock.lock(); _n += 1; lock.unlock() }
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

    // MARK: - Transcript fixtures

    /// A single-line transcript carrying an UNPAIRED background-Bash launch (so the
    /// scanner reports outstanding async work). `model` drives the interval policy.
    private func outstandingLine(model: String) throws -> String {
        let line: [String: Any] = [
            "type": "assistant", "sessionId": "s", "uuid": "u-bg", "timestamp": "2026-06-26T10:00:00.000Z",
            "message": ["model": model, "content": [[
                "type": "tool_use", "id": "bg-1", "name": "Bash",
                "input": ["command": "long_running_thing", "run_in_background": true]]]],
        ]
        return String(data: try JSONSerialization.data(withJSONObject: line), encoding: .utf8)!
    }

    /// A transcript line that PAIRS the bg-1 launch with its tool_result (so the
    /// scanner now reports NOTHING outstanding) - used to model the async work
    /// completing for Finding 2.
    private func completionLine() throws -> String {
        let line: [String: Any] = [
            "type": "user", "sessionId": "s", "uuid": "u-done", "timestamp": "2026-06-26T10:05:00.000Z",
            "message": ["content": [[
                "type": "tool_result", "tool_use_id": "bg-1", "content": "done"]]],
        ]
        return String(data: try JSONSerialization.data(withJSONObject: line), encoding: .utf8)!
    }

    private func writeTranscript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-hard-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Engine wiring (transcript resolved from a STABLE path so a rewrite
    // of that same file is what changes the file identity).

    private struct Wired {
        let engine: TriageEngine
        let bus: EventBus
        let injector: CapturingInjector
        let notifier: MockNotifier
        let parses: ParseCounter
    }

    private func makeEngine(clock: ClockBox, transcript: URL, parses: ParseCounter) -> Wired {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-hard-bus-\(UUID().uuidString).log")))
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
                .appendingPathComponent("wd-hard-router-\(UUID().uuidString).log")))

        // Scanner resolves the SAME url for any session id, and bumps the parse
        // counter on every real read+parse so the cache hit is observable.
        let scanner = AsyncWorkScanner(
            transcriptURL: { _ in transcript },
            onScanParse: { parses.bump() })

        let engine = TriageEngine(
            client: LLMClient(
                provider: .anthropic, apiKey: "sk-ant-test", redactor: DefaultRedactor(),
                baseURL: URL(string: "https://mock.anthropic.test")!, session: URLSession(configuration: .ephemeral),
                traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                    .appendingPathComponent("wd-hard-client-\(UUID().uuidString).log"))),
            bus: bus, model: "claude-haiku-4-5-20251001", windowSize: 30, costStore: nil,
            dispatcher: dispatcher,
            plannerEnabled: { false },
            autoDispatchDisabledRead: { false },
            stallWatchdog: StallWatchdog(),
            watchdogPolicy: WatchdogPolicy(),
            asyncWorkScanner: scanner,
            watchdogEnabledRead: { true },
            idleThresholdSeconds: 15,
            idleCheckIntervalSeconds: 3600,  // park the timer; we drive checkIdleStates
            injectionLedger: ledger,
            now: { clock.now })
        engine.onDecision = { d in Task { @MainActor in await router.dispatch(decision: d) } }
        engine.start()
        return Wired(engine: engine, bus: bus, injector: injector, notifier: notifier, parses: parses)
    }

    private func seedStoppedSession(_ w: Wired, _ clock: ClockBox, sessionId: String) async throws {
        w.bus.publish(.sessionStart(.init(
            sessionId: sessionId, cwd: "/Users/test/supervisor", gitBranch: "autonomous-x",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: clock.now)))
        clock.advance(by: 1)
        w.bus.publish(.assistantText(.init(
            sessionId: sessionId, text: "Kicked off the background task.", turnUUID: "u-stop", ts: clock.now)))
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - Finding 1a: caching

    /// Two consecutive ticks over an UNCHANGED transcript parse exactly once: the
    /// second tick is served from the file-identity cache. A rewrite of the file
    /// (new size/mtime) forces a re-parse on the next tick.
    func testUnchangedTranscriptIsNotReparsed() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let parses = ParseCounter()
        // Opus -> 45m interval, so neither tick crosses it: we isolate the parse
        // behavior from the nudge behavior (no inject involved).
        let url = try writeTranscript([try outstandingLine(model: "claude-opus-4-8")])
        defer { try? FileManager.default.removeItem(at: url) }
        let w = makeEngine(clock: clock, transcript: url, parses: parses)
        defer { w.engine.stop() }
        try await seedStoppedSession(w, clock, sessionId: "sess-cache")

        // Past the 15s idle floor so the watchdog scans, under 45m so no nudge.
        clock.advance(by: 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(parses.count, 1, "first tick parses the transcript once")

        // Second tick, file UNCHANGED -> served from cache, NO new parse.
        clock.advance(by: 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(parses.count, 1, "unchanged transcript is NOT re-parsed (file-identity cache hit)")

        // Rewrite the SAME file with more content -> size+mtime change -> re-parse.
        // (sleep to guarantee a distinct mtime on coarse-resolution filesystems.)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try (try outstandingLine(model: "claude-opus-4-8") + "\n" + (try completionLine()) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        clock.advance(by: 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(parses.count, 2, "a changed transcript (new size/mtime) is re-parsed")
    }

    // MARK: - Finding 1b: pruning

    /// A session silent past the 24h stale-eviction bound is removed from the
    /// watchdog maps on the next tick (no unbounded growth), and is no longer
    /// scanned thereafter.
    func testStaleSessionIsEvicted() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let parses = ParseCounter()
        let url = try writeTranscript([try outstandingLine(model: "claude-opus-4-8")])
        defer { try? FileManager.default.removeItem(at: url) }
        let w = makeEngine(clock: clock, transcript: url, parses: parses)
        defer { w.engine.stop() }
        try await seedStoppedSession(w, clock, sessionId: "sess-stale")

        // One normal tick: the session is tracked and scanned.
        clock.advance(by: 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(w.engine.watchdogTrackedSessionCount, 1, "session tracked while live")
        XCTAssertEqual(w.engine.watchdogScanCacheCount, 1, "scan cached for the live session")
        XCTAssertEqual(parses.count, 1)

        // Jump > 24h past the session's last event -> next tick prunes it.
        clock.advance(by: 25 * 60 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(w.engine.watchdogTrackedSessionCount, 0, "stale session evicted from idleStates")
        XCTAssertEqual(w.engine.watchdogScanCacheCount, 0, "stale session's scan cache evicted too")

        // A further tick must not scan the evicted session (parse count frozen).
        let parsesAfterPrune = parses.count
        clock.advance(by: 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(parses.count, parsesAfterPrune, "evicted session is no longer scanned")
        XCTAssertTrue(w.injector.texts.isEmpty, "an evicted session never nudges")
    }

    // MARK: - Finding 2: completion resets the cycle

    /// A session that escalated (3 nudges then stop) whose async work then
    /// completes (scanner outstanding true -> false) has its nudge count +
    /// escalate-hold cleared, so a LATER, separate stall nudges again from 1
    /// rather than staying held.
    func testAsyncCompletionResetsAfterEscalation() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let parses = ParseCounter()
        // Haiku -> 20m interval. Start with the work OUTSTANDING.
        let url = try writeTranscript([try outstandingLine(model: "claude-haiku-4-5-20251001")])
        defer { try? FileManager.default.removeItem(at: url) }
        let w = makeEngine(clock: clock, transcript: url, parses: parses)
        defer { w.engine.stop() }
        try await seedStoppedSession(w, clock, sessionId: "sess-complete")

        // Drive 3 nudges (each a fresh 21m interval of silence, no real event
        // between ticks so the cycle is not reset by movement).
        for i in 0..<3 {
            clock.advance(by: 21 * 60)
            w.engine.checkIdleStates()
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertEqual(w.injector.texts.count, i + 1, "nudge \(i + 1) injected")
        }
        // 4th tick -> escalate (notify, no 4th nudge).
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(w.injector.texts.count, 3, "escalated, not a 4th nudge")
        XCTAssertFalse(w.notifier.outcomes.isEmpty, "escalation posted a notify")

        // The async work now COMPLETES: rewrite the transcript so the bg-1 launch
        // is paired with its tool_result -> scanner reports NOTHING outstanding.
        try await Task.sleep(nanoseconds: 1_100_000_000)  // distinct mtime
        try (try outstandingLine(model: "claude-haiku-4-5-20251001") + "\n" + (try completionLine()) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        // Tick: the watchdog observes outstanding true -> false and resets the
        // cycle. No nudge (nothing outstanding), no further escalation notify.
        let notifyBefore = w.notifier.outcomes.count
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(w.injector.texts.count, 3, "completion alone injects nothing")
        XCTAssertEqual(w.notifier.outcomes.count, notifyBefore, "completion alone posts no new notify")

        // A LATER, SEPARATE stall: async work outstanding again. Because the cycle
        // was reset on completion, this must nudge afresh (count goes to 4 overall)
        // rather than staying held by the prior escalate-stop.
        try await Task.sleep(nanoseconds: 1_100_000_000)  // distinct mtime
        try (try outstandingLine(model: "claude-haiku-4-5-20251001") + "\n").write(to: url, atomically: true, encoding: .utf8)
        clock.advance(by: 21 * 60)
        w.engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(w.injector.texts.count, 4,
                       "after completion reset, a fresh stall nudges again (not held by the old escalation)")
    }
}
