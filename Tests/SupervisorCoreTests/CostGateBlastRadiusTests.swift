// CostGateBlastRadiusTests.swift
//
// The fail-closed daily-cap gate (audit B4) sits in front of EVERY model call
// and cannot, on its own, tell "the owner's budget is spent" from "the cost
// store would not read." Both arrive as spent >= cap. Treating them the same
// meant a locked SQLite file or a full disk silently stopped Supervisor from
// reviewing destructive commands, which is the one thing the product exists to
// do, and reported it to the owner as a spending event.
//
// The carve-out: keep fail-closed everywhere the money actually goes (idle
// evaluation, dispatch, question-answering), let the bash / destructive-command
// path through when the gate's failure is a READ ERROR rather than a real cap
// hit, and raise a distinct `triageDegraded` system event so the owner is told
// supervision is running unmetered. A genuine cap hit still blocks everything.
//
// These tests drive the real engine through the real client and count HTTP
// requests at a URLProtocol mock, so "the call happened" means a request was
// actually issued, not that a flag was set.

import XCTest
@testable import SupervisorCore

@MainActor
final class CostGateBlastRadiusTests: XCTestCase {

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]
    nonisolated(unsafe) static var requestCount: Int = 0

    override func setUp() async throws {
        try await super.setUp()
        // Same drain as the sibling cost tests: these paths dispatch through
        // unstructured Tasks whose HTTP call can outlive the test that
        // scheduled it, and the counter is file-static.
        try await Task.sleep(nanoseconds: 200_000_000)
        Self.canned.removeAll()
        Self.requestCount = 0
    }

    override func tearDown() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
        try await super.tearDown()
    }

    // MARK: - Harness

    private struct StoreUnavailable: Error {}

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [BlastRadiusMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func tempLog(_ tag: String) -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-\(tag)-\(UUID().uuidString).log"))
    }

    /// Collects the system escalations the engine raises, which is the C2
    /// notify path's own input: whatever lands here is what reaches the banner,
    /// the hover and the remote page.
    final class CapturedSystemEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [SystemEscalationEvent] = []
        var events: [SystemEscalationEvent] { lock.lock(); defer { lock.unlock() }; return _events }
        func append(_ e: SystemEscalationEvent) { lock.lock(); _events.append(e); lock.unlock() }
    }

    private func makeEngine(
        capCheck: @escaping @Sendable () -> DailyCapGate.Verdict?,
        transcript: URL?,
        clock: @escaping @MainActor () -> Date
    ) -> (TriageEngine, EventBus, CapturedSystemEvents) {
        let bus = EventBus(trace: tempLog("bus"))
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: tempLog("client"),
            capCheck: capCheck
        )
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            idleThresholdSeconds: 15,
            idleReTriageIntervalSeconds: 60,
            // Park the background timer: only explicit checkIdleStates() ticks.
            idleCheckIntervalSeconds: 3600,
            transcriptTailURL: { _ in transcript },
            now: clock
        )
        let captured = CapturedSystemEvents()
        engine.onSystemEvent = { captured.append($0) }
        engine.start()
        return (engine, bus, captured)
    }

    private func makeTranscript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-\(UUID().uuidString).jsonl")
        try "{\"type\":\"assistant\"}\n".write(to: url, atomically: true, encoding: .utf8)
        return url
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

    private func publishBashCall(
        _ bus: EventBus, command: String, toolUseId: String, sessionId: String = "s-blast", at ts: Date
    ) {
        bus.publish(.sessionStart(.init(
            sessionId: sessionId, cwd: "/Users/test/supervisor", gitBranch: "main",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: ts)))
        bus.publish(.userPrompt(.init(sessionId: sessionId, text: "clean up", ts: ts)))
        bus.publish(.bashToolCall(.init(
            sessionId: sessionId, command: command, description: nil,
            toolUseId: toolUseId, turnUUID: "u1", ts: ts)))
    }

    private func publishIdleSession(_ bus: EventBus, sessionId: String = "s-blast", at ts: Date) {
        bus.publish(.sessionStart(.init(
            sessionId: sessionId, cwd: "/Users/test/supervisor", gitBranch: "main",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: ts)))
        bus.publish(.assistantText(.init(
            sessionId: sessionId, text: "All done — ready for next.", turnUUID: "u-stop", ts: ts)))
    }

    /// A verdict shaped like the one a broken cost store produces: spend
    /// synthesized AT the cap, flagged as unread.
    private func unreadableStoreVerdict(cap: Double = 2.00) -> DailyCapGate.Verdict {
        DailyCapGate.evaluate(
            cap: cap, spentUSD: { throw StoreUnavailable() }, trace: tempLog("gate")
        )!
    }

    // MARK: - (a) broken store + a real command: review it, and say so once

    func testStoreReadErrorStillTriagesABashCommandAndReportsItOnce() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let verdict = unreadableStoreVerdict()
        XCTAssertTrue(verdict.storeReadFailed, "harness check: this is the READ-ERROR verdict, not a cap hit")
        XCTAssertEqual(verdict.spent, verdict.cap,
                       "harness check: a broken read still presents AT the cap, which is what used to block everything")

        let (engine, bus, systemEvents) = makeEngine(
            capCheck: { verdict }, transcript: try makeTranscript(), clock: { clock.now }
        )
        defer { engine.stop() }

        publishBashCall(bus, command: "rm -rf /tmp/build", toolUseId: "t1", at: clock.now)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(Self.requestCount, 1,
                       "a broken ledger must not stop Supervisor reviewing a destructive command")

        let degraded = systemEvents.events.filter {
            if case .triageDegraded = $0 { return true } else { return false }
        }
        XCTAssertEqual(degraded.count, 1, "the owner is told exactly once that spend is not being tracked")
        XCTAssertEqual(degraded.first, .triageDegraded(reason: .costStoreUnreadable))

        // It must NOT masquerade as a cap hit: different copy, different key.
        XCTAssertFalse(systemEvents.events.contains {
            if case .costCapHit = $0 { return true } else { return false }
        }, "a broken store is not a spending event and must not be reported as one")
    }

    /// The dedupe half of "exactly once": three more commands through the same
    /// broken store do not page three more times, even though each one is a
    /// separate successful call that would otherwise clear the incident ledger.
    func testRepeatedCommandsUnderABrokenStorePageOnlyOnce() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let verdict = unreadableStoreVerdict()
        let (engine, bus, systemEvents) = makeEngine(
            capCheck: { verdict }, transcript: try makeTranscript(), clock: { clock.now }
        )
        defer { engine.stop() }

        publishBashCall(bus, command: "rm -rf /tmp/a", toolUseId: "t1", at: clock.now)
        try await Task.sleep(nanoseconds: 300_000_000)
        for (i, cmd) in ["rm -rf /tmp/b", "rm -rf /tmp/c", "rm -rf /tmp/d"].enumerated() {
            bus.publish(.bashToolCall(.init(
                sessionId: "s-blast", command: cmd, description: nil,
                toolUseId: "t\(i + 2)", turnUUID: "u\(i + 2)", ts: clock.now)))
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        XCTAssertEqual(Self.requestCount, 4, "every command is still reviewed")
        let degraded = systemEvents.events.filter {
            if case .triageDegraded = $0 { return true } else { return false }
        }
        XCTAssertEqual(degraded.count, 1,
                       "one incident, one page: a broken store must not buzz the owner's phone per command")
    }

    // MARK: - (b) broken store + an idle tick: spend nothing

    func testStoreReadErrorBlocksTheIdlePath() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let verdict = unreadableStoreVerdict()
        let (engine, bus, systemEvents) = makeEngine(
            capCheck: { verdict }, transcript: try makeTranscript(), clock: { clock.now }
        )
        defer { engine.stop() }

        publishIdleSession(bus, at: clock.now)
        try await Task.sleep(nanoseconds: 150_000_000)

        // Several eligible idle ticks. This is the timer-driven path, where the
        // money goes, so it stays fail-closed: an unreadable ledger means we do
        // not know what has been spent, and buying verdicts on a timer while
        // blind to the total is exactly the failure the cap exists to prevent.
        clock.advance(by: 20)
        for _ in 0..<5 {
            engine.checkIdleStates()
            clock.advance(by: 61)
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(Self.requestCount, 0,
                       "the spend-heavy idle path stays fail-closed when spend cannot be read")

        // Blocking is only half the requirement. This test used to discard the
        // system-event spy and assert nothing about WHAT the owner was told,
        // which let the idle path page ".costCapHit" carrying a spend figure
        // the fail-closed gate had invented, plus a remedy (raise the cap) that
        // can never clear it because the synthesized spend rises with the cap.
        let degraded = systemEvents.events.filter {
            if case .triageDegraded = $0 { return true } else { return false }
        }
        XCTAssertEqual(degraded.first, .triageDegraded(reason: .costStoreUnreadable),
                       "a blocked idle tick must page the honest 'cannot read the spend record' event")
        XCTAssertFalse(systemEvents.events.contains {
            if case .costCapHit = $0 { return true } else { return false }
        }, "an unreadable ledger is not a cap hit and must never be paged as one, on ANY path")

        // Five blocked ticks, one page. cost_cap_hit is wiped by the
        // clear-on-success sweep, so classifying this as a cap hit also meant a
        // new incident (and a new page) every time any other call succeeded.
        // triage_degraded is exempt from that sweep, which is what ends the loop.
        XCTAssertEqual(degraded.count, 1,
                       "one broken ledger is one incident, however many ticks it blocks")
    }

    // MARK: - (c) a REAL cap hit blocks both paths

    func testRealCapHitBlocksBothTheBashAndTheIdlePath() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        // Read succeeded; the owner has genuinely spent past the cap.
        let verdict = DailyCapGate.evaluate(
            cap: 2.00, spentUSD: { 2.50 }, trace: tempLog("gate")
        )!
        XCTAssertFalse(verdict.storeReadFailed, "harness check: this is a REAL cap hit")

        let (engine, bus, systemEvents) = makeEngine(
            capCheck: { verdict }, transcript: try makeTranscript(), clock: { clock.now }
        )
        defer { engine.stop() }

        publishBashCall(bus, command: "rm -rf /tmp/build", toolUseId: "t1", at: clock.now)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(Self.requestCount, 0,
                       "the carve-out is for a broken ledger only: a real cap still refuses the bash path")

        publishIdleSession(bus, sessionId: "s-idle", at: clock.now)
        try await Task.sleep(nanoseconds: 150_000_000)
        clock.advance(by: 20)
        engine.checkIdleStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.requestCount, 0, "and the idle path too")

        // The owner hears about it as a COST CAP, the honest description, and
        // never as a degradation.
        XCTAssertTrue(systemEvents.events.contains {
            if case .costCapHit = $0 { return true } else { return false }
        }, "a real cap hit is still reported as a cap hit")
        XCTAssertFalse(systemEvents.events.contains {
            if case .triageDegraded = $0 { return true } else { return false }
        }, "a working store that says 'over budget' is not a degradation")
    }

    // MARK: - Recovery

    /// The store coming back has to close the incident, or a break later in the
    /// day would be silently swallowed by the still-open first one.
    func testStoreRecoveringClosesTheDegradedIncidentSoALaterBreakPagesAgain() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))

        // A capCheck the test can flip between broken and healthy.
        final class GateBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _broken = true
            var broken: Bool { lock.lock(); defer { lock.unlock() }; return _broken }
            func set(_ b: Bool) { lock.lock(); _broken = b; lock.unlock() }
        }
        let box = GateBox()
        let trace = tempLog("gate")
        let capCheck: @Sendable () -> DailyCapGate.Verdict? = {
            box.broken
                ? DailyCapGate.evaluate(cap: 2.00, spentUSD: { throw StoreUnavailable() }, trace: trace)
                : DailyCapGate.evaluate(cap: 2.00, spentUSD: { 0.10 }, trace: trace)
        }

        let (engine, bus, systemEvents) = makeEngine(
            capCheck: capCheck, transcript: try makeTranscript(), clock: { clock.now }
        )
        defer { engine.stop() }

        publishBashCall(bus, command: "rm -rf /tmp/a", toolUseId: "t1", at: clock.now)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(systemEvents.events.count, 1, "the break pages")

        // Store recovers; a command through the healthy gate closes the incident.
        box.set(false)
        bus.publish(.bashToolCall(.init(
            sessionId: "s-blast", command: "rm -rf /tmp/b", description: nil,
            toolUseId: "t2", turnUUID: "u2", ts: clock.now)))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(systemEvents.events.count, 1, "recovery is quiet; it is not news")

        // It breaks again: a NEW incident, so a NEW page rather than silence.
        box.set(true)
        bus.publish(.bashToolCall(.init(
            sessionId: "s-blast", command: "rm -rf /tmp/c", description: nil,
            toolUseId: "t3", turnUUID: "u3", ts: clock.now)))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(systemEvents.events.count, 2,
                       "a second break is a second incident, not a repeat of the first")
    }

    // MARK: - The event itself

    func testDegradedEventIsDistinguishableFromACapHit() {
        let degraded = SystemEscalationEvent.triageDegraded(reason: .costStoreUnreadable)
        let capHit = SystemEscalationEvent.costCapHit(spentUSD: 2.10, capUSD: 2.00)

        XCTAssertNotEqual(degraded.kind, capHit.kind,
                          "same dedupe key would mean one incident hides the other")
        XCTAssertEqual(degraded.kind, "triage_degraded.cost_store_unreadable")
        XCTAssertNotEqual(degraded.title, capHit.title)
        XCTAssertNotEqual(degraded.body, capHit.body)

        // Copy rule for this channel: nothing session-derived, and no em dashes.
        for text in [degraded.title, degraded.body] {
            XCTAssertFalse(text.contains("—"), "system-event copy carries no em dashes")
            XCTAssertFalse(text.isEmpty)
        }
        // The distinction the owner actually needs: a cap hit means nothing is
        // watched, this means the risky commands still are.
        XCTAssertTrue(degraded.body.contains("still being reviewed"),
                      "the body has to say what IS still working, or it reads as a total outage")
        XCTAssertTrue(capHit.body.contains("not being watched"))
    }
}

// MARK: - URLProtocol mock

private final class BlastRadiusMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        CostGateBlastRadiusTests.requestCount += 1
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = CostGateBlastRadiusTests.canned[path] else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
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
