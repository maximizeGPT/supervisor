// RemoteInboxTransportIntegrationTests.swift
//
// Item 9: the live subscribe path, end to end, over a real socket.
//
// Everything else about the reply channel is tested against stubs, which is
// right for the gates and wrong for the transport. `URLSessionRemoteInbox
// Transport` has a whole half that only exists once there is a server on
// the other end: a response with no Content-Length has to STREAM rather
// than arrive in one lump, a non-2xx has to surface as a failure rather
// than as an empty stream, a server-side close has to end the stream
// cleanly, and the poll URL has to carry a query string ntfy would read.
// None of that is exercised by a scripted `RemoteInboxTransport`, and all
// of it is what breaks in the field.
//
// So these tests stand up `FakeNtfyServer` on 127.0.0.1 on a kernel-chosen
// port and point the REAL transport, the REAL `RemoteInboxSubscriber` and
// the REAL `RemoteReplyGate` at it. The only stub left is the injector, at
// the very end of the chain, standing in for a keyboard.
//
// HOW THIS AVOIDS THE CLOCK. Nothing here sleeps and nothing here asserts
// on elapsed time. The subscriber's sleeper is replaced with one that
// records the pause and returns, so the ladder is a recorded value rather
// than a wait; every wait in the file is an XCTestExpectation fulfilled by
// the code under test. "Injected exactly once" is not a count checked after
// a delay, it is an expectation with `assertForOverFulfill` set, so a
// second injection fails the test at the moment it happens no matter how
// long afterwards it arrives.
//
// TEARDOWN. The server and the subscriber are instance properties torn down
// in `tearDown()` as well as in each test's `defer`, so a failed assertion
// cannot leak a listening socket or leave a connection parked in a `hang`
// episode for the rest of the suite.

import XCTest
@testable import SupervisorCore

final class RemoteInboxTransportIntegrationTests: XCTestCase {

    /// A topic long enough for the endpoint to arm on.
    private static let topic = "supervisorTestTopic0"

    private var server: FakeNtfyServer?
    private var subscriber: RemoteInboxSubscriber?

    override func tearDown() {
        subscriber?.stop()
        subscriber = nil
        server?.stop()
        server = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func trace() -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-transport-\(UUID()).log"))
    }

    /// Records what reached the keyboard. The stub is here and nowhere
    /// earlier: everything upstream of it in these tests is production code.
    private final class RecordingInjector: RemoteReplyInjecting, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [RemoteReplyInjection] = []
        private let onInject: @Sendable () -> Void

        init(onInject: @escaping @Sendable () -> Void) {
            self.onInject = onInject
        }

