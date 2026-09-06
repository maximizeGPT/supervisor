// SystemEscalationTests.swift
//
// The Supervisor-is-down escalation path (C2/D1), in three layers:
//
//   1. The pure classification table: which LLM failures page (cap hit,
//      401/402/403) and which never may (rate limits, 5xx, network blips).
//   2. The incident emission policy (page on open, one 6h still-down
//      repeat, cleared by success) and the remote side's short storm-guard
//      dedupe on postSystemEvent.
//   3. The storm test: a real TriageEngine over a mocked provider that
//      answers 402 to everything. N flagged commands must produce exactly
//      ONE system-event emission (one page + one hover notice at the
//      wiring seam) and, after the breaker opens, ZERO further network
//      attempts.

import XCTest
@testable import SupervisorCore

final class SystemEscalationTests: XCTestCase {

    // MARK: - 1. Classification table

    func testCapErrorClassifiesAsCostCapHit() {
        let event = SystemEscalationEvent.classify(DailyCapExceededError(capUSD: 5, spentUSD: 5.12))
        XCTAssertEqual(event, .costCapHit(spentUSD: 5.12, capUSD: 5))
    }

    /// A refusal from a ledger that could not be read is a degradation, not a
    /// cap hit. Its `spentUSD` is synthesized equal to the cap by the
    /// fail-closed gate, so the cap-hit copy would quote a number nobody
    /// measured and name a remedy (raise the cap) that cannot work: the
    /// synthesized spend rises to meet whatever cap is set next.
    func testUnreadableStoreClassifiesAsDegradedNotACapHit() {
        let event = SystemEscalationEvent.classify(
            DailyCapExceededError(capUSD: 2, spentUSD: 2, storeReadFailed: true)
        )
        XCTAssertEqual(event, .triageDegraded(reason: .costStoreUnreadable))
    }

    /// The message the owner actually reads must not contain a spend figure or
    /// a "raise the cap" instruction when the number is invented.
    func testUnreadableStoreMessageDoesNotQuoteInventedSpendOrAnImpossibleRemedy() {
        let message = SystemEscalationEvent.triageDegraded(reason: .costStoreUnreadable).body
        XCTAssertFalse(message.contains("$"), "no dollar figure: nothing was measured")
        XCTAssertFalse(message.lowercased().contains("raise"),
                       "raising the cap cannot clear a synthesized spend that follows the cap up")
    }

    func testAuthAndBillingStatusesClassifyAsProviderUnavailable() {
        XCTAssertEqual(SystemEscalationEvent.classify(AnthropicClientError.invalidKey(message: "x")),
                       .providerUnavailable(status: 401))
        XCTAssertEqual(SystemEscalationEvent.classify(AnthropicClientError.permissionDenied(message: "x")),
                       .providerUnavailable(status: 403))
        XCTAssertEqual(SystemEscalationEvent.classify(AnthropicClientError.requestError(status: 402, message: "Insufficient Balance")),
                       .providerUnavailable(status: 402))
    }

    func testSelfHealingFailuresNeverPage() {
        // Rate limits, server errors, network blips and shape problems heal
        // on their own (or are bugs, not owner actions); paging a phone for
        // them is how the channel gets muted.
        let never: [Error] = [
            AnthropicClientError.rateLimit(message: "x", retryAfter: 30),
            AnthropicClientError.requestError(status: 400, message: "x"),
            AnthropicClientError.serverError(status: 503, message: "x"),
            AnthropicClientError.network(underlying: "offline"),
            AnthropicClientError.decodingFailed(reason: "x"),
            AnthropicClientError.redactorMissing,
            RemoteNotifyError.transport(underlying: "unrelated"),
        ]
        for error in never {
            XCTAssertNil(SystemEscalationEvent.classify(error), "\(error) must not escalate")
        }
    }

