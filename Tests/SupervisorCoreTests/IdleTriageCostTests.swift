// IdleTriageCostTests.swift
//
// The cost defect this file pins, in the owner's words: "i filled up $10 in
// deepseek last night... it should never be using that many credits for 1-2
// flags." The live trace showed 199 `evaluating idle` calls in 40 minutes
// (~300/hour) against sessions that had produced no events for hours — each
// one a ~5.5k-token body describing a session that had not moved.
//
// The invariant that closes it: an idle session whose transcript has not
// changed produces ZERO LLM calls, no matter how many ticks elapse. These
// tests drive `checkIdleStates()` directly against a mocked clock and a real
// temp transcript file, and count HTTP requests through the URLProtocol mock.

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class IdleTriageCostTests: XCTestCase {

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]
    nonisolated(unsafe) static var requestCount: Int = 0

    override func setUp() async throws {
        try await super.setUp()
        // Same drain as IdleDetectionTests: the idle path dispatches an
        // unstructured Task whose HTTP call can outlive the test that
        // scheduled it, and the request counter is file-static.
        try await Task.sleep(nanoseconds: 200_000_000)
        Self.canned.removeAll()
        Self.requestCount = 0
    }

    override func tearDown() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
        try await super.tearDown()
    }

    // MARK: - Harness

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CostMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// A real transcript file on disk, so the fingerprint gate reads the same
    /// way it does in production. Returns the URL; append to it to simulate
    /// the worker writing a new turn.
    private func makeTranscript(_ contents: String = "{\"type\":\"assistant\"}\n") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idle-cost-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func makeEngine(
        clock: @escaping @MainActor () -> Date,
        transcript: URL?,
        idleThresholdSeconds: TimeInterval = 15,
        idleReTriageIntervalSeconds: TimeInterval = 60,
        dormantSessionSilenceSeconds: TimeInterval = TriageEngine.defaultDormantSessionSilenceSeconds
    ) -> (TriageEngine, EventBus, TriageEngineTests.CapturedDecisions) {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("idle-cost-\(UUID().uuidString).log")))
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("idle-cost-client-\(UUID().uuidString).log"))
        )
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            idleThresholdSeconds: idleThresholdSeconds,
            idleReTriageIntervalSeconds: idleReTriageIntervalSeconds,
            // Park the background timer: only explicit checkIdleStates() ticks.
            idleCheckIntervalSeconds: 3600,
            dormantSessionSilenceSeconds: dormantSessionSilenceSeconds,
            transcriptTailURL: { _ in transcript },
            now: clock
        )
        let captured = TriageEngineTests.CapturedDecisions()
        engine.onDecision = { d in captured.append(d) }
        engine.start()
        return (engine, bus, captured)
    }

    private static func allClearResponse() -> Data {
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
            "usage": ["input_tokens": 5500, "output_tokens": 10],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func publishIdleSession(
        _ bus: EventBus, sessionId: String = "s-cost", at ts: Date
    ) {
        bus.publish(.sessionStart(.init(
            sessionId: sessionId,
            cwd: "/Users/test/supervisor",
            gitBranch: "feat/cost",
            projectHash: "-tmp",
            jsonlPath: "/tmp/x.jsonl",
            ts: ts
        )))
        bus.publish(.assistantText(.init(
            sessionId: sessionId,
            text: "All done — ready for next.",
            turnUUID: "u-stop",
            ts: ts
        )))
    }

    // MARK: - (a) unchanged transcript => zero calls, forever

    func testUnchangedTranscriptProducesExactlyOneCallAcrossManyTicks() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let transcript = try makeTranscript()
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, _) = makeEngine(clock: { clock.now }, transcript: transcript)
        defer { engine.stop() }

        publishIdleSession(bus, at: clock.now)
        try await Task.sleep(nanoseconds: 150_000_000)

        // First tick past the idle threshold: one call, and it records the
        // fingerprint of the (unchanging) transcript.
        clock.advance(by: 20)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.requestCount, 1, "the first idle tick should evaluate once")

        // 60 further re-triage windows — an hour of a session sitting still.
        // Under the old flat 60s gate this was 60 more ~5.5k-token calls.
        for _ in 0..<60 {
            clock.advance(by: 61)
            engine.checkIdleStates()
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(Self.requestCount, 1,
                       "an idle session whose transcript never changed must never be re-evaluated")
    }

    // MARK: - (c) a new transcript event triggers exactly one more call

    func testNewTranscriptEventTriggersExactlyOneFurtherCall() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let transcript = try makeTranscript()
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, _) = makeEngine(clock: { clock.now }, transcript: transcript)
        defer { engine.stop() }

        publishIdleSession(bus, at: clock.now)
        try await Task.sleep(nanoseconds: 150_000_000)

        clock.advance(by: 20)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.requestCount, 1)

        // Quiet ticks change nothing.
        for _ in 0..<5 {
            clock.advance(by: 61)
            engine.checkIdleStates()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.requestCount, 1, "quiet ticks stay free")

        // The worker writes a new turn. The fingerprint moves, so the next
        // eligible tick evaluates once — and only once.
        try append("{\"type\":\"assistant\",\"n\":2}", to: transcript)
        clock.advance(by: 61)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.requestCount, 2, "a real transcript change earns exactly one evaluation")

        for _ in 0..<5 {
            clock.advance(by: 61)
            engine.checkIdleStates()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.requestCount, 2, "and the session goes quiet again afterwards")
    }

    // MARK: - The carve-out: an engaged human is a clock-dependent no-fire

    /// The one rubric input that moves without a transcript write is "a user
    /// message in the last 30 seconds." A pure content hash would freeze the
    /// first (correctly) no-fire verdict forever and silently disable the
    /// drive loop for that session, so the engaged flag is part of the
    /// fingerprint — worth exactly one extra call once the window lapses.
    func testHumanEngagedWindowLapsingEarnsOneMoreEvaluation() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let transcript = try makeTranscript()
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, _) = makeEngine(
            clock: { clock.now }, transcript: transcript,
            idleThresholdSeconds: 15, idleReTriageIntervalSeconds: 10
        )
        defer { engine.stop() }

        bus.publish(.sessionStart(.init(
            sessionId: "s-cost", cwd: "/Users/test/supervisor", gitBranch: "feat/cost",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: clock.now
        )))
        bus.publish(.userPrompt(.init(
            sessionId: "s-cost", text: "ok go", ts: clock.now
        )))
        // The worker answers immediately, so the first idle tick lands while
        // the human is still inside the 30s engaged window.
        clock.advance(by: 2)
        bus.publish(.assistantText(.init(
            sessionId: "s-cost", text: "Done — ready for next.", turnUUID: "u-2", ts: clock.now
        )))
        try await Task.sleep(nanoseconds: 150_000_000)

        clock.advance(by: 16)   // t=18: user message is 18s old, engaged=true
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.requestCount, 1)

        clock.advance(by: 20)   // t=38: user message is 38s old, engaged=false
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.requestCount, 2,
                       "the engaged window lapsing is a genuinely different question")

        // And then it settles: nothing else changes, nothing else is bought.
        for _ in 0..<10 {
            clock.advance(by: 11)
            engine.checkIdleStates()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.requestCount, 2)
    }

    // MARK: - (b) a dormant session buys nothing

    /// The fix-queue #9 guard stopped the INJECTION for an abandoned session
    /// but the tick still bought a verdict first. A session the operator walked
    /// away from must cost nothing at all.
    func testDormantSessionProducesZeroCalls() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let transcript = try makeTranscript()
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, _) = makeEngine(
            clock: { clock.now }, transcript: transcript,
            dormantSessionSilenceSeconds: 300
        )
        defer { engine.stop() }

        publishIdleSession(bus, at: clock.now)
        try await Task.sleep(nanoseconds: 150_000_000)

        // Past the dormant bound before the first eligible tick.
        clock.advance(by: 400)
        for _ in 0..<20 {
            engine.checkIdleStates()
            clock.advance(by: 61)
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(Self.requestCount, 0,
                       "a dormant session must not reach the provider at all")
    }

    /// The same guard, one layer down: `evaluateIdle` refuses a dormant session
    /// even when something calls it directly, so no future caller can
    /// reintroduce the spend by bypassing the tick walk.
    func testEvaluateIdleItselfRefusesADormantSession() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let transcript = try makeTranscript()
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, _) = makeEngine(
            clock: { clock.now }, transcript: transcript,
            dormantSessionSilenceSeconds: 300
        )
        defer { engine.stop() }

        publishIdleSession(bus, at: clock.now)
        try await Task.sleep(nanoseconds: 150_000_000)

        // A first tick while still active proves the path is otherwise live.
        clock.advance(by: 20)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.requestCount, 1)

        // Now cross the dormant bound. The fingerprint is unchanged too, so
        // clear the tick gate by touching the transcript: only the dormancy
        // check can stop this one.
        //
        // NOTE: this drives the guard through `checkIdleStates`, which has its
        // OWN dormancy check upstream, so this assertion holds even if the
        // inner `evaluateIdle` guard is deleted. The test below is the one that
        // actually pins the inner guard.
        try append("{\"type\":\"assistant\",\"n\":2}", to: transcript)
        clock.advance(by: 400)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(Self.requestCount, 1,
                       "dormancy outranks a changed transcript: no verdict is worth buying for an abandoned chat")
    }

    /// The inner guard, driven DIRECTLY through the test seam. Without this the
    /// `evaluateIdle` dormancy check is unreachable from the suite: every path
    /// into it goes through `checkIdleStates`, which refuses a dormant session
    /// first, so deleting the inner guard broke nothing that any test could
    /// see. The guard exists precisely for a future caller that skips the tick
    /// walk, which is exactly what this test is.
    func testEvaluateIdleDirectlyRefusesADormantSession() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let transcript = try makeTranscript()
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, _) = makeEngine(
            clock: { clock.now }, transcript: transcript,
            dormantSessionSilenceSeconds: 300
        )
        defer { engine.stop() }

        publishIdleSession(bus, at: clock.now)
        try await Task.sleep(nanoseconds: 150_000_000)

        // Control: called directly while the session is still ACTIVE, the path
        // reaches the provider. Without this half, a seam that was broken in
        // some unrelated way would make the dormant assertion pass for the
        // wrong reason.
        clock.advance(by: 20)
        await engine._evaluateIdleForTesting(sessionId: "s-cost")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(Self.requestCount, 1,
                       "the direct path is live for an active session")

        // Same direct call past the dormant bound: the inner guard must refuse
        // it. Nothing upstream is involved this time.
        clock.advance(by: 400)
        await engine._evaluateIdleForTesting(sessionId: "s-cost")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(Self.requestCount, 1,
                       "evaluateIdle's own dormancy guard refuses an abandoned session, with no tick walk above it to help")
    }

    // MARK: - Backoff ladder (pure)

    func testBackoffLadderShape() {
        let base: TimeInterval = 60
        XCTAssertEqual(TriageEngine.idleReTriageBackoffSeconds(step: 0, base: base), 60)
        XCTAssertEqual(TriageEngine.idleReTriageBackoffSeconds(step: 1, base: base), 120)
        XCTAssertEqual(TriageEngine.idleReTriageBackoffSeconds(step: 2, base: base), 300)
        XCTAssertEqual(TriageEngine.idleReTriageBackoffSeconds(step: 3, base: base), 900)
        XCTAssertEqual(TriageEngine.idleReTriageBackoffSeconds(step: 4, base: base), 1800)
    }

    func testBackoffLadderCapsAndClampsOutOfRangeSteps() {
        let base: TimeInterval = 60
        XCTAssertEqual(TriageEngine.idleReTriageBackoffSeconds(step: 5, base: base), 1800)
        XCTAssertEqual(TriageEngine.idleReTriageBackoffSeconds(step: 99, base: base), 1800,
                       "the ladder caps at 30 minutes")
        XCTAssertEqual(TriageEngine.idleReTriageBackoffSeconds(step: -3, base: base), 60,
                       "a negative step is the bottom rung, never a negative interval")
    }

    func testBackoffLadderIsRelativeToTheConfiguredInterval() {
        // A short-interval harness keeps its short intervals; the ladder is a
        // shape, not a set of absolute seconds.
        XCTAssertEqual(TriageEngine.idleReTriageBackoffSeconds(step: 2, base: 0.1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TriageEngine.idleReTriageBackoffSeconds(step: 4, base: 1), 30)
    }

    /// Defense in depth for the session the fingerprint gate cannot see: with
    /// no readable transcript the ladder is the only thing bounding cadence, so
    /// an hour of stillness must cost far fewer calls than the flat 60s gate.
    func testUnfingerprintableSessionBacksOff() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let (engine, bus, _) = makeEngine(clock: { clock.now }, transcript: nil)
        defer { engine.stop() }

        publishIdleSession(bus, at: clock.now)
        try await Task.sleep(nanoseconds: 150_000_000)

        clock.advance(by: 20)
        // One hour of 30-second ticks. The flat gate allowed 60 calls; the
        // ladder allows 60s, +2m, +5m, +15m, then every 30m => 6.
        for _ in 0..<120 {
            engine.checkIdleStates()
            clock.advance(by: 30)
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertLessThanOrEqual(Self.requestCount, 8,
                                 "an hour of an unchanging session must not cost 60 calls")
        XCTAssertGreaterThanOrEqual(Self.requestCount, 1,
                                    "it must still be evaluated, just far less often")
    }

    /// The RESET half of the ladder, which nothing covered: every backoff test
    /// only ever climbed. Grow the step to 2+ on a session the fingerprint gate
    /// cannot see, then make the transcript readable with genuinely new
    /// content, and the next interval must be the BASE one again rather than
    /// the stretched rung. If the reset regressed, a session that woke up would
    /// stay on a 5-minute (or 30-minute) leash while it was actively working.
    func testBackoffResetsWhenTheTranscriptBecomesReadableAgain() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))

        // The scanner resolves this box per call, so the session can go from
        // unfingerprintable (no transcript) to fingerprintable mid-test.
        final class TranscriptBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _url: URL?
            init(_ u: URL?) { _url = u }
            var url: URL? { lock.lock(); defer { lock.unlock() }; return _url }
            func set(_ u: URL?) { lock.lock(); _url = u; lock.unlock() }
        }
        let box = TranscriptBox(nil)

        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("idle-cost-\(UUID().uuidString).log")))
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("idle-cost-client-\(UUID().uuidString).log"))
        )
        let engine = TriageEngine(
            client: client, bus: bus, model: "claude-haiku-4-5-20251001",
            windowSize: 30, costStore: nil,
            idleThresholdSeconds: 15,
            idleReTriageIntervalSeconds: 60,
            idleCheckIntervalSeconds: 3600,
            transcriptTailURL: { _ in box.url },
            now: { clock.now }
        )
        engine.start()
        defer { engine.stop() }

        publishIdleSession(bus, at: clock.now)
        try await Task.sleep(nanoseconds: 150_000_000)

        // Climb the ladder. With no readable transcript there is no fingerprint,
        // so each eligible tick takes the else-branch and adds a rung. Each
        // advance has to clear the rung the PREVIOUS tick just moved us to
        // (60s, 120s, 300s, 900s at a 60s base), which is the whole point of
        // the ladder, so the walk is 20s / 121s / 301s and lands on step 3.
        clock.advance(by: 20)
        engine.checkIdleStates()                       // first tick: fires, step 0 -> 1
        try await Task.sleep(nanoseconds: 250_000_000)
        clock.advance(by: 121)
        engine.checkIdleStates()                       // rung 1 is 120s: fires, 1 -> 2
        try await Task.sleep(nanoseconds: 250_000_000)
        clock.advance(by: 301)
        engine.checkIdleStates()                       // rung 2 is 300s: fires, 2 -> 3
        try await Task.sleep(nanoseconds: 250_000_000)
        let callsAfterClimb = Self.requestCount
        XCTAssertEqual(callsAfterClimb, 3, "three eligible ticks, three climbs")

        // Proof the ladder really is stretched now: rung 3 is 15 minutes, so a
        // tick one base interval later must NOT fire.
        clock.advance(by: 61)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(Self.requestCount, callsAfterClimb,
                       "the step really did grow: 61s is under the stretched rung")

        // Now the transcript becomes readable AND carries genuinely new content,
        // so the fingerprint is non-nil and differs from the recorded nil hash.
        // Wait out the stretched 15-minute rung so this tick is eligible at all.
        let transcript = try makeTranscript("{\"type\":\"assistant\",\"n\":\"fresh\"}\n")
        box.set(transcript)
        clock.advance(by: 901)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(Self.requestCount, callsAfterClimb + 1,
                       "past the stretched rung with new content, the session is evaluated")

        // THE ASSERTION THIS TEST EXISTS FOR: the step is back at 0, so the next
        // interval is the BASE 60s and not the 5-minute rung it was on. A tick
        // one base interval later fires. Append new content first so the
        // unchanged-content gate is not what answers instead.
        try append("{\"type\":\"assistant\",\"n\":\"fresher\"}", to: transcript)
        clock.advance(by: 61)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(Self.requestCount, callsAfterClimb + 2,
                       "the ladder reset to the base interval: 61s is enough again, where 61s was refused before the reset")
    }

    // MARK: - Pure fingerprint unit coverage

    func testFingerprintIsNilWithoutATranscript() {
        XCTAssertNil(TriageEngine.idleTriageInputFingerprint(tailLines: nil, humanEngaged: false),
                     "no readable transcript means no fingerprint, so the gate must not engage")
    }

    func testFingerprintIsStableAndContentSensitive() {
        let a = TriageEngine.idleTriageInputFingerprint(tailLines: ["one", "two"], humanEngaged: false)
        let b = TriageEngine.idleTriageInputFingerprint(tailLines: ["one", "two"], humanEngaged: false)
        let c = TriageEngine.idleTriageInputFingerprint(tailLines: ["one", "three"], humanEngaged: false)
        let d = TriageEngine.idleTriageInputFingerprint(tailLines: ["one", "two"], humanEngaged: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d, "the engaged flag has to move the fingerprint or the carve-out is dead")
        XCTAssertNotNil(a)
    }

    func testFingerprintSeparatorBlocksForgedCollision() {
        // A transcript line that spells out the engaged marker must not be able
        // to impersonate a different engaged value.
        let forged = TriageEngine.idleTriageInputFingerprint(
            tailLines: ["engaged=true\u{1F}payload"], humanEngaged: false)
        let real = TriageEngine.idleTriageInputFingerprint(
            tailLines: ["payload"], humanEngaged: true)
        XCTAssertNotEqual(forged, real)
    }
}

// MARK: - URLProtocol mock

private final class CostMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        IdleTriageCostTests.requestCount += 1
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = IdleTriageCostTests.canned[path] else {
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
