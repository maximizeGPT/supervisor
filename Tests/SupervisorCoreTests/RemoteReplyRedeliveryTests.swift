// RemoteReplyRedeliveryTests.swift
//
// One integration test, for the property no single-layer test can hold: a
// reply that arrives TWICE is typed once.
//
// It is worth its own file because the two halves of the defence live in
// different types and neither is sufficient. The subscriber re-delivers on
// purpose (a poll after a reconnect asks for everything since the cursor,
// and the message that was already streamed is inside that window), and the
// gate's replay check is what makes that safe. A test of the gate alone
// asserts on a message id the test itself chose; a test of the subscriber
// alone cannot see an injection. So this wires the REAL
// `RemoteInboxSubscriber` to the REAL `RemoteReplyGate` and fakes nothing
// but the socket.
//
// No sleeps and no wall-clock waits: the sleeper is a recorder, and the
// test waits on the pass count rather than on elapsed time.

import XCTest
@testable import SupervisorCore

final class RemoteReplyRedeliveryTests: XCTestCase {

    /// The only fake, and it is the transport boundary. It answers stream
    /// calls from a script and answers every poll with the same backlog a
    /// real ntfy poll would return: everything since the cursor, which
    /// includes the message the stream already delivered.
    final class ReplayingTransport: RemoteInboxTransport, @unchecked Sendable {
        enum Episode {
            /// Yield these lines, then break the connection. The shape a
            /// stream has when a wifi handoff kills it mid-flight, and the
            /// only shape that produces a redelivery worth testing.
            case linesThenFailure([String], Error)
            case failure(Error)
        }

        private let lock = NSLock()
        private var episodes: [Episode]
        private let fallback: Error
        private let pollLines: [String]
        private var _pollCalls: [URL] = []
        private var _streamCalls = 0

        init(episodes: [Episode], fallback: Error, pollLines: [String]) {
            self.episodes = episodes
            self.fallback = fallback
            self.pollLines = pollLines
        }

        var pollCalls: [URL] {
            lock.lock(); defer { lock.unlock() }
            return _pollCalls
        }

        var streamCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return _streamCalls
        }

        func stream(url: URL) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            _streamCalls += 1
            let episode = episodes.isEmpty ? Episode.failure(fallback) : episodes.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                switch episode {
                case .linesThenFailure(let lines, let error):
                    for line in lines { continuation.yield(line) }
                    continuation.finish(throwing: error)
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }

        func poll(url: URL) async throws -> [String] {
            lock.lock(); _pollCalls.append(url); lock.unlock()
            return pollLines
        }
    }

    final class RecordingInjector: RemoteReplyInjecting, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [RemoteReplyInjection] = []
        var requests: [RemoteReplyInjection] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }
        func injectRemoteReply(_ request: RemoteReplyInjection) async -> RemoteReplyInjectionResult {
            lock.lock(); _requests.append(request); lock.unlock()
            return .injected
        }
    }

    final class DispositionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [RemoteReplyDisposition] = []
        var entries: [RemoteReplyDisposition] {
            lock.lock(); defer { lock.unlock() }
            return _entries
        }
        func append(_ d: RemoteReplyDisposition) {
            lock.lock(); _entries.append(d); lock.unlock()
        }
    }

    final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        func record() -> Int {
            lock.lock(); defer { lock.unlock() }
            _count += 1
            return _count
        }
    }

    private func scratchLog() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-redelivery-\(UUID().uuidString).log")
    }

    func testAMessageDeliveredByTheStreamAndAgainByThePollIsTypedOnce() async throws {
        let table = ReplyCorrelationTable()
        let injector = RecordingInjector()
        let dispositions = DispositionLog()
        let gate = RemoteReplyGate(
            correlations: table,
            injecting: injector,
            configuration: .init(enabled: true),
            trace: TraceLog(path: scratchLog())
        )
        let code = try XCTUnwrap(table.mint(
            sessionId: "session-a", cwd: "/tmp/proj", branch: "main",
            outcomeKind: "inject_degraded", flagId: "flag-1"
        ))
        // One ntfy object, one id. The id is the whole replay defence, so
        // the redelivery below has to carry the SAME one, which is exactly
        // what a real poll returns.
        let line = #"{"id":"nTfY1","time":1700000000,"event":"message","topic":"t","message":"REPLY"}"#
            .replacingOccurrences(of: "REPLY", with: "\(code) go ahead and push")

        // Four stream passes: the first delivers and then breaks, the next
        // three fail, which is what tips the loop into polling. The poll
        // then returns the backlog since the cursor, containing that same
        // message.
        let transport = ReplayingTransport(
            episodes: [
                .linesThenFailure([line], RemoteInboxTransportError.rejected(status: 500)),
                .failure(RemoteInboxTransportError.rejected(status: 500)),
                .failure(RemoteInboxTransportError.rejected(status: 500)),
            ],
            fallback: RemoteInboxTransportError.rejected(status: 500),
            pollLines: [line]
        )

        let sleeps = SleepRecorder()
        // Fulfilled on the FOURTH pause, which is one full pass after the
        // poll: `pollOnce` awaits the ingest before it returns, so by then
        // the redelivered message has been all the way through the gate.
        let done = expectation(description: "the poll pass completed")
        done.assertForOverFulfill = false
        let subscriber = RemoteInboxSubscriber(
            endpoint: try XCTUnwrap(RemoteReplyEndpoint.derive(
                from: RemoteWebhookURL(validating: "https://ntfy.sh/hDs8dpM3zLpTGGQEabcd"),
                format: .ntfy
            )),
            enabled: true,
            transport: transport,
            trace: TraceLog(path: scratchLog()),
            sleeper: { _ in
                if sleeps.record() >= 4 { done.fulfill() }
            }
        ) { message in
            dispositions.append(await gate.accept(message))
        }

        subscriber.start()
        await fulfillment(of: [done], timeout: 10)
        subscriber.stop()

        XCTAssertFalse(transport.pollCalls.isEmpty,
                       "a stream that keeps failing has to fall back to polling")
        let seen = dispositions.entries
        XCTAssertGreaterThanOrEqual(seen.count, 2,
                                    "the gate saw the message more than once, which is the point")
        XCTAssertEqual(seen.first, .injected(sessionId: "session-a"))
        XCTAssertEqual(seen.dropFirst().filter { $0 != .duplicate }, [],
                       "every redelivery is refused by the replay check, not by luck")
        XCTAssertEqual(injector.requests.count, 1,
                       "and the owner's sentence was typed into the session exactly once")
        XCTAssertEqual(injector.requests.first?.text, "go ahead and push")
        XCTAssertEqual(table.liveCount(), 0, "the code was spent on the first delivery")
    }
}
