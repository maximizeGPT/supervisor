// RemoteInboxSubscriberTests.swift
//
// The socket half, against a scripted transport. Nothing here opens a
// connection and nothing here sleeps: the backoff is a recorded value, not
// a wall-clock wait, so a busy machine cannot change a result.
//
// What is worth testing here is narrow on purpose, because the subscriber
// decides nothing. It has to decode correctly, carry the message id through
// (the gate's replay defence is useless without it), ignore keepalives, and
// keep reconnecting inside a bounded ladder.

import XCTest
@testable import SupervisorCore

final class RemoteInboxSubscriberTests: XCTestCase {

    // MARK: - Fixtures

    /// Yields scripted lines, then either finishes (a server-side close) or
    /// throws (a broken connection). Each `stream` call takes the next
    /// script entry, so a test can drive several reconnects in a row.
    final class ScriptedTransport: RemoteInboxTransport, @unchecked Sendable {
        enum Episode {
            case lines([String])
            case failure(Error)
        }

        private let lock = NSLock()
        private var episodes: [Episode]
        private var _streamCalls = 0
        private var _pollCalls: [URL] = []
        /// What every attempt past the script does. Defaults to the shape a
        /// broken endpoint has; a test about an endpoint that REFUSES us
        /// sets it to that status instead, because the refusal has to keep
        /// happening for the backoff to be observable.
        private let fallback: Error

        init(_ episodes: [Episode], fallback: Error = RemoteInboxTransportError.notHTTP) {
            self.episodes = episodes
            self.fallback = fallback
        }

        var streamCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return _streamCalls
        }

        var pollCalls: [URL] {
            lock.lock(); defer { lock.unlock() }
            return _pollCalls
        }

        func stream(url: URL) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            _streamCalls += 1
            let episode = episodes.isEmpty ? Episode.failure(fallback) : episodes.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                switch episode {
                case .lines(let lines):
                    for line in lines { continuation.yield(line) }
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }

