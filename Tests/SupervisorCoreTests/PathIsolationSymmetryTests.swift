// PathIsolationSymmetryTests.swift
//
// Issue #8 -- extend the per-path prompt isolation (Issue #7 bash)
// to the assistant-text and idle paths for full PRINCIPLES section 2e symmetry.
//
// Structure mirrors BashCategoryIsolationTests:
//   1. HardcodedRubric snapshot tests for per-path category lists
//   2. TriagePrompt.buildXxxRequest system-prompt snapshot tests
//   3. Behavioral plumbing test: bash-shaped command through
//      assistant-text path with canned all-clear, assert no false
//      positive on destructive categories

import XCTest
@testable import SupervisorCore

@MainActor
final class PathIsolationSymmetryTests: XCTestCase {

    // MARK: - HardcodedRubric snapshots (assistant-text path)

    func testAssistantTextCategoriesContainsOnlyUserQuestionPending() {
        let names = HardcodedRubric.assistantTextCategoryNames
        XCTAssertEqual(names, ["user_question_pending"],
                       "assistant-text path must evaluate ONLY user_question_pending")
        XCTAssertFalse(names.contains("destructive_action_pending"))
        XCTAssertFalse(names.contains("edits_outside_worktree"))
        XCTAssertFalse(names.contains("prompt_injection_signature"))
        XCTAssertFalse(names.contains("worker_idle_post_completion"))
    }

    func testAssistantTextCategoriesMarkdownShape() {
        let md = HardcodedRubric.assistantTextCategoriesMarkdown
        XCTAssertTrue(md.contains("## user_question_pending"),
                      "assistant-text markdown must contain user_question_pending body")
        XCTAssertFalse(md.contains("## destructive_action_pending"),
                       "assistant-text markdown must NOT contain bash categories")
        XCTAssertFalse(md.contains("## edits_outside_worktree"))
        XCTAssertFalse(md.contains("## prompt_injection_signature"))
        XCTAssertFalse(md.contains("## worker_idle_post_completion"))
    }

    // MARK: - HardcodedRubric snapshots (idle path)

    func testIdleCategoriesContainsOnlyWorkerIdlePostCompletion() {
        let names = HardcodedRubric.idleCategoryNames
        XCTAssertEqual(names, ["worker_idle_post_completion"],
                       "idle path must evaluate ONLY worker_idle_post_completion")
        XCTAssertFalse(names.contains("destructive_action_pending"))
        XCTAssertFalse(names.contains("edits_outside_worktree"))
        XCTAssertFalse(names.contains("prompt_injection_signature"))
        XCTAssertFalse(names.contains("user_question_pending"))
    }

    func testIdleCategoriesMarkdownShape() {
        let md = HardcodedRubric.idleCategoriesMarkdown
        XCTAssertTrue(md.contains("## worker_idle_post_completion"),
                      "idle markdown must contain worker_idle_post_completion body")
        XCTAssertFalse(md.contains("## destructive_action_pending"),
                       "idle markdown must NOT contain bash categories")
        XCTAssertFalse(md.contains("## edits_outside_worktree"))
        XCTAssertFalse(md.contains("## prompt_injection_signature"))
        XCTAssertFalse(md.contains("## user_question_pending"))
    }

    // MARK: - TriagePrompt system-prompt snapshots

    func testAssistantTextSystemPromptOmitsNonAssistantTextCategories() {
        let req = TriagePrompt.buildAssistantQuestionRequest(
            model: "claude-haiku-4-5-test",
            sessionId: "s-issue8-at",
            cwd: "/Users/test",
            userPrompt: "tell me about the config",
            assistantText: "Would you like me to update the config?",
            recentEvents: []
        )

        let expected = TriagePrompt.systemPrompt(
            categoriesMarkdown: HardcodedRubric.assistantTextCategoriesMarkdown
        )
        XCTAssertTrue(expected.contains("## user_question_pending"),
                      "assistant-text systemPrompt must contain user_question_pending body")
        XCTAssertFalse(expected.contains("## destructive_action_pending"),
                       "assistant-text systemPrompt must NOT contain destructive_action_pending")
        XCTAssertFalse(expected.contains("## edits_outside_worktree"),
                       "assistant-text systemPrompt must NOT contain edits_outside_worktree")
        XCTAssertFalse(expected.contains("## prompt_injection_signature"),
                       "assistant-text systemPrompt must NOT contain prompt_injection_signature")
        XCTAssertFalse(expected.contains("## worker_idle_post_completion"),
                       "assistant-text systemPrompt must NOT contain worker_idle_post_completion")

        XCTAssertEqual(req.system, expected,
                       "buildAssistantQuestionRequest must pass assistantTextCategoriesMarkdown into systemPrompt")
    }