    func testCopyCarriesTheNumbersAndNoEmDashes() {
        let cap = SystemEscalationEvent.costCapHit(spentUSD: 5.1234, capUSD: 5)
        XCTAssertTrue(cap.body.contains("$5.12"), cap.body)
        XCTAssertTrue(cap.body.contains("$5.00"), cap.body)

        let credit = SystemEscalationEvent.providerUnavailable(status: 402)
        XCTAssertTrue(credit.body.contains("402"), credit.body)
        XCTAssertTrue(credit.body.contains("credit"), credit.body)

        for event in [cap, credit, .providerUnavailable(status: 401), .providerUnavailable(status: 403), .providerUnavailable(status: 599)] {
            XCTAssertFalse(event.title.contains("\u{2014}"), "no em dashes: \(event.title)")
            XCTAssertFalse(event.body.contains("\u{2014}"), "no em dashes: \(event.body)")
            XCTAssertFalse(event.body.contains("/Users"), "nothing path-shaped: \(event.body)")
        }

        XCTAssertEqual(cap.kind, "cost_cap_hit")
        XCTAssertEqual(credit.kind, "provider_unavailable")
    }

    // MARK: - 2. Incident emission policy (the engine's ledger)

    func testIncidentEmissionPagesOnOpenOnceMoreAtSixHoursThenNever() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        var (state, emit) = SystemEscalationEvent.incidentEmission(state: nil, now: t)
        XCTAssertTrue(emit, "an incident pages the moment it opens")

        // The old behavior was an hourly drumbeat all day; a still-open
        // incident must stay silent through every re-hit inside 6 hours.
        for offset: TimeInterval in [60, 3600, 2 * 3600, 5 * 3600] {
            let next = SystemEscalationEvent.incidentEmission(state: state, now: t.addingTimeInterval(offset))
            state = next.state
            XCTAssertFalse(next.emit, "no repeat at +\(Int(offset))s")
        }

        // Still down after 6 hours: exactly one "still down" repeat.
        let repeated = SystemEscalationEvent.incidentEmission(state: state, now: t.addingTimeInterval(6 * 3600))
        state = repeated.state
        XCTAssertTrue(repeated.emit, "one repeat when the incident survives 6 hours")

