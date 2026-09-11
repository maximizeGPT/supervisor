// RemoteReplyLocalResolutionTests.swift
//
// Answering at the Mac kills the code that was paged out to answer the same
// question remotely. Two routes reach that: the panel (`respondToFlag`) and
// a swiped banner, which the notification-centre delegate already records
// as `user_response = dismissed`.
//
// The banner route is the one that was missing. Without it a question the
// owner closed on their phone screen left a working write handle into the
// session for the rest of the code's hour, on a topic anyone subscribed can
// read. The delegate itself lives in an executable target XCTest cannot
// import, so the behaviour lives on `HoverViewModel` and the delegate's
// call is one line.

import XCTest
@testable import SupervisorCore

final class RemoteReplyLocalResolutionTests: XCTestCase {

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

    private static func scratchLog() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-local-\(UUID().uuidString).log")
    }

    private func message(_ body: String) -> RemoteInboxMessage {
        RemoteInboxMessage(id: UUID().uuidString, event: "message", message: body)
    }

    @MainActor
    func testSwipingTheBannerAwayRetiresThatFlagsCodeAndOnlyThat() async throws {
        // Answering at the Mac closes the question the page asked, and a
        // banner swipe IS an answer (the delegate records it as
        // `user_response = dismissed`). Without this hook the code stayed
        // live for the rest of its hour on a publicly readable topic.
        let table = ReplyCorrelationTable()
        let injector = RecordingInjector()
        let gate = RemoteReplyGate(
            correlations: table,
            injecting: injector,
            configuration: .init(enabled: true),
            trace: TraceLog(path: Self.scratchLog())
        )
        let now = Date()
        let vm = HoverViewModel(
            bus: EventBus(trace: TraceLog(path: Self.scratchLog())),
            trace: TraceLog(path: Self.scratchLog())
        )
        vm.onFlagBannerDismissed = { flagId in table.retireAll(flagId: flagId) }

        let dismissed = try XCTUnwrap(table.mint(
            sessionId: "session-1", cwd: "/tmp/proj", branch: "main",
            outcomeKind: "inject_degraded", flagId: "flag-dismissed", at: now
        ))
        let other = try XCTUnwrap(table.mint(
            sessionId: "session-2", cwd: "/tmp/other", branch: "main",
            outcomeKind: "inject_degraded", flagId: "flag-other", at: now
        ))

        vm.noteFlagBannerDismissed(flagId: "flag-dismissed")

        let dead = await gate.accept(message("\(dismissed) go ahead"))
        XCTAssertEqual(dead, .unknownCode, "the swiped flag's code is dead")
        let live = await gate.accept(message("\(other) go ahead"))
        XCTAssertEqual(live, .injected(sessionId: "session-2"),
                       "and no other page's code was touched")
        XCTAssertEqual(injector.requests.count, 1)
    }

    @MainActor
    func testAnUnwiredOrEmptyBannerDismissIsHarmless() {
        // Most installs never arm the reply channel, so the hook is nil;
        // and an id-less notification must not reach `retireAll`, whose
        // empty-string guard is the only thing between it and a filter that
        // would match every entry with a nil flagId.
        let vm = HoverViewModel(
            bus: EventBus(trace: TraceLog(path: Self.scratchLog())),
            trace: TraceLog(path: Self.scratchLog())
        )
        vm.noteFlagBannerDismissed(flagId: "flag-1")

        let table = ReplyCorrelationTable()
        var seen: [String] = []
        vm.onFlagBannerDismissed = { seen.append($0) }
        vm.noteFlagBannerDismissed(flagId: "")
        XCTAssertTrue(seen.isEmpty, "an id-less dismissal reaches nothing")

        _ = table.mint(sessionId: "s", cwd: nil, branch: nil, outcomeKind: "k", flagId: nil)
        table.retireAll(flagId: "")
        XCTAssertEqual(table.liveCount(), 1,
                       "an empty flag id must never retire the codes that have none")
    }
}
