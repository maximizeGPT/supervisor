// PlannerTests.swift
//
// v0.2.0 M2b - unit tests for the Planner. Mirrors DispatcherTests'
// URLProtocol mock so the LLM call is observable, and seeds an in-memory
// SupervisorDatabase + PlanStore (the StorageTests PlanStore pattern) so we
// can assert persistence. Covers:
//   - the Planner produces the expected ordered steps,
//   - it persists them via PlanStore as awaitingApproval with steps pending,
//   - a grounding backstop drops an obviously-fabricated step,
//   - re-plan keeps completed steps verbatim and revises the remainder.

import XCTest
import GRDB
@testable import SupervisorCore

@MainActor
final class PlannerTests: XCTestCase {

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

    // MARK: - Harness

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PlannerMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeClient() -> LLMClient {
        LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("planner-client-\(UUID().uuidString).log"))
        )
    }

    /// A Planner over an in-memory DB; returns both so tests can inspect the
    /// store after a plan call. A session row is seeded to satisfy the
    /// plans.session_id FK.
    private func makePlanner(
        sessionId: String = "sess-plan",
        grounder: (any ProposalGrounding)? = nil
    ) throws -> (Planner, PlanStore) {
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: sessionId, projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"
        ))
        let store = PlanStore(database: db)
        let planner = Planner(
            client: makeClient(),
            store: store,
            principlesText: "PRINCIPLES.md (test stub).",
            grounder: grounder,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("planner-tests-\(UUID().uuidString).log"))
        )
        return (planner, store)
    }

    /// Canned record_plan response with the supplied ordered steps.
    private static func planResponse(
        steps: [(title: String, objective: String, done: String)]
    ) -> Data {
        let stepObjs: [[String: Any]] = steps.map {
            ["title": $0.title, "objective": $0.objective, "done_criteria": $0.done]
        }
        let body: [String: Any] = [
            "id": "msg_plan",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_plan",
                "name": "record_plan",
                "input": ["steps": stepObjs] as [String: Any],
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 6200, "output_tokens": 720],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// A realistic 3-step plan grounded in the sample objective.
    private static func threeStepResponse() -> Data {
        planResponse(steps: [
            (title: "Schema + migration",
             objective: "Add the tweets table and a v5 migration so scheduled tweets persist.",
             done: "Migration applies on a fresh DB and a round-trip test passes; swift build is green."),
            (title: "Scheduler",
             objective: "Add a TweetScheduler that reads due rows and posts them on an interval.",
             done: "A unit test drives the scheduler with a fake clock and asserts due tweets fire."),
            (title: "End-to-end verify",
             objective: "Wire the scheduler into the app entry point and post one real tweet end to end.",
             done: "A tweet appears on the timeline; the trace shows the post call succeeded."),
        ])
    }

    private func sampleContext(sessionId: String = "sess-plan") -> SessionContext {
        SessionContext(
            sessionUUID: sessionId,
            cwd: "/c",
            gitBranch: "autonomous-test",
            lastNTurns: [],
            openIssues: [],
            currentBranchCommits: [],
            objective: "Build a tweet engine that posts to X on a schedule."
        )
    }

    // MARK: - Tests

    /// The Planner produces the expected ordered steps and returns .planned.
    func testPlannerProducesOrderedSteps() async throws {
        Self.canned["/v1/messages"] = (200, Self.threeStepResponse(), [:])
        let (planner, _) = try makePlanner()

        let result = await planner.plan(context: sampleContext())

        guard case let .planned(plan) = result else {
            return XCTFail("expected .planned, got \(result)")
        }
        XCTAssertEqual(plan.steps.count, 3)
        XCTAssertEqual(plan.steps.map { $0.index }, [0, 1, 2], "steps are 0-based and ordered")
        XCTAssertEqual(plan.steps.map { $0.title },
                       ["Schema + migration", "Scheduler", "End-to-end verify"],
                       "step order is preserved from the model output")
        XCTAssertEqual(plan.steps[0].objective,
                       "Add the tweets table and a v5 migration so scheduled tweets persist.")
        XCTAssertFalse(plan.steps[0].doneCriteria.isEmpty, "each step carries done-criteria")
        XCTAssertEqual(plan.objective, "Build a tweet engine that posts to X on a schedule.")
    }

    /// The Planner persists the plan via PlanStore as awaitingApproval with
    /// every step pending - the standing human gate.
    func testPlannerPersistsAsAwaitingApprovalWithStepsPending() async throws {
        Self.canned["/v1/messages"] = (200, Self.threeStepResponse(), [:])
        let (planner, store) = try makePlanner()

        let result = await planner.plan(context: sampleContext())
        guard case .planned = result else { return XCTFail("expected .planned, got \(result)") }

        // Reload straight from the store - proves it persisted, not just returned.
        let loaded = try XCTUnwrap(try store.currentPlan(sessionId: "sess-plan"))
        XCTAssertEqual(loaded.status, .awaitingApproval,
                       "a fresh plan persists awaiting the one-time approval gate")
        XCTAssertNil(loaded.approvedAt, "not approved yet")
        XCTAssertEqual(loaded.currentStepIndex, 0)
        XCTAssertEqual(loaded.steps.count, 3)
        XCTAssertTrue(loaded.steps.allSatisfy { $0.status == .pending },
                      "every step persists pending")
        XCTAssertTrue(loaded.steps.allSatisfy { $0.lastVerdict == nil },
                      "no step has a verdict yet")
        XCTAssertEqual(loaded.steps.map { $0.id }.count, Set(loaded.steps.map { $0.id }).count,
                       "step ids are unique")
    }

    /// A grounding backstop drops an obviously-fabricated step (one that
    /// proposes building already-existing machinery), keeping the rest.
    func testGroundingBackstopDropsFabricatedStep() async throws {
        // Step 2 is the self-referential runaway ("build the dispatch loop")  - 
        // premiseRejection must drop it; the two real steps survive.
        Self.canned["/v1/messages"] = (200, Self.planResponse(steps: [
            (title: "Real step A",
             objective: "Add the tweets table and a migration so scheduled tweets persist.",
             done: "Round-trip test passes."),
            (title: "Fabricated",
             objective: "Build the dispatch loop and LoopController that watch the queue and inject the next prompt.",
             done: "The loop runs."),
            (title: "Real step B",
             objective: "Add a TweetScheduler that posts due rows on an interval.",
             done: "Scheduler unit test passes."),
        ]), [:])
        let (planner, store) = try makePlanner()

        let result = await planner.plan(context: sampleContext())
        guard case let .planned(plan) = result else {
            return XCTFail("expected .planned, got \(result)")
        }
        XCTAssertEqual(plan.steps.count, 2, "the fabricated build-existing step is dropped")
        XCTAssertEqual(plan.steps.map { $0.title }, ["Real step A", "Real step B"],
                       "survivors keep order and are re-indexed contiguously")
        XCTAssertEqual(plan.steps.map { $0.index }, [0, 1], "indices are contiguous after the drop")

        // And the persisted plan reflects the drop too.
        let loaded = try XCTUnwrap(try store.currentPlan(sessionId: "sess-plan"))
        XCTAssertEqual(loaded.steps.count, 2)
    }

    /// If EVERY proposed step fails grounding, nothing persists and the
    /// Planner returns .ungrounded (the single-step Dispatcher is the fallback).
    func testAllStepsUngroundedPersistsNothing() async throws {
        Self.canned["/v1/messages"] = (200, Self.planResponse(steps: [
            (title: "Self-ref 1",
             objective: "Build the Dispatcher.",
             done: "It exists."),
            (title: "Self-ref 2",
             objective: "Stand up the triage engine.",
             done: "It runs."),
        ]), [:])
        let (planner, store) = try makePlanner()

        let result = await planner.plan(context: sampleContext())
        guard case .ungrounded = result else {
            return XCTFail("expected .ungrounded, got \(result)")
        }
        XCTAssertNil(try store.currentPlan(sessionId: "sess-plan"),
                     "an all-ungrounded plan must not persist anything")
    }

    /// Malformed record_plan (no steps array) surfaces as .error, not a crash.
    func testPlannerReturnsErrorOnMalformedResponse() async throws {
        let body: [String: Any] = [
            "id": "msg_bad", "type": "message", "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use", "id": "toolu_bad", "name": "record_plan",
                "input": ["not_steps": "oops"] as [String: Any],
            ]],
            "stop_reason": "tool_use", "stop_sequence": NSNull(),
            "usage": ["input_tokens": 100, "output_tokens": 20],
        ]
        Self.canned["/v1/messages"] = (200, try! JSONSerialization.data(withJSONObject: body), [:])
        let (planner, store) = try makePlanner()

        let result = await planner.plan(context: sampleContext())
        guard case .error = result else {
            return XCTFail("expected .error on malformed response, got \(result)")
        }
        XCTAssertNil(try store.currentPlan(sessionId: "sess-plan"))
    }

    /// The cap: a model returning 9 steps is clamped to maxSteps (7).
    func testPlannerCapsAtMaxSteps() async throws {
        let nine = (1...9).map { i in
            (title: "Step \(i)",
             objective: "Do real grounded thing number \(i) in the codebase.",
             done: "Thing \(i) verified.")
        }
        Self.canned["/v1/messages"] = (200, Self.planResponse(steps: nine), [:])
        let (planner, _) = try makePlanner()

        let result = await planner.plan(context: sampleContext())
        guard case let .planned(plan) = result else {
            return XCTFail("expected .planned, got \(result)")
        }
        XCTAssertEqual(plan.steps.count, Planner.maxSteps, "9 proposed steps clamp to the cap")
    }

    /// Re-plan keeps completed steps verbatim and revises only the remainder.
    func testReplanKeepsCompletedRevisesRemainder() async throws {
        // The model's re-plan returns the REVISED remainder only.
        Self.canned["/v1/messages"] = (200, Self.planResponse(steps: [
            (title: "Revised scheduler",
             objective: "Rework the TweetScheduler to back off on rate-limit errors from the API.",
             done: "A unit test asserts exponential backoff on a 429."),
            (title: "Revised verify",
             objective: "Re-run the end-to-end post after the backoff change and confirm it still posts.",
             done: "A tweet posts and the trace shows one retry then success."),
        ]), [:])
        let (planner, store) = try makePlanner()

        // An existing plan: step 0 passed, steps 1 & 2 still pending.
        let existing = Plan(
            id: "plan-existing",
            sessionId: "sess-plan",
            objective: "Build a tweet engine that posts to X on a schedule.",
            steps: [
                PlanStep(id: "s0", index: 0, title: "Schema + migration",
                         objective: "Add the tweets table and migration.",
                         doneCriteria: "Round-trip passes.",
                         status: .passed, attempts: 1,
                         lastVerdict: .init(passed: true, score: 0.95, feedback: "schema ok")),
                PlanStep(id: "s1", index: 1, title: "Scheduler",
                         objective: "Add a TweetScheduler that posts due rows.",
                         doneCriteria: "Scheduler test passes.", status: .pending),
                PlanStep(id: "s2", index: 2, title: "Verify",
                         objective: "Post one real tweet end to end.",
                         doneCriteria: "Tweet appears.", status: .pending),
            ],
            status: .running,
            currentStepIndex: 1
        )

        let result = await planner.replan(
            existing: existing,
            observation: "The X API now rate-limits us; the scheduler must back off on 429s.",
            cwd: "/c"
        )
        guard case let .planned(newPlan) = result else {
            return XCTFail("expected .planned, got \(result)")
        }

        // Completed step carried VERBATIM (same objective + verdict), re-indexed 0.
        XCTAssertEqual(newPlan.steps.first?.id, "s0", "the completed step is carried by id")
        XCTAssertEqual(newPlan.steps.first?.status, .passed, "completed step keeps its status")
        XCTAssertEqual(newPlan.steps.first?.objective, "Add the tweets table and migration.",
                       "completed step objective is unchanged")
        XCTAssertEqual(newPlan.steps.first?.lastVerdict?.score ?? 0, 0.95, accuracy: 0.0001,
                       "completed step keeps its verdict")
        XCTAssertEqual(newPlan.steps.first?.index, 0)

        // The remainder is REVISED (the new titles), not the old pending steps.
        let titles = newPlan.steps.map { $0.title }
        XCTAssertEqual(titles, ["Schema + migration", "Revised scheduler", "Revised verify"],
                       "old pending steps are replaced by the revised remainder")
        XCTAssertFalse(titles.contains("Verify"), "the old remainder is gone")

        // New plan is awaiting approval, current index = completed count, steps
        // after the completed one are pending.
        XCTAssertEqual(newPlan.status, .awaitingApproval)
        XCTAssertEqual(newPlan.currentStepIndex, 1, "current index = number of completed steps")
        XCTAssertEqual(newPlan.steps.map { $0.index }, [0, 1, 2], "contiguous indices")
        XCTAssertEqual(newPlan.steps[1].status, .pending)
        XCTAssertEqual(newPlan.steps[2].status, .pending)

        // Persisted as the new current plan.
        let loaded = try XCTUnwrap(try store.currentPlan(sessionId: "sess-plan"))
        XCTAssertEqual(loaded.id, newPlan.id)
        XCTAssertEqual(loaded.steps.count, 3)
    }

    // MARK: - Prompt / schema snapshot

    /// The Planner system prompt must carry its core decomposition constraints.
    func testSystemPromptCarriesPlanningConstraints() {
        let p = Planner.systemPrompt
        XCTAssertTrue(p.contains("3 to 7"), "must state the step-count band")
        XCTAssertTrue(p.contains("record_plan"), "must reference the forced tool call")
        XCTAssertTrue(p.lowercased().contains("ground"), "must teach grounding")
        XCTAssertTrue(p.contains("done_criteria"), "must require done-criteria per step")
    }

    /// The user message decomposes the objective and surfaces grounding context.
    func testUserMessageSurfacesObjectiveAndContext() {
        let ctx = SessionContext(
            sessionUUID: "s", cwd: "/c", gitBranch: "b",
            lastNTurns: [], openIssues: [], currentBranchCommits: [],
            productDirection: "Ship a great product.",
            objective: "Build the tweet engine.",
            knownGaps: "# Known Gaps\n- backoff missing")
        let msg = Planner.userMessage(context: ctx, principles: "(stub)")
        XCTAssertTrue(msg.contains("SESSION OBJECTIVE"), "must include the objective section")
        XCTAssertTrue(msg.contains("Build the tweet engine"), "must include the objective text")
        XCTAssertTrue(msg.contains("Known Gaps"), "must include known gaps section")
        XCTAssertTrue(msg.contains("backoff missing"), "must include known gaps content")
        XCTAssertTrue(msg.contains("record_plan"), "must instruct the forced call")
    }
}

