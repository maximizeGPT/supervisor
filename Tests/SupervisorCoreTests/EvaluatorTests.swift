// EvaluatorTests.swift
//
// v0.2.0 M2c - unit tests for the Evaluator. Mirrors PlannerTests'
// URLProtocol mock so the LLM call is observable, and seeds an in-memory
// SupervisorDatabase + PlanStore (the StorageTests / PlannerTests pattern) so
// we can assert persistence. Covers:
//   - record_verdict parsing + the pass/fail threshold BOUNDARY,
//   - the SKEPTIC test: an Observation whose assistant text claims success but
//     whose ground truth does NOT meet the done-criteria -> passed=false with
//     specific feedback (the judge ignores the self-report),
//   - verdict persistence via PlanStore.updateStep (status + verdict + attempts),
//   - ObservationBuilder extracts the right ground truth (tool results/errors)
//     from a canned SupervisorEvent array.

import XCTest
import GRDB
@testable import SupervisorCore

@MainActor
final class EvaluatorTests: XCTestCase {

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
        cfg.protocolClasses = [EvaluatorMockURLProtocol.self]
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
                .appendingPathComponent("evaluator-client-\(UUID().uuidString).log"))
        )
    }

    private func makeEvaluator(
        store: PlanStore? = nil,
        threshold: Double = Evaluator.defaultThreshold
    ) -> Evaluator {
        Evaluator(
            client: makeClient(),
            store: store,
            threshold: threshold,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("evaluator-tests-\(UUID().uuidString).log"))
        )
    }

    /// Canned record_verdict response with the supplied fields.
    private static func verdictResponse(passed: Bool, score: Double, feedback: String) -> Data {
        let body: [String: Any] = [
            "id": "msg_verdict",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_verdict",
                "name": "record_verdict",
                "input": ["passed": passed, "score": score, "feedback": feedback] as [String: Any],
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 1200, "output_tokens": 120],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func sampleStep(
        id: String = "step-1",
        doneCriteria: String = "The new test passes and `swift build` is green."
    ) -> PlanStep {
        PlanStep(
            id: id,
            index: 0,
            title: "Add the scheduler",
            objective: "Add a TweetScheduler that posts due rows on an interval.",
            doneCriteria: doneCriteria,
            status: .active,
            attempts: 0
        )
    }

    // MARK: - Parsing + threshold boundary

    /// A clean pass: judge says passed=true with a score above threshold.
    func testEvaluateParsesPassVerdict() async throws {
        Self.canned["/v1/messages"] = (200, Self.verdictResponse(
            passed: true, score: 0.92,
            feedback: "swift build succeeded and the new scheduler test passed."), [:])
        let evaluator = makeEvaluator()

        let verdict = await evaluator.evaluate(
            step: sampleStep(),
            observation: Observation(
                assistantText: "Implemented the scheduler.",
                commands: [.init(command: "swift test --filter Scheduler", output: "Test Suite passed", isError: false)]))

        XCTAssertTrue(verdict.passed)
        XCTAssertEqual(verdict.score, 0.92, accuracy: 0.0001)
        XCTAssertFalse(verdict.feedback.isEmpty)
    }

    /// Threshold boundary: score EXACTLY at the default threshold (0.8) with the
    /// judge boolean true passes (the gate is score >= threshold).
    func testThresholdBoundaryAtThresholdPasses() async throws {
        Self.canned["/v1/messages"] = (200, Self.verdictResponse(
            passed: true, score: 0.8, feedback: "criteria met."), [:])
        let evaluator = makeEvaluator(threshold: 0.8)

        let verdict = await evaluator.evaluate(step: sampleStep(), observation: Observation())
        XCTAssertTrue(verdict.passed, "score == threshold must pass (>= gate)")
        XCTAssertEqual(verdict.score, 0.8, accuracy: 0.0001)
    }

    /// Threshold boundary: score just BELOW threshold fails even if the judge's
    /// own boolean was optimistically true. The Evaluator ANDs score>=threshold
    /// onto the boolean, so a high-ish but sub-threshold score cannot pass.
    func testThresholdBoundaryBelowThresholdFailsEvenIfJudgeSaysPass() async throws {
        Self.canned["/v1/messages"] = (200, Self.verdictResponse(
            passed: true, score: 0.79,
            feedback: "Most criteria met but the build was not run."), [:])
        let evaluator = makeEvaluator(threshold: 0.8)

        let verdict = await evaluator.evaluate(step: sampleStep(), observation: Observation())
        XCTAssertFalse(verdict.passed, "0.79 < 0.8 must fail despite judge passed=true")
        XCTAssertEqual(verdict.score, 0.79, accuracy: 0.0001, "the raw score is preserved")
    }

    /// A custom (lower) threshold is honored: 0.7 at threshold 0.65 passes.
    func testCustomThresholdIsHonored() async throws {
        Self.canned["/v1/messages"] = (200, Self.verdictResponse(
            passed: true, score: 0.7, feedback: "good enough for the relaxed gate."), [:])
        let evaluator = makeEvaluator(threshold: 0.65)
        XCTAssertEqual(evaluator.passThreshold, 0.65, accuracy: 0.0001)

        let verdict = await evaluator.evaluate(step: sampleStep(), observation: Observation())
        XCTAssertTrue(verdict.passed, "0.70 >= 0.65 passes under the relaxed threshold")
    }

    /// The judge boolean is respected too: passed=false with a high score still
    /// fails (both must agree). Guards against a high score alone passing.
    func testJudgeFalseFailsEvenWithHighScore() async throws {
        Self.canned["/v1/messages"] = (200, Self.verdictResponse(
            passed: false, score: 0.95,
            feedback: "Looks mostly done but a required criterion is unverified."), [:])
        let evaluator = makeEvaluator(threshold: 0.8)

        let verdict = await evaluator.evaluate(step: sampleStep(), observation: Observation())
        XCTAssertFalse(verdict.passed, "judge passed=false must fail regardless of score")
    }

    /// A score returned as a whole JSON integer (1) decodes as 1.0 and passes.
    func testScoreAsIntegerParses() async throws {
        let body: [String: Any] = [
            "id": "m", "type": "message", "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use", "id": "t", "name": "record_verdict",
                "input": ["passed": true, "score": 1, "feedback": "all criteria met."] as [String: Any],
            ]],
            "stop_reason": "tool_use", "stop_sequence": NSNull(),
            "usage": ["input_tokens": 100, "output_tokens": 20],
        ]
        Self.canned["/v1/messages"] = (200, try! JSONSerialization.data(withJSONObject: body), [:])
        let evaluator = makeEvaluator()

        let verdict = await evaluator.evaluate(step: sampleStep(), observation: Observation())
        XCTAssertTrue(verdict.passed)
        XCTAssertEqual(verdict.score, 1.0, accuracy: 0.0001, "integer 1 -> 1.0")
    }

    /// Out-of-range scores are clamped into 0...1.
    func testScoreClampedIntoRange() async throws {
        Self.canned["/v1/messages"] = (200, Self.verdictResponse(
            passed: true, score: 1.7, feedback: "over-confident model."), [:])
        let verdict = await makeEvaluator().evaluate(step: sampleStep(), observation: Observation())
        XCTAssertEqual(verdict.score, 1.0, accuracy: 0.0001, "1.7 clamps to 1.0")
    }

    /// A malformed record_verdict (missing score) degrades to a conservative
    /// FAIL, not a crash and not a pass-on-trust.
    func testMalformedVerdictDegradesToFail() async throws {
        let body: [String: Any] = [
            "id": "m", "type": "message", "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use", "id": "t", "name": "record_verdict",
                "input": ["passed": true, "feedback": "no score field"] as [String: Any],
            ]],
            "stop_reason": "tool_use", "stop_sequence": NSNull(),
            "usage": ["input_tokens": 100, "output_tokens": 20],
        ]
        Self.canned["/v1/messages"] = (200, try! JSONSerialization.data(withJSONObject: body), [:])

        let verdict = await makeEvaluator().evaluate(step: sampleStep(), observation: Observation())
        XCTAssertFalse(verdict.passed, "unparseable verdict must fail closed")
        XCTAssertEqual(verdict.score, 0, accuracy: 0.0001)
        XCTAssertFalse(verdict.feedback.isEmpty, "still gives feedback to redirect")
    }

    /// A transport failure (no canned response) degrades to a conservative
    /// FAIL - a judge we cannot reach must never pass a step.
    func testTransportFailureDegradesToFail() async throws {
        // No canned entry -> the mock fails the request.
        let verdict = await makeEvaluator().evaluate(step: sampleStep(), observation: Observation())
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.score, 0, accuracy: 0.0001)
    }

    // MARK: - The skeptic test (ground-truth over self-report)

    /// The CARDINAL behavior: the session's assistant text loudly claims
    /// success, but the observed ground truth (a failing build) does NOT meet
    /// the done-criteria. The Evaluator must return passed=false with specific
    /// feedback. We drive this by canning the judge's response to the failing
    /// observation (the mock cannot run a real model), AND we assert the
    /// user-message we hand the model fences the self-report off as a claim and
    /// foregrounds the ground truth - i.e. the skeptic framing is actually sent.
    func testSkepticIgnoresSelfReportWhenGroundTruthFails() async throws {
        // Ground truth: the session SAYS it is done, but swift build errored.
        let observation = Observation(
            stepTitle: "Add the scheduler",
            assistantText: "Done! The TweetScheduler is fully implemented and the build is green. All tests pass.",
            commands: [
                .init(command: "swift build",
                      output: "Compiling SupervisorCore TweetScheduler.swift\n"
                            + "Sources/SupervisorCore/TweetScheduler.swift:12:20: error: cannot find type 'Clock' in scope\n"
                            + "error: build failed",
                      isError: true),
            ],
            errors: ["command failed: swift build",
                     "Sources/SupervisorCore/TweetScheduler.swift:12:20: error: cannot find type 'Clock' in scope"])

        // A correctly-skeptical judge returns fail with the real error quoted.
        Self.canned["/v1/messages"] = (200, Self.verdictResponse(
            passed: false, score: 0.1,
            feedback: "Done-criteria not met: `swift build` failed with \"cannot find type 'Clock' in scope\" in TweetScheduler.swift:12. The session claimed the build is green but the ground truth shows it is red. Declare or import Clock and re-run swift build."), [:])

        let step = sampleStep(doneCriteria: "The new scheduler test passes and `swift build` is green.")

        // Assert the framing we SEND foregrounds ground truth and fences the
        // self-report - the prompt is what makes the judge skeptical.
        let userMsg = Evaluator.userMessage(step: step, observation: observation)
        XCTAssertTrue(userMsg.contains("OBSERVED GROUND TRUTH"), "ground truth section is present")
        XCTAssertTrue(userMsg.contains("DO NOT trust"), "the self-report is explicitly fenced as untrusted")
        XCTAssertTrue(userMsg.contains("cannot find type 'Clock'"), "the real build error is in the ground truth we send")
        XCTAssertTrue(userMsg.contains("[RESULT: ERROR]"), "the failing command is marked as an error result")

        let verdict = await makeEvaluator().evaluate(step: step, observation: observation)

        XCTAssertFalse(verdict.passed, "the flattered self-report must NOT pass a red build")
        XCTAssertLessThan(verdict.score, Evaluator.defaultThreshold, "score reflects the failure")
        XCTAssertTrue(verdict.feedback.contains("Clock"),
                      "feedback is specific - it names the real error, not 'make it better'")
    }

    /// The system prompt must carry the skeptic instruction (grade on ground
    /// truth, disregard self-claimed success) - a snapshot guard so the cardinal
    /// rule cannot be silently edited out.
    func testSystemPromptEnforcesSkepticism() {
        let p = Evaluator.systemPrompt
        XCTAssertTrue(p.contains("record_verdict"), "references the forced tool call")
        XCTAssertTrue(p.lowercased().contains("ground truth"), "teaches grading on ground truth")
        XCTAssertTrue(p.lowercased().contains("done-criteria"), "grades against the rubric")
        XCTAssertTrue(p.lowercased().contains("never"), "carries a NEVER (do not trust self-report)")
        XCTAssertTrue(p.lowercased().contains("claim"), "frames the self-report as a claim to verify")
    }

    // MARK: - Persistence

    /// persistVerdict writes status + verdict + incremented attempts via
    /// PlanStore.updateStep; reloading the plan reflects all three.
    func testPersistVerdictWritesStatusVerdictAndAttempts() async throws {
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: "sess-eval", projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        let store = PlanStore(database: db)

        // Seed a plan with one active step (attempts=0).
        let step = PlanStep(id: "s0", index: 0, title: "Add the scheduler",
                            objective: "Add a TweetScheduler.",
                            doneCriteria: "Test passes; build green.",
                            status: .active, attempts: 0)
        try store.create(Plan(
            id: "plan-eval", sessionId: "sess-eval",
            objective: "Build a scheduler.", steps: [step],
            status: .running, currentStepIndex: 0))

        let evaluator = makeEvaluator(store: store)
        let verdict = PlanStep.Verdict(passed: false, score: 0.2, feedback: "build failed: missing type")

        let newAttempts = try evaluator.persistVerdict(step: step, verdict: verdict)
        XCTAssertEqual(newAttempts, 1, "attempts incremented from 0 to 1")

        let loaded = try XCTUnwrap(try store.currentPlan(sessionId: "sess-eval"))
        let reloadedStep = try XCTUnwrap(loaded.steps.first)
        XCTAssertEqual(reloadedStep.status, .failed, "a failed verdict sets status=failed")
        XCTAssertEqual(reloadedStep.attempts, 1, "the incremented attempt count persisted")
        XCTAssertEqual(reloadedStep.lastVerdict?.passed, false)
        XCTAssertEqual(reloadedStep.lastVerdict?.score ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(reloadedStep.lastVerdict?.feedback, "build failed: missing type")
    }

    /// A passing verdict persists status=passed.
    func testPersistPassingVerdictSetsStatusPassed() async throws {
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: "sess-pass", projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        let store = PlanStore(database: db)
        let step = PlanStep(id: "sp", index: 0, title: "T", objective: "O",
                            doneCriteria: "D", status: .active, attempts: 2)
        try store.create(Plan(id: "pp", sessionId: "sess-pass", objective: "obj",
                              steps: [step], status: .running, currentStepIndex: 0))

        let evaluator = makeEvaluator(store: store)
        let newAttempts = try evaluator.persistVerdict(
            step: step, verdict: .init(passed: true, score: 0.9, feedback: "all good: build green, tests pass"))
        XCTAssertEqual(newAttempts, 3, "attempts goes 2 -> 3")

        let loaded = try XCTUnwrap(try store.currentPlan(sessionId: "sess-pass"))
        XCTAssertEqual(loaded.steps.first?.status, .passed)
        XCTAssertEqual(loaded.steps.first?.attempts, 3)
        XCTAssertEqual(loaded.steps.first?.lastVerdict?.passed, true)
    }

    /// persistVerdict without a store throws (the store is optional at init).
    func testPersistWithoutStoreThrows() async throws {
        let evaluator = makeEvaluator(store: nil)
        XCTAssertThrowsError(
            try evaluator.persistVerdict(step: sampleStep(), verdict: .init(passed: true, score: 1, feedback: "x"))
        ) { error in
            guard case Evaluator.EvaluatorError.noStore = error else {
                return XCTFail("expected .noStore, got \(error)")
            }
        }
    }

    // MARK: - ObservationBuilder

    /// The builder pairs Bash calls with their results by tool-use id, collects
    /// assistant text, and distills error signals - the right ground truth.
    func testObservationBuilderExtractsGroundTruth() {
        let now = Date()
        let events: [SupervisorEvent] = [
            .assistantText(.init(sessionId: "s", text: "I'll add the scheduler and verify it.",
                                 turnUUID: "u1", ts: now)),
            .bashToolCall(.init(sessionId: "s", command: "swift build", description: "build the package",
                                toolUseId: "tu1", turnUUID: "u1", ts: now)),
            .bashToolResult(.init(sessionId: "s", toolUseId: "tu1",
                                  output: "Compiling SupervisorCore\nSources/Foo.swift:3:1: error: cannot find 'Bar' in scope\nerror: build failed",
                                  isError: true, ts: now)),
            .bashToolCall(.init(sessionId: "s", command: "swift test --filter Scheduler", description: nil,
                                toolUseId: "tu2", turnUUID: "u1", ts: now)),
            .bashToolResult(.init(sessionId: "s", toolUseId: "tu2",
                                  output: "Test Suite 'SchedulerTests' passed", isError: false, ts: now)),
            // A non-Bash signal that must be ignored.
            .systemSignal(.init(sessionId: "s", subtype: "hookFired", preventedContinuation: false, ts: now)),
        ]

        let obs = ObservationBuilder.build(from: events, stepTitle: "Add the scheduler")

        XCTAssertEqual(obs.stepTitle, "Add the scheduler")
        XCTAssertEqual(obs.commands.count, 2, "both Bash commands captured")

        // Command 1 paired to its FAILING result.
        let build = obs.commands[0]
        XCTAssertEqual(build.command, "swift build")
        XCTAssertEqual(build.description, "build the package")
        XCTAssertTrue(build.isError, "the failing result is paired by tool-use id")
        XCTAssertTrue(build.output.contains("cannot find 'Bar'"), "the real build output is carried")

        // Command 2 paired to its PASSING result.
        let test = obs.commands[1]
        XCTAssertEqual(test.command, "swift test --filter Scheduler")
        XCTAssertFalse(test.isError)
        XCTAssertNil(test.description)

        // Assistant text is collected (as the claim).
        XCTAssertTrue(obs.assistantText.contains("add the scheduler"))

        // Errors distilled: the failing command + its compile-error line.
        XCTAssertTrue(obs.errors.contains { $0.contains("command failed: swift build") },
                      "the error-flagged command is distilled")
        XCTAssertTrue(obs.errors.contains { $0.contains("cannot find 'Bar'") },
                      "the compiler error line is distilled from the output")

        // No Edit/Write events exist yet, so no file changes from a Bash window.
        XCTAssertTrue(obs.fileChanges.isEmpty)
        XCTAssertFalse(obs.hasNoGroundTruth, "commands ran, so there IS ground truth")
    }

    /// An event window with only assistant prose (no commands, no files) yields
    /// an observation with no ground truth - the signal the prompt leans on to
    /// fail a step that only CLAIMS success.
    func testObservationBuilderNoGroundTruthFromProseOnly() {
        let now = Date()
        let events: [SupervisorEvent] = [
            .assistantText(.init(sessionId: "s", text: "All done, everything works perfectly!",
                                 turnUUID: "u1", ts: now)),
        ]
        let obs = ObservationBuilder.build(from: events)
        XCTAssertTrue(obs.commands.isEmpty)
        XCTAssertTrue(obs.hasNoGroundTruth, "prose with no commands/files has no ground truth")
        XCTAssertTrue(obs.assistantText.contains("All done"))
    }

    /// A Bash call whose result never arrived is still captured (command with
    /// empty output, not an error) - the builder does not drop unpaired calls.
    func testObservationBuilderHandlesUnpairedCall() {
        let now = Date()
        let events: [SupervisorEvent] = [
            .bashToolCall(.init(sessionId: "s", command: "swift build", description: nil,
                                toolUseId: "tuX", turnUUID: "u1", ts: now)),
        ]
        let obs = ObservationBuilder.build(from: events)
        XCTAssertEqual(obs.commands.count, 1)
        XCTAssertEqual(obs.commands.first?.output, "")
        XCTAssertEqual(obs.commands.first?.isError, false)
    }

    /// Oversized command output is truncated head+tail so a noisy log cannot
    /// blow the judge's context, while keeping the ends where verdicts live.
    func testObservationBuilderTruncatesHugeOutput() {
        let now = Date()
        let huge = String(repeating: "x", count: 50_000)
        let events: [SupervisorEvent] = [
            .bashToolCall(.init(sessionId: "s", command: "swift test", description: nil,
                                toolUseId: "tu", turnUUID: "u", ts: now)),
            .bashToolResult(.init(sessionId: "s", toolUseId: "tu",
                                  output: "HEAD_MARKER" + huge + "TAIL_MARKER", isError: false, ts: now)),
        ]
        let obs = ObservationBuilder.build(from: events)
        let out = try! XCTUnwrap(obs.commands.first?.output)
        XCTAssertLessThan(out.utf8.count, 50_000, "the output was truncated")
        XCTAssertTrue(out.contains("HEAD_MARKER"), "the head is preserved")
        XCTAssertTrue(out.contains("TAIL_MARKER"), "the tail is preserved")
        XCTAssertTrue(out.contains("truncated"), "the elision is marked")
    }
}

// MARK: - URLProtocol mock

private final class EvaluatorMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = EvaluatorTests.canned[path] else {
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
