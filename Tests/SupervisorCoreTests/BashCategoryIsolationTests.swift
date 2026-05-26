// BashCategoryIsolationTests.swift
//
// Issue #7 — bash triage shouldn't surface user_question_pending.
// Verifies the §2e per-path prompt isolation fix:
//
//   1. HardcodedRubric.bashCategoriesMarkdown excludes the
//      assistant-text-only categories.
//   2. TriagePrompt.buildRequest (bash path) passes the bash-scoped
//      markdown into systemPrompt — so the rubric BODY for
//      user_question_pending / worker_idle_post_completion never
//      appears in the bash path's system message.
//   3. buildRequest's user message ends with the per-path scope
//      sentence (belt + suspenders per §8a — even if Haiku ignores
//      the system-prompt filter, the scope sentence in the user
//      message reinforces the same constraint).
//
// What this test does NOT prove: that real Haiku, given a bash
// command containing the literal substring `user_question_pending`,
// respects the per-path scope and returns candidates=[]. That
// requires a calibration sweep (filed for v0.4.x; Mohammed's
// Issue #7 spec said "No API budget" for this fix). The snapshot
// tests below prove the prompt-level fix is in place; the
// behavioral test at the bottom proves engine plumbing handles a
// canned all-clear correctly for the post-fix prompt.

import XCTest
@testable import SupervisorCore

@MainActor
final class BashCategoryIsolationTests: XCTestCase {

    // MARK: - HardcodedRubric snapshots

    func testBashCategoriesExcludesAssistantTextOnlyCategories() {
        let names = HardcodedRubric.bashCategoryNames
        XCTAssertTrue(names.contains("destructive_action_pending"))
        XCTAssertTrue(names.contains("edits_outside_worktree"))
        XCTAssertTrue(names.contains("prompt_injection_signature"))
        XCTAssertFalse(names.contains("user_question_pending"),
                       "bash categories must NOT include user_question_pending — that's the §2e bug Issue #7 closes")
        XCTAssertFalse(names.contains("worker_idle_post_completion"),
                       "bash categories must NOT include worker_idle_post_completion — fires only from the idle-tick timer, never bash")
    }

    func testBashCategoriesMarkdownContainsBashBodiesButNotOthers() {
        let md = HardcodedRubric.bashCategoriesMarkdown
        XCTAssertTrue(md.contains("## destructive_action_pending"),
                      "bash markdown must contain the destructive_action_pending body")
        XCTAssertTrue(md.contains("## edits_outside_worktree"))
        XCTAssertTrue(md.contains("## prompt_injection_signature"))
        XCTAssertFalse(md.contains("## user_question_pending"),
                       "bash markdown must NOT contain the user_question_pending body")
        XCTAssertFalse(md.contains("## worker_idle_post_completion"),
                       "bash markdown must NOT contain the worker_idle_post_completion body")
    }

    // MARK: - TriagePrompt.buildRequest snapshot

    /// The bash path's system prompt must NOT include the rubric
    /// bodies for assistant-text-only categories. This is the
    /// strongest form of the fix — even if Haiku ignored the user-
    /// message scope sentence, it has no rubric body to ground a
    /// user_question_pending verdict against in this path.
    func testBashSystemPromptOmitsAssistantTextCategoryBodies() {
        let req = TriagePrompt.buildRequest(
            model: "claude-haiku-4-5-test",
            input: TriagePromptInput(
                cwd: "/Users/test",
                userPrompt: "let's search for stuff",
                bashCall: BashToolCallInfo(
                    sessionId: "s1",
                    command: "grep user_question_pending logs/",
                    description: nil,
                    toolUseId: "t-grep-1",
                    turnUUID: "u1",
                    ts: Date()
                ),
                recentResult: nil,
                recentEvents: []
            )
        )
        // The system prompt is the second tuple element of the
        // request body in our codebase — but to keep this test
        // implementation-detail-light, we serialize the prompt
        // directly via the function.
        let prompt = TriagePrompt.systemPrompt(
            categoriesMarkdown: HardcodedRubric.bashCategoriesMarkdown
        )

        XCTAssertTrue(prompt.contains("## destructive_action_pending"),
                      "bash systemPrompt must contain destructive_action_pending body")
        XCTAssertFalse(prompt.contains("## user_question_pending"),
                       "bash systemPrompt must NOT contain user_question_pending body — Issue #7's §2e fix")
        XCTAssertFalse(prompt.contains("## worker_idle_post_completion"),
                       "bash systemPrompt must NOT contain worker_idle_post_completion body")

        // Sanity: the request reaches the model. Pull system off the
        // built request so the test catches future regressions where
        // a refactor changes buildRequest's wiring but not this
        // snapshot helper.
        XCTAssertEqual(req.system, prompt,
                       "buildRequest must pass HardcodedRubric.bashCategoriesMarkdown into systemPrompt — a mismatch here means the per-path scoping regressed")
    }

