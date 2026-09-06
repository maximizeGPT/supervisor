// RemoteNotifierTests.swift
//
// The four gates, the retry rules, and the fanout invariants. A stub
// transport stands in for the network so every assertion is on bytes and call
// counts rather than on a live webhook. Nothing in this file opens a socket.
//
// Coverage:
//   - RemoteWebhookURL rejects everything that is not https
//   - disabled / policy-skip / dedupe all short-circuit before any POST
//   - dedupe stamps on SUCCESS only, so a dropped message is retried by the
//     next escalation instead of being swallowed for the window
//   - retryable vs terminal HTTP statuses
//   - apply() flips the switch live
//   - FanoutNotifier always runs the banner first and never lets a remote
//     failure change what the router sees

import XCTest
@testable import SupervisorCore

final class RemoteNotifierTests: XCTestCase {

    // MARK: - Doubles

    final class StubTransport: RemoteNotifyTransport, @unchecked Sendable {
        /// `body` is the wire bytes; content type + headers ride along so
        /// the ntfy shape tests can assert on the whole request.
        struct Sent: Sendable {
            let body: Data
            let contentType: String
            let headers: [String: String]
            let url: URL
        }

        private let lock = NSLock()
        private var _sent: [Sent] = []
        private var _results: [Result<Int, Error>]

        /// Status returned once the scripted results run out.
        let fallbackStatus: Int

        init(results: [Result<Int, Error>] = [], fallbackStatus: Int = 204) {
            self._results = results
            self.fallbackStatus = fallbackStatus
        }

        var sent: [Sent] {
            lock.lock(); defer { lock.unlock() }
            return _sent
        }

        var callCount: Int { sent.count }

        func post(_ body: RemoteNotifyPayload.WireBody, to url: URL) async throws -> Int {
            lock.lock()
            _sent.append(Sent(body: body.data, contentType: body.contentType, headers: body.headers, url: url))
            let next = _results.isEmpty ? nil : _results.removeFirst()
            lock.unlock()
            switch next {
            case .none:              return fallbackStatus
            case .some(.success(let status)): return status
            case .some(.failure(let error)):  throw error
            }
        }
    }

    final class RecordingNotifier: Notifying, @unchecked Sendable {
        private let lock = NSLock()
        private var _kinds: [String] = []
        let result: Notifier.Outcome
        /// Shared ordering log so a test can assert primary-before-secondary.
        let order: OrderLog?
        let name: String

        init(name: String, result: Notifier.Outcome = .posted, order: OrderLog? = nil) {
            self.name = name
            self.result = result
            self.order = order
        }

        var kinds: [String] {
            lock.lock(); defer { lock.unlock() }
            return _kinds
        }

        func post(decision: TriageDecision) async -> Notifier.Outcome {
            record("notify")
            return result
        }

        func postInterventionResult(
            decision: TriageDecision,
            outcome: InterventionOutcome
        ) async -> Notifier.Outcome {
            record(RemoteNotifyPolicy.outcomeKind(outcome))
            return result
        }

        private func record(_ kind: String) {
            lock.lock(); _kinds.append(kind); lock.unlock()
            order?.append(name)
        }
    }

