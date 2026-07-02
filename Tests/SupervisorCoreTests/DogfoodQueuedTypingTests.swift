// DogfoodQueuedTypingTests.swift
//
// Wave 4 headless dogfood — Scenario 4 (the "queued" honesty contract).
//
// OWNER POLICY (2026-06-13): Supervisor must never type into — or queue
// behind — a composer the human is actively using. So a delivery that lands
// while a real keystroke was <2s ago must DEFER: no type call, and a
// distinct .queued outcome (not a failure, not silence, and never a false
// "sent"). When the human pauses, the loop re-fires and the SAME dispatch is
// delivered — recorded as a SEPARATE fired/answered entry.
//
// This drives the real InterventionRouter with a MUTABLE human-activity
// probe so one test can walk the whole arc: typing → queued → idle →
// delivered. It asserts on the router outcomes AND on how the HoverViewModel
// action log renders them, since "queued" vs "sent" is exactly the honesty
// the log must not blur.

import XCTest
import Darwin
@testable import SupervisorCore

@MainActor
final class DogfoodQueuedTypingTests: XCTestCase {

    // MARK: - A continue-dispatch queues while typing, delivers once idle

    func testContinueDispatchQueuesWhileTypingThenDeliversWhenIdle() async {
        let probe = MutableHumanActivityProbe(idleSeconds: 0.5)  // typing right now
        let notifier = MockNotifier()
        let injector = MockInjector()
        let router = makeRouter(notifier: notifier, injector: injector, probe: probe)

        let proposal = "Pick up Issue #7 and close the per-path-isolation gap. Stop at 75min per §12."
        let decision = continueDecision(sessionId: "queued-continue", proposal: proposal)

        // (1) Human at the keyboard → the dispatch must be HELD, not typed.
        await router.dispatch(decision: decision)
        XCTAssertTrue(injector.calls.isEmpty,
                      "must NOT type into a composer the human is actively using")
        XCTAssertEqual(notifier.outcomes.count, 1)
        if case let .queued(head) = notifier.outcomes.first {
            XCTAssertTrue(proposal.hasPrefix(head), "the queued indicator carries what's pending")
        } else {
            XCTFail("expected .queued, got \(String(describing: notifier.outcomes.first))")
        }

        // (2) Human pauses; the loop re-fires the same dispatch → it delivers.
        probe.set(999)
        await router.dispatch(decision: decision)
        XCTAssertEqual(injector.calls.count, 1, "once idle, the held dispatch is delivered exactly once")
        XCTAssertEqual(injector.calls.first?.text, SupervisorInjectionMarker.wrap(proposal))
        XCTAssertEqual(notifier.outcomes.count, 2, "delivery is a SEPARATE entry from the queue")
        if case .continueFired = notifier.outcomes.last {
            // OK — a real fired outcome, distinct from the earlier .queued.
        } else {
            XCTFail("expected .continueFired on delivery, got \(String(describing: notifier.outcomes.last))")
        }

        // (3) The hover action log renders them as two DISTINCT, honest
        //     entries — "queued" is never conflated with "sent".
        let hover = HoverViewModel(bus: EventBus(trace: traceLog()), trace: traceLog())
        for outcome in notifier.outcomes {
            hover.recordInterventionOutcome(decision, outcome)
        }
        XCTAssertEqual(hover.recentActions.count, 2, "queue and delivery are two separate log entries")
        let labels = hover.recentActions.map(\.plainDescription)
        XCTAssertTrue(labels.contains { $0.contains("Queued") },
                      "the queued entry must read as queued, not sent; got \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("Sent Claude Code its next task") },
                      "the delivery entry must read as sent; got \(labels)")
    }

    // MARK: - An answer-inject queues while typing, delivers once idle