        func poll(url: URL) async throws -> [String] {
            lock.lock(); _pollCalls.append(url); lock.unlock()
            return []
        }
    }

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [RemoteInboxMessage] = []
        var messages: [RemoteInboxMessage] {
            lock.lock(); defer { lock.unlock() }
            return _messages
        }
        func append(_ m: RemoteInboxMessage) {
            lock.lock(); _messages.append(m); lock.unlock()
        }
    }

    /// Records the pages a denial produced, so "exactly once per episode"
    /// is an assertion on a list and not on a log line.
    final class DenialRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _statuses: [Int] = []
        var statuses: [Int] {
            lock.lock(); defer { lock.unlock() }
            return _statuses
        }
        func record(_ status: Int) {
            lock.lock(); _statuses.append(status); lock.unlock()
        }
    }

    final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _pauses: [TimeInterval] = []
        var pauses: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return _pauses
        }
        func record(_ seconds: TimeInterval) {
            lock.lock(); _pauses.append(seconds); lock.unlock()
        }
    }

    private func endpoint() throws -> RemoteReplyEndpoint {
        try XCTUnwrap(RemoteReplyEndpoint.derive(
            from: RemoteWebhookURL(validating: "https://ntfy.sh/hDs8dpM3zLpTGGQEabcd"),
            format: .ntfy
        ))
    }

    private func trace() -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-sub-\(UUID().uuidString).log"))
    }

    // MARK: - Decoding

    func testDecodeKeepsTheMessageIdTheReplayDefenceNeeds() {
        let decoded = RemoteInboxMessage.decode(
            line: #"{"id":"kMr8Xq","time":1700000000,"event":"message","topic":"t","message":"a7k2mq go ahead"}"#
        )
        XCTAssertEqual(decoded?.id, "kMr8Xq")
        XCTAssertEqual(decoded?.event, "message")
        XCTAssertEqual(decoded?.message, "a7k2mq go ahead")
        XCTAssertTrue(decoded?.isMessage ?? false)
    }

    func testDecodeRejectsAnythingThatIsNotAnNtfyObject() {
        for line in [
            "",
            "   ",
            "<html><body>404 not found</body></html>",
            #"{"event":"message","message":"no id"}"#,
            #"{"id":"","event":"message","message":"empty id"}"#,
            #"{"id":"x","message":"no event"}"#,
            #"{"id":"x","event":"mes"#,   // a truncated final line
        ] {
            XCTAssertNil(RemoteInboxMessage.decode(line: line),
                         "must not decode: \(line)")
        }
    }

    func testKeepalivesAndOpensAreNotMessages() {
        let keepalive = RemoteInboxMessage.decode(line: #"{"id":"k1","event":"keepalive"}"#)
        XCTAssertNotNil(keepalive)
        XCTAssertFalse(keepalive?.isMessage ?? true)

        let open = RemoteInboxMessage.decode(line: #"{"id":"o1","event":"open"}"#)
        XCTAssertFalse(open?.isMessage ?? true)
    }

    // MARK: - Arming

    func testTheLoopStaysInertWhenTheFeatureIsOff() async throws {
        let transport = ScriptedTransport([.lines([])])
        let sink = Sink()
        let subscriber = RemoteInboxSubscriber(
            endpoint: try endpoint(),
            enabled: false,
            transport: transport,
            trace: trace(),
            sleeper: { _ in }
        ) { sink.append($0) }

        XCTAssertFalse(subscriber.isArmed)
        XCTAssertEqual(subscriber.gateReason, "disabled")
        subscriber.start()
        subscriber.stop()
        XCTAssertEqual(transport.streamCalls, 0,
                       "a disabled channel must not open a connection at all")
    }

    func testTheLoopStaysInertWithNoEndpoint() {
        let transport = ScriptedTransport([])
        let subscriber = RemoteInboxSubscriber(
            endpoint: nil,
            enabled: true,
            transport: transport,
            trace: trace(),
            sleeper: { _ in }
        ) { _ in }

        XCTAssertFalse(subscriber.isArmed)
        XCTAssertEqual(subscriber.gateReason, "no_endpoint")
        subscriber.start()
        subscriber.stop()
        XCTAssertEqual(transport.streamCalls, 0)
    }

    func testArmingNeedsBothTheSwitchAndAnEndpoint() throws {
        let subscriber = RemoteInboxSubscriber(
            endpoint: nil,
            enabled: false,
            transport: ScriptedTransport([]),
            trace: trace(),
            sleeper: { _ in }
        ) { _ in }
        XCTAssertFalse(subscriber.isArmed)

        subscriber.apply(endpoint: try endpoint(), enabled: false)
        XCTAssertFalse(subscriber.isArmed, "an endpoint alone is not consent")

        subscriber.apply(endpoint: nil, enabled: true)
        XCTAssertFalse(subscriber.isArmed, "consent alone is not an address")

        subscriber.apply(endpoint: try endpoint(), enabled: true)
        XCTAssertTrue(subscriber.isArmed)
        XCTAssertEqual(subscriber.gateReason, "armed")
        subscriber.stop()
    }

    // MARK: - Ingest

    func testOnlyMessagesReachTheHandlerAndTheyKeepTheirIds() async {
        let sink = Sink()
        let subscriber = RemoteInboxSubscriber(
            endpoint: nil,
            enabled: false,
            transport: ScriptedTransport([]),
            trace: trace(),
            sleeper: { _ in }
        ) { sink.append($0) }

        await subscriber.ingest(#"{"id":"k1","event":"keepalive"}"#)
        await subscriber.ingest(#"{"id":"o1","event":"open"}"#)
        await subscriber.ingest(#"{"id":"m1","event":"message","message":"a7k2mq go"}"#)
        await subscriber.ingest("garbage that is not json")
        await subscriber.ingest(#"{"id":"m2","event":"message","message":""}"#)

        XCTAssertEqual(sink.messages.map(\.id), ["m1"],
                       "keepalives, opens, junk and empty bodies are not replies")
        XCTAssertEqual(sink.messages.first?.message, "a7k2mq go")
    }

    // MARK: - Reconnect

    func testReconnectBackoffIsBoundedAndClimbs() async throws {
        // Four failures in a row, then the loop is cancelled. The pauses
        // must follow the ladder and never exceed its ceiling, because this
        // is a channel the owner is waiting on: a five-minute backoff after
        // a wifi blip is a reply that silently does nothing for five
        // minutes.
        let recorder = SleepRecorder()
        let transport = ScriptedTransport([
            .failure(RemoteInboxTransportError.rejected(status: 500)),
            .failure(RemoteInboxTransportError.rejected(status: 502)),
            .failure(RemoteInboxTransportError.notHTTP),
            .failure(RemoteInboxTransportError.notHTTP),
        ])
        let done = expectation(description: "four reconnect attempts")
        // The loop keeps retrying until `stop()`, so more pauses can land
        // after the one the test is waiting for.
        done.assertForOverFulfill = false
        let subscriber = RemoteInboxSubscriber(
            endpoint: try endpoint(),
            enabled: true,
            transport: transport,
            trace: trace(),
            sleeper: { seconds in
                recorder.record(seconds)
                if recorder.pauses.count >= 4 { done.fulfill() }
            }
        ) { _ in }

        subscriber.start()
        await fulfillment(of: [done], timeout: 5)
        subscriber.stop()

        XCTAssertEqual(Array(recorder.pauses.prefix(2)), [1, 2],
                       "the ladder climbs from the bottom rung")
        XCTAssertEqual(recorder.pauses.dropFirst(2).first, 30,
                       "past the poll-fallback threshold the loop drops to the slow poll cadence")
        for pause in recorder.pauses {
            XCTAssertLessThanOrEqual(pause, 30,
                                     "the backoff ceiling is thirty seconds, not minutes")
        }
        XCTAssertFalse(transport.pollCalls.isEmpty,
                       "a stream that keeps failing must fall back to polling, not go quiet")
    }

    func testARejectedResponseIsAFailureAndNotAQuietChannel() async throws {
        // A 404 on a topic that has been deleted must reconnect, not sit
        // there looking healthy. A broken channel that reads as a quiet one
        // is the failure mode the whole health story exists to prevent.
        let recorder = SleepRecorder()
        let transport = ScriptedTransport([
            .failure(RemoteInboxTransportError.rejected(status: 404)),
            .failure(RemoteInboxTransportError.rejected(status: 404)),
        ])
        let done = expectation(description: "retried after a 404")
        done.assertForOverFulfill = false
        let subscriber = RemoteInboxSubscriber(
            endpoint: try endpoint(),
            enabled: true,
            transport: transport,
            trace: trace(),
            sleeper: { _ in
                recorder.record(0)
                if recorder.pauses.count >= 2 { done.fulfill() }
            }
        ) { _ in }

        subscriber.start()
        await fulfillment(of: [done], timeout: 5)
        subscriber.stop()
        XCTAssertGreaterThanOrEqual(transport.streamCalls, 2)
    }

    // MARK: - An endpoint that refuses us outright

    func testARefusedEndpointBacksOffToMinutesAndPagesTheOwnerOnce() async throws {
        // A 401, 403 or 404 will not heal on the next attempt: the topic is
        // gone, the server wants a token, or the URL is wrong. Retrying it
        // every thirty seconds forever, with nothing said to the owner, is a
        // channel that is off and looks quiet.
        let recorder = SleepRecorder()
        let denials = DenialRecorder()
        let done = expectation(description: "four refused attempts")
        done.assertForOverFulfill = false
        let transport = ScriptedTransport([], fallback: RemoteInboxTransportError.rejected(status: 403))
        let subscriber = RemoteInboxSubscriber(
            endpoint: try endpoint(),
            enabled: true,
            transport: transport,
            trace: trace(),
            sleeper: { seconds in
                recorder.record(seconds)
                if recorder.pauses.count >= 4 { done.fulfill() }
            },
            onDenied: { denials.record($0) }
        ) { _ in }

        subscriber.start()
        await fulfillment(of: [done], timeout: 5)
        let health = subscriber.inboxHealth
        subscriber.stop()

        XCTAssertEqual(Array(recorder.pauses.prefix(4)), [300, 300, 300, 300],
                       "a refusal outranks the backoff ladder from the first one")
        XCTAssertEqual(denials.statuses, [403],
                       "one page per episode, however many times the endpoint says no")
        XCTAssertEqual(health.deniedStatus, 403,
                       "and the panel can say which status, not just that something is wrong")
        XCTAssertTrue(health.armed)
    }

    func testEveryRefusingStatusIsTreatedAsDegradedAndNothingElseIs() {
        for status in [401, 403, 404] {
            XCTAssertEqual(
                RemoteInboxSubscriber.deniedStatus(for: RemoteInboxTransportError.rejected(status: status)),
                status
            )
        }
        // A 500 or a dropped socket is worth retrying at speed: it is the
        // server having a bad minute, not the server saying no.
        for status in [429, 500, 502, 503] {
            XCTAssertNil(
                RemoteInboxSubscriber.deniedStatus(for: RemoteInboxTransportError.rejected(status: status))
            )
        }
        XCTAssertNil(RemoteInboxSubscriber.deniedStatus(for: RemoteInboxTransportError.notHTTP))
        XCTAssertNil(RemoteInboxSubscriber.deniedStatus(for: URLError(.timedOut)))
    }

    func testARecoveredEndpointClearsTheDenialAndTheNextOnePagesAgain() async throws {
        // Two rules in one run. An ordinary failure must NOT clear a
        // standing denial (a 403 followed by a timeout is still a channel
        // that will not read), and a successful read MUST clear it, latch
        // included, so a later refusal is a new episode the owner hears
        // about.
        let recorder = SleepRecorder()
        let denials = DenialRecorder()
        let done = expectation(description: "four attempts")
        done.assertForOverFulfill = false
        let transport = ScriptedTransport(
            [
                .failure(RemoteInboxTransportError.rejected(status: 403)),
                .failure(RemoteInboxTransportError.notHTTP),
                .lines([#"{"id":"m1","event":"message","message":"a7k2mq go ahead"}"#]),
                .failure(RemoteInboxTransportError.rejected(status: 403)),
            ],
            fallback: RemoteInboxTransportError.rejected(status: 403)
        )
        let subscriber = RemoteInboxSubscriber(
            endpoint: try endpoint(),
            enabled: true,
            transport: transport,
            trace: trace(),
            sleeper: { seconds in
                recorder.record(seconds)
                if recorder.pauses.count >= 4 { done.fulfill() }
            },
            onDenied: { denials.record($0) }
        ) { _ in }

        subscriber.start()
        await fulfillment(of: [done], timeout: 5)
        subscriber.stop()

        XCTAssertEqual(Array(recorder.pauses.prefix(4)), [300, 300, 1, 300],
                       "the denial survives an ordinary failure and dies on a successful read")
        XCTAssertEqual(denials.statuses, [403, 403],
                       "the refusal after a recovery is a new episode, not a repeat")
    }

    func testFlippingTheSwitchOrChangingTheEndpointClearsTheDenial() async throws {
        // The owner fixed the URL. The endpoint they just typed is not the
        // one that was refused, so it gets a clean ladder and a page of its
        // own if it is also refused.
        //
        // The sleeper PARKS after the first pause instead of returning, so
        // the loop is quiescent while the assertions run. Reading state out
        // from under a spinning loop is how a test starts passing on a
        // quiet machine and failing on a loaded one; the park is cancelled
        // by `apply`'s own stop, so nothing here waits on the clock.
        let recorder = SleepRecorder()
        let denials = DenialRecorder()
        let parked = expectation(description: "denied once, then parked")
        parked.assertForOverFulfill = false
        let transport = ScriptedTransport([], fallback: RemoteInboxTransportError.rejected(status: 404))
        let subscriber = RemoteInboxSubscriber(
            endpoint: try endpoint(),
            enabled: true,
            transport: transport,
            trace: trace(),
            sleeper: { seconds in
                recorder.record(seconds)
                parked.fulfill()
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            },
            onDenied: { denials.record($0) }
        ) { _ in }

        subscriber.start()
        await fulfillment(of: [parked], timeout: 5)
        XCTAssertEqual(subscriber.inboxHealth.deniedStatus, 404)
        XCTAssertEqual(denials.statuses, [404])

        subscriber.apply(endpoint: nil, enabled: false)
        XCTAssertNil(subscriber.inboxHealth.deniedStatus,
                     "a disarmed channel reports no standing refusal")
        XCTAssertEqual(subscriber.inboxHealth.consecutiveFailures, 0)
        subscriber.stop()
    }

    // MARK: - Trace hygiene

    func testTransportErrorsAreReducedToSomethingSafeToLog() {
        // A URLError carries the full failing URL in its userInfo, and the
        // topic rides in that URL's path.
        let urlError = URLError(
            .cannotConnectToHost,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://ntfy.sh/SECRET-TOPIC-VALUE/json"]
        )
        let reduced = RemoteInboxSubscriber.traceSafeMessage(for: urlError)
        XCTAssertFalse(reduced.contains("SECRET-TOPIC-VALUE"))
        XCTAssertFalse(reduced.contains("ntfy.sh"))
        XCTAssertEqual(reduced, "URLError \(URLError.Code.cannotConnectToHost.rawValue)")

        XCTAssertEqual(
            RemoteInboxSubscriber.traceSafeMessage(for: RemoteInboxTransportError.rejected(status: 404)),
            "http_404"
        )
        XCTAssertEqual(
            RemoteInboxSubscriber.traceSafeMessage(for: RemoteInboxTransportError.lineTooLong(cap: 65536)),
            "line_too_long_cap_65536"
        )
    }
}
