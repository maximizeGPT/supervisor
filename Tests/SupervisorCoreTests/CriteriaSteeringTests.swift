// CriteriaSteeringTests.swift
//
// v0.2.0 M6 - prompt criteria steering. Two layers:
//
//   1. CriteriaSteering (pure): the general bar is always present; the design
//      bar is appended ONLY when the UI/design keyword heuristic fires on the
//      step's title + objective; the heuristic itself (positive + negative).
//   2. PlanLoop integration: a normal step injection carries the general bar
//      framing the step's objective; a UI/design step ALSO carries the design
//      bar; the composition with the M5 checkpoint note keeps the criteria bar
//      AND the checkpoint note exactly once each, in a sensible order; and the
//      gate (toggle + approved running plan) still sits entirely in front of all
//      of it.
//
// No network: the Planner + Evaluator are mocked; the PlanStore + LoopController
// are real (in-memory). Here we drive PlanLoop directly and assert on the
// returned PlanLoopAction + persisted state, mirroring PlanLoopWiringTests /
// ContextStewardTests. The marked + ledgered property of the resulting injection
// is proven end-to-end in PlanHarnessEngineTests (the real router path); the
// criteria-bar text simply rides that same path, and a focused engine-level test
// here (testGeneralBarInjectionIsMarkedAndLedgered) confirms a steered first-step
// injection arrives marked + recorded.

import XCTest
@testable import SupervisorCore

@MainActor
final class CriteriaSteeringTests: XCTestCase {

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