        // And that is the last word until the incident closes.
        for offset: TimeInterval in [7 * 3600, 24 * 3600, 72 * 3600] {
            let next = SystemEscalationEvent.incidentEmission(state: state, now: t.addingTimeInterval(offset))
            state = next.state
            XCTAssertFalse(next.emit, "at most one repeat per incident (+\(Int(offset))s)")
        }
    }

    func testAClearedLedgerPagesTheNewIncidentImmediately() {
        // The engine drops the ledger entry on the first successful call,
        // so the next failure arrives with state nil — and pages at once,
        // even one minute after the old incident's page. This is the
        // "new incident inside the old hour" case the stamp map got wrong.
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let opened = SystemEscalationEvent.incidentEmission(state: nil, now: t.addingTimeInterval(60))
        XCTAssertTrue(opened.emit)
        XCTAssertEqual(opened.state.firstPagedAt, t.addingTimeInterval(60))
        XCTAssertNil(opened.state.repeatedAt)
    }

    // MARK: - 2b. Remote storm guard

    func testPostSystemEventAppliesTheStormGuardWindow() async throws {
        let transport = RemoteNotifierTests.StubTransport()
        let clock = RemoteNotifierTests.TestClock()
        let notifier = RemoteNotifier(
            endpoint: try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/1/token"),
            configuration: .init(enabled: true, retryDelay: 0),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("system-escalation-\(UUID()).log")),
            now: { [clock] in clock.now }
        )

        _ = await notifier.postSystemEvent(.providerUnavailable(status: 402))
        _ = await notifier.postSystemEvent(.providerUnavailable(status: 402))
        XCTAssertEqual(transport.callCount, 1, "an emit storm collapses at the wire")

        // A DIFFERENT kind is a different problem and goes through.
        _ = await notifier.postSystemEvent(.costCapHit(spentUSD: 5, capUSD: 5))
        XCTAssertEqual(transport.callCount, 2)

        // Separate from the intervention channel's 60s window.
        clock.advance(61)
        _ = await notifier.postSystemEvent(.providerUnavailable(status: 402))
        XCTAssertEqual(transport.callCount, 2, "the storm guard outlives the 60s window")

        // Past the guard the ledger's word is law again: a re-opened
        // incident (or the 6h repeat) must not be swallowed here.
        clock.advance(SystemEscalationEvent.remoteStormGuardSeconds)
        _ = await notifier.postSystemEvent(.providerUnavailable(status: 402))
        XCTAssertEqual(transport.callCount, 3)
    }

    // MARK: - 3. The 402 storm through a real engine

    /// Every POST answers 402 and counts itself.
    private final class Always402URLProtocol: URLProtocol {
        nonisolated(unsafe) static var requestCount = 0
        static let lock = NSLock()

        static func resetCount() {
            lock.lock(); requestCount = 0; lock.unlock()
        }
        static var count: Int {
            lock.lock(); defer { lock.unlock() }
            return requestCount
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            Self.lock.lock(); Self.requestCount += 1; Self.lock.unlock()
            let body = Data(#"{"error":{"type":"insufficient_balance","message":"Insufficient Balance"}}"#.utf8)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 402, httpVersion: "HTTP/1.1", headerFields: [:]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    @MainActor
    func testA402StormProducesExactlyOneEscalationAndStopsCalling() async throws {
        Always402URLProtocol.resetCount()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Always402URLProtocol.self]
        let scratch = FileManager.default.temporaryDirectory
        let trace = TraceLog(path: scratch.appendingPathComponent("storm-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: URLSession(configuration: cfg),
            traceLog: trace
        )
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            supervisorPausedRead: { false },
            idleThresholdSeconds: 9999,
            idleReTriageIntervalSeconds: 9999,
            idleCheckIntervalSeconds: 3600,  // keep the 1Hz timer out of this test
            recordEngineProgress: {},
            trace: trace
        )
        // The wiring seam main.swift hangs the page + banner + hover notice
        // off: counting emissions here counts all three surfaces at once.
        final class EventLog: @unchecked Sendable {
            private let lock = NSLock()
            private var inner: [SystemEscalationEvent] = []
            func append(_ e: SystemEscalationEvent) { lock.lock(); inner.append(e); lock.unlock() }
            var snapshot: [SystemEscalationEvent] { lock.lock(); defer { lock.unlock() }; return inner }
        }
        let emitted = EventLog()
        engine.onSystemEvent = { emitted.append($0) }
        engine.start()
        defer { engine.stop() }

        bus.publish(.sessionStart(.init(
            sessionId: "s-storm", cwd: "/Users/test/proj", gitBranch: "main",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: Date()
        )))
        bus.publish(.userPrompt(.init(sessionId: "s-storm", text: "run the checks", ts: Date())))

        // First command: hits the wire, meets the 402, trips the breaker.
        bus.publish(.bashToolCall(.init(
            sessionId: "s-storm", command: "echo one", description: nil,
            toolUseId: "t-1", turnUUID: "u-1", ts: Date()
        )))
        let deadline = Date().addingTimeInterval(5)
        while emitted.snapshot.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(emitted.snapshot, [.providerUnavailable(status: 402)])
        let wireCallsAtTrip = Always402URLProtocol.count
        XCTAssertGreaterThanOrEqual(wireCallsAtTrip, 1)

        // The storm: more commands while the account is still dead. The
        // breaker is open, so none of these may touch the network, and the
        // hourly throttle means none of them re-emit.
        for index in 2...6 {
            bus.publish(.bashToolCall(.init(
                sessionId: "s-storm", command: "echo \(index)", description: nil,
                toolUseId: "t-\(index)", turnUUID: "u-\(index)", ts: Date()
            )))
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(emitted.snapshot.count, 1,
                       "a 402 storm pages once; the second page carries no new information")
        XCTAssertEqual(Always402URLProtocol.count, wireCallsAtTrip,
                       "an open breaker means zero further network attempts, not one failed call per command")
    }
}
