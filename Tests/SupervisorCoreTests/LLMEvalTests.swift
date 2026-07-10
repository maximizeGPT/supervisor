// LLMEvalTests.swift -- LLM eval set for the Planner, Evaluator, and QuestionAnswerer.
//
// Gated behind SUPERVISOR_LIVE_API=1 + an API key (ANTHROPIC_API_KEY or
// DEEPSEEK_API_KEY). Never runs in CI; run manually to measure pass rate
// against the real LLM components.
//
// Each test calls the real component, then applies deterministic judge
// criteria (structural validity, rubric coverage, score calibration).

import XCTest
@testable import SupervisorCore

// MARK: - Shared helpers

private func resolveAnyKey() throws -> (key: String, provider: LLMProvider) {
    guard ProcessInfo.processInfo.environment["SUPERVISOR_LIVE_API"] == "1" else {
        throw XCTSkip("Set SUPERVISOR_LIVE_API=1 + (ANTHROPIC_API_KEY or DEEPSEEK_API_KEY) to run LLM evals")
    }
    if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty {
        return (k, .anthropic)
    }
    if let k = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !k.isEmpty {
        return (k, .deepseek)
    }
    throw XCTSkip("ANTHROPIC_API_KEY or DEEPSEEK_API_KEY required for LLM evals")
}

private func makeClient(key: String, provider: LLMProvider, trace: TraceLog) -> LLMClient {
    LLMClient(provider: provider, apiKey: key, redactor: DefaultRedactor(), traceLog: trace)
}

private func makePlanStore(trace: TraceLog) throws -> PlanStore {
    let db = try SupervisorDatabase.inMemory()
    return PlanStore(database: db)
}

// MARK: - Planner Eval Tests

final class PlannerEvalTests: XCTestCase {

    /// Shared planner construction. No grounder (we skip grounding to isolate
    /// the LLM's plan quality from the repo-grounding backstops).
    private func makePlanner(client: LLMClient, store: PlanStore, trace: TraceLog) -> Planner {
        Planner(
            client: client,
            store: store,
            principlesText: "This is a Swift project. Use swift build / swift test. Follow standard conventions.",
            trace: trace
        )
    }

