// DispatcherTests.swift
//
// v0.4.0 Part B — unit tests for the Dispatcher itself. Mirrors the
// URLProtocol mock pattern from TriageEngineTests / IdleDetectionTests
// so the Haiku call is observable; mock IssueFetching /
// BranchCommitFetching let us isolate the gh-failure path from the
// real subprocess.

import XCTest
@testable import SupervisorCore

@MainActor
final class DispatcherTests: XCTestCase {

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
        cfg.protocolClasses = [DispatcherMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeDispatcher(
        issueFetcher: (any IssueFetching)? = nil,
        commitFetcher: (any BranchCommitFetching)? = nil
    ) -> Dispatcher {
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("dispatcher-client-\(UUID().uuidString).log"))
        )
        return Dispatcher(
            client: client,
            principlesText: "PRINCIPLES.md (test stub).",
            issueFetcher: issueFetcher,
            commitFetcher: commitFetcher,
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("dispatcher-tests-\(UUID().uuidString).log"))
        )
    }

    /// Canned Haiku response — record_dispatch with the supplied fields.
    private static func haikuDispatchResponse(
        proposal: String = "Continue Part B's dispatcher. Wire the InterventionRouter's .continue handler and write 6 integration tests. Stop at 21:59 UTC per §12.",
        justification: String = "Mechanical follow-on from the dispatcher commit; tests are the obvious next unit per §6.",
        confidence: String = "high",
        selectedPath: String = "continue_branch",
        selectedIssueNumber: Int? = nil,
        requiresHumanPresence: Bool? = nil
    ) -> Data {
        var input: [String: Any] = [
            "next_task_proposal": proposal,
            "justification": justification,
            "confidence": confidence,
            "selected_path": selectedPath,
        ]
        if let n = selectedIssueNumber {
            input["selected_issue_number"] = n
        }
        if let h = requiresHumanPresence {
            input["requires_human_presence"] = h
        }
        let body: [String: Any] = [
            "id": "msg_disp",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_disp",
                "name": "record_dispatch",
                "input": input,
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 5500, "output_tokens": 480],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func haikuMalformedResponse() -> Data {
        // record_dispatch missing required fields — engine must surface
        // as .error rather than crashing.
        let body: [String: Any] = [
            "id": "msg_disp_bad",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_disp_bad",
                "name": "record_dispatch",
                "input": ["confidence": "high"] as [String: Any],
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 100, "output_tokens": 50],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func sampleContext() -> SessionContext {
        SessionContext(
            sessionUUID: "sess-test",
            cwd: "/Users/test/supervisor",
            gitBranch: "autonomous-20260525T193906Z",
            lastNTurns: [],
            openIssues: [
                DispatchIssue(number: 7, title: "Bash cross-category bleed",
                              body: "Per §2e per-path prompt isolation: bash triage matches user_question_pending on regex literals.",
                              labels: ["bug", "v0.4.0"])
            ],
            currentBranchCommits: [
                DispatchCommit(sha: "4370ad8", subject: "v0.4.0 Part A: idle-detection rubric + schema + timer", body: ""),
                DispatchCommit(sha: "900a66e", subject: "v0.4.0 Part A: IdleDetectionTests", body: ""),
            ]
        )
    }

    // MARK: - Tests

    /// Spec test #1's prerequisite: Dispatcher returns .ready with high
    /// confidence when Haiku reports it. Engine downstream maps to
    /// action=.continue + auto-dispatch.
    func testDispatcherReturnsReadyOnHighConfidence() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuDispatchResponse(confidence: "high"), [:])
        let dispatcher = makeDispatcher()

        let result = await dispatcher.dispatch(context: sampleContext())

        guard case let .ready(prompt, justification, confidence, path, _, _, _) = result else {
            return XCTFail("expected .ready, got \(result)")
        }
        XCTAssertFalse(prompt.isEmpty, "high-confidence dispatch must carry a prompt")
        XCTAssertFalse(justification.isEmpty, "high-confidence dispatch must carry a justification")
        XCTAssertEqual(confidence, .high)
        XCTAssertEqual(path, .continueBranch)
    }

    /// Spec test #2 prerequisite: low-confidence Haiku output normalizes
    /// to DispatchResult.lowConfidence (the prompt is unused; the
    /// justification surfaces as the banner reason).
    func testDispatcherNormalizesLowConfidenceToLowConfidenceResult() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuDispatchResponse(
            confidence: "low",
            selectedPath: "low_confidence_no_action"
        ), [:])
        let dispatcher = makeDispatcher()

        let result = await dispatcher.dispatch(context: sampleContext())

        guard case let .lowConfidence(reasoning) = result else {
            return XCTFail("expected .lowConfidence, got \(result)")
        }
        XCTAssertFalse(reasoning.isEmpty, "low-confidence path must carry a reason for the banner")
    }

    /// Spec test #4: gh fetcher throws → Dispatcher still runs against
    /// the Haiku endpoint with an empty issues array. The Dispatcher
    /// MUST work without gh per the spec ("degrade gracefully").
    func testDispatcherProceedsWithEmptyIssuesWhenFetcherThrows() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuDispatchResponse(confidence: "medium"), [:])
        let throwingIssues = ThrowingIssueFetcher()
        let throwingCommits = ThrowingCommitFetcher()
        let dispatcher = makeDispatcher(
            issueFetcher: throwingIssues,
            commitFetcher: throwingCommits
        )

        let result = await dispatcher.dispatchForIdleSession(
            sessionUUID: "sess-test",
            cwd: "/Users/test/supervisor",
            gitBranch: "autonomous-test",
            lastNTurns: []
        )

        // Dispatcher should NOT propagate the fetcher errors — the
        // Haiku call still ran with empty arrays, and the result is
        // whatever Haiku returned.
        switch result {
        case .ready, .lowConfidence:
            break  // either is acceptable — the contract is "no crash"
        case let .error(reasoning):
            XCTFail("expected .ready or .lowConfidence (Haiku still ran), got .error: \(reasoning)")
        }
    }

    /// Spec test #6: transition_to_issue path populates the issue
    /// number in the DispatchResult.
    func testDispatcherTransitionPathPopulatesIssueNumber() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuDispatchResponse(
            proposal: "Pick up Issue #7. Diff the bash triage prompt against the assistant-text prompt and fix the per-path-isolation gap per PRINCIPLES §2e.",
            justification: "Issue #7 has clear scope grounded in §2e; no values calls; small enough for one session.",
            confidence: "high",
            selectedPath: "transition_to_issue",
            selectedIssueNumber: 7
        ), [:])
        let dispatcher = makeDispatcher()

        let result = await dispatcher.dispatch(context: sampleContext())

        guard case let .ready(_, _, confidence, path, issueNumber, _, _) = result else {
            return XCTFail("expected .ready, got \(result)")
        }
        XCTAssertEqual(confidence, .high)
        XCTAssertEqual(path, .transitionToIssue)
        XCTAssertEqual(issueNumber, 7,
                       "transition_to_issue path must populate selected_issue_number on the result")
    }

    /// Defensive — malformed Haiku response (missing required fields)
    /// must surface as .error rather than crashing.
    func testDispatcherReturnsErrorOnMalformedResponse() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuMalformedResponse(), [:])
        let dispatcher = makeDispatcher()

        let result = await dispatcher.dispatch(context: sampleContext())

        guard case .error = result else {
            return XCTFail("expected .error on malformed response, got \(result)")
        }
    }

    /// The Dispatcher system prompt is the product per PRINCIPLES §2c
    /// — make sure key constraints stay in it. This is a snapshot-
    /// style test: if the prompt body drifts away from its dispatch
    /// contract, this catches it before it ships.
    func testSystemPromptCarriesCoreConstraints() {
        let prompt = Dispatcher.systemPrompt
        // Critical voice + content constraints surfaced in the B8
        // checkpoint:
        XCTAssertTrue(prompt.contains("File an issue, don't build the feature now"),
                      "must cite PRINCIPLES §1d (no inventing scope)")
        XCTAssertTrue(prompt.contains("continue_branch"),
                      "must define PATH 1")
        XCTAssertTrue(prompt.contains("transition_to_issue"),
                      "must define PATH 2")
        XCTAssertTrue(prompt.contains("low_confidence_no_action"),
                      "must define the low-confidence path")
        XCTAssertTrue(prompt.contains("autonomous opener"),
                      "must teach the voice for the next_task_proposal")
        XCTAssertTrue(prompt.contains("75 min"),
                      "must reference the §12 hard stop in the proposal-shape rule")
        XCTAssertTrue(prompt.contains("record_dispatch"),
                      "must reference the forced tool call")
        // Mohammed's B8 edits:
        XCTAssertTrue(prompt.contains("Cite specific file paths or function names"),
                      "must require file-paths-not-just-modules specificity in the proposal")
        XCTAssertTrue(prompt.contains("prior_dispatches_considered"),
                      "must teach Haiku to read the loop-state signal")
        XCTAssertTrue(prompt.contains("Low confidence is a feature, not a failure"),
                      "must include the framing that teaches confident low-confidence returns")
        XCTAssertTrue(prompt.contains("# Worked examples"),
                      "must carry the four worked examples Mohammed approved at B8")
        XCTAssertTrue(prompt.contains("Example 1 — PATH 1 (continue_branch), HIGH"),
                      "Example 1 (continue_branch, high) must be present")
        XCTAssertTrue(prompt.contains("Example 2 — PATH 2 (transition_to_issue), HIGH"),
                      "Example 2 (transition_to_issue, high) must be present")
        XCTAssertTrue(prompt.contains("Example 3 — PATH 1 (continue_branch), MEDIUM"),
                      "Example 3 (continue_branch, medium) must be present")
        XCTAssertTrue(prompt.contains("Example 4 — LOW confidence"),
                      "Example 4 (the low-confidence framing) must be present")
    }

    /// The user message must surface `prior_dispatches_considered` so
    /// Haiku can read it. The Loop state section is the Part C
    /// integration point.
    func testUserMessageSurfacesLoopState() {
        let ctx = SessionContext(
            sessionUUID: "sess-loop",
            cwd: "/Users/test/supervisor",
            gitBranch: "autonomous-test",
            lastNTurns: [],
            openIssues: [],
            currentBranchCommits: [],
            priorDispatchesConsidered: 4
        )
        let msg = Dispatcher.userMessage(context: ctx, principles: "(stub)")
        XCTAssertTrue(msg.contains("# Loop state"),
                      "user message must include a Loop state section")
        XCTAssertTrue(msg.contains("prior_dispatches_considered: 4"),
                      "user message must surface the count to Haiku")
    }

    /// The parser must read `prior_dispatches_considered` back from
    /// the record_dispatch output and surface it on .ready, so the
    /// trace log can confirm Haiku saw the loop-state signal.
    func testParserEchoesPriorDispatchesCount() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuDispatchResponse(
            confidence: "high",
            selectedPath: "continue_branch"
        ).replacingPriorDispatchesEcho(with: 4), [:])
        let dispatcher = makeDispatcher()

        let result = await dispatcher.dispatch(context: sampleContext())

        guard case let .ready(_, _, _, _, _, priorEchoed, _) = result else {
            return XCTFail("expected .ready, got \(result)")
        }
        XCTAssertEqual(priorEchoed, 4,
                       "Haiku's prior_dispatches_considered echo must surface on the .ready result")
    }

    /// v0.4.1: requires_human_presence=true must surface on the .ready
    /// result so the engine/router can gate auto-dispatch.
    func testParserReadsRequiresHumanPresenceTrue() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuDispatchResponse(
            confidence: "high",
            selectedPath: "continue_branch",
            requiresHumanPresence: true
        ), [:])
        let dispatcher = makeDispatcher()

        let result = await dispatcher.dispatch(context: sampleContext())

        guard case let .ready(_, _, _, _, _, _, requiresHuman) = result else {
            return XCTFail("expected .ready, got \(result)")
        }
        XCTAssertTrue(requiresHuman,
                      "requires_human_presence=true must surface on the .ready result")
    }

    /// v0.4.1: when requires_human_presence is absent (pre-v0.4.1
    /// dispatchers), it defaults to false.
    func testParserDefaultsRequiresHumanPresenceToFalse() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuDispatchResponse(
            confidence: "high",
            selectedPath: "continue_branch"
        ), [:])
        let dispatcher = makeDispatcher()

        let result = await dispatcher.dispatch(context: sampleContext())

        guard case let .ready(_, _, _, _, _, _, requiresHuman) = result else {
            return XCTFail("expected .ready, got \(result)")
        }
        XCTAssertFalse(requiresHuman,
                       "absent requires_human_presence must default to false")
    }

    /// v0.4.1: system prompt must teach the requires_human_presence gate.
    func testSystemPromptTeachesRequiresHumanPresenceGate() {
        let prompt = Dispatcher.systemPrompt
        XCTAssertTrue(prompt.contains("requires_human_presence"),
                      "system prompt must teach the gate")
        XCTAssertTrue(prompt.contains("launching macOS apps") || prompt.contains("Accessibility permissions"),
                      "system prompt must explain WHAT triggers the gate")
    }
}

/// Helper to splice prior_dispatches_considered into a canned response
/// body without rebuilding the whole JSON. Hacky-but-targeted: rewrites
/// the tool_use input dict to add the field.
private extension Data {
    func replacingPriorDispatchesEcho(with value: Int) -> Data {
        var obj = try! JSONSerialization.jsonObject(with: self) as! [String: Any]
        var content = (obj["content"] as! [[String: Any]])
        var block = content[0]
        var input = block["input"] as! [String: Any]
        input["prior_dispatches_considered"] = value
        block["input"] = input
        content[0] = block
        obj["content"] = content
        return try! JSONSerialization.data(withJSONObject: obj)
    }
}

// MARK: - Mock fetchers

private struct ThrowingIssueFetcher: IssueFetching {
    func fetchOpenIssues(cwd: String) async throws -> [DispatchIssue] {
        throw FetcherError.toolNotInstalled("gh")
    }
}

private struct ThrowingCommitFetcher: BranchCommitFetching {
    func fetchBranchCommits(cwd: String, branch: String, baseBranch: String) async throws -> [DispatchCommit] {
        throw FetcherError.toolNotInstalled("git")
    }
}

// MARK: - URLProtocol mock

private final class DispatcherMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = DispatcherTests.canned[path] else {
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
