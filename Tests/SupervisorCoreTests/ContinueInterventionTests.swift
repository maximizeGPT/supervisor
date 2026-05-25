// ContinueInterventionTests.swift
//
// v0.4.0 Part B — router-side tests for the .continue action. Builds
// a TriageDecision with the three confidence values the dispatcher
// can produce + verifies the router emits the right
// InterventionOutcome. Mirrors the existing InterventionRouterTests
// mock pattern (MockNotifier captures outcomes; MockInjector +
// StubLocator inject without touching real apps).
//
// Spec coverage (from v0.4.0 Part B B7):
//   - test #1: high confidence → injects the proposal
//   - test #3: medium confidence → notifies with proposal text
//   - test #2: low confidence → notifies with reason
//   - test #5: high confidence + locator nil → degrades to medium banner

import XCTest
import Darwin
@testable import SupervisorCore

@MainActor
final class ContinueInterventionTests: XCTestCase {

    // MARK: - Mocks (re-use InterventionRouterTests shapes via fresh
    // copies — Swift's @testable means we could import them, but XCTest
    // doesn't let us reach into another test class's nested mocks
    // cleanly, so we duplicate the small ones.)

    final class MockNotifier: Notifying, @unchecked Sendable {
        struct Posted { let outcome: InterventionOutcome? }
        private let lock = NSLock()
        private var _calls: [Posted] = []
        var calls: [Posted] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func post(decision: TriageDecision) async -> Notifier.Outcome {
            lock.lock(); _calls.append(Posted(outcome: nil)); lock.unlock()
            return .posted
        }
        func postInterventionResult(
            decision: TriageDecision,
            outcome: InterventionOutcome
        ) async -> Notifier.Outcome {
            lock.lock(); _calls.append(Posted(outcome: outcome)); lock.unlock()
            return .posted
        }
    }

    struct StubLocator: ProcessLocator {
        let handle: ProcessHandle?
        func locate(targetCwd: String) -> ProcessHandle? { handle }
    }

    /// Default injector — succeeds, returns the byte count. Tests
    /// that want failure throw via `errorToThrow`.
    final class CountingMockInjector: Injector, @unchecked Sendable {
        struct Call: Equatable { let text: String; let pid: pid_t }
        private let lock = NSLock()
        private var _calls: [Call] = []
        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        var errorToThrow: InjectError?
        func inject(text: String, claudeCodePID: pid_t) async throws -> Int {
            lock.lock(); defer { lock.unlock() }
            if let err = errorToThrow { throw err }
            _calls.append(Call(text: text, pid: claudeCodePID))
            return text.utf8.count
        }
    }

    // MARK: - Fixtures

    /// Build a TriageDecision with the worker_idle_post_completion
    /// shape Part B's engine produces after the dispatcher runs:
    /// action=.continue, nextTaskProposal + confidence set, the
    /// dispatcher's justification carried as asymmetryNote.
    private func makeContinueDecision(
        confidence: String,
        proposal: String? = nil,
        justification: String = "Mechanical follow-on from the prior commit; tests are the canonical next unit per §6.",
        cwd: String? = "/tmp/test-cwd"
    ) -> TriageDecision {
        let candidate = TriageCandidate(
            category: "worker_idle_post_completion",
            severity: .medium,
            matchedCommand: "(idle) stop-shape: ready for next",
            action: .continue,
            reasoningPlain: "Worker has been idle for 15 seconds after a stop-shaped event.",
            reasoningTechnical: "worker_idle_post_completion fired; dispatcher returned confidence=\(confidence).",
            asymmetryNote: justification,
            nextTaskProposal: proposal,
            confidence: confidence
        )
        return TriageDecision(
            sessionId: "s-continue",
            cwd: cwd,
            candidate: candidate,
            triggeringEvent: BashToolCallInfo(
                sessionId: "s-continue",
                command: "(idle)",
                description: nil,
                toolUseId: "idle-1",
                turnUUID: "u1",
                ts: Date()
            ),
            usage: AnthropicUsage(
                input_tokens: 1, output_tokens: 1,
                cache_creation_input_tokens: nil,
                cache_read_input_tokens: nil
            ),
            model: "haiku",
            prePost: .preExecution
        )
    }