    /// The bash path's USER message must end with the per-path
    /// scope sentence — belt to the system-prompt-body filter's
    /// suspenders. Haiku has been observed pattern-matching on
    /// category names appearing in bash commands; the explicit
    /// scope sentence is the strongest per-turn reminder.
    func testBashUserMessageContainsPerPathScopeSentence() {
        let req = TriagePrompt.buildRequest(
            model: "claude-haiku-4-5-test",
            input: TriagePromptInput(
                cwd: "/Users/test",
                userPrompt: "",
                bashCall: BashToolCallInfo(
                    sessionId: "s1",
                    command: "rm -rf /tmp/x",
                    description: nil,
                    toolUseId: "t-rm-1",
                    turnUUID: "u1",
                    ts: Date()
                ),
                recentResult: nil,
                recentEvents: []
            )
        )
        // The user message lives in the first message.content slot
        // as a plain string for the bash path.
        guard case let .string(userText)? = req.messages.first?.content else {
            return XCTFail("bash request must have a string user message")
        }

        XCTAssertTrue(userText.contains("Evaluate ONLY against the bash-shaped categories"),
                      "user message must open the per-path scope sentence")
        XCTAssertTrue(userText.contains("Do NOT return user_question_pending"),
                      "user message must explicitly forbid user_question_pending from this path")
        XCTAssertTrue(userText.contains("worker_idle_post_completion"),
                      "user message must explicitly forbid worker_idle_post_completion from this path")
        XCTAssertTrue(userText.contains("grep regex"),
                      "user message must call out the specific failure mode (literal category name in a bash command)")
    }

    /// Default-arg compatibility: the systemPrompt() function with no
    /// args still returns the full-corpus prompt, so assistant-text
    /// + idle paths (which haven't been migrated to per-path-scoped
    /// markdown) continue to work as before.
    func testSystemPromptDefaultArgReturnsFullCorpus() {
        let full = TriagePrompt.systemPrompt()
        XCTAssertTrue(full.contains("## destructive_action_pending"))
        XCTAssertTrue(full.contains("## user_question_pending"),
                      "default systemPrompt() still includes all bodies — assistant-text + idle paths rely on this")
        XCTAssertTrue(full.contains("## worker_idle_post_completion"))
    }

    // MARK: - Behavioral plumbing test

    /// Mirrors the IdleDetectionTests / TriageEngineTests URLProtocol
    /// mock pattern: drive a bash command that LITERALLY contains
    /// "user_question_pending" through the engine with a canned
    /// all-clear Haiku response. Verifies the engine emits no
    /// decision — proving engine plumbing handles the post-fix
    /// prompt correctly. (Doesn't prove real Haiku respects the
    /// scope; that's calibration territory, deferred per Issue #7
    /// "No API budget".)
    func testBashTriagePlumbingRespectsAllClearWithCategoryNameInCommand() async throws {
        Self.canned["/v1/messages"] = (200, Self.allClearResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        bus.publish(.sessionStart(.init(
            sessionId: "s-issue7", cwd: "/Users/test/proj", gitBranch: "main",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: Date()
        )))
        bus.publish(.userPrompt(.init(
            sessionId: "s-issue7", text: "grep through the logs", ts: Date()
        )))
        // The crucial bash command: contains the literal substring
        // `user_question_pending`. Pre-fix, Haiku has been observed
        // returning a flag in that category; with the all-clear
        // canned response we just verify the engine doesn't
        // synthesize a flag of its own.
        bus.publish(.bashToolCall(.init(
            sessionId: "s-issue7",
            command: "grep -E 'user_question_pending|triage.answer' ~/Library/Logs/Supervisor/supervisor.log",
            description: nil,
            toolUseId: "t-grep-uqp",
            turnUUID: "u1",
            ts: Date()
        )))

        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(captured.snapshot.count, 0,
                       "bash command with literal category-name substring + canned all-clear must produce no decision")
    }

    // MARK: - Harness (mirrors TriageEngineTests' shape)

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
        cfg.protocolClasses = [Issue7MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeEngine() -> (TriageEngine, EventBus, TriageEngineTests.CapturedDecisions) {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("issue7-\(UUID().uuidString).log")))
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("issue7-client-\(UUID().uuidString).log"))
        )
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            idleThresholdSeconds: 9999,
            idleReTriageIntervalSeconds: 9999,
            idleCheckIntervalSeconds: 3600  // disable the timer
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

private final class Issue7MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = BashCategoryIsolationTests.canned[path] else {
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