        var requests: [RemoteReplyInjection] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        func injectRemoteReply(_ request: RemoteReplyInjection) async -> RemoteReplyInjectionResult {
            lock.lock(); _requests.append(request); lock.unlock()
            onInject()
            return .injected
        }
    }

    private final class PauseRecorder: @unchecked Sendable {
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

    /// One ntfy JSON line, the shape the real server emits.
    private func line(id: String, event: String, message: String = "") -> String {
        var object: [String: Any] = ["id": id, "time": 1_757_000_000, "event": event, "topic": Self.topic]
        if !message.isEmpty { object["message"] = message }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - The whole path, over a socket

    /// One coherent run covering four things that share the server:
    ///
    ///   1. a message injected EXACTLY once,
    ///   2. an `open` and a `keepalive` handled without incident,
    ///   3. the stream dropping, the loop degrading to the poll fallback,
    ///      and the poll re-delivering the SAME message id with no second
    ///      injection,
    ///   4. that the loop then comes to rest on a healthy quiet stream.
    ///
    /// They are one test because they are one continuous life of one
    /// connection loop, and splitting them would mean asserting on a state
    /// three reconnects deep that no separate test could honestly reach.
    func testStreamKeepalivePollFallbackAndExactlyOnceDelivery() async throws {
        let server = FakeNtfyServer()
        self.server = server
        try server.start()
        defer { server.stop() }

        let messageId = "MSG-0001"
        let correlations = ReplyCorrelationTable()
        let code = try XCTUnwrap(correlations.mint(
            sessionId: "session-abc",
            cwd: "/Users/you/project",
            branch: "main",
            outcomeKind: "answer"
        ))
        let replyText = "yes go ahead"

        // Episode 1 is a real stream: ntfy's opening event, a keepalive,
        // then the owner's reply, then a clean close. Episodes 2 to 4 fail
        // outright, which is what drives the loop into the poll fallback
        // (three consecutive failures). Everything after that hangs, so the
        // loop parks instead of spinning against a no-op sleeper.
        server.scriptStream([
            .lines([
                line(id: "OPEN-1", event: "open"),
                line(id: "KEEP-1", event: "keepalive"),
                line(id: messageId, event: "message", message: "\(code) \(replyText)"),
            ]),
            .status(500),
            .status(500),
            .status(500),
        ], fallback: .hang)

        // The poll re-delivers the message the stream already delivered.
        // That is the real behaviour being defended against: a reconnect
        // and a `since` cursor overlap, and the id is the only thing
        // standing between that and the owner's sentence being typed twice.
        server.scriptPoll(lines: [line(id: messageId, event: "message", message: "\(code) \(replyText)")])

        let injectedOnce = expectation(description: "the reply is injected")
        injectedOnce.expectedFulfillmentCount = 1
        injectedOnce.assertForOverFulfill = true

        let duplicateRefused = expectation(description: "the re-delivered message is refused as a duplicate")
        duplicateRefused.expectedFulfillmentCount = 1
        duplicateRefused.assertForOverFulfill = true

        let polled = expectation(description: "the poll fallback ran")
        polled.assertForOverFulfill = false
        server.observeRequests { request in
            if request.query["poll"] == "1" { polled.fulfill() }
        }

        let injector = RecordingInjector { injectedOnce.fulfill() }
        let gate = RemoteReplyGate(
            correlations: correlations,
            injecting: injector,
            configuration: .init(enabled: true),
            trace: trace()
        )

        let endpoint = RemoteReplyEndpoint(base: server.baseURL, topic: Self.topic)
        let pauses = PauseRecorder()
        let subscriber = RemoteInboxSubscriber(
            endpoint: endpoint,
            enabled: true,
            transport: URLSessionRemoteInboxTransport(),
            trace: trace(),
            // The backoff becomes a recorded number instead of a wait. A
            // busy machine cannot change what this test means.
            sleeper: { seconds in pauses.record(seconds) },
            handler: { message in
                let disposition = await gate.accept(message)
                if disposition == .duplicate { duplicateRefused.fulfill() }
            }
        )
        self.subscriber = subscriber
        defer { subscriber.stop() }

        subscriber.start()
        await fulfillment(of: [injectedOnce, polled, duplicateRefused], timeout: 60)

        // 1. Exactly one injection, carrying the owner's text with the code
        //    stripped, routed to the session the code was minted for.
        XCTAssertEqual(injector.requests.count, 1)
        XCTAssertEqual(injector.requests.first?.text, replyText)
        XCTAssertEqual(injector.requests.first?.sessionId, "session-abc")

        // 2. The gate's own books agree: one accepted, one duplicate, and
        //    nothing charged to the owner's failure budget.
        let stats = gate.snapshot
        XCTAssertEqual(stats.accepted, 1)
        XCTAssertEqual(stats.duplicates, 1)
        XCTAssertEqual(stats.badCodes, 0)
        XCTAssertFalse(stats.lockedOut)

        // 3. The open and keepalive events reached the loop and stopped
        //    there. Had either been treated as owner text, the gate would
        //    have counted it unsolicited; had either broken the read, the
        //    message after them would never have arrived.
        XCTAssertEqual(stats.unsolicited, 0, "non-message events must not reach the gate at all")

        // 4. The poll asked for what came AFTER the message it had already
        //    seen, which is the cursor doing its job.
        let pollRequests = server.requests.filter { $0.query["poll"] == "1" }
        XCTAssertFalse(pollRequests.isEmpty)
        XCTAssertEqual(pollRequests.first?.query["since"], messageId,
                       "the poll's cursor is the last id the stream delivered")
        XCTAssertEqual(pollRequests.first?.path, "/\(Self.topic)/json")

        // 5. The stream was retried the whole time. Polling is the degraded
        //    mode, not the destination.
        let streamRequests = server.requests.filter { $0.query["poll"] != "1" }
        XCTAssertGreaterThanOrEqual(streamRequests.count, 4,
                                    "the loop keeps reconnecting while it polls")

        // 6. The backoff stayed on the bounded ladder and reached the poll
        //    cadence, without this test having waited a second of it.
        XCTAssertFalse(pauses.pauses.isEmpty)
        let ceiling = max(RemoteInboxSubscriber.pollInterval, RemoteInboxSubscriber.backoffLadder.max() ?? 0)
        XCTAssertLessThanOrEqual(pauses.pauses.max() ?? 0, ceiling,
                                 "an ordinary failure run must never reach the denial cadence")

        // 7. Health is honest about a channel that failed and recovered.
        XCTAssertTrue(subscriber.inboxHealth.armed)
        XCTAssertNil(subscriber.inboxHealth.deniedStatus, "500s are blips, not refusals")
    }

    // MARK: - A 404 is a refusal, not a quiet channel

    /// The degraded state: a topic that is not there answers 404, and the
    /// loop has to treat that as "this will not work until something
    /// changes" rather than as "no replies yet". A 404 read as an empty
    /// stream is indistinguishable from a healthy silent channel, which is
    /// the exact failure the whole health story exists to prevent.
    func testA404DegradesTheChannelAndPagesTheOwnerOnce() async throws {
        let server = FakeNtfyServer()
        self.server = server
        try server.start()
        defer { server.stop() }

        // Every attempt is refused, because a refusal is a standing state
        // and the loop has to keep probing it.
        server.scriptStream([], fallback: .status(404))

        let paged = expectation(description: "the owner is paged about the refusal")
        paged.expectedFulfillmentCount = 1
        paged.assertForOverFulfill = true

        // The loop drops to a minutes-scale cadence once refused. Parking
        // there is how this test observes the degraded cadence without
        // sitting through it, and it stops a no-op sleeper from spinning
        // the reconnect loop for the rest of the run.
        let deniedCadence = expectation(description: "the loop drops to the denial cadence")
        deniedCadence.assertForOverFulfill = false
        let pauses = PauseRecorder()

        let denials = PauseRecorder()
        let endpoint = RemoteReplyEndpoint(base: server.baseURL, topic: Self.topic)
        let subscriber = RemoteInboxSubscriber(
            endpoint: endpoint,
            enabled: true,
            transport: URLSessionRemoteInboxTransport(),
            trace: trace(),
            sleeper: { seconds in
                pauses.record(seconds)
                guard seconds >= RemoteInboxSubscriber.deniedPause else { return }
                deniedCadence.fulfill()
                // Park. Cancelled by `stop()` in the defer below.
                try? await Task.sleep(nanoseconds: UInt64.max)
            },
            onDenied: { status in
                denials.record(TimeInterval(status))
                paged.fulfill()
            },
            handler: { _ in XCTFail("a refused endpoint delivers no messages") }
        )
        self.subscriber = subscriber
        defer { subscriber.stop() }

        subscriber.start()
        await fulfillment(of: [paged, deniedCadence], timeout: 60)

        // The page carried the status, once.
        XCTAssertEqual(denials.pauses, [404])

        // The panel's own line, from the same health snapshot the row reads
        // at render, so what the owner is told matches what the loop knows.
        let health = subscriber.inboxHealth
        XCTAssertEqual(health.deniedStatus, 404)
        XCTAssertTrue(health.armed, "both gates still pass; it is the endpoint that refuses")
        XCTAssertGreaterThan(health.consecutiveFailures, 0)
        XCTAssertEqual(
            HoverViewModel.remoteReplyInboxLine(health),
            "Replies: your ntfy endpoint answered 404. Replies are not arriving."
        )

        // And the cadence really is the slow one, not the ladder.
        XCTAssertEqual(pauses.pauses.last, RemoteInboxSubscriber.deniedPause)
    }

    // MARK: - A non-stream body is a failure, not silence

    /// The sibling of the 404: a 200 that is not a stream. A server that
    /// answers an HTML error page with a 200 is a captive portal or a
    /// misconfigured proxy, and every line of it decodes to nothing. What
    /// matters is that the loop does not sit there believing it is
    /// subscribed: the body ends, the stream closes, and it reconnects.
    func testAnHTMLBodyOnA200YieldsNoMessagesAndReconnects() async throws {
        let server = FakeNtfyServer()
        self.server = server
        try server.start()
        defer { server.stop() }

        let reconnected = expectation(description: "the loop tried again after a junk body")
        reconnected.expectedFulfillmentCount = 2
        reconnected.assertForOverFulfill = false
        server.observeRequests { request in
            if request.query["poll"] != "1" { reconnected.fulfill() }
        }

        server.scriptStream([
            .lines(["<html>", "<body>Captive portal</body>", "</html>"]),
        ], fallback: .hang)

        let subscriber = RemoteInboxSubscriber(
            endpoint: RemoteReplyEndpoint(base: server.baseURL, topic: Self.topic),
            enabled: true,
            transport: URLSessionRemoteInboxTransport(),
            trace: trace(),
            sleeper: { _ in },
            handler: { _ in XCTFail("an HTML body carries no ntfy messages") }
        )
        self.subscriber = subscriber
        defer { subscriber.stop() }

        subscriber.start()
        await fulfillment(of: [reconnected], timeout: 60)
        XCTAssertNil(subscriber.inboxHealth.deniedStatus, "a 200 is not a refusal, however useless its body")
    }
}