    private func makeRouter(
        notifier: any Notifying = MockNotifier(),
        locator: any ProcessLocator = StubLocator(handle: ProcessHandle(pid: 42, execPath: "/usr/local/bin/claude", cwd: "/tmp/test-cwd")),
        injector: any Injector = CountingMockInjector()
    ) -> InterventionRouter {
        InterventionRouter(
            notifier: notifier,
            locator: locator,
            signalSender: DarwinSignalSender(),
            injector: injector,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("continue-router-\(UUID().uuidString).log"))
        )
    }

    // MARK: - Tests

    /// Spec test #1: high confidence → router injects the proposal
    /// via the Injector + notifier records .continueFired.
    func testContinueHighConfidenceInjectsProposal() async throws {
        let notifier = MockNotifier()
        let injector = CountingMockInjector()
        let router = makeRouter(notifier: notifier, injector: injector)

        let proposal = "Pick up Issue #7. Diff the bash triage prompt against the assistant-text prompt and fix the per-path-isolation gap per PRINCIPLES §2e. Stop at 75min per §12."
        let decision = makeContinueDecision(
            confidence: "high",
            proposal: proposal
        )

        await router.dispatch(decision: decision)

        XCTAssertEqual(injector.calls.count, 1,
                       "high-confidence dispatch must invoke the injector exactly once")
        XCTAssertEqual(injector.calls.first?.text, proposal,
                       "the full next_task_proposal must be the injected text")
        XCTAssertEqual(injector.calls.first?.pid, 42)

        XCTAssertEqual(notifier.calls.count, 1)
        if case let .continueFired(pid, bytes, promptHead)? = notifier.calls.first?.outcome {
            XCTAssertEqual(pid, 42)
            XCTAssertEqual(bytes, proposal.utf8.count)
            XCTAssertTrue(promptHead.hasPrefix("Pick up Issue #7"),
                          "banner head must carry the first chars of the proposal so the user sees what got sent")
        } else {
            XCTFail("expected .continueFired outcome, got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    /// Spec test #3: medium confidence → router does NOT inject; it
    /// surfaces the proposal as a banner with .continueProposedMedium.
    func testContinueMediumConfidenceProposesViaBanner() async throws {
        let notifier = MockNotifier()
        let injector = CountingMockInjector()
        let router = makeRouter(notifier: notifier, injector: injector)

        let proposal = "Pick up Issue #5 OR Issue #7 — both are plausible follow-ons; you decide."
        let decision = makeContinueDecision(
            confidence: "medium",
            proposal: proposal
        )

        await router.dispatch(decision: decision)

        XCTAssertEqual(injector.calls.count, 0,
                       "medium-confidence MUST NOT auto-dispatch; the user decides")
        XCTAssertEqual(notifier.calls.count, 1)
        if case let .continueProposedMedium(p, _)? = notifier.calls.first?.outcome {
            XCTAssertEqual(p, proposal)
        } else {
            XCTFail("expected .continueProposedMedium outcome, got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    /// Spec test #2: low confidence → router emits .continueLowConfidence
    /// with the dispatcher's reasoning, no inject.
    func testContinueLowConfidenceShowsReasoningBanner() async throws {
        let notifier = MockNotifier()
        let injector = CountingMockInjector()
        let router = makeRouter(notifier: notifier, injector: injector)

        let reasoning = "Recent commits look like thrashing on the same file; not enough signal for a confident dispatch."
        let decision = makeContinueDecision(
            confidence: "low",
            proposal: nil,
            justification: reasoning
        )

        await router.dispatch(decision: decision)

        XCTAssertEqual(injector.calls.count, 0)
        XCTAssertEqual(notifier.calls.count, 1)
        if case let .continueLowConfidence(r)? = notifier.calls.first?.outcome {
            XCTAssertEqual(r, reasoning,
                           "banner reason must be the dispatcher's justification so the user knows WHY supervisor went quiet")
        } else {
            XCTFail("expected .continueLowConfidence outcome, got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    /// Spec test #5: high confidence + locator returns nil →
    /// degrade to a medium-confidence banner (NOT a low-confidence
    /// one — we still have the proposal; the user can paste it).
    func testContinueHighConfidenceDegradesToMediumOnLocatorFailure() async throws {
        let notifier = MockNotifier()
        let injector = CountingMockInjector()
        let router = makeRouter(
            notifier: notifier,
            locator: StubLocator(handle: nil),  // locator can't find Claude.app
            injector: injector
        )

        let proposal = "Run the full test suite and journal the result. Stop at 75min per §12."
        let decision = makeContinueDecision(
            confidence: "high",
            proposal: proposal
        )

        await router.dispatch(decision: decision)

        XCTAssertEqual(injector.calls.count, 0,
                       "locator failure must prevent the inject call (no PID to target)")
        XCTAssertEqual(notifier.calls.count, 1)
        if case let .continueProposedMedium(p, _)? = notifier.calls.first?.outcome {
            XCTAssertEqual(p, proposal,
                           "the proposal text must survive the degrade so the user can paste it manually")
        } else {
            XCTFail("expected degrade-to-.continueProposedMedium on locator nil, got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    /// Defensive: high-confidence dispatch with an empty proposal
    /// (shouldn't happen in practice — Dispatcher contract guarantees
    /// prompt-on-high — but verify the router doesn't crash and
    /// degrades sensibly).
    func testContinueHighConfidenceWithoutProposalDegradesToLowConfidence() async throws {
        let notifier = MockNotifier()
        let injector = CountingMockInjector()
        let router = makeRouter(notifier: notifier, injector: injector)

        let decision = makeContinueDecision(
            confidence: "high",
            proposal: nil  // contract violation, should degrade
        )

        await router.dispatch(decision: decision)

        XCTAssertEqual(injector.calls.count, 0,
                       "no proposal text → nothing to inject")
        XCTAssertEqual(notifier.calls.count, 1)
        switch notifier.calls.first?.outcome {
        case .continueLowConfidence?: break
        default:
            XCTFail("expected .continueLowConfidence degrade for empty-proposal-on-high, got \(String(describing: notifier.calls.first?.outcome))")
        }
    }

    /// Inject succeeds at the injector level, but the proposal is
    /// very long — verify the promptHead in the banner truncates
    /// without dropping the full payload from the inject call.
    func testContinueHighConfidenceTruncatesBannerHeadButInjectsFullProposal() async throws {
        let notifier = MockNotifier()
        let injector = CountingMockInjector()
        let router = makeRouter(notifier: notifier, injector: injector)

        // 600-char proposal — well above the 80-char banner head cap.
        let longProposal = String(repeating: "Pick up Issue #7 per §2e. ", count: 25)
        let decision = makeContinueDecision(
            confidence: "high",
            proposal: longProposal
        )

        await router.dispatch(decision: decision)

        // Inject MUST carry the full proposal.
        XCTAssertEqual(injector.calls.first?.text, longProposal,
                       "the injector receives the entire proposal, not the truncated banner head")

        // Banner head should be ≤80 chars (the router caps with prefix(80)).
        if case let .continueFired(_, _, head)? = notifier.calls.first?.outcome {
            XCTAssertLessThanOrEqual(head.count, 80)
        } else {
            XCTFail("expected .continueFired")
        }
    }
}
