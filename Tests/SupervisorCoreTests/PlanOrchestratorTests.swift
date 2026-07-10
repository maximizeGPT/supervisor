// PlanOrchestratorTests.swift
//
// v0.2.0 M2d-1 - unit tests for the pure plan-orchestration decision brain
// (PlanOrchestrator.decide) and the LoopController plan-lifecycle transitions
// (decideAndRecord). Pure logic, fast, NO LLM and NO live I/O - the decision
// tests touch no storage at all; the two persistence tests use an in-memory
// SupervisorDatabase + PlanStore (the EvaluatorTests / StorageTests pattern).
//
// Covers every branch and the documented precedence:
//   - pass -> advance; pass on last step -> complete.
//   - fail under cap with improving score -> redirect carrying the exact feedback.
//   - fail at cap -> escalate(.nonConvergence).
//   - no score progress across attempts -> escalate(.nonConvergence).
//   - each human-insight flag -> escalate with the matching trigger.
//   - safety/destructive precedence beats a passing verdict.
//   - budget exhausted -> abort (and abort outranks an escalation).
//   - replan signal -> replan (carrying the reason).
//   - LoopController records the right persisted transition for advance,
//     complete, and redirect.

import XCTest
import GRDB
@testable import SupervisorCore

final class PlanOrchestratorTests: XCTestCase {

    // MARK: - Fixtures

    /// A plan of `count` pending steps with stable ids step-0..step-(n-1).
    private func makePlan(count: Int, currentStepIndex: Int = 0) -> Plan {
        let steps = (0..<count).map { i in
            PlanStep(
                id: "step-\(i)", index: i, title: "Step \(i)",
                objective: "Do step \(i).",
                doneCriteria: "Step \(i) is verifiably done.",
                status: .active
            )
        }
        return Plan(
            id: "plan-1", sessionId: "sess-1", objective: "Build the thing.",
            steps: steps, status: .running, currentStepIndex: currentStepIndex
        )
    }

    private func pass(_ score: Double = 0.9, _ feedback: String = "all criteria met") -> PlanStep.Verdict {
        PlanStep.Verdict(passed: true, score: score, feedback: feedback)
    }

    private func fail(_ score: Double = 0.3, _ feedback: String = "build failed: missing type Foo") -> PlanStep.Verdict {
        PlanStep.Verdict(passed: false, score: score, feedback: feedback)
    }

    private let orch = PlanOrchestrator()

    // MARK: - Pass -> advance / complete

