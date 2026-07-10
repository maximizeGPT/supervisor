// ScenarioReplayTests.swift
//
// Deterministic scenario-replay test harness. Drives the REAL
// PlanOrchestrator + PlanLoop + LoopController + AuditStore + PlanStore
// through scripted scenarios, asserting decisions + injections + audit records.
// No network, no LLM: Planner and Evaluator are mocked with canned results.

import XCTest
@testable import SupervisorCore

@MainActor
final class ScenarioReplayTests: XCTestCase {

    // MARK: - Mocks

    final class MockPlanner: Planning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var planCalls = 0
        private(set) var replanCalls = 0
        var plannedResult: PlanResult
        var replanResult: PlanResult
        init(plannedResult: PlanResult = .ungrounded(reasoning: "stub"),
             replanResult: PlanResult = .ungrounded(reasoning: "stub")) {
            self.plannedResult = plannedResult
            self.replanResult = replanResult
        }
        func planForSession(sessionUUID: String, cwd: String?, gitBranch: String?, lastNTurns: [SupervisorEvent]) async -> PlanResult {
            lock.lock(); planCalls += 1; lock.unlock()
            return plannedResult
        }
        func replan(existing: Plan, observation: String, cwd: String?) async -> PlanResult {
            lock.lock(); replanCalls += 1; lock.unlock()
            return replanResult
        }
    }

    final class MockEvaluator: Evaluating, @unchecked Sendable {
        private let lock = NSLock()
        private var staged: [PlanStep.Verdict]
        private(set) var calls = 0
        private(set) var gradedStepIds: [String] = []
        init(_ staged: [PlanStep.Verdict]) { self.staged = staged }
        func evaluate(step: PlanStep, observation: Observation) async -> PlanStep.Verdict {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            gradedStepIds.append(step.id)
            if staged.count > 1 { return staged.removeFirst() }
            return staged.first ?? PlanStep.Verdict(passed: false, score: 0, feedback: "no staged verdict")
        }
    }

    // MARK: - Builders

    private func freshDB() throws -> SupervisorDatabase {
        try SupervisorDatabase.inMemory()
    }

    private func seedSession(_ db: SupervisorDatabase, id: String) throws {
        try SessionStore(database: db).upsert(StoredSession(
            id: id, projectHash: "p", cwd: "/Users/test/proj",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/tmp/x.jsonl"))
    }

    private func makeHarness(
        db: SupervisorDatabase,
        planner: any Planning,
        evaluator: any Evaluating,
        contextSteward: ContextSteward = ContextSteward(),
        orchestrator: PlanOrchestrator = PlanOrchestrator()
    ) -> (PlanLoop, PlanStore, LoopController, AuditStore) {
        let store = PlanStore(database: db)
        let auditStore = AuditStore(database: db)
        let loop = LoopController(
            loopCapDisabled: { true },
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("sr-lc-\(UUID().uuidString).log")),
            planStore: store,
            orchestrator: orchestrator)
        let pl = PlanLoop(
            planner: planner, evaluator: evaluator, planStore: store,
            loopController: loop,
            contextSteward: contextSteward,
            auditStore: auditStore,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("sr-pl-\(UUID().uuidString).log")))
        return (pl, store, loop, auditStore)
    }

    private func threeStepPlan(sessionId: String, status: Plan.Status = .awaitingApproval) -> Plan {
        Plan(
            id: "plan-\(sessionId)", sessionId: sessionId,
            objective: "Build the widget end to end.",
            steps: [
                PlanStep(id: "s0-\(sessionId)", index: 0, title: "Add model",
                         objective: "Add a Widget model with name and size fields.",
                         doneCriteria: "swift build green; Widget struct exists.", status: .pending),
                PlanStep(id: "s1-\(sessionId)", index: 1, title: "Add tests",
                         objective: "Add unit tests for Widget validation.",
                         doneCriteria: "swift test passes; at least 3 test cases.", status: .pending),
                PlanStep(id: "s2-\(sessionId)", index: 2, title: "Wire into app",
                         objective: "Wire Widget into the main app screen.",
                         doneCriteria: "app builds; Widget list view renders.", status: .pending),
            ],
            status: status, currentStepIndex: 0)
    }

    private func pass(_ score: Double = 0.95) -> PlanStep.Verdict {
        .init(passed: true, score: score, feedback: "criteria met")
    }
    private func fail(_ feedback: String = "build failed", score: Double = 0.2) -> PlanStep.Verdict {
        .init(passed: false, score: score, feedback: feedback)
    }

    /// Build a window with real ground truth so the drive cycle does not skip
    /// on the empty-observation guard.
    private func windowWithActivity(sessionId: String, after: Date? = nil) -> [SupervisorEvent] {
        let t = after ?? Date()
        return [
            .bashToolCall(.init(sessionId: sessionId, command: "swift build",
                                description: nil, toolUseId: "tu-\(UUID().uuidString)",
                                turnUUID: "u", ts: t.addingTimeInterval(1))),
            .bashToolResult(.init(sessionId: sessionId,
                                  toolUseId: "tu-\(UUID().uuidString)",
                                  output: "Build complete!", isError: false,
                                  ts: t.addingTimeInterval(2))),
        ]
    }

    // ======================================================================
    // MARK: - 1. Happy path: 3-step plan passes all steps
    // ======================================================================

    func testScenario1_HappyPathThreeStepPlan() async throws {
        let db = try freshDB()
        let sid = "sess-happy3"
        try seedSession(db, id: sid)
        let planner = MockPlanner()
        let evaluator = MockEvaluator([pass(), pass(), pass()])
        let (pl, store, _, auditStore) = makeHarness(db: db, planner: planner, evaluator: evaluator)
        try store.create(threeStepPlan(sessionId: sid))

        // Approve
        let approveAction = await pl.approvePlan(planId: "plan-\(sid)")
        guard case let .inject(_, idx0, kind0) = approveAction else {
            return XCTFail("approve should inject first step, got \(approveAction)")
        }
        XCTAssertEqual(idx0, 0)
        XCTAssertEqual(kind0, .firstStep)

        // Drive step 0 (pass) -> advance to step 1
        let injectTime0 = Date().addingTimeInterval(-5)
        let running0 = try XCTUnwrap(pl.runningPlan(sessionId: sid))
        let action0 = await pl.driveIdleStep(
            plan: running0, sessionId: sid, cwd: "/c",
            window: windowWithActivity(sessionId: sid, after: injectTime0),
            stepInjectedAt: injectTime0)
        guard case let .inject(_, idx1, kind1) = action0 else {
            return XCTFail("pass on step 0 should advance, got \(action0)")
        }
        XCTAssertEqual(idx1, 1)
        XCTAssertEqual(kind1, .nextStep)

        // Drive step 1 (pass) -> advance to step 2
        let injectTime1 = Date().addingTimeInterval(-3)
        let running1 = try XCTUnwrap(pl.runningPlan(sessionId: sid))
        let action1 = await pl.driveIdleStep(
            plan: running1, sessionId: sid, cwd: "/c",
            window: windowWithActivity(sessionId: sid, after: injectTime1),
            stepInjectedAt: injectTime1)
        guard case let .inject(_, idx2, kind2) = action1 else {
            return XCTFail("pass on step 1 should advance, got \(action1)")
        }
        XCTAssertEqual(idx2, 2)
        XCTAssertEqual(kind2, .nextStep)

        // Drive step 2 (pass, last step) -> complete
        let injectTime2 = Date().addingTimeInterval(-1)
        let running2 = try XCTUnwrap(pl.runningPlan(sessionId: sid))
        let action2 = await pl.driveIdleStep(
            plan: running2, sessionId: sid, cwd: "/c",
            window: windowWithActivity(sessionId: sid, after: injectTime2),
            stepInjectedAt: injectTime2)
        guard case let .notify(_, escalation) = action2 else {
            return XCTFail("pass on last step should complete, got \(action2)")
        }
        XCTAssertNil(escalation)

        // Assert final state
        let final = try XCTUnwrap(try store.currentPlan(sessionId: sid))
        XCTAssertEqual(final.status, .completed)
        for step in final.steps {
            XCTAssertEqual(step.status, .passed, "step \(step.index) should be passed")
        }

        // Assert audit entries: 3 planStep + 3 verdict = 6 entries
        let audits = try auditStore.entries(sessionId: sid)
        let planStepAudits = audits.filter { $0.kind == .planStep }
        let verdictAudits = audits.filter { $0.kind == .verdict }
        XCTAssertEqual(planStepAudits.count, 3, "one planStep audit per step driven")
        XCTAssertEqual(verdictAudits.count, 3, "one verdict audit per step graded")
    }

    // ======================================================================
    // MARK: - 2. Step fails then redirects
    // ======================================================================

    func testScenario2_StepFailsThenRedirects() async throws {
        let db = try freshDB()
        let sid = "sess-redir"
        try seedSession(db, id: sid)
        let feedback = "swift build failed: cannot find type Widget"
        let evaluator = MockEvaluator([fail(feedback)])
        let (pl, store, _, _) = makeHarness(db: db, planner: MockPlanner(), evaluator: evaluator)

        var plan = threeStepPlan(sessionId: sid, status: .running)
        plan.steps[0].status = .active
        try store.create(plan)

        let injectTime = Date().addingTimeInterval(-5)
        let running = try XCTUnwrap(pl.runningPlan(sessionId: sid))
        let action = await pl.driveIdleStep(
            plan: running, sessionId: sid, cwd: "/c",
            window: windowWithActivity(sessionId: sid, after: injectTime),
            stepInjectedAt: injectTime)

        guard case let .inject(text, idx, kind) = action else {
            return XCTFail("a sub-cap failure should redirect, got \(action)")
        }
        XCTAssertEqual(idx, 0, "redirect retries the SAME step")
        XCTAssertEqual(kind, .redirect)
        XCTAssertEqual(text, feedback)

        let after = try XCTUnwrap(try store.currentPlan(sessionId: sid))
        XCTAssertEqual(after.steps[0].status, .retrying)
        XCTAssertEqual(after.currentStepIndex, 0)
        XCTAssertEqual(after.steps[0].attempts, 1)
    }

    // ======================================================================
    // MARK: - 3. Step fails past retry cap -> escalation
    // ======================================================================

    func testScenario3_StepFailsPastRetryCapEscalates() async throws {
        let db = try freshDB()
        let sid = "sess-cap"
        try seedSession(db, id: sid)
        // Three improving-but-failing verdicts
        let evaluator = MockEvaluator([
            fail("f1", score: 0.30),
            fail("f2", score: 0.45),
            fail("f3", score: 0.60),
        ])
        let (pl, store, loop, auditStore) = makeHarness(db: db, planner: MockPlanner(), evaluator: evaluator)

        var plan = threeStepPlan(sessionId: sid, status: .running)
        plan.steps[0].status = .active
        try store.create(plan)

        // Attempts 1 + 2 redirect
        for attempt in 1...2 {
            let injectTime = Date().addingTimeInterval(Double(-10 + attempt))
            let running = try XCTUnwrap(pl.runningPlan(sessionId: sid))
            let action = await pl.driveIdleStep(
                plan: running, sessionId: sid, cwd: "/c",
                window: windowWithActivity(sessionId: sid, after: injectTime),
                stepInjectedAt: injectTime)
            guard case .inject(_, _, .redirect) = action else {
                return XCTFail("attempt \(attempt) should redirect, got \(action)")
            }
        }

        // Attempt 3 -> escalate
        let injectTime3 = Date().addingTimeInterval(-1)
        let running3 = try XCTUnwrap(pl.runningPlan(sessionId: sid))
        let action3 = await pl.driveIdleStep(
            plan: running3, sessionId: sid, cwd: "/c",
            window: windowWithActivity(sessionId: sid, after: injectTime3),
            stepInjectedAt: injectTime3)
        guard case let .notify(_, escalation) = action3 else {
            return XCTFail("attempt 3 should escalate, got \(action3)")
        }
        XCTAssertEqual(escalation, .nonConvergence)

        // Loop is stopped
        let snap = await loop.canDispatch(sessionId: sid)
        guard case .stopped = snap else {
            return XCTFail("loop should be stopped after escalation, got \(snap)")
        }

        // FIX 2: plan persisted .paused on escalation (durable across restart),
        // step has 3 attempts
        let after = try XCTUnwrap(try store.currentPlan(sessionId: sid))
        XCTAssertEqual(after.status, .paused)
        XCTAssertEqual(after.steps[0].attempts, 3)

        // Audit recorded the escalation verdict
        let audits = try auditStore.entries(sessionId: sid)
        let verdictAudits = audits.filter { $0.kind == .verdict }
        XCTAssertEqual(verdictAudits.count, 3)
    }

    // ======================================================================
    // MARK: - 4. Destructive command observed -> escalation
    // ======================================================================

    func testScenario4_DestructiveCommandEscalates() async throws {
        let db = try freshDB()
        let sid = "sess-destruct"
        try seedSession(db, id: sid)
        let evaluator = MockEvaluator([pass()])
        let (pl, store, loop, _) = makeHarness(db: db, planner: MockPlanner(), evaluator: evaluator)

        var plan = threeStepPlan(sessionId: sid, status: .running)
        plan.steps[0].status = .active
        try store.create(plan)

        let now = Date()
        let injectTime = now.addingTimeInterval(-5)
        let window: [SupervisorEvent] = [
            .bashToolCall(.init(sessionId: sid, command: "git reset --hard HEAD~3",
                                description: nil, toolUseId: "tu1", turnUUID: "u1", ts: now)),
            .bashToolResult(.init(sessionId: sid, toolUseId: "tu1",
                                  output: "HEAD is now at abc123", isError: false, ts: now)),
        ]

        let running = try XCTUnwrap(pl.runningPlan(sessionId: sid))
        let action = await pl.driveIdleStep(
            plan: running, sessionId: sid, cwd: "/c",
            window: window, stepInjectedAt: injectTime)

        guard case let .notify(_, escalation) = action else {
            return XCTFail("destructive command should escalate, got \(action)")
        }
        XCTAssertEqual(escalation, .destructiveAction)

        // Loop stopped, plan did not advance
        let dispatchDecision = await loop.canDispatch(sessionId: sid)
        guard case .stopped = dispatchDecision else {
            return XCTFail("loop should be stopped, got \(dispatchDecision)")
        }
        let after = try XCTUnwrap(try store.currentPlan(sessionId: sid))
        XCTAssertEqual(after.currentStepIndex, 0, "plan did not advance on destructive escalation")
    }

    // ======================================================================
    // MARK: - 5. Stall with outstanding bg task
    // ======================================================================

    func testScenario5_StallWithOutstandingBgTask() {
        let watchdog = StallWatchdog(maxNudges: 2)
        let now = Date()
        let interval: TimeInterval = 120 // 2 minutes

        // First stall: checkIn
        let signals1 = WatchdogSignals(
            lastActivityTime: now.addingTimeInterval(-180),
            asyncWorkOutstanding: true,
            nudgeCount: 0,
            escalatedStopped: false)
        let d1 = watchdog.assess(signals: signals1, now: now, interval: interval)
        guard case .checkIn = d1 else {
            return XCTFail("should check in on first stall, got \(d1)")
        }

        // Second nudge
        let signals2 = WatchdogSignals(
            lastActivityTime: now.addingTimeInterval(-180),
            asyncWorkOutstanding: true,
            nudgeCount: 1,
            escalatedStopped: false)
        let d2 = watchdog.assess(signals: signals2, now: now, interval: interval)
        guard case .checkIn = d2 else {
            return XCTFail("should check in on second nudge, got \(d2)")
        }

        // Budget exhausted -> escalate
        let signals3 = WatchdogSignals(
            lastActivityTime: now.addingTimeInterval(-180),
            asyncWorkOutstanding: true,
            nudgeCount: 2,
            escalatedStopped: false)
        let d3 = watchdog.assess(signals: signals3, now: now, interval: interval)
        guard case .escalate = d3 else {
            return XCTFail("should escalate after budget exhausted, got \(d3)")
        }
    }

    // ======================================================================
    // MARK: - 6. Two similar-titled sessions: targeting the right one
    // ======================================================================

    func testScenario6_TwoSessionsTargetCorrectOne() async throws {
        let db = try freshDB()
        let sidA = "sess-A"
        let sidB = "sess-B"
        try seedSession(db, id: sidA)
        try seedSession(db, id: sidB)
        let evaluator = MockEvaluator([pass()])
        let (pl, store, _, _) = makeHarness(db: db, planner: MockPlanner(), evaluator: evaluator)

        // Create plans for both sessions
        var planA = threeStepPlan(sessionId: sidA, status: .running)
        planA.steps[0].status = .active
        try store.create(planA)

        var planB = threeStepPlan(sessionId: sidB, status: .running)
        planB.steps[0].status = .active
        try store.create(planB)

        // Drive step on session A only
        let injectTime = Date().addingTimeInterval(-5)
        let runningA = try XCTUnwrap(pl.runningPlan(sessionId: sidA))
        let action = await pl.driveIdleStep(
            plan: runningA, sessionId: sidA, cwd: "/c",
            window: windowWithActivity(sessionId: sidA, after: injectTime),
            stepInjectedAt: injectTime)
        guard case .inject(_, 1, .nextStep) = action else {
            return XCTFail("session A should advance to step 1, got \(action)")
        }

        // Session B's plan is untouched
        let afterB = try XCTUnwrap(try store.currentPlan(sessionId: sidB))
        XCTAssertEqual(afterB.currentStepIndex, 0, "session B's plan cursor is untouched")
        XCTAssertEqual(afterB.steps[0].status, .active, "session B's step 0 is still active")
        XCTAssertEqual(afterB.steps[0].attempts, 0, "session B's step 0 has 0 attempts")
    }

    // ======================================================================
    // MARK: - 7. Awaiting-approval plan is NOT driven
    // ======================================================================

    func testScenario7_AwaitingApprovalPlanNotDriven() async throws {
        let db = try freshDB()
        let sid = "sess-await"
        try seedSession(db, id: sid)
        let (pl, store, _, _) = makeHarness(db: db, planner: MockPlanner(), evaluator: MockEvaluator([pass()]))
        try store.create(threeStepPlan(sessionId: sid, status: .awaitingApproval))

        // runningPlan returns nil for an awaiting-approval plan
        XCTAssertNil(pl.runningPlan(sessionId: sid), "awaiting-approval plan should NOT be returned by runningPlan")

        // hasAnyPlan confirms the plan exists
        XCTAssertTrue(pl.hasAnyPlan(sessionId: sid), "hasAnyPlan should be true")
    }

    // ======================================================================
    // MARK: - 8. Approve -> first step injected
    // ======================================================================

    func testScenario8_ApprovePlanInjectsFirstStep() async throws {
        let db = try freshDB()
        let sid = "sess-approve"
        try seedSession(db, id: sid)
        let (pl, store, _, _) = makeHarness(db: db, planner: MockPlanner(), evaluator: MockEvaluator([pass()]))
        try store.create(threeStepPlan(sessionId: sid, status: .awaitingApproval))

        // Plan is not drivable before approval
        XCTAssertNil(pl.runningPlan(sessionId: sid))

        // Approve
        let action = await pl.approvePlan(planId: "plan-\(sid)")
        guard case let .inject(text, idx, kind) = action else {
            return XCTFail("approve should inject first step, got \(action)")
        }
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(kind, .firstStep)
        XCTAssertTrue(text.contains("Widget model"), "injected text contains the step's objective")

        // Plan transitions to running
        let after = try XCTUnwrap(try store.currentPlan(sessionId: sid))
        XCTAssertEqual(after.status, .running, "plan status should be running after approval")
        XCTAssertEqual(after.steps[0].status, .active, "first step should be active")
        XCTAssertNotNil(after.approvedAt, "approvedAt should be set")
    }

    // ======================================================================
    // MARK: - 9. Escalated plan is NOT re-driven
    // ======================================================================

    func testScenario9_EscalatedPlanNotReDriven() async throws {
        let db = try freshDB()
        let sid = "sess-esc-stop"
        try seedSession(db, id: sid)
        let evaluator = MockEvaluator([
            fail("f1", score: 0.3),
            fail("f2", score: 0.5),
            fail("f3", score: 0.7),
        ])
        let (pl, store, loop, _) = makeHarness(db: db, planner: MockPlanner(), evaluator: evaluator)

        var plan = threeStepPlan(sessionId: sid, status: .running)
        plan.steps[0].status = .active
        try store.create(plan)

        // Drive to escalation (3 attempts)
        for attempt in 1...2 {
            let injectTime = Date().addingTimeInterval(Double(-10 + attempt))
            let running = try XCTUnwrap(pl.runningPlan(sessionId: sid))
            let _ = await pl.driveIdleStep(
                plan: running, sessionId: sid, cwd: "/c",
                window: windowWithActivity(sessionId: sid, after: injectTime),
                stepInjectedAt: injectTime)
        }
        let injectTime3 = Date().addingTimeInterval(-1)
        let running3 = try XCTUnwrap(pl.runningPlan(sessionId: sid))
        let action3 = await pl.driveIdleStep(
            plan: running3, sessionId: sid, cwd: "/c",
            window: windowWithActivity(sessionId: sid, after: injectTime3),
            stepInjectedAt: injectTime3)
        guard case .notify(_, .nonConvergence) = action3 else {
            return XCTFail("expected non-convergence escalation, got \(action3)")
        }

        // After escalation, canDispatch returns stopped
        let dispatch = await loop.canDispatch(sessionId: sid)
        guard case .stopped = dispatch else {
            return XCTFail("loop should be stopped after escalation, got \(dispatch)")
        }

        // FIX 2: the plan is persisted .paused (for the human to resume) and the
        // LOOP is stopped.
        let after = try XCTUnwrap(try store.currentPlan(sessionId: sid))
        XCTAssertEqual(after.status, .paused)
    }

    // ======================================================================
    // MARK: - 10. Context steward checkpoint at safe boundary
    // ======================================================================

    func testScenario10_ContextStewardCheckpointAtSafeBoundary() async throws {
        let db = try freshDB()
        let sid = "sess-checkpoint"
        try seedSession(db, id: sid)
        // Two passes: step 0 passes, then at the advance boundary the context
        // steward fires a checkpoint before injecting step 1.
        let evaluator = MockEvaluator([pass()])
        // Set steward thresholds low so any window trips checkpoint
        let steward = ContextSteward(
            checkpointAgeSeconds: 1,
            checkpointEventCount: 1,
            checkpointAttemptsOnStep: 100,  // don't trigger on attempts
            severeAgeSeconds: 99999,
            severeEventCount: 99999,
            severeAttemptsOnStep: 99999)
        let (pl, store, _, _) = makeHarness(
            db: db, planner: MockPlanner(), evaluator: evaluator,
            contextSteward: steward)

        var plan = threeStepPlan(sessionId: sid, status: .running)
        plan.steps[0].status = .active
        try store.create(plan)

        // Build a window with events that are "old enough" to trip the steward
        let longAgo = Date().addingTimeInterval(-7200) // 2 hours ago
        let injectTime = longAgo.addingTimeInterval(-1)
        let window: [SupervisorEvent] = [
            .bashToolCall(.init(sessionId: sid, command: "swift build",
                                description: nil, toolUseId: "tu-old",
                                turnUUID: "u", ts: longAgo)),
            .bashToolResult(.init(sessionId: sid, toolUseId: "tu-old",
                                  output: "Build complete!", isError: false,
                                  ts: longAgo.addingTimeInterval(1))),
        ]

        let running = try XCTUnwrap(pl.runningPlan(sessionId: sid))
        let action = await pl.driveIdleStep(
            plan: running, sessionId: sid, cwd: "/c",
            window: window, stepInjectedAt: injectTime)

        guard case let .inject(text, idx, kind) = action else {
            return XCTFail("pass with checkpoint steward should inject next step, got \(action)")
        }
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(kind, .nextStep)
        XCTAssertTrue(text.contains("Checkpoint"), "injection should contain checkpoint preamble")
        XCTAssertTrue(text.contains("HANDOFF.md"), "checkpoint should mention HANDOFF.md")
    }

    // ======================================================================
    // MARK: - 11. Budget exhausted -> abort
    // ======================================================================

    func testScenario11_BudgetExhaustedAborts() {
        let orchestrator = PlanOrchestrator()
        let plan = threeStepPlan(sessionId: "sess-budget", status: .running)
        let step = plan.steps[0]

        let decision = orchestrator.decide(
            plan: plan, currentStep: step,
            verdict: pass(),
            signals: OrchestrationSignals(attemptsOnStep: 1, budgetExhausted: true))

        guard case let .abort(reason) = decision else {
            return XCTFail("budget exhausted should abort, got \(decision)")
        }
        XCTAssertTrue(reason.lowercased().contains("budget"))
    }

    func testScenario11_BudgetExhaustedAbortsPersisted() async throws {
        let db = try freshDB()
        let sid = "sess-budget2"
        try seedSession(db, id: sid)
        let evaluator = MockEvaluator([pass()])
        let (_, store, loop, _) = makeHarness(db: db, planner: MockPlanner(), evaluator: evaluator)

        var plan = threeStepPlan(sessionId: sid, status: .running)
        plan.steps[0].status = .active
        try store.create(plan)

        // Call decideAndRecord with budgetExhausted
        let outcome = await loop.decideAndRecord(
            sessionId: sid, plan: plan, step: plan.steps[0],
            verdict: pass(),
            extraSignals: OrchestrationSignals(attemptsOnStep: 0, budgetExhausted: true),
            now: Date())

        guard case .abort = outcome.decision else {
            return XCTFail("expected abort, got \(outcome.decision)")
        }
        XCTAssertEqual(outcome.recordedPlanStatus, .aborted)

        let after = try XCTUnwrap(try store.currentPlan(sessionId: sid))
        XCTAssertEqual(after.status, .aborted)
    }

    // ======================================================================
    // MARK: - 12. Sensitivity setting shifts evaluator threshold
    // ======================================================================

    func testScenario12_SensitivityShiftsThreshold() {
        // Cautious: threshold 0.9
        XCTAssertEqual(DecisionSensitivity.cautious.evaluatorPassThreshold, 0.9)
        // Balanced: threshold 0.8
        XCTAssertEqual(DecisionSensitivity.balanced.evaluatorPassThreshold, 0.8)
        // Decisive: threshold 0.7
        XCTAssertEqual(DecisionSensitivity.decisive.evaluatorPassThreshold, 0.7)

        // A score of 0.85 passes at balanced/decisive but fails at cautious
        let orchestrator = PlanOrchestrator()
        let plan = threeStepPlan(sessionId: "sens", status: .running)
        let step = plan.steps[0]

        // At balanced threshold (0.8): score 0.85 + passed=true -> advance
        let verdictBalanced = PlanStep.Verdict(passed: true, score: 0.85, feedback: "ok")
        let decisionBalanced = orchestrator.decide(
            plan: plan, currentStep: step,
            verdict: verdictBalanced,
            signals: OrchestrationSignals(attemptsOnStep: 1))
        XCTAssertEqual(decisionBalanced, .advance, "score 0.85 advances at balanced threshold")

        // At cautious threshold (0.9): same score 0.85 would be below threshold
        // The Evaluator applies the threshold gate before producing the verdict,
        // so with threshold=0.9, score=0.85 -> passed=false
        let verdictCautious = PlanStep.Verdict(passed: false, score: 0.85, feedback: "below threshold")
        let decisionCautious = orchestrator.decide(
            plan: plan, currentStep: step,
            verdict: verdictCautious,
            signals: OrchestrationSignals(attemptsOnStep: 1))
        guard case .redirect = decisionCautious else {
            return XCTFail("score 0.85 should redirect at cautious threshold, got \(decisionCautious)")
        }

        // At decisive threshold (0.7): score 0.75 + passed=true -> advance
        let verdictDecisive = PlanStep.Verdict(passed: true, score: 0.75, feedback: "ok")
        let decisionDecisive = orchestrator.decide(
            plan: plan, currentStep: step,
            verdict: verdictDecisive,
            signals: OrchestrationSignals(attemptsOnStep: 1))
        XCTAssertEqual(decisionDecisive, .advance, "score 0.75 advances at decisive threshold")
    }
}
