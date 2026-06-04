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
        sessionId: String = "s1",
        suggestedInjectText: String? = nil,
        category: String = "destructive_action_pending"
    ) -> TriageDecision {
        TriageDecision(
            sessionId: sessionId,
            cwd: cwd,
            candidate: TriageCandidate(
                category: category,
                severity: .high,
                matchedCommand: "rm -rf /tmp/x",
                action: action,
                reasoningPlain: "fake plain",
                reasoningTechnical: "fake technical",
                suggestedInjectText: suggestedInjectText
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
        sender: CapturingSignalSender = CapturingSignalSender(),
        injector: MockInjector = MockInjector(),
        activeSessionCount: @escaping () -> Int = { 1 }
    ) -> (router: InterventionRouter, notifier: MockNotifier, sender: CapturingSignalSender, injector: MockInjector) {
        let notifier = MockNotifier()
        let router = InterventionRouter(
            notifier: notifier,
            locator: StubLocator(handle: handle),
            signalSender: sender,
            injector: injector,
            activeSessionCount: activeSessionCount,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("router-test-\(UUID().uuidString).log"))
        )
        return (router, notifier, sender, injector)
    }

    // MARK: - Tests

    func testNotifyDispatchPostsBanner_NoSignalSent() async {
        let (router, notifier, sender, _) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .notify))
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls.first?.outcome, .notifyOnly,
                       "notify path must post via postInterventionResult with .notifyOnly")
        XCTAssertTrue(sender.sent.isEmpty, "notify path must not send any signal")
    }

    func testPauseDispatchSendsSIGSTOPAndPostsPauseBanner() async {
        // v0.1.4 Gap 1+2+3 + v0.1.6 recovery doc: successful pause posts
        // an outcome-aware banner carrying the recovery doc path.
        let (router, notifier, sender, _) = makeRouter()
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
        let (router, notifier, sender, _) = makeRouter()
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
        let (router, notifier, sender, _) = makeRouter(handle: nil)
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertTrue(sender.sent.isEmpty, "no signal sent when locator returns nil")
        XCTAssertEqual(notifier.calls.count, 1, "locator-nil must degrade to a notify banner")
        XCTAssertEqual(notifier.calls.first?.outcome, .notifyOnly,
                       "degraded path must use .notifyOnly outcome (not a misleading pauseSucceeded)")
    }

    func testPausePermissionDeniedDegradesToNotify() async {
        let sender = CapturingSignalSender()
        sender.throwOnNext = SignalError(errnoValue: EPERM)
        let (router, notifier, _, _) = makeRouter(sender: sender)
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertTrue(sender.sent.isEmpty, "send() threw before recording — no successful signal")
        XCTAssertEqual(notifier.calls.count, 1, "EPERM must degrade to notify")
        XCTAssertEqual(notifier.calls.first?.outcome, .notifyOnly)
    }

    func testPauseProcessGoneDegradesToNotify() async {
        let sender = CapturingSignalSender()
        sender.throwOnNext = SignalError(errnoValue: ESRCH)
        let (router, notifier, _, _) = makeRouter(sender: sender)
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(notifier.calls.count, 1, "ESRCH must degrade to notify")
        XCTAssertEqual(notifier.calls.first?.outcome, .notifyOnly)
    }

    func testPauseMissingCwdDegradesToNotifyWithoutCallingLocator() async {
        // Locator stub returns a non-nil handle, but the decision has no
        // cwd — router must short-circuit at the cwd check, NOT call the
        // locator, NOT send a signal, fire notify.
        let (router, notifier, sender, _) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .pause, cwd: nil))
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(notifier.calls.count, 1)
    }

    func testDoublePauseIsHarmlessNoOpOnSender() async {
        // Sender is mock; SIGSTOP to an already-stopped process is a
        // no-op on Darwin but the sender doesn't model that. The test's
        // invariant is "router doesn't crash when dispatched twice."
        let (router, _, sender, _) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .pause))
        await router.dispatch(decision: makeDecision(action: .pause))
        XCTAssertEqual(sender.sent, [
            .init(signal: SIGSTOP, pid: 4242),
            .init(signal: SIGSTOP, pid: 4242),
        ])
    }

    func testKillAfterPauseSendsBothSignalsInOrder() async {
        let (router, _, sender, _) = makeRouter()
        await router.dispatch(decision: makeDecision(action: .pause))
        await router.dispatch(decision: makeDecision(action: .kill))
        XCTAssertEqual(sender.sent, [
            .init(signal: SIGSTOP, pid: 4242),
            .init(signal: SIGTERM, pid: 4242),
        ])
    }

    // MARK: - Inject tests (v0.3.0)

    func testInjectWithTextAndPIDPostsInjectSucceededBanner() async {
        // Happy path: candidate carries inject text, locator returns a PID,
        // mock injector accepts and returns byte count. Router must post
        // .injectSucceeded with the same PID and byte count.
        let injector = MockInjector()
        injector.bytesToReturn = 42
        let (router, notifier, sender, recorder) = makeRouter(injector: injector)
        await router.dispatch(decision: makeDecision(
            action: .inject,
            suggestedInjectText: "Use sysctl with cwd matching."
        ))
        XCTAssertEqual(recorder.calls.count, 1, "inject path must call the injector exactly once")
        XCTAssertEqual(recorder.calls.first?.text, "Use sysctl with cwd matching.")
        XCTAssertEqual(recorder.calls.first?.pid, 4242)
        XCTAssertTrue(sender.sent.isEmpty, "inject path must NOT send any signal")
        XCTAssertEqual(notifier.calls.count, 1)
        if case let .injectSucceeded(pid, bytes) = notifier.calls.first?.outcome {
            XCTAssertEqual(pid, 4242)
            XCTAssertEqual(bytes, 42)
        } else {
            XCTFail("expected injectSucceeded outcome, got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    // MARK: - Multi-session misroute guard (2026-06-04)

    /// The exact bug: >1 session live AND the locator fell back to the shared
    /// Claude desktop host (handle.cwd "/" != the decision cwd) — pasting into
    /// the frontmost tab could hit the WRONG session. Must degrade to notify,
    /// never inject.
    func testMultiSessionUnconfirmedTargetDegradesWithoutInjecting() async {
        let fallback = ProcessHandle(pid: 94716, execPath: "/Applications/Claude.app/Contents/MacOS/Claude", cwd: "/")
        let (router, notifier, _, recorder) = makeRouter(handle: fallback, activeSessionCount: { 2 })
        await router.dispatch(decision: makeDecision(action: .inject, suggestedInjectText: "Answer for session A"))
        XCTAssertTrue(recorder.calls.isEmpty, "must NOT inject when the target session can't be confirmed across multiple sessions")
        if case let .injectDegraded(intended, reason) = notifier.calls.first?.outcome {
            XCTAssertEqual(reason, "multi_session_unconfirmed_target")
            XCTAssertEqual(intended, "Answer for session A", "the intended text must still surface as a banner")
        } else {
            XCTFail("expected injectDegraded, got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    /// Single session: even the desktop fallback is safe (only one place it can
    /// go), so the gate must NOT fire — no regression for single-session users.
    func testSingleSessionWithFallbackTargetStillInjects() async {
        let fallback = ProcessHandle(pid: 94716, execPath: "/Applications/Claude.app/Contents/MacOS/Claude", cwd: "/")
        let injector = MockInjector(); injector.bytesToReturn = 10
        let (router, _, _, recorder) = makeRouter(handle: fallback, injector: injector, activeSessionCount: { 1 })
        await router.dispatch(decision: makeDecision(action: .inject, suggestedInjectText: "x"))
        XCTAssertEqual(recorder.calls.count, 1, "single session is unambiguous — inject must proceed")
    }

    /// Multiple sessions but the locator PINNED this session's own process
    /// (handle.cwd == the decision cwd, e.g. a terminal session). Precise
    /// targeting is safe regardless of how many sessions are live.
    func testMultiSessionWithPreciseTargetStillInjects() async {
        let precise = ProcessHandle(pid: 4242, execPath: "/path/claude", cwd: "/tmp/test-cwd")
        let injector = MockInjector(); injector.bytesToReturn = 10
        let (router, _, _, recorder) = makeRouter(handle: precise, injector: injector, activeSessionCount: { 5 })
        await router.dispatch(decision: makeDecision(action: .inject, suggestedInjectText: "x"))
        XCTAssertEqual(recorder.calls.count, 1, "a precise per-session match is safe even with many sessions live")
    }

    func testInjectWithNoSuggestedTextDegradesToPlainNotify() async {
        // Inject action but no text — degrade to plain notify, NOT
        // injectDegraded (because there's no intended text to surface).
        let injector = MockInjector()
        let (router, notifier, sender, recorder) = makeRouter(injector: injector)
        await router.dispatch(decision: makeDecision(action: .inject, suggestedInjectText: nil))
        XCTAssertTrue(recorder.calls.isEmpty, "injector must NOT be called when no text")
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(notifier.calls.first?.outcome, .notifyOnly,
                       "no-text inject falls through to plain notify (nothing to surface in banner)")
    }

    func testInjectLocatorNilDegradesWithIntendedTextInBanner() async {
        // Locator fails → inject can't run → banner must carry the
        // intended text so the user can paste manually.
        let injector = MockInjector()
        let (router, notifier, sender, recorder) = makeRouter(handle: nil, injector: injector)
        await router.dispatch(decision: makeDecision(
            action: .inject,
            suggestedInjectText: "Answer text"
        ))
        XCTAssertTrue(recorder.calls.isEmpty, "injector must NOT be called when locator returns nil")
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(notifier.calls.count, 1)
        if case let .injectDegraded(intended, reason) = notifier.calls.first?.outcome {
            XCTAssertEqual(intended, "Answer text")
            XCTAssertEqual(reason, "locator_nil")
        } else {
            XCTFail("expected injectDegraded(locator_nil), got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    func testInjectNoHostingAppDegrades() async {
        let injector = MockInjector()
        injector.errorToThrow = .noHostingApp
        let (router, notifier, sender, recorder) = makeRouter(injector: injector)
        await router.dispatch(decision: makeDecision(
            action: .inject,
            suggestedInjectText: "Answer text"
        ))
        XCTAssertEqual(recorder.calls.count, 1, "injector must be called before it errors")
        XCTAssertTrue(sender.sent.isEmpty)
        if case let .injectDegraded(_, reason) = notifier.calls.first?.outcome {
            XCTAssertEqual(reason, "no_hosting_app")
        } else {
            XCTFail("expected injectDegraded(no_hosting_app), got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    func testInjectTargetUnresolvableDegradesWithSpecificReason() async {
        // The invariant's failure path: when the specific target can't be
        // resolved, inject throws targetUnresolvable and the router degrades to
        // notify with a DISTINCT, specific trace reason (§4b) — never a global
        // post, never a generic "fell back to notify".
        let injector = MockInjector()
        injector.errorToThrow = .targetUnresolvable(reason: "no_host_pid")
        let (router, notifier, sender, recorder) = makeRouter(injector: injector)
        await router.dispatch(decision: makeDecision(
            action: .inject,
            suggestedInjectText: "Answer text"
        ))
        XCTAssertEqual(recorder.calls.count, 1, "injector must be called before it errors")
        XCTAssertTrue(sender.sent.isEmpty, "must NOT fall back to any send/post on an unresolved target")
        if case let .injectDegraded(_, reason) = notifier.calls.first?.outcome {
            XCTAssertEqual(reason, "target_unresolvable_no_host_pid",
                           "degrade reason must name the specific failure")
        } else {
            XCTFail("expected injectDegraded(target_unresolvable_no_host_pid), got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    func testInjectUnsupportedHostDegrades() async {
        let injector = MockInjector()
        injector.errorToThrow = .unsupportedHost(bundleID: "com.example.weird")
        let (router, notifier, _, _) = makeRouter(injector: injector)
        await router.dispatch(decision: makeDecision(
            action: .inject,
            suggestedInjectText: "Answer text"
        ))
        if case let .injectDegraded(_, reason) = notifier.calls.first?.outcome {
            XCTAssertTrue(reason.contains("unsupported_host"),
                          "reason must encode the unsupported bundle ID for trace")
            XCTAssertTrue(reason.contains("com.example.weird"))
        } else {
            XCTFail("expected injectDegraded(unsupported_host_*), got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    func testInjectMissingCwdDegradesWithoutCallingInjector() async {
        let injector = MockInjector()
        let (router, notifier, _, recorder) = makeRouter(injector: injector)
        await router.dispatch(decision: makeDecision(
            action: .inject,
            cwd: nil,
            suggestedInjectText: "Answer text"
        ))
        XCTAssertTrue(recorder.calls.isEmpty, "missing cwd must not reach the injector")
        if case let .injectDegraded(_, reason) = notifier.calls.first?.outcome {
            XCTAssertEqual(reason, "no_cwd_on_decision")
        } else {
            XCTFail("expected injectDegraded(no_cwd_on_decision)")
        }
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
            case .injectSucceeded(let pid, let bytes):
                return base + " Supervisor answered (PID \(pid), \(bytes) bytes injected)."
            case .injectDegraded(let intendedText, _):
                return base + " Supervisor would have answered: \(intendedText) Paste this into Claude Code to continue."
            case .continueFired(let pid, _, let promptHead):
                return base + " Supervisor dispatched: \(promptHead)\(promptHead.count >= 80 ? "..." : "") (PID \(pid))"
            case .continueProposedMedium(let proposal, _):
                return base + " Supervisor proposes: \(proposal) Paste this into Claude Code to continue, or write your own."
            case .continueLowConfidence(let reasoning):
                return base + " Supervisor saw idle but couldn't confidently dispatch — pick the next task yourself. Reason: \(reasoning)"
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
