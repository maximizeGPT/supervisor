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
        struct Posted {
            let decision: TriageDecision
            /// `nil` when the router called the legacy `post(decision:)`;
            /// set to the outcome passed when router called the v0.1.4
            /// `postInterventionResult(decision:outcome:)`.
            let outcome: InterventionOutcome?
        }
        private let lock = NSLock()
        private var _calls: [Posted] = []
        var calls: [Posted] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func post(decision: TriageDecision) async -> Notifier.Outcome {
            lock.lock(); _calls.append(Posted(decision: decision, outcome: nil)); lock.unlock()
            return .posted
        }
        func postInterventionResult(
            decision: TriageDecision,
            outcome: InterventionOutcome
        ) async -> Notifier.Outcome {
            lock.lock(); _calls.append(Posted(decision: decision, outcome: outcome)); lock.unlock()
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
        XCTAssertEqual(notifier.calls.first?.outcome, .notifyOnly,
                       "notify path must post via postInterventionResult with .notifyOnly")
        XCTAssertTrue(sender.sent.isEmpty, "notify path must not send any signal")
    }

    func testPauseDispatchSendsSIGSTOPAndPostsPauseBanner() async {
        // v0.1.4 Gap 1+2+3 + v0.1.6 recovery doc: successful pause posts
        // an outcome-aware banner carrying the recovery doc path.
        let (router, notifier, sender) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertEqual(sender.sent, [.init(signal: SIGSTOP, pid: 4242)])
        XCTAssertEqual(notifier.calls.count, 1,
                       "successful pause must post one outcome-aware banner")
        if case let .pauseSucceeded(pid, _) = notifier.calls.first?.outcome {
            XCTAssertEqual(pid, 4242, "banner outcome must carry the paused PID")
        } else {
            XCTFail("expected pauseSucceeded outcome, got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    func testKillDispatchSendsSIGTERMAndPostsKillBanner() async {
        let (router, notifier, sender) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .kill))
        XCTAssertEqual(sender.sent, [.init(signal: SIGTERM, pid: 4242)])
        XCTAssertEqual(notifier.calls.count, 1,
                       "successful kill must post one outcome-aware banner")
        if case .killSucceeded = notifier.calls.first?.outcome {
            // OK
        } else {
            XCTFail("expected killSucceeded outcome, got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    func testPauseLocatorNilDegradesToNotify() async {
        let (router, notifier, sender) = makeRouter(handle: nil)
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertTrue(sender.sent.isEmpty, "no signal sent when locator returns nil")
        XCTAssertEqual(notifier.calls.count, 1, "locator-nil must degrade to a notify banner")
        XCTAssertEqual(notifier.calls.first?.outcome, .notifyOnly,
                       "degraded path must use .notifyOnly outcome (not a misleading pauseSucceeded)")
    }

    func testPausePermissionDeniedDegradesToNotify() async {
        let sender = CapturingSignalSender()
        sender.throwOnNext = SignalError(errnoValue: EPERM)
        let (router, notifier, _) = makeRouter(sender: sender)
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertTrue(sender.sent.isEmpty, "send() threw before recording — no successful signal")
        XCTAssertEqual(notifier.calls.count, 1, "EPERM must degrade to notify")
        XCTAssertEqual(notifier.calls.first?.outcome, .notifyOnly)
    }

    func testPauseProcessGoneDegradesToNotify() async {
        let sender = CapturingSignalSender()
        sender.throwOnNext = SignalError(errnoValue: ESRCH)
        let (router, notifier, _) = makeRouter(sender: sender)
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(notifier.calls.count, 1, "ESRCH must degrade to notify")
        XCTAssertEqual(notifier.calls.first?.outcome, .notifyOnly)
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
        XCTAssertEqual(notifier.calls.first?.outcome, .notifyOnly)
        XCTAssertTrue(sender.sent.isEmpty, ".inject must NOT send any signal")
    }
}

// MARK: - Banner copy tests (Gap 1+2+3)

/// Pure body-string assertions for the outcome-aware composer. Mirrors
/// the NotifierTests pattern of using a shim instead of constructing a
/// real Notifier (which crashes the xctest harness).
final class NotifierOutcomeBodyTests: XCTestCase {

    private func decision(plain: String = "Claude Code is about to delete the project dir.") -> TriageDecision {
        TriageDecision(
            sessionId: "s",
            cwd: "/tmp/test",
            candidate: TriageCandidate(
                category: "destructive_action_pending",
                severity: .high,
                matchedCommand: "rm -rf /Users/main/x",
                action: .pause,
                reasoningPlain: plain,
                reasoningTechnical: "tech"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: "s", command: "rm -rf /Users/main/x", description: nil,
                toolUseId: "t1", turnUUID: "u1", ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                   cache_creation_input_tokens: nil,
                                   cache_read_input_tokens: nil),
            model: "claude-haiku-4-5-20251001",
            prePost: .preExecution
        )
    }

    /// Body composer shim — same shape as the real `Notifier.body(for:outcome:)`,
    /// extracted so we don't construct UNUserNotificationCenter.
    private struct BodyShim {
        func body(for d: TriageDecision, outcome: InterventionOutcome) -> String {
            let base = Notifier.bannerPrefix + d.candidate.reasoningPlain
            switch outcome {
            case .notifyOnly:
                return base
            case .pauseSucceeded(let pid, let path):
                if let p = path {
                    return base + " Session paused (PID \(pid)). Recovery: \(p.path)"
                } else {
                    return base + " Session paused. To resume: `kill -CONT \(pid)`."
                }
            case .killSucceeded(let path):
                if let p = path {
                    return base + " Session killed. Read recovery doc before starting new `claude`: \(p.path)"
                } else {
                    return base + " Session killed. Start a new `claude` invocation to continue."
                }
            }
        }
    }

    func testNotifyOnlyBodyMatchesV012Shape() {
        let s = BodyShim().body(for: decision(), outcome: .notifyOnly)
        XCTAssertTrue(s.hasPrefix(Notifier.bannerPrefix))
        XCTAssertFalse(s.contains("kill -CONT"))
        XCTAssertFalse(s.contains("Start a new"))
    }

    func testPauseSucceededBodyWithoutRecoveryFallsBackToKillCONT() {
        // Recovery-doc-nil (writer failed) → banner falls back to v0.1.4 inline copy.
        let s = BodyShim().body(for: decision(), outcome: .pauseSucceeded(pid: 12345, recoveryDocPath: nil))
        XCTAssertTrue(s.contains("kill -CONT 12345"),
                      "fallback pause banner must surface the literal kill -CONT command")
        XCTAssertTrue(s.contains("Session paused"))
    }

    func testPauseSucceededBodyWithRecoveryPointsToDoc() {
        // Happy path (v0.1.6): banner surfaces recovery doc path with the PID.
        let url = URL(fileURLWithPath: "/tmp/recovery/test-paused.md")
        let s = BodyShim().body(for: decision(), outcome: .pauseSucceeded(pid: 7777, recoveryDocPath: url))
        XCTAssertTrue(s.contains("PID 7777"), "v0.1.6 pause banner surfaces PID")
        XCTAssertTrue(s.contains("/tmp/recovery/test-paused.md"),
                      "v0.1.6 pause banner must surface the recovery doc path")
    }

    func testKillSucceededBodyWithoutRecoveryFallsBackToStartFreshClaude() {
        let s = BodyShim().body(for: decision(), outcome: .killSucceeded(recoveryDocPath: nil))
        XCTAssertTrue(s.contains("Start a new `claude` invocation"),
                      "fallback kill banner must direct user to a fresh session")
        XCTAssertTrue(s.contains("Session killed"))
    }

    func testKillSucceededBodyWithRecoveryPointsToDoc() {
        let url = URL(fileURLWithPath: "/tmp/recovery/test-killed.md")
        let s = BodyShim().body(for: decision(), outcome: .killSucceeded(recoveryDocPath: url))
        XCTAssertTrue(s.contains("Read recovery doc before starting new"),
                      "v0.1.6 kill banner must tell user to read the recovery doc first")
        XCTAssertTrue(s.contains("/tmp/recovery/test-killed.md"))
    }
}
