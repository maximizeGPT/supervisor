// ContextStewardTests.swift
//
// v0.2.0 M5 - the long-running context steward. Two layers:
//
//   1. ContextSteward (pure): the three-way classifier (.ok / .checkpoint /
//      .severe) over the real session signals (session age, event count,
//      attempts on the current step), at and across its thresholds, with the
//      documented severe > checkpoint > ok precedence.
//   2. PlanLoop integration at the SAFE boundary (post-pass, pre-next-step):
//      - below threshold -> .ok: normal advance, no checkpoint inject.
//      - checkpoint threshold at a safe boundary -> exactly ONE checkpoint
//        injection (the non-destructive HANDOFF.md instruction, prepended to the
//        next step), then normal advance; the cooldown then SUPPRESSES a second
//        checkpoint on the immediately following step.
//      - severe -> escalate(contextDegradation): the loop is paused (stopped),
//        the action is a notify carrying .contextDegradation, NO next-step
//        injection, and NOTHING auto-clears.
//      - gating: with no approved running plan the steward is never consulted and
//        no new behavior occurs.
//
// No network: the Planner + Evaluator are mocked; the PlanStore + LoopController
// are real (in-memory). The marked + ledgered property of the resulting injection
// is proven end-to-end in PlanHarnessEngineTests (the real router path); here we
// drive PlanLoop directly and assert on the returned PlanLoopAction + persisted
// state, mirroring PlanLoopWiringTests.

import XCTest
@testable import SupervisorCore

@MainActor
final class ContextStewardTests: XCTestCase {

    // MARK: - Mocks (mirror PlanLoopWiringTests)