// MARK: - URLProtocol mock

private final class PlannerMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = PlannerTests.canned[path] else {
            let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable)
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Mock grounder: reports a configurable symbol set as "missing" so a
/// cross-project step can be dropped deterministically without a real repo.
/// (The premise/staleness/env backstops are exercised by the planned tests
/// above; this is here for completeness of the grounding surface.)
final class PlannerStubGrounder: ProposalGrounding {
    let missing: [String]
    init(missing: [String]) { self.missing = missing }
    func missingSymbols(inProposal proposal: String, cwd: String) async -> [String] {
        missing.filter { proposal.contains($0) }
    }
}

@MainActor
final class PlannerCrossProjectTests: XCTestCase {

    /// A step naming a symbol absent from the repo (per the stub grounder) is
    /// dropped by the async cross-project backstop.
    func testCrossProjectStepDropped() async throws {
        PlannerTests.canned.removeAll()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PlannerCrossProjectMockURLProtocol.self]
        let client = LLMClient(
            provider: .anthropic, apiKey: "sk-ant-test", redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: URLSession(configuration: cfg),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("planner-xp-\(UUID().uuidString).log")))
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: "sx", projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        let store = PlanStore(database: db)
        let planner = Planner(
            client: client, store: store, principlesText: "stub",
            grounder: PlannerStubGrounder(missing: ["LandingHero"]),
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("planner-xp-t-\(UUID().uuidString).log")))

        let body: [String: Any] = [
            "id": "m", "type": "message", "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use", "id": "t", "name": "record_plan",
                "input": ["steps": [
                    ["title": "Real", "objective": "Add a TweetScheduler that posts due rows.", "done_criteria": "test passes"],
                    ["title": "Leak", "objective": "Restyle the LandingHero component on the marketing page.", "done_criteria": "looks good"],
                ]] as [String: Any],
            ]],
            "stop_reason": "tool_use", "stop_sequence": NSNull(),
            "usage": ["input_tokens": 100, "output_tokens": 50],
        ]
        PlannerCrossProjectTests.canned["/v1/messages"] = (200, try! JSONSerialization.data(withJSONObject: body), [:])

        let result = await planner.plan(context: SessionContext(
            sessionUUID: "sx", cwd: "/c", gitBranch: "b",
            lastNTurns: [], openIssues: [], currentBranchCommits: [],
            objective: "Build a tweet engine."))

        guard case let .planned(plan) = result else {
            return XCTFail("expected .planned, got \(result)")
        }
        XCTAssertEqual(plan.steps.count, 1, "the cross-project (LandingHero) step is dropped")
        XCTAssertEqual(plan.steps.first?.title, "Real")
    }

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]
}

private final class PlannerCrossProjectMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = PlannerCrossProjectTests.canned[path] else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