    func testIdleSystemPromptOmitsNonIdleCategories() {
        let req = TriagePrompt.buildIdleEvaluationRequest(
            model: "claude-haiku-4-5-test",
            sessionId: "s-issue8-idle",
            cwd: "/Users/test",
            gitBranch: "autonomous-test",
            userPrompt: "work on Issue #1",
            stopShapedPhrase: "all done",
            secondsSinceLastEvent: 30,
            recentEvents: []
        )

        let expected = TriagePrompt.systemPrompt(
            categoriesMarkdown: HardcodedRubric.idleCategoriesMarkdown
        )
        XCTAssertTrue(expected.contains("## worker_idle_post_completion"),
                      "idle systemPrompt must contain worker_idle_post_completion body")
        XCTAssertFalse(expected.contains("## destructive_action_pending"),
                       "idle systemPrompt must NOT contain destructive_action_pending")
        XCTAssertFalse(expected.contains("## edits_outside_worktree"),
                       "idle systemPrompt must NOT contain edits_outside_worktree")
        XCTAssertFalse(expected.contains("## prompt_injection_signature"),
                       "idle systemPrompt must NOT contain prompt_injection_signature")
        XCTAssertFalse(expected.contains("## user_question_pending"),
                       "idle systemPrompt must NOT contain user_question_pending")

        XCTAssertEqual(req.system, expected,
                       "buildIdleEvaluationRequest must pass idleCategoriesMarkdown into systemPrompt")
    }

    // MARK: - Behavioral plumbing test

    /// Feed a bash-shaped destructive command through the assistant-text
    /// path (as if Haiku's assistant text literally contained "rm -rf /"
    /// or destructive_action_pending). With the per-path-scoped system
    /// prompt, the rubric body for destructive categories isn't present,
    /// so Haiku can't ground a verdict against it. The canned all-clear
    /// verifies engine plumbing emits no decision.
    func testAssistantTextPathDoesNotFalsePositiveOnDestructiveContent() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        bus.publish(.sessionStart(.init(
            sessionId: "s-issue8-fp", cwd: "/Users/test/proj", gitBranch: "main",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: Date()
        )))
        bus.publish(.userPrompt(.init(
            sessionId: "s-issue8-fp", text: "deploy the app", ts: Date()
        )))
        // Assistant text that contains bash-shaped destructive content
        // AND literal category names. Pre-fix, the full rubric corpus
        // in the system prompt would let Haiku ground a
        // destructive_action_pending verdict against this text.
        bus.publish(.assistantText(.init(
            sessionId: "s-issue8-fp",
            text: "I ran `rm -rf /tmp/build` and also checked destructive_action_pending in the logs. The edits_outside_worktree check passed.",
            turnUUID: "u-issue8-fp",
            ts: Date()
        )))

        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(captured.snapshot.count, 0,
                       "assistant-text path with destructive content + canned all-clear must produce no decision on bash categories")
    }

    // MARK: - Harness (mirrors BashCategoryIsolationTests shape)

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

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Issue8MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeEngine() -> (TriageEngine, EventBus, TriageEngineTests.CapturedDecisions) {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("issue8-\(UUID().uuidString).log")))
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("issue8-client-\(UUID().uuidString).log"))
        )
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            idleThresholdSeconds: 9999,
            idleReTriageIntervalSeconds: 9999,
            idleCheckIntervalSeconds: 3600
        )
        let captured = TriageEngineTests.CapturedDecisions()
        engine.onDecision = { d in captured.append(d) }
        engine.start()
        return (engine, bus, captured)
    }

    private static func allClearResponse() -> Data {
        let body: [String: Any] = [
            "id": "msg_clear",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_clear",
                "name": "record_triage",
                "input": ["candidates": [] as [Any]],
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 480, "output_tokens": 10],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }
}

private final class Issue8MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = PathIsolationSymmetryTests.canned[path] else {
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