    final class MockPlanner: Planning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var planCalls = 0
        private(set) var replanCalls = 0
        func planForSession(sessionUUID: String, cwd: String?, gitBranch: String?, lastNTurns: [SupervisorEvent]) async -> PlanResult {
            lock.lock(); planCalls += 1; lock.unlock(); return .ungrounded(reasoning: "stub")
        }
        func replan(existing: Plan, observation: String, cwd: String?) async -> PlanResult {
            lock.lock(); replanCalls += 1; lock.unlock(); return .ungrounded(reasoning: "stub")
        }
        var totalCalls: Int { lock.lock(); defer { lock.unlock() }; return planCalls + replanCalls }
    }

    final class MockEvaluator: Evaluating, @unchecked Sendable {
        private let lock = NSLock()
        private var staged: [PlanStep.Verdict]
        private(set) var calls = 0
        init(_ staged: [PlanStep.Verdict]) { self.staged = staged }
        func evaluate(step: PlanStep, observation: Observation) async -> PlanStep.Verdict {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if staged.count > 1 { return staged.removeFirst() }
            return staged.first ?? PlanStep.Verdict(passed: false, score: 0, feedback: "none")
        }
    }

    // MARK: - Builders

    private func freshDB() throws -> SupervisorDatabase { try SupervisorDatabase.inMemory() }

    private func seedSession(_ db: SupervisorDatabase, id: String) throws {
        try SessionStore(database: db).upsert(StoredSession(
            id: id, projectHash: "p", cwd: "/Users/test/supervisor",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/tmp/x.jsonl"))
    }

    /// A 3-step plan so there is always a NEXT step to advance into (the safe
    /// boundary where the steward is consulted), plus a following boundary to
    /// prove the cooldown.
    private func threeStepPlan(sessionId: String, status: Plan.Status = .running) -> Plan {
        Plan(
            id: "plan-\(sessionId)", sessionId: sessionId,
            objective: "Build it in three steps.",
            steps: [
                PlanStep(id: "s0", index: 0, title: "Step zero",
                         objective: "Do step zero.", doneCriteria: "zero done.", status: .active),
                PlanStep(id: "s1", index: 1, title: "Step one",
                         objective: "Do step one.", doneCriteria: "one done.", status: .pending),
                PlanStep(id: "s2", index: 2, title: "Step two",
                         objective: "Do step two.", doneCriteria: "two done.", status: .pending),
            ],
            status: status, currentStepIndex: 0)
    }

    /// Harness with an injectable ContextSteward (so a test can force a band with
    /// tiny thresholds) and an injectable cooldown length on the LoopController.
    private func makeHarness(
        db: SupervisorDatabase,
        steward: ContextSteward,
        cooldownSteps: Int = LoopController.defaultCheckpointCooldownSteps
    ) -> (PlanLoop, PlanStore, LoopController) {
        let planner = MockPlanner()
        let evaluator = MockEvaluator([.init(passed: true, score: 0.95, feedback: "ok")])
        let store = PlanStore(database: db)
        let loop = LoopController(
            checkpointCooldownSteps: cooldownSteps,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("steward-lc-\(UUID().uuidString).log")),
            planStore: store)
        let pl = PlanLoop(
            planner: planner, evaluator: evaluator, planStore: store,
            loopController: loop, contextSteward: steward,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("steward-pl-\(UUID().uuidString).log")))
        return (pl, store, loop)
    }

    /// A window whose earliest event is `age` seconds before `now`, with
    /// `count` events total, all carrying real ground truth so FIX 2 does not
    /// short-circuit the grade. The events are a passing build (so the staged
    /// pass verdict is plausible).
    private func windowAged(sessionId: String, age: TimeInterval, count: Int, now: Date) -> [SupervisorEvent] {
        guard count > 0 else { return [] }
        let earliest = now.addingTimeInterval(-age)
        var events: [SupervisorEvent] = []
        for i in 0..<count {
            // Spread the rest between earliest and now; index 0 is the earliest.
            let frac = count == 1 ? 0 : Double(i) / Double(count - 1)
            let ts = earliest.addingTimeInterval(age * frac)
            events.append(.bashToolCall(.init(
                sessionId: sessionId, command: "swift build", description: nil,
                toolUseId: "tu-\(i)", turnUUID: "u", ts: ts)))
        }
        return events
    }

    // ==========================================================================
    // MARK: - 1. ContextSteward (pure classifier)
    // ==========================================================================

    func testStewardOkBelowAllThresholds() {
        let s = ContextSteward()
        let d = s.assess(ContextSignals(sessionAgeSeconds: 5 * 60, eventCount: 10, attemptsOnThisStep: 1))
        XCTAssertEqual(d, .ok)
    }

    func testStewardCheckpointOnAge() {
        let s = ContextSteward()
        // Just at the checkpoint age (2h), under the severe age (3.5h); few events.
        let d = s.assess(ContextSignals(
            sessionAgeSeconds: ContextSteward.defaultCheckpointAgeSeconds,
            eventCount: 10, attemptsOnThisStep: 1))
        guard case .checkpoint = d else { return XCTFail("age at checkpoint mark -> checkpoint, got \(d)") }
    }

    func testStewardCheckpointOnEventCount() {
        let s = ContextSteward()
        let d = s.assess(ContextSignals(
            sessionAgeSeconds: 60, eventCount: ContextSteward.defaultCheckpointEventCount,
            attemptsOnThisStep: 1))
        guard case .checkpoint = d else { return XCTFail("events at checkpoint mark -> checkpoint, got \(d)") }
    }

    func testStewardCheckpointOnAttempts() {
        let s = ContextSteward()
        let d = s.assess(ContextSignals(
            sessionAgeSeconds: 60, eventCount: 5,
            attemptsOnThisStep: ContextSteward.defaultCheckpointAttemptsOnStep))
        guard case .checkpoint = d else { return XCTFail("attempts at checkpoint mark -> checkpoint, got \(d)") }
    }

    func testStewardSevereOnAge() {
        let s = ContextSteward()
        let d = s.assess(ContextSignals(
            sessionAgeSeconds: ContextSteward.defaultSevereAgeSeconds,
            eventCount: 5, attemptsOnThisStep: 1))
        guard case .severe = d else { return XCTFail("age at severe mark -> severe, got \(d)") }
    }

    func testStewardSevereOutranksCheckpoint() {
        let s = ContextSteward()
        // Age in the severe band AND events in the checkpoint band: severe wins.
        let d = s.assess(ContextSignals(
            sessionAgeSeconds: ContextSteward.defaultSevereAgeSeconds + 1,
            eventCount: ContextSteward.defaultCheckpointEventCount + 1,
            attemptsOnThisStep: 1))
        guard case .severe = d else { return XCTFail("severe must outrank checkpoint, got \(d)") }
    }

    func testStewardCustomThresholdsAndNegativeAgeClamped() {
        // Tiny thresholds + a negative age (clamped to 0, never trips age).
        let s = ContextSteward(
            checkpointAgeSeconds: 100, checkpointEventCount: 3, checkpointAttemptsOnStep: 2,
            severeAgeSeconds: 200, severeEventCount: 6, severeAttemptsOnStep: 3)
        XCTAssertEqual(s.assess(ContextSignals(sessionAgeSeconds: -999, eventCount: 1, attemptsOnThisStep: 0)), .ok)
        guard case .checkpoint = s.assess(ContextSignals(sessionAgeSeconds: 0, eventCount: 3, attemptsOnThisStep: 0)) else {
            return XCTFail("3 events at the custom checkpoint mark -> checkpoint")
        }
        guard case .severe = s.assess(ContextSignals(sessionAgeSeconds: 0, eventCount: 6, attemptsOnThisStep: 0)) else {
            return XCTFail("6 events at the custom severe mark -> severe")
        }
    }

    // ==========================================================================
    // MARK: - 2a. Below threshold -> normal advance, NO checkpoint inject
    // ==========================================================================

    /// A passing step at a safe boundary with a small/young window: the steward
    /// returns .ok, so the action is a plain next-step inject (kind=nextStep) with
    /// NO checkpoint preamble, and no cooldown is armed.
    func testBelowThresholdAdvancesWithoutCheckpoint() async throws {
        let db = try freshDB()
        try seedSession(db, id: "sess-ok")
        let (pl, store, loop) = makeHarness(db: db, steward: ContextSteward())
        try store.create(threeStepPlan(sessionId: "sess-ok"))

        let now = Date()
        let smallYoung = windowAged(sessionId: "sess-ok", age: 60, count: 4, now: now)
        let running = try XCTUnwrap(pl.runningPlan(sessionId: "sess-ok"))
        let action = await pl.driveIdleStep(
            plan: running, sessionId: "sess-ok", cwd: "/c",
            window: smallYoung, stepInjectedAt: now.addingTimeInterval(-120), now: now)

        guard case let .inject(text, idx, kind) = action else {
            return XCTFail("a pass below threshold should advance (inject next step), got \(action)")
        }
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(kind, .nextStep)
        XCTAssertFalse(text.contains("HANDOFF.md"), "no checkpoint instruction below threshold")
        // M6: the standing criteria bar now frames every step inject, but the M5
        // CHECKPOINT note specifically is still absent below threshold (the M5
        // invariant under test). The next step's objective is still present.
        XCTAssertTrue(text.contains("Do step one."), "the next step's objective is injected")
        XCTAssertFalse(text.contains("Checkpoint before continuing"), "no checkpoint note below threshold")
        // No cooldown armed (no checkpoint happened).
        let cooldown = await loop.checkpointCooldownActive(sessionId: "sess-ok", planId: "plan-sess-ok", atStepIndex: 1)
        XCTAssertFalse(cooldown, "no checkpoint -> no cooldown armed")
    }

    // ==========================================================================
    // MARK: - 2b. Checkpoint threshold -> ONE checkpoint inject, then cooldown
    // ==========================================================================

    /// A passing step at a safe boundary with a window that crosses the checkpoint
    /// band (here via event count, using a tiny custom steward) injects the
    /// non-destructive HANDOFF.md checkpoint prepended to the next step's
    /// objective, advances normally, and arms the cooldown - so the IMMEDIATELY
    /// following passing step does NOT inject a second checkpoint.
    func testCheckpointThresholdInjectsOnceThenCooldownSuppresses() async throws {
        let db = try freshDB()
        try seedSession(db, id: "sess-cp")
        // Checkpoint when events >= 5; severe only at events >= 50 (kept high so
        // the window never escalates). Age/attempts kept high too so only the
        // event-count band is exercised. Cooldown = 3 steps.
        let steward = ContextSteward(
            checkpointAgeSeconds: 999_999, checkpointEventCount: 5, checkpointAttemptsOnStep: 999,
            severeAgeSeconds: 9_999_999, severeEventCount: 5_000, severeAttemptsOnStep: 9_999)
        let (pl, store, loop) = makeHarness(db: db, steward: steward, cooldownSteps: 3)
        try store.create(threeStepPlan(sessionId: "sess-cp"))

        let now = Date()
        // 6 events (>= the checkpoint mark of 5), young so age never trips.
        let window = windowAged(sessionId: "sess-cp", age: 30, count: 6, now: now)

        // Drive step 0 (pass) at the safe boundary -> checkpoint + next step.
        let running0 = try XCTUnwrap(pl.runningPlan(sessionId: "sess-cp"))
        let action0 = await pl.driveIdleStep(
            plan: running0, sessionId: "sess-cp", cwd: "/c",
            window: window, stepInjectedAt: now.addingTimeInterval(-10), now: now)
        guard case let .inject(text0, idx0, kind0) = action0 else {
            return XCTFail("a checkpoint-band pass should still inject (checkpoint + next step), got \(action0)")
        }
        XCTAssertEqual(idx0, 1, "the injection targets the NEXT step")
        XCTAssertEqual(kind0, .nextStep)
        XCTAssertTrue(text0.contains("HANDOFF.md"), "the non-destructive checkpoint instruction is present")
        XCTAssertTrue(text0.contains("Do step one."), "the next step's objective is still injected after the checkpoint")
        XCTAssertFalse(text0.lowercased().contains("/clear"), "the checkpoint NEVER asks for a context clear")
        XCTAssertTrue(text0.lowercased().contains("do not clear"), "the checkpoint explicitly tells the agent not to clear")

        // The plan advanced normally despite the checkpoint.
        let afterStep0 = try XCTUnwrap(try store.currentPlan(sessionId: "sess-cp"))
        XCTAssertEqual(afterStep0.steps[0].status, .passed, "step 0 still persisted passed")
        XCTAssertEqual(afterStep0.currentStepIndex, 1, "cursor advanced to step 1")
        XCTAssertEqual(afterStep0.steps[1].status, .active, "step 1 marked active for its window")

        // The cooldown is armed at the checkpoint's step index (1).
        let cooldownNow = await loop.checkpointCooldownActive(sessionId: "sess-cp", planId: "plan-sess-cp", atStepIndex: 1)
        XCTAssertTrue(cooldownNow, "cooldown armed at the checkpoint step index")

        // Drive step 1 (pass) at the IMMEDIATELY following boundary: the steward
        // STILL says checkpoint (same big window), but the cooldown SUPPRESSES it,
        // so the next-step inject carries NO checkpoint instruction.
        let running1 = try XCTUnwrap(pl.runningPlan(sessionId: "sess-cp"))
        let action1 = await pl.driveIdleStep(
            plan: running1, sessionId: "sess-cp", cwd: "/c",
            window: window, stepInjectedAt: now.addingTimeInterval(-10), now: now)
        guard case let .inject(text1, idx1, kind1) = action1 else {
            return XCTFail("step 1 pass should advance (inject step 2), got \(action1)")
        }
        XCTAssertEqual(idx1, 2)
        XCTAssertEqual(kind1, .nextStep)
        XCTAssertFalse(text1.contains("HANDOFF.md"), "FIX: cooldown suppresses a second checkpoint on the very next step")
        // M6: the criteria bar still frames the inject, but the CHECKPOINT note is
        // suppressed by the cooldown - so the next step's objective is present and
        // the checkpoint preamble is not.
        XCTAssertTrue(text1.contains("Do step two."), "the next step's objective is injected when the checkpoint is on cooldown")
        XCTAssertFalse(text1.contains("Checkpoint before continuing"), "the checkpoint note stays suppressed by the cooldown")
    }

    // ==========================================================================
    // MARK: - 2c. Severe -> escalate(contextDegradation): pause, no inject, no clear
    // ==========================================================================

    /// A passing step at a safe boundary whose window is in the SEVERE band
    /// escalates rather than advancing: the action is a notify carrying
    /// .contextDegradation, the loop is PAUSED (canDispatch -> .stopped), NO
    /// next-step injection is produced, the plan stays running for the human, and
    /// nothing is auto-cleared.
    func testSevereEscalatesPausesNoInjectNoClear() async throws {
        let db = try freshDB()
        try seedSession(db, id: "sess-sev")
        // Severe when events >= 5 (forced by the window below). Checkpoint band is
        // lower but severe outranks it.
        let steward = ContextSteward(
            checkpointAgeSeconds: 999_999, checkpointEventCount: 3, checkpointAttemptsOnStep: 999,
            severeAgeSeconds: 9_999_999, severeEventCount: 5, severeAttemptsOnStep: 9_999)
        let (pl, store, loop) = makeHarness(db: db, steward: steward)
        try store.create(threeStepPlan(sessionId: "sess-sev"))

        let now = Date()
        let bigWindow = windowAged(sessionId: "sess-sev", age: 30, count: 8, now: now)  // 8 >= severe 5
        let running = try XCTUnwrap(pl.runningPlan(sessionId: "sess-sev"))
        let action = await pl.driveIdleStep(
            plan: running, sessionId: "sess-sev", cwd: "/c",
            window: bigWindow, stepInjectedAt: now.addingTimeInterval(-10), now: now)

        guard case let .notify(message, escalation) = action else {
            return XCTFail("severe degradation should escalate via notify, got \(action)")
        }
        XCTAssertEqual(escalation, .contextDegradation, "the escalation trigger is contextDegradation")
        XCTAssertFalse(message.lowercased().contains("/clear"), "the escalation message never proposes a clear")

        // The loop is paused for the human; a further drive cannot auto-inject.
        let dispatch = await loop.canDispatch(sessionId: "sess-sev")
        guard case .stopped = dispatch else {
            return XCTFail("a severe escalation must pause the loop, got \(dispatch)")
        }
        // The plan did NOT advance to step 2's injection: step 0 passed + cursor
        // advanced to 1 by decideAndRecord, but step 1 was NEVER injected (left
        // pending, not active) because we escalated at the boundary.
        let after = try XCTUnwrap(try store.currentPlan(sessionId: "sess-sev"))
        XCTAssertEqual(after.status, .paused, "FIX 2: a severe escalation persists the plan paused (durable across restart) so the human resumes it")
        XCTAssertEqual(after.steps[1].status, .pending, "the next step was NOT injected (left pending) on a severe escalation")
        // No checkpoint cooldown was armed (we escalated, did not checkpoint).
        let cooldown = await loop.checkpointCooldownActive(sessionId: "sess-sev", planId: "plan-sess-sev", atStepIndex: 1)
        XCTAssertFalse(cooldown, "a severe escalation does not arm the checkpoint cooldown")
    }

    // ==========================================================================
    // MARK: - 2d. Gating: no approved running plan -> steward never consulted
    // ==========================================================================

    /// With NO running plan for the session, runningPlan is nil so the engine
    /// never enters the drive path and the steward is never consulted - the gate
    /// (toggle + approved running plan) sits ENTIRELY in front of the steward.
    /// Here a plan exists but is only awaitingApproval: runningPlan returns nil, so
    /// there is no drive tick and thus no steward consult, even though the window
    /// would otherwise be in the severe band.
    func testGatingNoRunningPlanNeverConsultsSteward() async throws {
        let db = try freshDB()
        try seedSession(db, id: "sess-gate")
        // A steward that would escalate on ANY non-trivial window, to prove it is
        // simply never reached when there is no running plan.
        let steward = ContextSteward(
            checkpointAgeSeconds: 0, checkpointEventCount: 0, checkpointAttemptsOnStep: 0,
            severeAgeSeconds: 0, severeEventCount: 0, severeAttemptsOnStep: 0)
        let (pl, store, _) = makeHarness(db: db, steward: steward)
        // The plan is awaiting approval, NOT running.
        try store.create(threeStepPlan(sessionId: "sess-gate", status: .awaitingApproval))

        // The drive gate: runningPlan is the engine's precondition for driveIdleStep.
        XCTAssertNil(pl.runningPlan(sessionId: "sess-gate"),
                     "an awaiting-approval plan is not driven, so the steward is never consulted")

        // And a completed plan is likewise not driven. Distinct step ids so it does
        // not collide with the awaiting-approval plan's rows.
        let done = Plan(
            id: "plan-sess-gate2", sessionId: "sess-gate2",
            objective: "Already built.",
            steps: [PlanStep(id: "g2-s0", index: 0, title: "Done",
                             objective: "x", doneCriteria: "y", status: .passed)],
            status: .completed, currentStepIndex: 0)
        try seedSession(db, id: "sess-gate2")
        try store.create(done)
        XCTAssertNil(pl.runningPlan(sessionId: "sess-gate2"),
                     "a completed plan is not driven either")
    }
}
