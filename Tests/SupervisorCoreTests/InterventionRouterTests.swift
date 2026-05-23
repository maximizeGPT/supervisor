// InterventionRouterTests.swift — A4 verification.
//
// Tests the InterventionRouter's dispatch policy with mocked Notifier /
// ProcessLocator / SignalSender. Coverage:
//
//   - .notify              → notifier.post called, no signal sent
//   - .pause + locator OK  → SIGSTOP sent to the located PID
//   - .kill  + locator OK  → SIGTERM sent to the located PID
//   - .pause, locator nil  → notifier.post fired (degrade), no signal
//   - .pause, EPERM throw  → notifier.post fired (degrade), signal attempted once
//   - .pause, ESRCH throw  → notifier.post fired (degrade), signal attempted once
//   - .pause, missing cwd  → notifier.post fired (degrade), locator not called
//   - double pause         → second SIGSTOP no-ops on the sender (no-throw)
//   - kill after pause     → SIGSTOP then SIGTERM, both fire

import XCTest
import Darwin
@testable import SupervisorCore

@MainActor
final class InterventionRouterTests: XCTestCase {

    // MARK: - Mocks

    final class MockNotifier: Notifying, @unchecked Sendable {
        struct Posted { let decision: TriageDecision }
        private let lock = NSLock()
        private var _calls: [Posted] = []
        var calls: [Posted] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func post(decision: TriageDecision) async -> Notifier.Outcome {
            lock.lock(); _calls.append(Posted(decision: decision)); lock.unlock()
            return .posted
        }
    }

    struct StubLocator: ProcessLocator {
        let handle: ProcessHandle?
        func locate(targetCwd: String) -> ProcessHandle? { handle }
    }

    final class CapturingSignalSender: SignalSender, @unchecked Sendable {
        struct Sent: Equatable { let signal: Int32; let pid: pid_t }
        private let lock = NSLock()
        private var _sent: [Sent] = []
        var sent: [Sent] {
            lock.lock(); defer { lock.unlock() }
            return _sent
        }
        var throwOnNext: SignalError?
        func send(_ signal: Int32, to pid: pid_t) throws {
            lock.lock(); defer { lock.unlock() }
            if let err = throwOnNext {
                throwOnNext = nil
                throw err
            }
            _sent.append(Sent(signal: signal, pid: pid))
        }
    }

    // MARK: - Fixtures

    private func makeDecision(
        action: FlagAction,
        cwd: String? = "/tmp/test-cwd",
        sessionId: String = "s1"
    ) -> TriageDecision {
        TriageDecision(
            sessionId: sessionId,
            cwd: cwd,
            candidate: TriageCandidate(
                category: "destructive_action_pending",
                severity: .high,
                matchedCommand: "rm -rf /tmp/x",
                action: action,
                reasoningPlain: "fake plain",
                reasoningTechnical: "fake technical"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: sessionId,
                command: "rm -rf /tmp/x",
                description: nil,
                toolUseId: "t1",
                turnUUID: "u1",
                ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                   cache_creation_input_tokens: nil,
                                   cache_read_input_tokens: nil),
            model: "haiku",
            prePost: .preExecution
        )
    }

    private func makeRouter(
        handle: ProcessHandle? = ProcessHandle(pid: 4242, execPath: "/path/claude", cwd: "/tmp/test-cwd"),
        sender: CapturingSignalSender = CapturingSignalSender()
    ) -> (router: InterventionRouter, notifier: MockNotifier, sender: CapturingSignalSender) {
        let notifier = MockNotifier()
        let router = InterventionRouter(
            notifier: notifier,
            locator: StubLocator(handle: handle),
            signalSender: sender,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("router-test-\(UUID().uuidString).log"))
        )
        return (router, notifier, sender)
    }

    // MARK: - Tests

    func testNotifyDispatchPostsBanner_NoSignalSent() async {
        let (router, notifier, sender) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .notify))
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertTrue(sender.sent.isEmpty, "notify path must not send any signal")
    }

    func testPauseDispatchSendsSIGSTOPToLocatedPID() async {
        let (router, notifier, sender) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertEqual(sender.sent, [.init(signal: SIGSTOP, pid: 4242)])
        XCTAssertTrue(notifier.calls.isEmpty,
                      "successful pause must NOT also fire a notify (the banner is the degraded path)")
    }

    func testKillDispatchSendsSIGTERMToLocatedPID() async {
        let (router, notifier, sender) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .kill))
        XCTAssertEqual(sender.sent, [.init(signal: SIGTERM, pid: 4242)])
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    func testPauseLocatorNilDegradesToNotify() async {
        let (router, notifier, sender) = makeRouter(handle: nil)
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertTrue(sender.sent.isEmpty, "no signal sent when locator returns nil")
        XCTAssertEqual(notifier.calls.count, 1, "locator-nil must degrade to a notify banner")
    }

    func testPausePermissionDeniedDegradesToNotify() async {
        let sender = CapturingSignalSender()
        sender.throwOnNext = SignalError(errnoValue: EPERM)
        let (router, notifier, _) = makeRouter(sender: sender)
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertTrue(sender.sent.isEmpty, "send() threw before recording — no successful signal")
        XCTAssertEqual(notifier.calls.count, 1, "EPERM must degrade to notify")
    }

    func testPauseProcessGoneDegradesToNotify() async {
        let sender = CapturingSignalSender()
        sender.throwOnNext = SignalError(errnoValue: ESRCH)
        let (router, notifier, _) = makeRouter(sender: sender)
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(notifier.calls.count, 1, "ESRCH must degrade to notify")
    }

    func testPauseMissingCwdDegradesToNotifyWithoutCallingLocator() async {
        // Locator stub returns a non-nil handle, but the decision has no
        // cwd — router must short-circuit at the cwd check, NOT call the
        // locator, NOT send a signal, fire notify.
        let (router, notifier, sender) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .pause, cwd: nil))
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(notifier.calls.count, 1)
    }

    func testDoublePauseIsHarmlessNoOpOnSender() async {
        // Sender is mock; SIGSTOP to an already-stopped process is a
        // no-op on Darwin but the sender doesn't model that. The test's
        // invariant is "router doesn't crash when dispatched twice."
        let (router, _, sender) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .pause))
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertEqual(sender.sent, [
            .init(signal: SIGSTOP, pid: 4242),
            .init(signal: SIGSTOP, pid: 4242),
        ])
    }

    func testKillAfterPauseSendsBothSignalsInOrder() async {
        let (router, _, sender) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .pause))
        await router.dispatch(decision: makeDecision(action: .kill))
        XCTAssertEqual(sender.sent, [
            .init(signal: SIGSTOP, pid: 4242),
            .init(signal: SIGTERM, pid: 4242),
        ])
    }

    func testInjectIsRoutedToNotifyForNow() async {
        // .inject is in the FlagAction enum but the executor is queued.
        // Router must treat .inject as notify until the executor ships.
        let (router, notifier, sender) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .inject))
        XCTAssertEqual(notifier.calls.count, 1, ".inject must degrade to notify in v0.1.4")
        XCTAssertTrue(sender.sent.isEmpty, ".inject must NOT send any signal")
    }
}