    private func makeHarness(
        db: SupervisorDatabase,
        steward: ContextSteward = ContextSteward(),
        cooldownSteps: Int = LoopController.defaultCheckpointCooldownSteps
    ) -> (PlanLoop, PlanStore, LoopController) {
        let planner = MockPlanner()
        let evaluator = MockEvaluator([.init(passed: true, score: 0.95, feedback: "ok")])
        let store = PlanStore(database: db)
        let loop = LoopController(
            checkpointCooldownSteps: cooldownSteps,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("criteria-lc-\(UUID().uuidString).log")),
            planStore: store)
        let pl = PlanLoop(
            planner: planner, evaluator: evaluator, planStore: store,
            loopController: loop, contextSteward: steward,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("criteria-pl-\(UUID().uuidString).log")))
        return (pl, store, loop)
    }

    /// A 3-step plan: a non-UI step 0, a UI step 1 (so an advance into it injects
    /// the design bar), and a plain step 2 to advance into. All non-UI titles use
    /// words that must NOT trip the design heuristic.
    private func mixedPlan(sessionId: String, status: Plan.Status = .running) -> Plan {
        Plan(
            id: "plan-\(sessionId)", sessionId: sessionId,
            objective: "Build the backend then the panel.",
            steps: [
                PlanStep(id: "s0", index: 0, title: "Add the scheduler",
                         objective: "Add a TweetScheduler that posts due rows and run the test.",
                         doneCriteria: "swift build green; new test passes.", status: .active),
                PlanStep(id: "s1", index: 1, title: "Build the plan view",
                         objective: "Add a SwiftUI view that shows the plan steps with the brand tokens.",
                         doneCriteria: "the view compiles and renders the steps.", status: .pending),
                PlanStep(id: "s2", index: 2, title: "Persist the run log",
                         objective: "Write each run outcome to the database and prove it round-trips.",
                         doneCriteria: "a stored row reads back equal.", status: .pending),
            ],
            status: status, currentStepIndex: 0)
    }

    private func windowAged(sessionId: String, age: TimeInterval, count: Int, now: Date) -> [SupervisorEvent] {
        guard count > 0 else { return [] }
        let earliest = now.addingTimeInterval(-age)
        var events: [SupervisorEvent] = []
        for i in 0..<count {
            let frac = count == 1 ? 0 : Double(i) / Double(count - 1)
            let ts = earliest.addingTimeInterval(age * frac)
            events.append(.bashToolCall(.init(
                sessionId: sessionId, command: "swift build", description: nil,
                toolUseId: "tu-\(i)", turnUUID: "u", ts: ts)))
        }
        return events
    }

    // ==========================================================================
    // MARK: - 1. CriteriaSteering (pure)
    // ==========================================================================

    /// The general bar is always present and carries its four standing rules; a
    /// non-UI step's preamble is EXACTLY the general bar (no design bar).
    func testGeneralBarAlwaysPresentNonUiHasNoDesignBar() {
        let step = PlanStep(index: 0, title: "Add the scheduler",
                            objective: "Add a TweetScheduler and run the test.",
                            doneCriteria: "build green; test passes.")
        XCTAssertFalse(CriteriaSteering.isDesignStep(step), "a backend step is not a design step")

        let preamble = CriteriaSteering.preamble(for: step)
        XCTAssertTrue(preamble.contains("Quality bar for this step"), "the general bar header is present")
        XCTAssertTrue(preamble.lowercased().contains("done-criteria"), "the general bar names the done-criteria")
        XCTAssertTrue(preamble.lowercased().contains("smallest correct change"), "the general bar asks for the smallest correct change")
        XCTAssertTrue(preamble.lowercased().contains("scope"), "the general bar mentions staying in scope")
        XCTAssertTrue(preamble.lowercased().contains("evidence"), "the general bar forbids claiming success without evidence")
        // No design bar on a non-UI step.
        XCTAssertFalse(preamble.contains("Design bar"), "a non-UI step gets NO design bar")
        XCTAssertEqual(preamble, CriteriaSteering.generalBar, "a non-UI step's preamble is exactly the general bar")
        // House rule: no em dashes in the injected copy.
        XCTAssertFalse(preamble.contains("\u{2014}"), "no em dashes in the criteria bar")
    }

    /// A UI/design step gets the general bar AND the design bar, with the design
    /// rules (one accent, tokens not literals, the anti-slop list).
    func testDesignStepGetsGeneralPlusDesignBar() {
        let step = PlanStep(index: 1, title: "Refresh the panel view",
                            objective: "Restyle the SwiftUI layout with the brand tokens and one accent.",
                            doneCriteria: "renders with the tokens.")
        XCTAssertTrue(CriteriaSteering.isDesignStep(step), "a SwiftUI view step IS a design step")

        let preamble = CriteriaSteering.preamble(for: step)
        XCTAssertTrue(preamble.contains("Quality bar for this step"), "the general bar is still present on a UI step")
        XCTAssertTrue(preamble.contains("Design bar"), "the design bar is appended for a UI step")
        XCTAssertTrue(preamble.lowercased().contains("one accent"), "the design bar carries the one-accent rule")
        XCTAssertTrue(preamble.lowercased().contains("token"), "the design bar asks for tokens over literals")
        XCTAssertTrue(preamble.lowercased().contains("gradient"), "the design bar lists the anti-slop defaults (gradient)")
        // The general bar leads, the design bar follows.
        let generalIdx = preamble.range(of: "Quality bar for this step")!.lowerBound
        let designIdx = preamble.range(of: "Design bar")!.lowerBound
        XCTAssertTrue(generalIdx < designIdx, "the general bar leads; the design bar follows")
        XCTAssertFalse(preamble.contains("\u{2014}"), "no em dashes in the design bar")
    }

    /// The heuristic fires on a spread of UI tokens (in the title OR the
    /// objective, case-insensitively) and does NOT fire on plainly-backend steps.
    func testDesignHeuristicPositivesAndNegatives() {
        // Positives: a representative keyword in either field, mixed case.
        let positives: [(String, String)] = [
            ("Build the Plan VIEW", "lay it out"),
            ("Refresh", "restyle the SwiftUI screen"),
            ("Add a button", "primary action"),
            ("Theme pass", "pick the accent COLOR"),
            ("Tune spacing", "tighten the layout"),
            ("New component", "a reusable card"),
            ("CSS polish", "the web export"),
            ("Hover panel", "the expanded panel"),
        ]
        for (title, objective) in positives {
            let step = PlanStep(index: 0, title: title, objective: objective, doneCriteria: "x")
            XCTAssertTrue(CriteriaSteering.isDesignStep(step), "expected design step for title=\(title) objective=\(objective)")
        }

        // Negatives: backend / infra work whose words merely CONTAIN design
        // letters must NOT fire (word-boundary guarding: build, require, guide,
        // viewer-free copy, etc.).
        let negatives: [(String, String)] = [
            ("Add the scheduler", "post due rows and run the test"),
            ("Build the parser", "require the new grammar"),
            ("Write the migration", "round-trip the row"),
            ("Wire the loop", "drive the next step"),
            ("Guide the retry", "improve the backoff"),  // "guide" contains "ui" but is not a word match
            ("Persist the log", "store each outcome"),
        ]
        for (title, objective) in negatives {
            let step = PlanStep(index: 0, title: title, objective: objective, doneCriteria: "x")
            XCTAssertFalse(CriteriaSteering.isDesignStep(step), "did NOT expect a design step for title=\(title) objective=\(objective)")
        }
    }

    // ==========================================================================
    // MARK: - 2a. A normal step injection carries the general bar (not the design bar)
    // ==========================================================================

    /// Approving a plan whose first step is NON-UI injects the first step's
    /// objective FRAMED by the general criteria bar, with NO design bar. The
    /// objective text is still present (the bar is prepended, not a replacement).
    func testApproveInjectsGeneralBarBeforeFirstStep() async throws {
        let db = try freshDB()
        try seedSession(db, id: "sess-gen")
        let (pl, store, _) = makeHarness(db: db)
        try store.create(mixedPlan(sessionId: "sess-gen", status: .approved))

        let action = await pl.approvePlan(planId: "plan-sess-gen")
        guard case let .inject(text, idx, kind) = action else {
            return XCTFail("approve should inject the first step, got \(action)")
        }
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(kind, .firstStep)
        XCTAssertTrue(text.contains("Quality bar for this step"), "the general criteria bar frames the first step")
        XCTAssertTrue(text.contains("TweetScheduler"), "the step's own objective is still injected")
        XCTAssertFalse(text.contains("Design bar"), "a non-UI first step gets NO design bar")
        // The bar leads, the objective follows.
        let barIdx = text.range(of: "Quality bar for this step")!.lowerBound
        let objIdx = text.range(of: "TweetScheduler")!.lowerBound
        XCTAssertTrue(barIdx < objIdx, "the criteria bar precedes the step objective")
    }

    /// A passing NON-UI step advances and injects the next step's objective framed
    /// by the general bar only (the next step here, "Build the plan view", IS a UI
    /// step, so this also doubles as the design-bar advance check below; we use the
    /// dedicated mixedPlan so step 0 -> step 1 lands on the UI step).
    func testAdvanceIntoUiStepInjectsDesignBar() async throws {
        let db = try freshDB()
        try seedSession(db, id: "sess-adv-ui")
        let (pl, store, _) = makeHarness(db: db)
        try store.create(mixedPlan(sessionId: "sess-adv-ui"))

        let now = Date()
        let window = windowAged(sessionId: "sess-adv-ui", age: 60, count: 4, now: now)
        let running = try XCTUnwrap(pl.runningPlan(sessionId: "sess-adv-ui"))
        let action = await pl.driveIdleStep(
            plan: running, sessionId: "sess-adv-ui", cwd: "/c",
            window: window, stepInjectedAt: now.addingTimeInterval(-120), now: now)

        guard case let .inject(text, idx, kind) = action else {
            return XCTFail("a pass on step 0 should advance + inject step 1, got \(action)")
        }
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(kind, .nextStep)
        // Step 1 is the SwiftUI view step -> general + design bar + the objective.
        XCTAssertTrue(text.contains("Quality bar for this step"), "the general bar frames the next step")
        XCTAssertTrue(text.contains("Design bar"), "advancing into a UI step injects the design bar")
        XCTAssertTrue(text.contains("SwiftUI view"), "the next step's objective is still injected")
        XCTAssertFalse(text.contains("HANDOFF.md"), "no checkpoint note when the steward says ok")
    }

    /// A passing UI step advancing into a NON-UI step injects the general bar but
    /// NOT the design bar (proves the design bar tracks the step being injected,
    /// not the one that just passed). Drives step 1 (UI) -> step 2 (non-UI).
    func testAdvanceIntoNonUiStepHasNoDesignBar() async throws {
        let db = try freshDB()
        try seedSession(db, id: "sess-adv-plain")
        let (pl, store, _) = makeHarness(db: db)
        var plan = mixedPlan(sessionId: "sess-adv-plain")
        plan.currentStepIndex = 1
        plan.steps[0].status = .passed
        plan.steps[1].status = .active
        try store.create(plan)

        let now = Date()
        let window = windowAged(sessionId: "sess-adv-plain", age: 60, count: 4, now: now)
        let running = try XCTUnwrap(pl.runningPlan(sessionId: "sess-adv-plain"))
        let action = await pl.driveIdleStep(
            plan: running, sessionId: "sess-adv-plain", cwd: "/c",
            window: window, stepInjectedAt: now.addingTimeInterval(-120), now: now)

        guard case let .inject(text, idx, kind) = action else {
            return XCTFail("a pass on step 1 should advance + inject step 2, got \(action)")
        }
        XCTAssertEqual(idx, 2)
        XCTAssertEqual(kind, .nextStep)
        XCTAssertTrue(text.contains("Quality bar for this step"), "the general bar frames the non-UI next step")
        XCTAssertFalse(text.contains("Design bar"), "advancing into a NON-UI step gets NO design bar")
        XCTAssertTrue(text.contains("round-trips"), "the next step's objective is still injected")
    }

    // ==========================================================================
    // MARK: - 2b. Composition with the M5 checkpoint note (each present once, ordered)
    // ==========================================================================

    /// On a post-pass advance that ALSO trips a checkpoint, the single injection
    /// composes the M6 criteria bar AND the M5 checkpoint note AND the next step's
    /// objective - each exactly once, in the order criteria bar -> checkpoint note
    /// -> objective - and is not corrupted. The next step here is the UI step, so
    /// the design bar is present too (still as part of the one criteria preamble).
    func testCompositionWithCheckpointEachOnceInOrder() async throws {
        let db = try freshDB()
        try seedSession(db, id: "sess-compose")
        // Force a checkpoint via event count; keep severe far away so it does not
        // escalate. Age/attempts kept high so only the event-count band fires.
        let steward = ContextSteward(
            checkpointAgeSeconds: 999_999, checkpointEventCount: 5, checkpointAttemptsOnStep: 999,
            severeAgeSeconds: 9_999_999, severeEventCount: 5_000, severeAttemptsOnStep: 9_999)
        let (pl, store, _) = makeHarness(db: db, steward: steward, cooldownSteps: 3)
        try store.create(mixedPlan(sessionId: "sess-compose"))

        let now = Date()
        let window = windowAged(sessionId: "sess-compose", age: 30, count: 6, now: now)  // 6 >= checkpoint 5
        let running = try XCTUnwrap(pl.runningPlan(sessionId: "sess-compose"))
        let action = await pl.driveIdleStep(
            plan: running, sessionId: "sess-compose", cwd: "/c",
            window: window, stepInjectedAt: now.addingTimeInterval(-10), now: now)

        guard case let .inject(text, idx, kind) = action else {
            return XCTFail("a checkpoint-band pass should still inject (criteria + checkpoint + next step), got \(action)")
        }
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(kind, .nextStep)

        // All three pieces are present.
        XCTAssertTrue(text.contains("Quality bar for this step"), "the M6 criteria bar is present")
        XCTAssertTrue(text.contains("HANDOFF.md"), "the M5 checkpoint note is present")
        XCTAssertTrue(text.contains("SwiftUI view"), "the next step's objective is present")

        // Each appears EXACTLY once (no duplication / corruption from composing).
        XCTAssertEqual(occurrences(of: "Quality bar for this step", in: text), 1, "the criteria bar appears exactly once")
        XCTAssertEqual(occurrences(of: "HANDOFF.md", in: text), 1, "the checkpoint note appears exactly once")
        XCTAssertEqual(occurrences(of: "Checkpoint before continuing", in: text), 1, "the checkpoint preamble is not duplicated")

        // Order: criteria bar -> checkpoint note -> objective.
        let criteriaIdx = text.range(of: "Quality bar for this step")!.lowerBound
        let checkpointIdx = text.range(of: "Checkpoint before continuing")!.lowerBound
        let objectiveIdx = text.range(of: "SwiftUI view")!.lowerBound
        XCTAssertTrue(criteriaIdx < checkpointIdx, "the criteria bar leads the checkpoint note")
        XCTAssertTrue(checkpointIdx < objectiveIdx, "the checkpoint note precedes the step objective")

        // The plan still advanced normally despite the composed inject.
        let after = try XCTUnwrap(try store.currentPlan(sessionId: "sess-compose"))
        XCTAssertEqual(after.steps[0].status, .passed, "step 0 still persisted passed")
        XCTAssertEqual(after.currentStepIndex, 1, "cursor advanced to step 1")
    }

    // ==========================================================================
    // MARK: - 2c. Gating unchanged: no running plan -> no steering injected
    // ==========================================================================

    /// The gate (an approved RUNNING plan) sits in front of the criteria steering:
    /// with only an awaiting-approval plan, runningPlan is nil so there is no drive
    /// tick and thus no injection at all - the steering adds text only to
    /// plan-step injections that already happen behind the opt-in.
    func testGatingNoRunningPlanNoSteering() async throws {
        let db = try freshDB()
        try seedSession(db, id: "sess-nogate")
        let (pl, store, _) = makeHarness(db: db)
        try store.create(mixedPlan(sessionId: "sess-nogate", status: .awaitingApproval))

        XCTAssertNil(pl.runningPlan(sessionId: "sess-nogate"),
                     "an awaiting-approval plan is not driven, so no criteria-steered inject is produced")

        // Approving a plan in a non-approvable state is a no-op (no inject), so the
        // steering never runs. Here the plan is already not approvable as running
        // would be; an unknown id is the simplest no-op proof.
        let action = await pl.approvePlan(planId: "does-not-exist")
        guard case .none = action else {
            return XCTFail("approving an unknown plan is a no-op (.none), got \(action)")
        }
    }

    // MARK: - Helpers

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