    func testAnswerInjectQueuesWhileTypingThenAnswersWhenIdle() async {
        let probe = MutableHumanActivityProbe(idleSeconds: 0.4)
        let notifier = MockNotifier()
        let injector = MockInjector()
        let router = makeRouter(notifier: notifier, injector: injector, probe: probe)

        let answer = "Use libproc + a cwd match; sysctl KERN_PROCARGS2 for the argv fallback."
        let decision = injectDecision(sessionId: "queued-answer", answer: answer)

        await router.dispatch(decision: decision)
        XCTAssertTrue(injector.calls.isEmpty, "an answer must not be typed while the human is typing")
        if case let .queued(head) = notifier.outcomes.first {
            XCTAssertTrue(answer.hasPrefix(head))
        } else {
            XCTFail("expected .queued, got \(String(describing: notifier.outcomes.first))")
        }

        probe.set(999)
        await router.dispatch(decision: decision)
        XCTAssertEqual(injector.calls.count, 1, "once idle, the answer is delivered")
        if case .injectSucceeded = notifier.outcomes.last {
            // OK
        } else {
            XCTFail("expected .injectSucceeded on delivery, got \(String(describing: notifier.outcomes.last))")
        }
    }

    // MARK: - Fixtures

    private func makeRouter(notifier: MockNotifier, injector: MockInjector,
                            probe: MutableHumanActivityProbe) -> InterventionRouter {
        InterventionRouter(
            notifier: notifier,
            // A precise per-session handle (cwd == decision cwd) so delivery,
            // when it happens, is unambiguous.
            locator: StubLocator(handle: ProcessHandle(
                pid: 42, execPath: "/usr/local/bin/claude", cwd: "/tmp/proj")),
            signalSender: DarwinSignalSender(),
            injector: injector,
            humanActivity: probe,
            trace: traceLog()
        )
    }

    private func continueDecision(sessionId: String, proposal: String) -> TriageDecision {
        decision(
            sessionId: sessionId,
            category: "worker_idle_post_completion",
            action: .continue,
            nextTaskProposal: proposal,
            confidence: "high"
        )
    }

    private func injectDecision(sessionId: String, answer: String) -> TriageDecision {
        decision(
            sessionId: sessionId,
            category: "user_question_pending",
            action: .inject,
            suggestedInjectText: answer
        )
    }

    private func decision(
        sessionId: String,
        category: String,
        action: FlagAction,
        suggestedInjectText: String? = nil,
        nextTaskProposal: String? = nil,
        confidence: String? = nil
    ) -> TriageDecision {
        TriageDecision(
            sessionId: sessionId,
            cwd: "/tmp/proj",
            candidate: TriageCandidate(
                category: category,
                severity: .medium,
                matchedCommand: "(idle)",
                action: action,
                reasoningPlain: "plain",
                reasoningTechnical: "tech",
                asymmetryNote: "justification",
                suggestedInjectText: suggestedInjectText,
                nextTaskProposal: nextTaskProposal,
                confidence: confidence
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: sessionId, command: "(idle)", description: nil,
                toolUseId: "idle-1", turnUUID: "u1", ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                  cache_creation_input_tokens: nil, cache_read_input_tokens: nil),
            model: "haiku",
            prePost: .preExecution
        )
    }

    private func traceLog() -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-queued-\(UUID().uuidString).log"))
    }

    // MARK: - Test doubles

    /// A human-activity probe whose reading can be flipped mid-test — typing
    /// now, idle later — so one test walks queued → delivered.
    private final class MutableHumanActivityProbe: HumanActivityProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var idle: TimeInterval
        init(idleSeconds: TimeInterval) { self.idle = idleSeconds }
        func set(_ v: TimeInterval) { lock.lock(); idle = v; lock.unlock() }
        func secondsSinceLastKeystroke() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return idle }
    }

    private struct StubLocator: ProcessLocator {
        let handle: ProcessHandle?
        func locate(targetCwd: String) -> ProcessHandle? { handle }
        func locate(bySessionId sessionId: String) -> ProcessHandle? { nil }
    }

    private final class MockNotifier: Notifying, @unchecked Sendable {
        private let lock = NSLock()
        private var _outcomes: [InterventionOutcome] = []
        var outcomes: [InterventionOutcome] { lock.lock(); defer { lock.unlock() }; return _outcomes }
        func post(decision: TriageDecision) async -> Notifier.Outcome { .posted }
        func postInterventionResult(decision: TriageDecision, outcome: InterventionOutcome) async -> Notifier.Outcome {
            lock.lock(); _outcomes.append(outcome); lock.unlock()
            return .posted
        }
    }
}