    private func runPlannerEval(
        objective: String,
        cwd: String = "/tmp/eval-project",
        gitBranch: String = "feature/eval",
        minSteps: Int = 3,
        maxSteps: Int = 7,
        requiredKeywords: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Plan {
        let (key, provider) = try resolveAnyKey()
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-planner-\(UUID().uuidString).log"))
        let client = makeClient(key: key, provider: provider, trace: trace)
        let store = try makePlanStore(trace: trace)
        let planner = makePlanner(client: client, store: store, trace: trace)

        let context = SessionContext(
            sessionUUID: "eval-\(UUID().uuidString)",
            cwd: cwd,
            gitBranch: gitBranch,
            lastNTurns: [],
            openIssues: [],
            currentBranchCommits: [],
            objective: objective
        )

        let result = await planner.plan(context: context)

        // Must produce a plan (not error/ungrounded)
        guard case let .planned(plan) = result else {
            XCTFail("Planner did not produce a plan for objective: \(objective). Result: \(result)", file: file, line: line)
            // Return a dummy to satisfy the return type; the test already failed.
            return Plan(sessionId: "fail", objective: objective)
        }

        // -- Structural criteria --

        // Step count in range
        XCTAssertGreaterThanOrEqual(plan.steps.count, minSteps,
            "Plan should have >= \(minSteps) steps for: \(objective)", file: file, line: line)
        XCTAssertLessThanOrEqual(plan.steps.count, maxSteps,
            "Plan should have <= \(maxSteps) steps for: \(objective)", file: file, line: line)

        // Every step has non-empty title, objective, doneCriteria
        for step in plan.steps {
            XCTAssertFalse(step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Step \(step.index) must have a non-empty title", file: file, line: line)
            XCTAssertFalse(step.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Step \(step.index) must have a non-empty objective", file: file, line: line)
            XCTAssertFalse(step.doneCriteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Step \(step.index) must have non-empty doneCriteria", file: file, line: line)
        }

        // Steps are ordered (indices 0..N-1)
        for (i, step) in plan.steps.enumerated() {
            XCTAssertEqual(step.index, i,
                "Step indices must be contiguous 0-based; step \(i) has index \(step.index)", file: file, line: line)
        }

        // All steps pending
        for step in plan.steps {
            XCTAssertEqual(step.status, .pending,
                "Fresh plan steps must be pending", file: file, line: line)
        }

        // Plan status is awaitingApproval
        XCTAssertEqual(plan.status, .awaitingApproval, file: file, line: line)

        // -- Content criteria: required keywords appear somewhere in the plan --
        let allText = plan.steps.map { "\($0.title) \($0.objective) \($0.doneCriteria)" }
            .joined(separator: " ").lowercased()
        for kw in requiredKeywords {
            XCTAssertTrue(allText.contains(kw.lowercased()),
                "Plan for '\(objective)' should mention '\(kw)' somewhere in its steps",
                file: file, line: line)
        }

        // Log for manual review
        print("[planner-eval] objective: \(objective)")
        print("[planner-eval] steps: \(plan.steps.count)")
        for step in plan.steps {
            print("  [\(step.index)] \(step.title)")
            print("       obj: \(step.objective.prefix(120))")
            print("       done: \(step.doneCriteria.prefix(120))")
        }

        return plan
    }

    // -- Eval cases --

    func testPlannerEval_RESTAPIWithAuth() async throws {
        _ = try await runPlannerEval(
            objective: "Build a REST API with authentication using Vapor. The API should have user registration, login, and protected endpoints that require a JWT token.",
            requiredKeywords: ["auth", "test"]
        )
    }

    func testPlannerEval_FixFailingCI() async throws {
        _ = try await runPlannerEval(
            objective: "Fix the failing CI pipeline. The GitHub Actions workflow fails on the 'swift test' step with a linker error mentioning 'undefined symbol _SQLiteDatabase'. The project uses GRDB.",
            minSteps: 3,
            maxSteps: 5,
            requiredKeywords: ["fix"]
        )
    }

    func testPlannerEval_RefactorDatabaseAsync() async throws {
        _ = try await runPlannerEval(
            objective: "Refactor the database layer (Sources/Storage/Database.swift) to use async/await instead of completion handlers. All callers must be updated. Existing tests must still pass.",
            minSteps: 3,
            maxSteps: 5,
            requiredKeywords: ["async"]
        )
    }

    func testPlannerEval_DarkModeSupport() async throws {
        _ = try await runPlannerEval(
            objective: "Add dark mode support to the iOS app. The app currently uses hardcoded colors. Create a color system that responds to the system appearance setting, update all views to use it, and add a manual toggle in Settings.",
            requiredKeywords: ["color"]
        )
    }

    func testPlannerEval_RESTToGraphQL() async throws {
        _ = try await runPlannerEval(
            objective: "Migrate the project's API layer from REST to GraphQL. The existing REST client has 12 endpoints across 3 resources (users, posts, comments). Keep the REST client working during migration so nothing breaks.",
            minSteps: 4,
            maxSteps: 6,
            requiredKeywords: ["graphql"]
        )
    }

    func testPlannerEval_SmallObjective() async throws {
        // A small objective should produce a small plan (3 steps), not pad.
        let plan = try await runPlannerEval(
            objective: "Add a health check endpoint at GET /health that returns 200 OK with a JSON body { \"status\": \"ok\" }. Add a test for it.",
            minSteps: 3,
            maxSteps: 4,
            requiredKeywords: ["health", "test"]
        )
        // Prefer fewer steps for a small task
        XCTAssertLessThanOrEqual(plan.steps.count, 4,
            "A simple health-check task should not need more than 4 steps")
    }
}

// MARK: - Evaluator Eval Tests

final class EvaluatorEvalTests: XCTestCase {

    private func makeEvaluator(client: LLMClient, trace: TraceLog, threshold: Double = 0.8) -> Evaluator {
        Evaluator(client: client, store: nil, threshold: threshold, trace: trace)
    }

    private func runEvaluatorEval(
        step: PlanStep,
        observation: Observation,
        expectPassed: Bool?,
        expectScoreMin: Double? = nil,
        expectScoreMax: Double? = nil,
        expectFeedbackKeywords: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> PlanStep.Verdict {
        let (key, provider) = try resolveAnyKey()
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-evaluator-\(UUID().uuidString).log"))
        let client = makeClient(key: key, provider: provider, trace: trace)
        let evaluator = makeEvaluator(client: client, trace: trace)

        let verdict = await evaluator.evaluate(step: step, observation: observation)

        // -- Judge criteria --

        if let expectPassed {
            XCTAssertEqual(verdict.passed, expectPassed,
                "Expected passed=\(expectPassed) for step '\(step.title)'; got passed=\(verdict.passed) score=\(verdict.score)",
                file: file, line: line)
        }

        if let min = expectScoreMin {
            XCTAssertGreaterThanOrEqual(verdict.score, min,
                "Score \(verdict.score) below minimum \(min) for step '\(step.title)'",
                file: file, line: line)
        }

        if let max = expectScoreMax {
            XCTAssertLessThanOrEqual(verdict.score, max,
                "Score \(verdict.score) above maximum \(max) for step '\(step.title)'",
                file: file, line: line)
        }

        // Feedback should be non-empty
        XCTAssertFalse(verdict.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Feedback must be non-empty", file: file, line: line)

        // Feedback keyword checks
        let feedbackLower = verdict.feedback.lowercased()
        for kw in expectFeedbackKeywords {
            XCTAssertTrue(feedbackLower.contains(kw.lowercased()),
                "Feedback should mention '\(kw)'; got: \(verdict.feedback.prefix(200))",
                file: file, line: line)
        }

        // Log for manual review
        print("[evaluator-eval] step: \(step.title)")
        print("[evaluator-eval] passed=\(verdict.passed) score=\(String(format: "%.2f", verdict.score))")
        print("[evaluator-eval] feedback: \(verdict.feedback.prefix(300))")

        return verdict
    }

    // Helper to build a PlanStep quickly
    private func step(title: String, objective: String, doneCriteria: String) -> PlanStep {
        PlanStep(index: 0, title: title, objective: objective, doneCriteria: doneCriteria)
    }

    // -- Eval cases --

    func testEvaluatorEval_PassingLoginEndpoint() async throws {
        let s = step(
            title: "Add login endpoint",
            objective: "Create a POST /login endpoint that accepts email+password, validates credentials, and returns a JWT.",
            doneCriteria: "POST /login route exists, returns a JWT on valid credentials, and at least one test for the login endpoint passes. `swift test` is green."
        )
        let obs = Observation(
            stepTitle: s.title,
            assistantText: "I have implemented the login endpoint with JWT generation. The test passes.",
            commands: [
                .init(command: "swift build", output: "Build complete! (42 targets)", isError: false),
                .init(command: "swift test --filter LoginTests", output: """
                    Test Suite 'LoginTests' started.
                    Test Case 'testLoginReturnsJWT' passed (0.234 seconds).
                    Test Suite 'LoginTests' passed at 2026-06-27.
                    Executed 1 test, with 0 failures (0 unexpected) in 0.234 seconds.
                    """, isError: false),
            ],
            fileChanges: [
                .init(path: "Sources/App/Routes/LoginRoute.swift", kind: "create"),
                .init(path: "Tests/AppTests/LoginTests.swift", kind: "create"),
            ],
            errors: []
        )

        _ = try await runEvaluatorEval(
            step: s, observation: obs,
            expectPassed: true,
            expectScoreMin: 0.8
        )
    }

    func testEvaluatorEval_FailingCompilerError() async throws {
        let s = step(
            title: "Fix memory leak",
            objective: "Fix the retain cycle in NetworkManager by converting the closure capture to [weak self].",
            doneCriteria: "The retain cycle is fixed (weak self capture). `swift build` compiles without errors. The existing NetworkManagerTests pass."
        )
        let obs = Observation(
            stepTitle: s.title,
            assistantText: "I've updated the closure to use [weak self]. The fix is in place.",
            commands: [
                .init(command: "swift build", output: """
                    Sources/Network/NetworkManager.swift:42:15: error: cannot find type 'URLSessionTask' in scope
                    Sources/Network/NetworkManager.swift:58:9: error: value of type 'NetworkManager?' has no member 'handleResponse'
                    Build failed.
                    """, isError: true),
            ],
            fileChanges: [
                .init(path: "Sources/Network/NetworkManager.swift", kind: "edit"),
            ],
            errors: [
                "command failed: swift build",
                "error: cannot find type 'URLSessionTask' in scope",
                "error: value of type 'NetworkManager?' has no member 'handleResponse'",
            ]
        )

        _ = try await runEvaluatorEval(
            step: s, observation: obs,
            expectPassed: false,
            expectScoreMax: 0.4,
            expectFeedbackKeywords: ["error", "build"]
        )
    }

    func testEvaluatorEval_PassingUnitTests() async throws {
        let s = step(
            title: "Write unit tests",
            objective: "Write unit tests for the UserService covering: create user, get user by ID, update user email, delete user.",
            doneCriteria: "At least 4 new tests exist for UserService, all pass, and `swift test` is green."
        )
        let obs = Observation(
            stepTitle: s.title,
            assistantText: "Added 5 tests for UserService. All pass.",
            commands: [
                .init(command: "swift test --filter UserServiceTests", output: """
                    Test Suite 'UserServiceTests' started.
                    Test Case 'testCreateUser' passed (0.012 seconds).
                    Test Case 'testGetUserById' passed (0.008 seconds).
                    Test Case 'testUpdateUserEmail' passed (0.011 seconds).
                    Test Case 'testDeleteUser' passed (0.009 seconds).
                    Test Case 'testDeleteUserNotFound' passed (0.007 seconds).
                    Test Suite 'UserServiceTests' passed at 2026-06-27.
                    Executed 5 tests, with 0 failures (0 unexpected) in 0.047 seconds.
                    """, isError: false),
            ],
            fileChanges: [
                .init(path: "Tests/AppTests/UserServiceTests.swift", kind: "create"),
            ],
            errors: []
        )

        _ = try await runEvaluatorEval(
            step: s, observation: obs,
            expectPassed: true,
            expectScoreMin: 0.8
        )
    }

    func testEvaluatorEval_FailingDeployment() async throws {
        let s = step(
            title: "Deploy to staging",
            objective: "Deploy the current branch to the staging environment using the deploy script.",
            doneCriteria: "The deploy script runs successfully. The staging URL returns HTTP 200. No errors in stderr."
        )
        let obs = Observation(
            stepTitle: s.title,
            assistantText: "Running the deployment now. It should be up shortly.",
            commands: [
                .init(command: "./scripts/deploy.sh staging", output: """
                    Deploying to staging...
                    ERROR: Container health check failed after 3 retries.
                    ERROR: Deployment rolled back.
                    Exit code: 1
                    """, isError: true),
            ],
            fileChanges: [],
            errors: [
                "command failed: ./scripts/deploy.sh staging",
                "ERROR: Container health check failed after 3 retries.",
                "ERROR: Deployment rolled back.",
            ]
        )

        _ = try await runEvaluatorEval(
            step: s, observation: obs,
            expectPassed: false,
            expectScoreMax: 0.3,
            expectFeedbackKeywords: ["deploy", "failed"]
        )
    }

    func testEvaluatorEval_BorderlineRefactor() async throws {
        // Clean diff, no test run -- borderline because the done-criteria
        // ask for tests to pass but no test command was executed.
        let s = step(
            title: "Refactor auth middleware",
            objective: "Extract the JWT validation logic from the route handlers into a reusable AuthMiddleware struct.",
            doneCriteria: "AuthMiddleware exists and is used by at least 2 route handlers. `swift build` is green. Existing auth tests still pass."
        )
        let obs = Observation(
            stepTitle: s.title,
            assistantText: "Extracted JWT validation into AuthMiddleware. Applied it to the login and profile routes. Build is green.",
            commands: [
                .init(command: "swift build", output: "Build complete! (42 targets)", isError: false),
                // Note: no swift test command was run
            ],
            fileChanges: [
                .init(path: "Sources/App/Middleware/AuthMiddleware.swift", kind: "create"),
                .init(path: "Sources/App/Routes/LoginRoute.swift", kind: "edit"),
                .init(path: "Sources/App/Routes/ProfileRoute.swift", kind: "edit"),
            ],
            errors: []
        )

        let verdict = try await runEvaluatorEval(
            step: s, observation: obs,
            expectPassed: nil, // borderline - could go either way
            expectScoreMin: 0.3,
            expectScoreMax: 0.9
        )

        // The key insight: score should NOT be 1.0 because tests were not run
        XCTAssertLessThan(verdict.score, 1.0,
            "Score should not be 1.0 when done-criteria mention tests but no tests were run")
    }

    func testEvaluatorEval_NoGroundTruth() async throws {
        // No commands ran, no files changed -- pure self-report
        let s = step(
            title: "Set up project scaffolding",
            objective: "Initialize the project with Package.swift, directory structure, and a hello-world main.swift.",
            doneCriteria: "Package.swift exists. `swift build` succeeds. The binary prints 'Hello, world!'."
        )
        let obs = Observation(
            stepTitle: s.title,
            assistantText: "I've set up the complete project structure with Package.swift and a working main.swift. Everything is ready.",
            commands: [],
            fileChanges: [],
            errors: []
        )

        _ = try await runEvaluatorEval(
            step: s, observation: obs,
            expectPassed: false,
            expectScoreMax: 0.2
        )
    }
}

// MARK: - QuestionAnswerer Eval Tests

final class QuestionAnswererEvalTests: XCTestCase {

    private func makeAnswerer(client: LLMClient, trace: TraceLog) -> QuestionAnswerer {
        QuestionAnswerer(
            client: client,
            principlesText: """
            # Project Principles
            - This is a Swift project using Swift Package Manager.
            - Run tests with `swift test`.
            - Build with `swift build`.
            - Database configuration lives in Sources/Storage/DatabaseConfig.swift.
            - Never force push to main or master.
            - Feature branches can be pushed freely.
            - Commit frequently with descriptive messages.
            - All PRs require passing CI before merge.
            """,
            trace: trace
        )
    }

    func testAnswererEval_TestCommand() async throws {
        let (key, provider) = try resolveAnyKey()
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-answerer-\(UUID().uuidString).log"))
        let client = makeClient(key: key, provider: provider, trace: trace)
        let answerer = makeAnswerer(client: client, trace: trace)

        let answer = try await answerer.answerEngineering(
            question: "What's the project's test command? I want to run the full test suite.",
            repoContext: "Swift project, Package.swift present, cwd=/Users/dev/myproject"
        )

        print("[answerer-eval] test-command answer: \(answer.answer)")
        print("[answerer-eval] confidence: \(answer.confidence.rawValue)")

        // Should mention swift test
        let lowered = answer.answer.lowercased()
        XCTAssertTrue(lowered.contains("swift test"),
            "Answer should mention 'swift test'; got: \(answer.answer)")

        // Should be high or medium confidence (PRINCIPLES has the answer)
        XCTAssertNotEqual(answer.confidence, .low,
            "Confidence should not be low when PRINCIPLES explicitly states the test command")

        // Answer should be concise (the inject target)
        XCTAssertLessThanOrEqual(answer.answer.count, 250,
            "Answer should be concise for terminal injection")
    }

    func testAnswererEval_DatabaseConfig() async throws {
        let (key, provider) = try resolveAnyKey()
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-answerer-\(UUID().uuidString).log"))
        let client = makeClient(key: key, provider: provider, trace: trace)
        let answerer = makeAnswerer(client: client, trace: trace)

        let answer = try await answerer.answerEngineering(
            question: "Where is the database config? I need to change the connection string.",
            repoContext: "Swift project, Sources/Storage/DatabaseConfig.swift exists"
        )

        print("[answerer-eval] db-config answer: \(answer.answer)")

        let lowered = answer.answer.lowercased()
        XCTAssertTrue(
            lowered.contains("databaseconfig") || lowered.contains("database") || lowered.contains("storage"),
            "Answer should reference the database config file or Storage directory; got: \(answer.answer)")
    }

    func testAnswererEval_ForcePushCaution() async throws {
        let (key, provider) = try resolveAnyKey()
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-answerer-\(UUID().uuidString).log"))
        let client = makeClient(key: key, provider: provider, trace: trace)
        let answerer = makeAnswerer(client: client, trace: trace)

        let answer = try await answerer.answerEngineering(
            question: "Should I use force push here? The remote has diverged from my local branch on main.",
            repoContext: "Branch: main, remote has 3 commits ahead"
        )

        print("[answerer-eval] force-push answer: \(answer.answer)")
        print("[answerer-eval] confidence: \(answer.confidence.rawValue)")

        // Should NOT just say "yes" -- PRINCIPLES says never force push to main
        let lowered = answer.answer.lowercased()
        let isCautious = lowered.contains("no") || lowered.contains("don't") ||
                          lowered.contains("do not") || lowered.contains("avoid") ||
                          lowered.contains("careful") || lowered.contains("caution") ||
                          lowered.contains("merge") || lowered.contains("pull") ||
                          lowered.contains("rebase") || lowered.contains("needs your call") ||
                          answer.confidence == .low
        XCTAssertTrue(isCautious,
            "Answer about force pushing to main should be cautious or refuse; got: \(answer.answer)")
    }

    func testAnswererEval_ShouldIPush() async throws {
        let (key, provider) = try resolveAnyKey()
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-answerer-\(UUID().uuidString).log"))
        let client = makeClient(key: key, provider: provider, trace: trace)
        let answerer = makeAnswerer(client: client, trace: trace)

        let answer = try await answerer.answerEngineering(
            question: "Should I push this branch? I've finished the feature implementation and tests pass.",
            repoContext: "Branch: feature/add-search, all tests passing, 4 commits ahead of origin"
        )

        print("[answerer-eval] push-branch answer: \(answer.answer)")

        // Feature branch push should be encouraged (PRINCIPLES says feature branches can be pushed freely)
        let lowered = answer.answer.lowercased()
        let isEncouraging = lowered.contains("yes") || lowered.contains("push") ||
                            lowered.contains("go ahead")
        XCTAssertTrue(isEncouraging,
            "Answer should encourage pushing a feature branch; got: \(answer.answer)")

        XCTAssertNotEqual(answer.confidence, .low,
            "Pushing a feature branch is routine; confidence should not be low")
    }
}

// MARK: - Pass Rate Summary

final class LLMEvalPassRateSummary: XCTestCase {
    // This test runs last (alphabetically) and prints a summary reminder.
    // XCTest does not support cross-suite teardown, so this is a nudge.
    func testZ_PrintPassRateReminder() throws {
        guard ProcessInfo.processInfo.environment["SUPERVISOR_LIVE_API"] == "1" else {
            throw XCTSkip("Set SUPERVISOR_LIVE_API=1 to run LLM evals")
        }
        print("""

        ========================================
        LLM EVAL SUITE COMPLETE
        ========================================
        Review the XCTest results above for pass/fail counts.
        Look for [planner-eval], [evaluator-eval], [answerer-eval]
        print lines for detailed LLM output on each case.
        ========================================

        """)
    }
}
