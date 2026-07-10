// ApprovePlanMarkerTests.swift
//
// v0.2.0 M4-prep - the marker-file approve affordance + plan-visibility logging.
// These prove the minimal live-validation enabler that lets the owner exercise
// the planner/evaluator loop on a real session WITHOUT the M3 approval UI:
//
//   1. APPROVE VIA MARKER. With the planner toggle ON, an approve-plan marker
//      present, and an awaiting-approval plan for a watched session -> the
//      periodic tick (checkIdleStates) approves THAT plan (it goes running, its
//      first step is injected MARKED + LEDGERED through the existing path) and
//      CONSUMES the marker (one-shot).
//   2. GATED OFF. With the planner toggle OFF, the marker is NEVER read or
//      consumed and no plan is approved - default behavior is unchanged.
//   3. NOTHING PENDING. With the toggle ON + the marker present but NO
//      awaiting-approval plan, the marker is consumed and nothing is approved.
//   4. PLAN VISIBILITY. Creating an awaiting-approval plan logs each step
//      (index, title, done-criteria) so the owner can review before approving.
//
// No network for the harness: the Planner/Evaluator are mocked, the PlanStore +
// LoopController are real (in-memory). The approve marker is driven through the
// engine's injectable `consumeApprovePlanMarker` seam backed by a TEMP-dir
// RuntimeToggles marker, so a test never touches the real marker the running app
// would pick up. Structure mirrors PlanHarnessEngineTests.

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class ApprovePlanMarkerTests: XCTestCase {

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]

    override func setUp() async throws {
        try await super.setUp()
        try await Task.sleep(nanoseconds: 200_000_000)
        Self.canned.removeAll()
    }
    override func tearDown() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
        try await super.tearDown()
    }

    /// Remove a temp dir for cleanup so it can NEVER fail the test. Under
    /// `@MainActor async`, XCTest has been observed to surface even a benign ENOENT
    /// from `removeItem` (NSCocoaError Code=4 / POSIX ENOENT) as a test failure —
    /// so the guarantee here is to never let `removeItem` see a missing path in the
    /// first place, not merely to swallow the throw. We GUARD on existence (a path
    /// already removed — e.g. by a second call — is a no-op) and only ever call
    /// `removeItem` on a path that exists at the guard. Callers additionally ensure
    /// the dir is EMPTY before removal (delete the known marker child first, engine
    /// stopped) so there is no recursive child-walk to race the engine's consume.
    static func removeQuietly(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Mocks (mirror PlanHarnessEngineTests)

    final class MockPlanner: Planning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        func planForSession(sessionUUID: String, cwd: String?, gitBranch: String?, lastNTurns: [SupervisorEvent]) async -> PlanResult {
            lock.lock(); calls += 1; lock.unlock(); return .ungrounded(reasoning: "stub")
        }
        func replan(existing: Plan, observation: String, cwd: String?) async -> PlanResult {
            lock.lock(); calls += 1; lock.unlock(); return .ungrounded(reasoning: "stub")
        }
    }

    final class MockEvaluator: Evaluating, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        let verdict: PlanStep.Verdict
        init(_ verdict: PlanStep.Verdict) { self.verdict = verdict }
        func evaluate(step: PlanStep, observation: Observation) async -> PlanStep.Verdict {
            lock.lock(); calls += 1; lock.unlock(); return verdict
        }
    }

    final class SpyDispatcher: Dispatching, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        func dispatchForIdleSession(sessionUUID: String, cwd: String?, gitBranch: String?, lastNTurns: [SupervisorEvent], priorDispatchesConsidered: Int) async -> DispatchResult {
            lock.lock(); calls += 1; lock.unlock()
            return .lowConfidence(reasoning: "spy dispatcher: no real work")
        }
    }

    final class MockNotifier: Notifying, @unchecked Sendable {
        func post(decision: TriageDecision) async -> Notifier.Outcome { .posted }
        func postInterventionResult(decision: TriageDecision, outcome: InterventionOutcome) async -> Notifier.Outcome { .posted }
    }

    final class CapturingInjector: Injector, @unchecked Sendable {
        private let lock = NSLock()
        private var _texts: [String] = []
        var texts: [String] { lock.lock(); defer { lock.unlock() }; return _texts }
        func inject(text: String, claudeCodePID: pid_t, targetWindowTitle: String? = nil) async throws -> Int {
            lock.lock(); _texts.append(text); lock.unlock(); return text.utf8.count
        }
    }

    struct ConfirmedLocator: ProcessLocator {
        let handle: ProcessHandle
        func locate(targetCwd: String) -> ProcessHandle? { handle }
        func locate(bySessionId: String) -> ProcessHandle? { handle }
    }

    final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ initial: Date) { _now = initial }
        var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
        func advance(by s: TimeInterval) { lock.lock(); _now = _now.addingTimeInterval(s); lock.unlock() }
    }

    // MARK: - Harness

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ApprovePlanMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func twoStepPlan(sessionId: String, status: Plan.Status) -> Plan {
        Plan(
            id: "plan-\(sessionId)", sessionId: sessionId,
            objective: "Build + verify the scheduler.",
            steps: [
                // Step ids are namespaced by session: plan_steps.id is a PRIMARY
                // KEY, so a test that creates plans for two sessions must not reuse
                // "s0"/"s1" across them or the second INSERT hits SQLite UNIQUE 19.
                PlanStep(id: "s0-\(sessionId)", index: 0, title: "Add scheduler",
                         objective: "Add a TweetScheduler that posts due rows.",
                         doneCriteria: "build green; test passes.",
                         status: status == .running ? .active : .pending),
                PlanStep(id: "s1-\(sessionId)", index: 1, title: "Wire it in",
                         objective: "Wire the scheduler into the app loop.",
                         doneCriteria: "runs on launch; test proves it.", status: .pending),
            ],
            status: status, currentStepIndex: 0)
    }

    /// Full engine wiring with the approve-plan marker driven through a temp-dir
    /// RuntimeToggles marker (NOT the real one). `markerDir` is unique per test.
    private func makeWiredEngine(
        sessionId: String,
        plannerEnabled: Bool,
        markerDir: URL,
        evaluatorVerdict: PlanStep.Verdict,
        clock: ClockBox,
        extraSessionIds: [String] = []
    ) throws -> (engine: TriageEngine, bus: EventBus, dispatcher: SpyDispatcher,
                 planner: MockPlanner, evaluator: MockEvaluator,
                 injector: CapturingInjector, ledger: InjectionLedger, store: PlanStore) {
        let db = try SupervisorDatabase.inMemory()
        let sessionStore = SessionStore(database: db)
        // Every session that will own a Plan must exist first: plans.session_id has
        // a FK -> sessions(id) (ON DELETE CASCADE), and neither PlanStore.create nor
        // consume(.sessionStart) inserts a sessions row (the latter only caches
        // cwd/branch in memory). So seed the primary session AND any extra sessions
        // whose plans this test creates, or the plan INSERT fails with SQLite FK 19.
        for sid in [sessionId] + extraSessionIds {
            try sessionStore.upsert(StoredSession(
                id: sid, projectHash: "p", cwd: "/Users/test/supervisor",
                startedAt: clock.now, lastSeenAt: clock.now, jsonlPath: "/tmp/x.jsonl"))
        }
        let store = PlanStore(database: db)

        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("apm-bus-\(UUID().uuidString).log")))
        let client = LLMClient(
            provider: .anthropic, apiKey: "sk-ant-test", redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!, session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("apm-client-\(UUID().uuidString).log")))

        let ledger = InjectionLedger()
        let dispatcher = SpyDispatcher()
        let planner = MockPlanner()
        let evaluator = MockEvaluator(evaluatorVerdict)
        let loop = LoopController(
            now: { clock.now },
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("apm-loop-\(UUID().uuidString).log")),
            planStore: store)
        let planLoop = PlanLoop(
            planner: planner, evaluator: evaluator, planStore: store, loopController: loop,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("apm-pl-\(UUID().uuidString).log")))

        let injector = CapturingInjector()
        let router = InterventionRouter(
            notifier: MockNotifier(),
            locator: ConfirmedLocator(handle: ProcessHandle(pid: 4242, execPath: "/usr/local/bin/claude", cwd: "/Users/test/supervisor")),
            signalSender: DarwinSignalSender(),
            injector: injector,
            humanActivity: StubHumanActivityProbe(idleSeconds: 999),
            injectionLedger: ledger,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("apm-router-\(UUID().uuidString).log")))

        let engine = TriageEngine(
            client: client, bus: bus, model: "claude-haiku-4-5-20251001",
            windowSize: 30, costStore: nil,
            dispatcher: dispatcher,
            loopController: loop,
            planLoop: planLoop,
            plannerEnabled: { plannerEnabled },
            // Drive the approve-plan marker off a TEMP dir so the test never
            // touches the real marker the running app would pick up. This is the
            // exact production seam (RuntimeToggles.consumeApprovePlanRequested),
            // just pointed at a temp dir.
            consumeApprovePlanMarker: { RuntimeToggles.consumeApprovePlanRequested(dir: markerDir) },
            autoDispatchDisabledRead: { false },
            idleCheckIntervalSeconds: 3600,  // unused: the background loop is off (below)
            injectionLedger: ledger,
            now: { clock.now })
        engine.onDecision = { d in Task { @MainActor in await router.dispatch(decision: d) } }
        // Drive checkIdleStates() manually; do NOT spawn the background idle-loop
        // Task (its cancelled sleep at teardown surfaces a handled CancellationError
        // against the test under XCTest). The bus subscription is still wired.
        engine.start(runIdleLoop: false)
        return (engine, bus, dispatcher, planner, evaluator, injector, ledger, store)
    }

    /// Register a watched session with the engine (so checkApprovePlanMarker can
    /// find its plan) by publishing a sessionStart, without forcing an idle fire.
    private func registerSession(_ bus: EventBus, _ clock: ClockBox, sessionId: String) async throws {
        bus.publish(.sessionStart(.init(
            sessionId: sessionId, cwd: "/Users/test/supervisor", gitBranch: "autonomous-x",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: clock.now)))
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    // ==========================================================================
    // MARK: - 1. Approve via the marker (toggle on + awaiting plan present)
    // ==========================================================================

    /// Toggle ON + approve-plan marker present + an AWAITING-APPROVAL plan for a
    /// watched session -> the tick approves THAT plan: it goes running, its first
    /// step is injected (marked + ledgered), and the marker is consumed.
    func testMarkerApprovesAwaitingPlanAndConsumesMarker() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let sid = "sess-approve"
        let markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apm-\(UUID().uuidString)", isDirectory: true)
        defer { Self.removeQuietly(markerDir) }

        let w = try makeWiredEngine(sessionId: sid, plannerEnabled: true, markerDir: markerDir,
                                    evaluatorVerdict: .init(passed: true, score: 1, feedback: "x"), clock: clock)
        defer { w.engine.stop() }
        try w.store.create(twoStepPlan(sessionId: sid, status: .awaitingApproval))
        try await registerSession(w.bus, clock, sessionId: sid)

        // Owner touches the approve-plan marker.
        RuntimeToggles.setApprovePlanRequested(true, dir: markerDir)
        XCTAssertTrue(RuntimeToggles.approvePlanRequested(dir: markerDir), "marker present before the tick")

        // The periodic tick approves + drives.
        w.engine.checkIdleStates()
        try? await Task.sleep(nanoseconds: 700_000_000)  // drain: a cancelled wait must not fail the test

        // The plan is now running with its first step injected.
        let plan = try XCTUnwrap(try w.store.currentPlan(sessionId: sid))
        XCTAssertEqual(plan.status, .running, "the marker approved the plan -> running")
        XCTAssertNotNil(plan.approvedAt, "approval was stamped")
        XCTAssertEqual(plan.steps[0].status, .active, "the first step is active (driving started)")

        XCTAssertEqual(w.injector.texts.count, 1, "approval injected exactly the first step")
        let injected = try XCTUnwrap(w.injector.texts.first)
        XCTAssertFalse(injected.contains("SUPERVISOR"),
                       "no-stamp decision: the approved plan's first step reads clean (no banner)")
        XCTAssertTrue(injected.contains("TweetScheduler"), "the first step's objective is injected")
        // Provenance is the ledger, not an in-text banner: the injection is
        // recorded AND correlates back so the triage recognizes its own turn.
        XCTAssertGreaterThan(w.ledger.entryCount(sessionId: sid), 0,
                             "the first-step injection is recorded in the InjectionLedger")
        XCTAssertTrue(w.ledger.isSupervisorInjected(sessionId: sid, text: injected, asOf: Date()),
                      "the clean injected step correlates back to its ledger entry")

        // The marker was consumed (one-shot): it is gone after the tick.
        XCTAssertFalse(RuntimeToggles.approvePlanRequested(dir: markerDir),
                       "the approve-plan marker is consumed (deleted) after approving")
        XCTAssertEqual(w.dispatcher.calls, 0, "approval drives the plan, it does not run the Dispatcher")
    }

    // ==========================================================================
    // MARK: - 2. Gated OFF (toggle off -> marker never read/consumed)
    // ==========================================================================

    /// Toggle OFF + an awaiting-approval plan + the marker present -> the marker
    /// is NEVER read (so it stays on disk), no plan is approved, nothing injected.
    /// Default behavior is unchanged.
    func testToggleOffDoesNotApproveAndLeavesMarker() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let sid = "sess-off"
        let markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apm-\(UUID().uuidString)", isDirectory: true)
        defer { Self.removeQuietly(markerDir) }

        let w = try makeWiredEngine(sessionId: sid, plannerEnabled: false, markerDir: markerDir,
                                    evaluatorVerdict: .init(passed: true, score: 1, feedback: "x"), clock: clock)
        defer { w.engine.stop() }
        try w.store.create(twoStepPlan(sessionId: sid, status: .awaitingApproval))
        try await registerSession(w.bus, clock, sessionId: sid)

        RuntimeToggles.setApprovePlanRequested(true, dir: markerDir)

        w.engine.checkIdleStates()
        try? await Task.sleep(nanoseconds: 500_000_000)  // drain: a cancelled wait must not fail the test

        let plan = try XCTUnwrap(try w.store.currentPlan(sessionId: sid))
        XCTAssertEqual(plan.status, .awaitingApproval, "toggle OFF: the plan is NOT approved")
        XCTAssertNil(plan.approvedAt, "no approval stamped with the toggle off")
        XCTAssertTrue(w.injector.texts.isEmpty, "toggle OFF: nothing injected")
        // The marker is NOT consumed when the toggle is off (the gate short-circuits
        // before reading it), so it is still present.
        XCTAssertTrue(RuntimeToggles.approvePlanRequested(dir: markerDir),
                      "toggle OFF: the marker is left untouched (never read/consumed)")
    }

    // ==========================================================================
    // MARK: - 3. Nothing pending (toggle on, marker present, no awaiting plan)
    // ==========================================================================

    /// Toggle ON + the marker present but NO awaiting-approval plan (only a
    /// running one) -> the marker is consumed and nothing new is approved/injected.
    func testMarkerWithNoAwaitingPlanIsConsumedNoApproval() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let sid = "sess-none"
        let markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apm-\(UUID().uuidString)", isDirectory: true)
        defer { Self.removeQuietly(markerDir) }

        let w = try makeWiredEngine(sessionId: sid, plannerEnabled: true, markerDir: markerDir,
                                    evaluatorVerdict: .init(passed: true, score: 1, feedback: "x"), clock: clock)
        defer { w.engine.stop() }
        // Only a RUNNING plan exists - there is nothing awaiting approval.
        try w.store.create(twoStepPlan(sessionId: sid, status: .running))
        try await registerSession(w.bus, clock, sessionId: sid)

        RuntimeToggles.setApprovePlanRequested(true, dir: markerDir)

        w.engine.checkIdleStates()
        try? await Task.sleep(nanoseconds: 500_000_000)  // drain: a cancelled wait must not fail the test

        // Nothing was approved (the running plan is untouched by the marker path),
        // and no first-step inject was produced by the approve path.
        let plan = try XCTUnwrap(try w.store.currentPlan(sessionId: sid))
        XCTAssertEqual(plan.status, .running, "no awaiting plan to approve; the running plan is unchanged by the marker")
        XCTAssertTrue(w.injector.texts.isEmpty, "the marker approved nothing -> no inject from the approve path")
        // The marker is still consumed (one-shot) so it cannot fire on a later tick.
        XCTAssertFalse(RuntimeToggles.approvePlanRequested(dir: markerDir),
                       "the marker is consumed even when nothing was pending")
    }

    // ==========================================================================
    // MARK: - 3b. FIX 6: >1 pending plan across sessions -> refuse to auto-approve
    // ==========================================================================

    /// The marker is a single global signal, but with MORE THAN ONE plan awaiting
    /// approval across sessions, silently approving "the newest" could start driving
    /// a session the owner did not mean to approve. FIX 6: the marker is consumed
    /// but NEITHER plan is approved and nothing is injected - the owner is asked to
    /// approve a specific plan from the panel.
    func testTwoPendingPlansAcrossSessionsRefusesAutoApprove() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let sid1 = "sess-a"
        let sid2 = "sess-b"
        let markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apm-\(UUID().uuidString)", isDirectory: true)
        // Teardown mirrors the sibling tests: the engine is stopped in a defer
        // (runs BEFORE the dir-removal defer, which is registered first) and the
        // temp dir is removed once via removeQuietly. Do NOT stop the engine in the
        // body followed by an await — that runs the cancelled idle-loop's
        // continuation during a test await, and XCTest records the loop's
        // (handled) CancellationError against this test.
        defer { Self.removeQuietly(markerDir) }

        let w = try makeWiredEngine(sessionId: sid1, plannerEnabled: true, markerDir: markerDir,
                                    evaluatorVerdict: .init(passed: true, score: 1, feedback: "x"), clock: clock,
                                    extraSessionIds: [sid2])
        defer { w.engine.stop() }
        // Two DIFFERENT sessions each with an awaiting-approval plan (both sessions
        // are seeded above so each plan's FK -> sessions(id) is satisfied).
        try w.store.create(twoStepPlan(sessionId: sid1, status: .awaitingApproval))
        try await registerSession(w.bus, clock, sessionId: sid1)
        clock.advance(by: 1)
        try w.store.create(twoStepPlan(sessionId: sid2, status: .awaitingApproval))
        try await registerSession(w.bus, clock, sessionId: sid2)

        RuntimeToggles.setApprovePlanRequested(true, dir: markerDir)
        w.engine.checkIdleStates()
        try? await Task.sleep(nanoseconds: 700_000_000)  // drain: a cancelled wait must not fail the test

        // NEITHER plan was approved; nothing was injected.
        let p1 = try XCTUnwrap(try w.store.currentPlan(sessionId: sid1))
        let p2 = try XCTUnwrap(try w.store.currentPlan(sessionId: sid2))
        XCTAssertEqual(p1.status, .awaitingApproval, "FIX 6: ambiguous marker did not approve session A's plan")
        XCTAssertEqual(p2.status, .awaitingApproval, "FIX 6: ambiguous marker did not approve session B's plan")
        XCTAssertTrue(w.injector.texts.isEmpty, "FIX 6: no plan was auto-approved, so no first-step inject")
        // The marker is still consumed (one-shot) so it cannot fire on a later tick.
        XCTAssertFalse(RuntimeToggles.approvePlanRequested(dir: markerDir),
                       "the marker is consumed even when it was ambiguous")
        // Teardown is handled by the defers (stop, then removeQuietly), exactly
        // like the sibling tests. The ambiguous path already consumed the marker,
        // so markerDir is empty and its single deferred removal never races a
        // recursive walk; sleep-first means no background tick touches the dir
        // after the manual checkIdleStates() above. No body stop()+await (which
        // would surface the idle loop's handled CancellationError against the test).
    }

    // ==========================================================================
    // MARK: - 4. Plan visibility: creating a plan logs every step
    // ==========================================================================

    /// Plan.logPlanSteps emits one info-level trace line per step (with the title
    /// and done-criteria) plus a header, so the owner can review the plan before
    /// approving. Asserts against the real trace file.
    func testPlanCreationLogsEachStep() throws {
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apm-planlog-\(UUID().uuidString).log")
        defer { Self.removeQuietly(traceURL) }
        let trace = TraceLog(path: traceURL)

        let plan = twoStepPlan(sessionId: "sess-log", status: .awaitingApproval)
        Planner.logPlanSteps(plan, trace: trace)
        trace.sync()

        let log = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("PLAN READY for approval"), "a review header is logged")
        XCTAssertTrue(log.contains("plan=plan-sess-log"), "the plan id is logged for review")
        // Each step's index, title, and done-criteria are present.
        XCTAssertTrue(log.contains("step 1/2: Add scheduler"), "step 1 title logged with index")
        XCTAssertTrue(log.contains("done-criteria: build green; test passes."), "step 1 done-criteria logged")
        XCTAssertTrue(log.contains("step 2/2: Wire it in"), "step 2 title logged with index")
        XCTAssertTrue(log.contains("runs on launch; test proves it."), "step 2 done-criteria logged")
    }
}

// MARK: - URLProtocol mock

private final class ApprovePlanMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = ApprovePlanMarkerTests.canned[path] else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