    func testPassOnNonLastStepAdvances() {
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: pass(),
            signals: OrchestrationSignals(attemptsOnStep: 1, scoreHistoryForStep: [0.9])
        )
        XCTAssertEqual(decision, .advance)
    }

    func testPassOnLastStepCompletes() {
        let plan = makePlan(count: 3, currentStepIndex: 2)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[2], verdict: pass(),
            signals: OrchestrationSignals(attemptsOnStep: 1, scoreHistoryForStep: [0.95])
        )
        XCTAssertEqual(decision, .complete)
    }

    func testSingleStepPlanPassCompletes() {
        let plan = makePlan(count: 1)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: pass(),
            signals: OrchestrationSignals(attemptsOnStep: 1)
        )
        XCTAssertEqual(decision, .complete, "the only step passing completes the plan")
    }

    // MARK: - Fail under cap with progress -> redirect (carrying exact feedback)

    func testFailUnderCapImprovingScoreRedirectsWithExactFeedback() {
        let plan = makePlan(count: 3)
        let fb = "swift build failed: cannot find type 'Clock' in TweetScheduler.swift:12. Declare Clock and re-run swift build."
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0],
            verdict: fail(0.5, fb),
            // attempt 2 of 3, score improved 0.3 -> 0.5.
            signals: OrchestrationSignals(attemptsOnStep: 2, scoreHistoryForStep: [0.3, 0.5])
        )
        XCTAssertEqual(decision, .redirect(feedback: fb),
                       "a failing-but-improving step under the cap redirects with the verdict feedback verbatim")
    }

    func testFirstFailUnderCapRedirects() {
        // First attempt: only one score, nothing to compare, so it is NOT
        // stalled and redirects under the cap.
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: fail(0.4, "missing test"),
            signals: OrchestrationSignals(attemptsOnStep: 1, scoreHistoryForStep: [0.4])
        )
        XCTAssertEqual(decision, .redirect(feedback: "missing test"))
    }

    // MARK: - Fail at cap -> escalate(.nonConvergence)

    func testFailAtAttemptCapEscalatesNonConvergence() {
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0],
            verdict: fail(0.7, "still not passing"),
            // attempt 3 of 3 (at cap) even though the score kept improving.
            signals: OrchestrationSignals(attemptsOnStep: 3, scoreHistoryForStep: [0.3, 0.5, 0.7])
        )
        guard case let .escalate(trigger, reason) = decision else {
            return XCTFail("expected escalate, got \(decision)")
        }
        XCTAssertEqual(trigger, .nonConvergence)
        XCTAssertTrue(reason.contains("cap"), "reason names the attempt-cap condition: \(reason)")
    }

    // MARK: - No score progress across attempts -> escalate(.nonConvergence)

    func testFailNoScoreProgressEscalatesNonConvergenceEvenUnderCap() {
        // Under the attempt cap (2 of 3) but the score did not improve
        // (0.5 -> 0.5): retrying is not helping, so escalate non-convergence.
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0],
            verdict: fail(0.5, "no change"),
            signals: OrchestrationSignals(attemptsOnStep: 2, scoreHistoryForStep: [0.5, 0.5])
        )
        guard case let .escalate(trigger, reason) = decision else {
            return XCTFail("expected escalate, got \(decision)")
        }
        XCTAssertEqual(trigger, .nonConvergence)
        XCTAssertTrue(reason.contains("not making progress"),
                      "reason names the no-progress condition: \(reason)")
    }

    func testFailRegressingScoreEscalatesNonConvergence() {
        // A score that went DOWN (0.6 -> 0.4) is also "no progress".
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0],
            verdict: fail(0.4, "regressed"),
            signals: OrchestrationSignals(attemptsOnStep: 2, scoreHistoryForStep: [0.6, 0.4])
        )
        guard case let .escalate(trigger, _) = decision else {
            return XCTFail("expected escalate, got \(decision)")
        }
        XCTAssertEqual(trigger, .nonConvergence)
    }

    // MARK: - Each human-insight flag -> escalate with the matching trigger

    func testNeedsHumanInputEscalatesAmbiguousRequirement() {
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: fail(),
            signals: OrchestrationSignals(attemptsOnStep: 1, needsHumanInput: true)
        )
        guard case let .escalate(trigger, _) = decision else {
            return XCTFail("expected escalate, got \(decision)")
        }
        XCTAssertEqual(trigger, .ambiguousRequirement)
    }

    func testOffPlanEscalatesPlanDeparture() {
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: fail(),
            signals: OrchestrationSignals(attemptsOnStep: 1, offPlan: true)
        )
        guard case let .escalate(trigger, _) = decision else {
            return XCTFail("expected escalate, got \(decision)")
        }
        XCTAssertEqual(trigger, .planDeparture)
    }

    func testDestructiveActionObservedEscalatesDestructiveAction() {
        // destructiveActionObserved is the boolean the caller sets from
        // DeterministicCatch; the orchestrator defers to that classification.
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: fail(),
            signals: OrchestrationSignals(attemptsOnStep: 1, destructiveActionObserved: true)
        )
        guard case let .escalate(trigger, _) = decision else {
            return XCTFail("expected escalate, got \(decision)")
        }
        XCTAssertEqual(trigger, .destructiveAction)
    }

    func testSafetyConcernEscalatesSafetySecurity() {
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: fail(),
            signals: OrchestrationSignals(attemptsOnStep: 1, safetyConcern: true)
        )
        guard case let .escalate(trigger, _) = decision else {
            return XCTFail("expected escalate, got \(decision)")
        }
        XCTAssertEqual(trigger, .safetySecurity)
    }

    // MARK: - Precedence: safety/destructive beat a PASSING verdict

    func testSafetyConcernBeatsPassingVerdict() {
        // The step graded PASS, but a safety concern was surfaced. Minimal
        // oversight: a human still needs to see it, so escalate, do NOT advance.
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: pass(0.99),
            signals: OrchestrationSignals(attemptsOnStep: 1, safetyConcern: true)
        )
        guard case let .escalate(trigger, _) = decision else {
            return XCTFail("expected escalate over a pass, got \(decision)")
        }
        XCTAssertEqual(trigger, .safetySecurity)
    }

    func testDestructiveActionBeatsPassingVerdict() {
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: pass(0.99),
            signals: OrchestrationSignals(attemptsOnStep: 1, destructiveActionObserved: true)
        )
        guard case let .escalate(trigger, _) = decision else {
            return XCTFail("expected escalate over a pass, got \(decision)")
        }
        XCTAssertEqual(trigger, .destructiveAction)
    }

    func testSafetyOutranksDestructiveWhenBothSet() {
        // Documented order: safetySecurity sits above destructiveAction.
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: fail(),
            signals: OrchestrationSignals(
                attemptsOnStep: 1, destructiveActionObserved: true, safetyConcern: true)
        )
        guard case let .escalate(trigger, _) = decision else {
            return XCTFail("expected escalate, got \(decision)")
        }
        XCTAssertEqual(trigger, .safetySecurity, "safety outranks destructive when both fire")
    }

    // MARK: - Budget exhausted -> abort (and abort outranks everything)

    func testBudgetExhaustedAborts() {
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: fail(),
            signals: OrchestrationSignals(attemptsOnStep: 1, budgetExhausted: true)
        )
        guard case let .abort(reason) = decision else {
            return XCTFail("expected abort, got \(decision)")
        }
        XCTAssertTrue(reason.lowercased().contains("budget"), "abort reason names the budget: \(reason)")
    }

    func testBudgetExhaustedOutranksEscalationAndPass() {
        // Budget is the top of the precedence list: even with a safety concern
        // AND a passing verdict, an exhausted budget aborts.
        let plan = makePlan(count: 3, currentStepIndex: 2)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[2], verdict: pass(0.99),
            signals: OrchestrationSignals(
                attemptsOnStep: 1, budgetExhausted: true, safetyConcern: true)
        )
        guard case .abort = decision else {
            return XCTFail("budget must outrank safety + a pass, got \(decision)")
        }
    }

    // MARK: - Replan signal

    func testNewInfoWarrantsReplanReturnsReplanWithReason() {
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: fail(),
            signals: OrchestrationSignals(
                attemptsOnStep: 1,
                newInfoWarrantsReplan: true,
                replanReason: "the API the next steps depend on was removed upstream")
        )
        XCTAssertEqual(decision, .replan(reason: "the API the next steps depend on was removed upstream"))
    }

    func testReplanSitsBelowHumanGateTriggers() {
        // A re-plan is autonomous, so a human-gate trigger (offPlan) that fires
        // at the same time wins over the re-plan.
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: fail(),
            signals: OrchestrationSignals(
                attemptsOnStep: 1, offPlan: true,
                newInfoWarrantsReplan: true, replanReason: "x")
        )
        guard case let .escalate(trigger, _) = decision else {
            return XCTFail("expected escalate (plan departure) over a replan, got \(decision)")
        }
        XCTAssertEqual(trigger, .planDeparture)
    }

    func testReplanBeatsRoutineAdvance() {
        // A pass would normally advance, but fresh info that the remaining plan
        // is wrong supersedes acting on a now-stale step.
        let plan = makePlan(count: 3)
        let decision = orch.decide(
            plan: plan, currentStep: plan.steps[0], verdict: pass(),
            signals: OrchestrationSignals(
                attemptsOnStep: 1, newInfoWarrantsReplan: true, replanReason: "scope changed")
        )
        XCTAssertEqual(decision, .replan(reason: "scope changed"),
                       "a warranted re-plan supersedes a routine advance")
    }

    // MARK: - Guardrail tunability

    func testCustomMaxAttemptsPerStepIsHonored() {
        // With a cap of 2, the SECOND failing attempt is at the cap and
        // escalates (where the default cap of 3 would still redirect).
        let strict = PlanOrchestrator(maxAttemptsPerStep: 2)
        let plan = makePlan(count: 3)
        let decision = strict.decide(
            plan: plan, currentStep: plan.steps[0], verdict: fail(0.6, "still failing"),
            signals: OrchestrationSignals(attemptsOnStep: 2, scoreHistoryForStep: [0.3, 0.6])
        )
        guard case let .escalate(trigger, _) = decision else {
            return XCTFail("expected escalate at the custom cap, got \(decision)")
        }
        XCTAssertEqual(trigger, .nonConvergence)
    }

    // MARK: - LoopController persisted transitions (in-memory PlanStore)

    /// Seed an in-memory DB + PlanStore with a running plan and return a
    /// LoopController wired to it. Mirrors the EvaluatorTests seeding pattern.
    private func makeControllerWithPlan(
        plan: Plan
    ) throws -> (LoopController, PlanStore) {
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: plan.sessionId, projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        let store = PlanStore(database: db)
        try store.create(plan)
        let lc = LoopController(
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("orch-loop-\(UUID().uuidString).log")),
            planStore: store)
        return (lc, store)
    }

    /// advance: a pass on a non-last step persists step=passed, plan=running,
    /// and the cursor moves to the next index.
    func testDecideAndRecordAdvancePersistsTransition() async throws {
        let plan = makePlan(count: 3, currentStepIndex: 0)
        let (lc, store) = try makeControllerWithPlan(plan: plan)

        let outcome = await lc.decideAndRecord(
            sessionId: plan.sessionId, plan: plan, step: plan.steps[0],
            verdict: pass(0.9), now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(outcome.decision, .advance)
        XCTAssertEqual(outcome.recordedStepStatus, .passed)
        XCTAssertEqual(outcome.recordedPlanStatus, .running)
        XCTAssertEqual(outcome.recordedCurrentStepIndex, 1)
        XCTAssertEqual(outcome.recordedAttempts, 1)

        // Reload from the store and confirm what was actually written.
        let loaded = try XCTUnwrap(try store.currentPlan(sessionId: plan.sessionId))
        XCTAssertEqual(loaded.status, .running)
        XCTAssertEqual(loaded.currentStepIndex, 1, "the cursor advanced to the next step")
        XCTAssertEqual(loaded.steps[0].status, .passed)
        XCTAssertEqual(loaded.steps[0].attempts, 1)
        XCTAssertEqual(loaded.steps[0].lastVerdict?.passed, true)
    }

    /// complete: a pass on the LAST step persists step=passed and plan=completed.
    func testDecideAndRecordCompletePersistsCompletedPlan() async throws {
        let plan = makePlan(count: 2, currentStepIndex: 1)
        let (lc, store) = try makeControllerWithPlan(plan: plan)

        let outcome = await lc.decideAndRecord(
            sessionId: plan.sessionId, plan: plan, step: plan.steps[1],
            verdict: pass(0.95), now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(outcome.decision, .complete)
        XCTAssertEqual(outcome.recordedPlanStatus, .completed)

        let loaded = try XCTUnwrap(try store.currentPlan(sessionId: plan.sessionId))
        XCTAssertEqual(loaded.status, .completed, "the plan is marked completed")
        XCTAssertEqual(loaded.steps[1].status, .passed)
    }

    /// redirect: a first failing attempt persists step=retrying, plan holds on
    /// the same step, and the redirect carries the verdict feedback.
    func testDecideAndRecordRedirectPersistsRetrying() async throws {
        let plan = makePlan(count: 3, currentStepIndex: 0)
        let (lc, store) = try makeControllerWithPlan(plan: plan)

        let outcome = await lc.decideAndRecord(
            sessionId: plan.sessionId, plan: plan, step: plan.steps[0],
            verdict: fail(0.3, "the build is red: missing type Foo"),
            now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(outcome.decision, .redirect(feedback: "the build is red: missing type Foo"))
        XCTAssertEqual(outcome.recordedStepStatus, .retrying)
        XCTAssertEqual(outcome.recordedCurrentStepIndex, 0, "the plan holds on the same step")

        let loaded = try XCTUnwrap(try store.currentPlan(sessionId: plan.sessionId))
        XCTAssertEqual(loaded.currentStepIndex, 0)
        XCTAssertEqual(loaded.steps[0].status, .retrying)
        XCTAssertEqual(loaded.steps[0].attempts, 1, "the attempt counter incremented")
        XCTAssertEqual(loaded.steps[0].lastVerdict?.passed, false)
    }

    /// The controller's per-step counter drives the cap: two failing grades of
    /// the SAME step (attempts 1 then 2) redirect under the default cap of 3,
    /// and the third grade (attempt 3) escalates non-convergence and persists
    /// step=failed.
    func testDecideAndRecordRepeatedFailuresHitCapAndEscalate() async throws {
        let plan = makePlan(count: 3, currentStepIndex: 0)
        let (lc, store) = try makeControllerWithPlan(plan: plan)
        let step = plan.steps[0]
        let t = Date(timeIntervalSince1970: 1_700_000_000)

        // Attempt 1: improving from nothing -> redirect.
        let o1 = await lc.decideAndRecord(
            sessionId: plan.sessionId, plan: plan, step: step,
            verdict: fail(0.3, "f1"), now: t)
        XCTAssertEqual(o1.recordedStepStatus, .retrying)

        // Attempt 2: score improved 0.3 -> 0.5, still under cap -> redirect.
        let o2 = await lc.decideAndRecord(
            sessionId: plan.sessionId, plan: plan, step: step,
            verdict: fail(0.5, "f2"), now: t)
        XCTAssertEqual(o2.recordedStepStatus, .retrying)
        XCTAssertEqual(o2.recordedAttempts, 2)

        // Attempt 3: now AT the cap -> escalate non-convergence, persist failed.
        let o3 = await lc.decideAndRecord(
            sessionId: plan.sessionId, plan: plan, step: step,
            verdict: fail(0.7, "f3"), now: t)
        guard case let .escalate(trigger, _) = o3.decision else {
            return XCTFail("expected escalate at the cap, got \(o3.decision)")
        }
        XCTAssertEqual(trigger, .nonConvergence)
        XCTAssertEqual(o3.recordedStepStatus, .failed)
        XCTAssertEqual(o3.recordedAttempts, 3)

        let loaded = try XCTUnwrap(try store.currentPlan(sessionId: plan.sessionId))
        XCTAssertEqual(loaded.steps[0].status, .failed)
        XCTAssertEqual(loaded.steps[0].attempts, 3, "the controller-owned counter reached the cap")
    }
}