    final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [String] = []
        var entries: [String] {
            lock.lock(); defer { lock.unlock() }
            return _entries
        }
        func append(_ entry: String) {
            lock.lock(); _entries.append(entry); lock.unlock()
        }
    }

    /// Movable clock so the dedupe window is testable without sleeping.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_700_000_000)
        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return _now
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock()
        }
    }

    // MARK: - Fixtures

    private func decision(
        sessionId: String = "sess-1",
        severity: FlagSeverity = .high,
        category: String = "destructive_action_pending"
    ) -> TriageDecision {
        TriageDecision(
            sessionId: sessionId,
            cwd: "/Users/test/code/repo",
            candidate: TriageCandidate(
                category: category,
                severity: severity,
                matchedCommand: "rm -rf /Users/test/code/repo/.build",
                action: .pause,
                reasoningPlain: "plain",
                reasoningTechnical: "technical"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: sessionId,
                command: "rm -rf /Users/test/code/repo/.build",
                description: nil,
                toolUseId: "t1",
                turnUUID: "u1",
                ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1),
            model: "haiku",
            prePost: .preExecution
        )
    }

    private func makeNotifier(
        enabled: Bool = true,
        detail: RemoteNotifyDetail = .minimal,
        dedupeWindow: TimeInterval = 60,
        maxAttempts: Int = 2,
        transport: StubTransport = StubTransport(),
        clock: TestClock = TestClock(),
        url: String = "https://discord.com/api/webhooks/1/token"
    ) throws -> (RemoteNotifier, StubTransport, TestClock) {
        let endpoint = try RemoteWebhookURL(validating: url)
        let notifier = RemoteNotifier(
            endpoint: endpoint,
            configuration: .init(
                enabled: enabled,
                detail: detail,
                dedupeWindow: dedupeWindow,
                maxAttempts: maxAttempts,
                // Zero delay: the retry policy is under test, not the wait.
                retryDelay: 0
            ),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: TraceLog(path: Self.scratchLogPath()),
            now: { [clock] in clock.now }
        )
        return (notifier, transport, clock)
    }

    private static func scratchLogPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-remote-tests-\(UUID().uuidString).log")
    }

    private let pause = InterventionOutcome.pauseSucceeded(pid: 4242, recoveryDocPath: nil)

    // MARK: - URL validation

    func testHTTPSRequired() {
        XCTAssertThrowsError(try RemoteWebhookURL(validating: "http://discord.com/api/webhooks/1/t")) { error in
            XCTAssertEqual(error as? RemoteNotifyError, .insecureURL(scheme: "http"))
        }
    }

    func testMalformedURLsRejected() {
        for raw in ["", "   ", "discord.com/webhook", "ftp://example.com/x", "https://"] {
            XCTAssertThrowsError(try RemoteWebhookURL(validating: raw),
                                 "\(raw.isEmpty ? "<empty>" : raw) must not validate")
        }
    }

    func testValidURLKeepsHostAndDetectsFormat() throws {
        let endpoint = try RemoteWebhookURL(validating: "  https://hooks.slack.com/services/T/B/X  ")
        XCTAssertEqual(endpoint.loggableHost, "hooks.slack.com")
        XCTAssertEqual(endpoint.format, .slack)
    }

    // MARK: - Gate 1: enabled

    func testDisabledSendsNothing() async throws {
        let (notifier, transport, _) = try makeNotifier(enabled: false)
        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .skippedDeniedSilently)
        XCTAssertEqual(transport.callCount, 0)
    }

    func testApplyEnablesLiveWithoutRebuilding() async throws {
        let (notifier, transport, _) = try makeNotifier(enabled: false)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(transport.callCount, 0)

        notifier.apply(.init(enabled: true, detail: .minimal, dedupeWindow: 60, maxAttempts: 2, retryDelay: 0))
        XCTAssertTrue(notifier.currentConfiguration.enabled)

        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .posted)
        XCTAssertEqual(transport.callCount, 1)
    }

    func testApplyDisablesLiveWithoutRebuilding() async throws {
        // The switch must work in BOTH directions: the owner turning the
        // channel off mid-run must silence it as immediately as turning it
        // on armed it.
        let (notifier, transport, _) = try makeNotifier(enabled: true)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(transport.callCount, 1)

        notifier.apply(.init(enabled: false, detail: .minimal, dedupeWindow: 0, maxAttempts: 2, retryDelay: 0))
        XCTAssertFalse(notifier.currentConfiguration.enabled)

        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .skippedDeniedSilently)
        XCTAssertEqual(transport.callCount, 1, "nothing may reach the network after the off flip")
    }

    // MARK: - Gate 2: endpoint

    func testNoEndpointSkipsSilentlyAndSendsNothing() async throws {
        let transport = StubTransport()
        let notifier = RemoteNotifier(
            endpoint: nil,
            configuration: .init(enabled: true, detail: .minimal, dedupeWindow: 60, maxAttempts: 2, retryDelay: 0),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: TraceLog(path: Self.scratchLogPath())
        )
        XCTAssertFalse(notifier.hasEndpoint)
        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .skippedDeniedSilently)
        XCTAssertEqual(transport.callCount, 0)
    }

    func testApplyEndpointArmsAnEndpointLessNotifierLive() async throws {
        // The store-the-URL-then-flip-the-switch setup order against a
        // running app: the notifier exists first, the URL arrives later.
        let transport = StubTransport()
        let notifier = RemoteNotifier(
            endpoint: nil,
            configuration: .init(enabled: true, detail: .minimal, dedupeWindow: 60, maxAttempts: 2, retryDelay: 0),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: TraceLog(path: Self.scratchLogPath())
        )
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(transport.callCount, 0)

        notifier.apply(endpoint: try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/1/token"))
        XCTAssertTrue(notifier.hasEndpoint)

        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .posted)
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(transport.sent.first?.url.absoluteString, "https://discord.com/api/webhooks/1/token")
    }

    // MARK: - Gate 2: policy

    func testPolicySkipSendsNothing() async throws {
        let (notifier, transport, _) = try makeNotifier()
        let outcome = await notifier.postInterventionResult(
            decision: decision(),
            outcome: .continueFired(pid: 1, bytes: 2, promptHead: "next")
        )
        XCTAssertEqual(outcome, .skippedDeniedSilently)
        XCTAssertEqual(transport.callCount, 0, "a handled dispatch must never reach the network")
    }

    func testQueuedDeliveryNeverReachesTheNetwork() async throws {
        // The human is at the keyboard, which is the one situation where the
        // banner is already enough.
        let (notifier, transport, _) = try makeNotifier()
        let outcome = await notifier.postInterventionResult(
            decision: decision(),
            outcome: .queued(promptHead: "next")
        )
        XCTAssertEqual(outcome, .skippedDeniedSilently)
        XCTAssertEqual(transport.callCount, 0)
    }

    func testLegacyPostPathStillHitsThePolicy() async throws {
        // post(decision:) maps to notifyOnly, so a low-severity flag posted
        // through the old entry point must not bypass the volume gate.
        let (notifier, transport, _) = try makeNotifier()
        let outcome = await notifier.post(decision: decision(severity: .low))
        XCTAssertEqual(outcome, .skippedDeniedSilently)
        XCTAssertEqual(transport.callCount, 0)

        _ = await notifier.post(decision: decision(severity: .high))
        XCTAssertEqual(transport.callCount, 1, "a high-severity notify is worth the owner's attention")
    }

    // MARK: - Gate 3: dedupe

    func testDuplicateInsideWindowIsSuppressed() async throws {
        let (notifier, transport, _) = try makeNotifier(dedupeWindow: 60)
        let first = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        let second = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(first, .posted)
        XCTAssertEqual(second, .skippedDeniedSilently)
        XCTAssertEqual(transport.callCount, 1, "a flapping loop must page once, not forty times")
    }

    func testDifferentCategoryIsNotSuppressed() async throws {
        let (notifier, transport, _) = try makeNotifier(dedupeWindow: 60)
        _ = await notifier.postInterventionResult(decision: decision(category: "destructive_action_pending"), outcome: pause)
        _ = await notifier.postInterventionResult(decision: decision(category: "prompt_injection_signature"), outcome: pause)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testInventedCategoriesCollapseToOneDedupeKey() async throws {
        // The dedupe key uses the NORMALIZED category. A model minting a
        // fresh invented category per event would otherwise mint a fresh key
        // per event and defeat the collapse entirely.
        let (notifier, transport, _) = try makeNotifier(dedupeWindow: 60)
        _ = await notifier.postInterventionResult(decision: decision(category: "made_up_one"), outcome: pause)
        _ = await notifier.postInterventionResult(decision: decision(category: "made_up_two"), outcome: pause)
        XCTAssertEqual(transport.callCount, 1,
                       "two invented categories must share the unrecognized_category key inside the window")
    }

    func testDedupeBoundaryJustInsideTheWindow() async throws {
        let (notifier, transport, clock) = try makeNotifier(dedupeWindow: 60)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        clock.advance(59)
        let second = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(second, .skippedDeniedSilently, "59s into a 60s window is still suppressed")
        XCTAssertEqual(transport.callCount, 1)
    }

    func testDedupeBoundaryExactlyAtTheWindow() async throws {
        // The window is a strict age < window check: at exactly 60s the
        // stamp has expired and the next escalation goes through.
        let (notifier, transport, clock) = try makeNotifier(dedupeWindow: 60)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        clock.advance(60)
        let second = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(second, .posted)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testWindowExpiryLetsTheNextOneThrough() async throws {
        let (notifier, transport, clock) = try makeNotifier(dedupeWindow: 60)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        clock.advance(61)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testZeroWindowDisablesDedupe() async throws {
        let (notifier, transport, _) = try makeNotifier(dedupeWindow: 0)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testFailedDeliveryDoesNotStampTheDedupeWindow() async throws {
        // The whole point of the channel is that the pause notification
        // arrives. One dropped packet must not cost the owner the window.
        let transport = StubTransport(results: [.success(400), .success(204)])
        let (notifier, _, _) = try makeNotifier(maxAttempts: 1, transport: transport)
        let dropped = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        let retried = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(dropped, .failed(reason: "http_400"))
        XCTAssertEqual(retried, .posted)
        XCTAssertEqual(transport.callCount, 2)
    }

    // MARK: - Delivery and retries

    func testSuccessfulDeliveryPostsTheComposedBody() async throws {
        let (notifier, transport, _) = try makeNotifier()
        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .posted)
        let sent = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(sent.url.absoluteString, "https://discord.com/api/webhooks/1/token")
        let json = String(decoding: sent.body, as: UTF8.self)
        XCTAssertTrue(json.hasPrefix("{\"content\":"), "discord host must produce a discord body: \(json)")
        XCTAssertTrue(json.contains("Supervisor paused Claude Code"), json)
        XCTAssertFalse(json.contains("rm -rf"), "default detail is minimal, so the command stays home")
    }

    func testRetriesOnServerErrorThenSucceeds() async throws {
        let transport = StubTransport(results: [.success(503), .success(204)])
        let (notifier, _, _) = try makeNotifier(maxAttempts: 2, transport: transport)
        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .posted)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testRetriesOnTransportErrorThenSucceeds() async throws {
        let transport = StubTransport(results: [
            .failure(RemoteNotifyError.transport(underlying: "offline")),
            .success(204),
        ])
        let (notifier, _, _) = try makeNotifier(maxAttempts: 2, transport: transport)
        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .posted)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testDoesNotRetryTerminalStatus() async throws {
        let transport = StubTransport(results: [.success(404), .success(204)])
        let (notifier, _, _) = try makeNotifier(maxAttempts: 3, transport: transport)
        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .failed(reason: "http_404"))
        XCTAssertEqual(transport.callCount, 1, "a 404 means the URL is wrong; hammering it changes nothing")
    }

    func testExhaustedRetriesReportFailure() async throws {
        let transport = StubTransport(results: [.success(500), .success(500)])
        let (notifier, _, _) = try makeNotifier(maxAttempts: 2, transport: transport)
        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .failed(reason: "http_500"))
        XCTAssertEqual(transport.callCount, 2)
    }

    func testRetryClassification() {
        XCTAssertTrue(RemoteNotifier.isRetryable(.transport(underlying: "x")))
        XCTAssertTrue(RemoteNotifier.isRetryable(.rejected(status: 429)))
        XCTAssertTrue(RemoteNotifier.isRetryable(.rejected(status: 500)))
        XCTAssertTrue(RemoteNotifier.isRetryable(.rejected(status: 408)))
        XCTAssertFalse(RemoteNotifier.isRetryable(.rejected(status: 400)))
        XCTAssertFalse(RemoteNotifier.isRetryable(.rejected(status: 404)))
        XCTAssertFalse(RemoteNotifier.isRetryable(.encodingFailed(reason: "x")))
        XCTAssertEqual(RemoteNotifier.failureTag(.rejected(status: 429)), "http_429")
        XCTAssertEqual(RemoteNotifier.failureTag(.transport(underlying: "x")), "transport")
    }

    func testFullDetailReachesTheWireWhenConfigured() async throws {
        let (notifier, transport, _) = try makeNotifier(detail: .full)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        let json = String(decoding: try XCTUnwrap(transport.sent.first).body, as: UTF8.self)
        XCTAssertTrue(json.contains("rm -rf"), "full detail is opt-in and must actually send the command")
    }

    func testConcurrentIdenticalEscalationsPostOnce() async throws {
        // The delivered stamp lands only after the transport returns, so two
        // identical escalations racing through the dedupe gate would both
        // POST without the in-flight reservation. Hold the first POST open
        // until the second call has been and gone.
        final class GatedTransport: RemoteNotifyTransport, @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0
            private var _released = false
            var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
            func release() { lock.lock(); _released = true; lock.unlock() }
            func post(_ body: RemoteNotifyPayload.WireBody, to url: URL) async throws -> Int {
                lock.lock(); _calls += 1; lock.unlock()
                while true {
                    lock.lock(); let done = _released; lock.unlock()
                    if done { return 204 }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }
        let transport = GatedTransport()
        let endpoint = try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/1/token")
        let notifier = RemoteNotifier(
            endpoint: endpoint,
            configuration: .init(enabled: true, detail: .minimal, dedupeWindow: 60, maxAttempts: 1, retryDelay: 0),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: TraceLog(path: Self.scratchLogPath())
        )
        let d = decision()
        let first = Task { await notifier.postInterventionResult(decision: d, outcome: pause) }
        // Wait until the first POST is actually in flight before racing it.
        while transport.calls == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let second = await notifier.postInterventionResult(decision: d, outcome: pause)
        XCTAssertEqual(second, .skippedDeniedSilently, "the racing duplicate must be reserved out, not double-page")
        transport.release()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .posted)
        XCTAssertEqual(transport.calls, 1)
    }

    // MARK: - Trace privacy

    func testTransportErrorNeverTracesTheWebhookURL() async throws {
        // URLSession NSErrors carry the full failing URL in userInfo. The
        // trace log must never see it: the URL is a bearer credential.
        let secretURL = "https://discord.com/api/webhooks/999/FAKE-SECRET-WEBHOOK-TOKEN"
        let underlying = URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLStringErrorKey: secretURL,
            NSURLErrorFailingURLErrorKey: URL(string: secretURL) as Any,
        ])
        let transport = StubTransport(results: [.failure(underlying), .failure(underlying)])
        let logPath = Self.scratchLogPath()
        let trace = TraceLog(path: logPath)
        let notifier = RemoteNotifier(
            endpoint: try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/1/token"),
            configuration: .init(enabled: true, detail: .minimal, dedupeWindow: 0, maxAttempts: 2, retryDelay: 0),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: trace
        )
        let outcome = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .failed(reason: "transport"))
        trace.sync()
        let logged = try String(contentsOf: logPath, encoding: .utf8)
        XCTAssertFalse(logged.contains("FAKE-SECRET-WEBHOOK-TOKEN"),
                       "the failing URL's token must never reach the trace log: \(logged)")
        XCTAssertFalse(logged.contains("/api/webhooks/"),
                       "no webhook path may reach the trace log: \(logged)")
        XCTAssertTrue(logged.contains("remote.transport_error"),
                      "the failure itself must still be traced: \(logged)")
    }

    func testTraceSafeMessageReducesAURLErrorToItsCodeAlone() {
        // Code only, no localizedDescription: nobody can prove every
        // localized string for every code on every OS build is URL-free,
        // and the numeric code is what a debugging session actually needs.
        let secretURL = "https://hooks.slack.com/services/T/B/FAKE-SECRET"
        let e = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: secretURL])
        XCTAssertEqual(RemoteNotifier.traceSafeMessage(for: e),
                       "URLError \(URLError.Code.timedOut.rawValue)")

        struct WeirdError: Error { let secret = "https://hooks.slack.com/services/X" }
        XCTAssertEqual(RemoteNotifier.traceSafeMessage(for: WeirdError()), "WeirdError",
                       "an unknown error type is reduced to its type name")
    }

    // MARK: - Text cap

    func testTextCapClipsAPayloadThatActuallyExceedsIt() {
        // The quoted fields are individually capped at 400, so the only
        // uncapped contributor is the project basename; a pathological cwd
        // is what pushes the composed text past maxTextLength for real.
        let hugeBasename = String(repeating: "d", count: RemoteNotifyPayload.maxTextLength + 500)
        let d = TriageDecision(
            sessionId: "sess-cap",
            cwd: "/Users/test/\(hugeBasename)",
            candidate: TriageCandidate(
                category: "destructive_action_pending",
                severity: .high,
                matchedCommand: "rm -rf /",
                action: .pause,
                reasoningPlain: "plain",
                reasoningTechnical: "technical"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: "sess-cap", command: "rm -rf /", description: nil,
                toolUseId: "t1", turnUUID: "u1", ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1),
            model: "haiku",
            prePost: .preExecution
        )
        let payload = RemoteNotifyPayload.compose(
            decision: d, outcome: pause, reason: "worker_paused",
            detail: .minimal, redactor: DefaultRedactor()
        )
        XCTAssertEqual(payload.text.count, RemoteNotifyPayload.maxTextLength + 3,
                       "an over-cap composition must be clipped to the cap plus the ... marker")
        XCTAssertTrue(payload.text.hasSuffix("..."))
    }

    // MARK: - Fanout

    func testFanoutRunsPrimaryFirstAndReturnsItsOutcome() async throws {
        let order = OrderLog()
        let primary = RecordingNotifier(name: "banner", result: .skippedDeniedSilently, order: order)
        let secondary = RecordingNotifier(name: "remote", result: .posted, order: order)
        let fanout = FanoutNotifier(
            primary: primary,
            secondaries: [secondary],
            trace: TraceLog(path: Self.scratchLogPath())
        )

        let outcome = await fanout.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .skippedDeniedSilently,
                       "the router must keep seeing the BANNER's outcome, not the remote channel's")
        XCTAssertEqual(order.entries, ["banner", "remote"])
        XCTAssertEqual(secondary.kinds, ["pause"])
    }

    func testFanoutSecondaryFailureDoesNotChangeTheResult() async throws {
        let primary = RecordingNotifier(name: "banner", result: .posted)
        let secondary = RecordingNotifier(name: "remote", result: .failed(reason: "transport"))
        let fanout = FanoutNotifier(
            primary: primary,
            secondaries: [secondary],
            trace: TraceLog(path: Self.scratchLogPath())
        )
        let outcome = await fanout.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .posted)
    }

    func testFanoutLegacyPostPathAlsoFansOut() async throws {
        let primary = RecordingNotifier(name: "banner")
        let secondary = RecordingNotifier(name: "remote")
        let fanout = FanoutNotifier(
            primary: primary,
            secondaries: [secondary],
            trace: TraceLog(path: Self.scratchLogPath())
        )
        _ = await fanout.post(decision: decision())
        XCTAssertEqual(primary.kinds, ["notify"])
        XCTAssertEqual(secondary.kinds, ["notify"])
    }

    func testFanoutWithNoSecondariesIsATransparentPassthrough() async throws {
        let primary = RecordingNotifier(name: "banner", result: .posted)
        let fanout = FanoutNotifier(
            primary: primary,
            secondaries: [],
            trace: TraceLog(path: Self.scratchLogPath())
        )
        let outcome = await fanout.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(outcome, .posted)
        XCTAssertEqual(primary.kinds, ["pause"])
    }

    // MARK: - Keychain slot

    func testWebhookKeychainSlotIsNamespacedWithTheProviderKeys() {
        // The E2E harness isolates every Supervisor secret by prefix. A
        // hardcoded service here would let an isolated run overwrite the
        // owner's real webhook. Asserted against an INJECTED environment:
        // comparing the live `service` to the live `keychainServiceBase`
        // would compare a value to its own ingredient and pass no matter
        // what the composition did.
        XCTAssertEqual(
            KeychainRemoteNotifyURLStore.service(environment: [:]),
            "live.supervisor.api.remotenotify"
        )
        XCTAssertEqual(
            KeychainRemoteNotifyURLStore.service(environment: ["SUPERVISOR_KEYCHAIN_PREFIX": "test.supervisor.e2e"]),
            "test.supervisor.e2e.remotenotify",
            "the E2E prefix must namespace the webhook slot exactly like the provider keys"
        )
        XCTAssertEqual(
            KeychainRemoteNotifyURLStore.service(environment: ["SUPERVISOR_KEYCHAIN_PREFIX": ""]),
            "live.supervisor.api.remotenotify",
            "an empty prefix resolves to the live base, same rule as keychainServiceBase"
        )
    }

    // Known coverage gap, on purpose: these tests exercise
    // InMemoryRemoteNotifyURLStore, never KeychainRemoteNotifyURLStore's
    // real read/write/delete (a unit test run must not touch the developer's
    // live Keychain, and a mocked Keychain would test the mock). The real
    // store is exercised by the E2E harness under
    // $SUPERVISOR_KEYCHAIN_PREFIX isolation; building a second in-process
    // harness for it here would duplicate that without the isolation.
    func testInMemoryStoreRoundTrips() throws {
        let store = InMemoryRemoteNotifyURLStore()
        XCTAssertNil(try store.read())
        try store.write("https://example.com/hook")
        XCTAssertEqual(try store.read(), "https://example.com/hook")
        try store.delete()
        XCTAssertNil(try store.read(), "delete is the off switch of last resort and must actually clear")
    }

    // MARK: - Real transport (URLProtocol-mocked)

    /// Mock protocol so the REAL URLSessionRemoteNotifyTransport — its
    /// session configuration and its redirect-refusing delegate included —
    /// can be exercised without a socket.
    final class MockWebhookURLProtocol: URLProtocol {
        enum Script {
            case redirect(to: String, status: Int)
            case fail(URLError)
            case status(Int)
        }
        nonisolated(unsafe) static var script: Script = .status(204)
        nonisolated(unsafe) static var requestCount = 0
        static let scriptLock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.scriptLock.lock()
            Self.requestCount += 1
            let script = Self.script
            Self.scriptLock.unlock()
            guard let url = request.url else { return }
            switch script {
            case .redirect(let location, let status):
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": location]
                )!
                // Announce the redirect so the session consults its delegate;
                // the delegate refuses, and the 3xx response itself is what
                // the task completes with.
                client?.urlProtocol(
                    self,
                    wasRedirectedTo: URLRequest(url: URL(string: location)!),
                    redirectResponse: response
                )
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            case .fail(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .status(let status):
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private func makeMockedTransport() -> URLSessionRemoteNotifyTransport {
        MockWebhookURLProtocol.scriptLock.lock()
        MockWebhookURLProtocol.requestCount = 0
        MockWebhookURLProtocol.scriptLock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockWebhookURLProtocol.self]
        return URLSessionRemoteNotifyTransport(timeout: 5, configuration: configuration)
    }

    func testRealTransportRefusesRedirects() async throws {
        MockWebhookURLProtocol.script = .redirect(to: "https://elsewhere.example.com/x", status: 302)
        let transport = makeMockedTransport()
        let status = try await transport.post(
            RemoteNotifyPayload.WireBody(data: Data("{}".utf8), contentType: "application/json"),
            to: URL(string: "https://discord.com/api/webhooks/1/token")!
        )
        XCTAssertEqual(status, 302,
                       "a 3xx must surface as the rejected status, never be followed")
        XCTAssertEqual(MockWebhookURLProtocol.requestCount, 1,
                       "the credential-bearing POST must never be re-issued to the redirect target")
    }

    func testRealTransportSanitizesNetworkFailures() async throws {
        let secretURL = "https://discord.com/api/webhooks/999/FAKE-SECRET-WEBHOOK-TOKEN"
        MockWebhookURLProtocol.script = .fail(URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorFailingURLStringErrorKey: secretURL,
        ]))
        let transport = makeMockedTransport()
        do {
            _ = try await transport.post(
                RemoteNotifyPayload.WireBody(data: Data("{}".utf8), contentType: "application/json"),
                to: URL(string: secretURL)!
            )
            XCTFail("a failing load must throw")
        } catch let e as RemoteNotifyError {
            guard case .transport(let underlying) = e else {
                return XCTFail("expected .transport, got \(e)")
            }
            XCTAssertFalse(underlying.contains("FAKE-SECRET-WEBHOOK-TOKEN"),
                           "the thrown error must not carry the URL: \(underlying)")
            XCTAssertFalse(underlying.contains("/api/webhooks/"), underlying)
            XCTAssertTrue(underlying.contains("URLError"), underlying)
        }
    }

    // MARK: - Delivery health belongs to ONE endpoint

    /// The panel's Remote escalation row renders delivery health. Carrying it
    /// across an endpoint swap made the row say "Delivered 12m ago" about the
    /// webhook the owner had just replaced, at exactly the moment they were
    /// checking whether the new one works.
    func testApplyingANewEndpointResetsDeliveryHealth() async throws {
        let (notifier, _, _) = try makeNotifier()
        _ = await notifier.post(decision: decision())
        XCTAssertNotNil(notifier.deliveryHealth.lastSuccessAt,
                        "harness check: the first endpoint delivered")

        notifier.apply(endpoint: try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/2/other"))
        XCTAssertEqual(notifier.deliveryHealth, RemoteNotifier.DeliveryHealth(),
                       "a fresh endpoint has no delivery history until it delivers something")
    }

    /// A failure run belongs to its endpoint too. Carrying "failing for an
    /// hour" onto a replacement would send the owner chasing a problem they
    /// had just fixed.
    func testApplyingANewEndpointClearsAStandingFailureRun() async throws {
        let transport = StubTransport(results: [.success(404), .success(404), .success(404), .success(404)])
        let (notifier, _, _) = try makeNotifier(transport: transport)
        _ = await notifier.post(decision: decision())
        XCTAssertGreaterThan(notifier.deliveryHealth.consecutiveFailures, 0,
                             "harness check: the first endpoint is failing")

        notifier.apply(endpoint: try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/3/other"))
        XCTAssertEqual(notifier.deliveryHealth.consecutiveFailures, 0)
        XCTAssertNil(notifier.deliveryHealth.firstFailureAt)
        XCTAssertNil(notifier.deliveryHealth.lastFailureReason)
    }

    /// Re-applying the SAME endpoint is not a swap, so the history it earned
    /// survives. The config watcher re-reads the Keychain periodically.
    func testReapplyingTheSameEndpointKeepsItsHistory() async throws {
        let url = "https://discord.com/api/webhooks/1/token"
        let (notifier, _, _) = try makeNotifier(url: url)
        _ = await notifier.post(decision: decision())
        let before = notifier.deliveryHealth

        notifier.apply(endpoint: try RemoteWebhookURL(validating: url))
        XCTAssertEqual(notifier.deliveryHealth, before)
    }

    func testRealTransportReturnsSuccessStatus() async throws {
        MockWebhookURLProtocol.script = .status(204)
        let transport = makeMockedTransport()
        let status = try await transport.post(
            RemoteNotifyPayload.WireBody(data: Data("{}".utf8), contentType: "application/json"),
            to: URL(string: "https://hooks.slack.com/services/T/B/X")!
        )
        XCTAssertEqual(status, 204)
    }
}
