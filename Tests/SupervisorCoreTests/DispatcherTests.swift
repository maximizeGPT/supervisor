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
        proposal: String = "Pick up Issue #7: fix the per-path triage isolation gap and add 6 integration tests for it. Stop at 21:59 UTC per §12.",
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
        // Core dispatch paths
        XCTAssertTrue(prompt.contains("continue_branch"),
                      "must define PATH 1")
        XCTAssertTrue(prompt.contains("transition_to_issue"),
                      "must define PATH 2")
        XCTAssertTrue(prompt.contains("low_confidence_no_action"),
                      "must define the low-confidence path")
        // Voice / shape constraints (v0.8.1: operator voice rewrite)
        XCTAssertTrue(prompt.contains("first-principles operator"),
                      "must teach the operator voice")
        XCTAssertTrue(prompt.contains("75 min"),
                      "must reference the hard stop in the proposal-shape rule")
        XCTAssertTrue(prompt.contains("record_dispatch"),
                      "must reference the forced tool call")
        XCTAssertTrue(prompt.contains("DO NOT cite specific function names"),
                      "must forbid ungrounded implementation claims")
        XCTAssertTrue(prompt.contains("prior_dispatches_considered"),
                      "must teach the model to read the loop-state signal")
        XCTAssertTrue(prompt.contains("Low confidence is a feature, not a failure"),
                      "must include the framing that teaches confident low-confidence returns")
        // Direction + Known Gaps awareness
        XCTAssertTrue(prompt.contains("PRODUCT-DIRECTION"),
                      "must reference the project direction file")
        XCTAssertTrue(prompt.contains("Known Gaps"),
                      "must reference the known gaps record")
        XCTAssertTrue(prompt.contains("requires_human_presence"),
                      "must include the human-presence gate")
        // Worked examples
        XCTAssertTrue(prompt.contains("Example 1"),
                      "Example 1 must be present")
        XCTAssertTrue(prompt.contains("Example 2"),
                      "Example 2 must be present")
    }

    /// Verify the system prompt loaded from the .txt file, not the
    /// minimal inline fallback. The file-load mechanism matters because
    /// the .txt is the canonical source shared with the Python hook.
    func testSystemPromptLoadsFromFile() {
        let prompt = Dispatcher.systemPrompt
        // The inline fallback is ~100 chars. The real prompt is >5000.
        // If this fails, the file wasn't found at the expected path.
        XCTAssertTrue(prompt.count > 2000,
                      "system prompt should be the full file, not the ~100-char inline fallback (got \(prompt.count) chars)")
        // Cross-check: read the .txt directly and verify the opening matches.
        let txtPath = "/Users/main/supervisor/Tools/dispatch-loop-hook/dispatcher-system-prompt.txt"
        if let fileContent = try? String(contentsOfFile: txtPath, encoding: .utf8) {
            let fileHead = String(fileContent.prefix(200))
            let promptHead = String(prompt.prefix(200))
            XCTAssertEqual(fileHead, promptHead,
                           "system prompt head must match the .txt file head")
        }
        // If the file doesn't exist (CI, different machine), the length
        // check above is sufficient — the fallback is too short to pass.
    }

    /// Verify the user message includes the new context sections
    /// (direction, known gaps, source markers, diff stat).
    func testUserMessageIncludesEnrichedContext() {
        let ctx = SessionContext(
            sessionUUID: "sess-ctx",
            cwd: "/Users/test/supervisor",
            gitBranch: "autonomous-test",
            lastNTurns: [],
            openIssues: [],
            currentBranchCommits: [],
            productDirection: "Build a great product.",
            knownGaps: "## Half-wired\n- Feature X not wired",
            sourceMarkers: ["Sources/Foo.swift:42: // TODO: wire this"],
            recentFilesChanged: ["Sources/Foo.swift | 10 +++"]
        )
        let msg = Dispatcher.userMessage(context: ctx, principles: "(stub)")
        XCTAssertTrue(msg.contains("PRODUCT-DIRECTION.md"),
                      "user message must include direction section")
        XCTAssertTrue(msg.contains("Build a great product"),
                      "user message must include direction content")
        XCTAssertTrue(msg.contains("Known Gaps"),
                      "user message must include known gaps section")
        XCTAssertTrue(msg.contains("Feature X not wired"),
                      "user message must include known gaps content")
        XCTAssertTrue(msg.contains("Source markers"),
                      "user message must include source markers section")
        XCTAssertTrue(msg.contains("TODO: wire this"),
                      "user message must include marker content")
        XCTAssertTrue(msg.contains("Recent files changed"),
                      "user message must include diff stat section")
        XCTAssertTrue(msg.contains("Sources/Foo.swift | 10"),
                      "user message must include diff stat content")
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
        XCTAssertTrue(prompt.contains("IS human-required") && prompt.contains("Is NOT human-required"),
                      "system prompt must enumerate both positive and negative examples for the gate")
        XCTAssertTrue(prompt.contains("Default: false"),
                      "system prompt must specify false as the default")
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

/// Root-cause guard: the dispatcher must reject proposals to build/wire
/// machinery that already exists (the self-referential runaway), but must
/// never block genuine product work.
final class DispatcherPremiseTests: XCTestCase {

    private func rejected(_ p: String, _ j: String = "advances the project") -> Bool {
        Dispatcher.premiseRejection(proposal: p, justification: j) != nil
    }

    func testRejectsBuildingExistingMachinery() {
        // The exact runaway and its kin.
        XCTAssertTrue(rejected("Build the CGEventPost-based Dispatcher + LoopController that watches the dispatch queue and types the next prompt."))
        XCTAssertTrue(rejected("Implement the dispatch loop that reads the queue and dispatches."))
        XCTAssertTrue(rejected("Wire up the LoopController hard-stops."))
        XCTAssertTrue(rejected("Build and ship the deterministic catch for irreversible commands."))
        XCTAssertTrue(rejected("Stand up the triage engine."))
        // False "it's not there" claims about existing components.
        XCTAssertTrue(rejected("The dispatch engine is not wired yet.", "the loop_dispatches table exists but the engine is not wired"))
        XCTAssertTrue(rejected("The Injector is missing."))
    }

    func testAllowsRealProductWork() {
        // Genuine product work that merely MENTIONS a component must pass.
        XCTAssertFalse(rejected("Fix the flag counter so it resets per work-window in HoverViewModel."))
        XCTAssertFalse(rejected("Add a unit test for the dispatcher's grounding so regressions are caught."))
        XCTAssertFalse(rejected("Close the Issue #12 calibration gap by correcting fixture expectations."))
        XCTAssertFalse(rejected("Improve the injector's reliability on Electron hosts."))
        XCTAssertFalse(rejected("Fix the dispatcher so it stops proposing already-done work."))
        XCTAssertFalse(rejected("Review the rubric corpus and journal the verdict."))
    }
}

/// Stale-loop guard: the dispatcher must degrade a proposal that repeats work
/// it already dispatched this run (the "calibrate Issue #12 three times"
/// failure), while never blocking genuinely new or sequential work.
final class DispatcherStalenessTests: XCTestCase {

    private func stale(_ p: String, _ recent: [String]) -> Bool {
        Dispatcher.stalenessRejection(proposal: p, against: recent) != nil
    }

    func testRejectsNearVerbatimRepeat() {
        let recent = ["Calibrate the Issue #12 positive-recall gap with a Haiku sweep"]
        // Exact repeat.
        XCTAssertTrue(stale("Calibrate the Issue #12 positive-recall gap with a Haiku sweep", recent))
        // Light rewording (tense/filler) — same task, still caught.
        XCTAssertTrue(stale("Re-calibrate the Issue 12 positive recall gap using a Haiku sweep now", recent))
    }

    func testAllowsGenuinelyNewWork() {
        let recent = ["Calibrate the Issue #12 positive-recall gap with a Haiku sweep"]
        XCTAssertFalse(stale("Fix the inject locator so it targets the right session of two", recent))
        XCTAssertFalse(stale("Add a unit test for the broadcast-kill catch", recent))
    }

    func testAllowsSequentialNumberedWork() {
        // Numbers carry identity, so consecutive sub-tasks differing only by an
        // index must NOT be treated as a repeat.
        let recent = ["Diagnose Issue #12 sub-bucket 1 fixtures and journal the verdict"]
        XCTAssertFalse(stale("Diagnose Issue #12 sub-bucket 2 fixtures and journal the verdict", recent))
    }

    func testEmptyHistoryAndShortProposalsAreNeverStale() {
        XCTAssertFalse(stale("Calibrate the Issue #12 positive-recall gap", []))
        XCTAssertFalse(stale("Fix it", ["Fix it"]))   // <4 significant tokens → not judged
    }

    func testUserMessageSurfacesRecentProposals() {
        let ctx = SessionContext(
            sessionUUID: "sess-stale",
            cwd: "/Users/test/supervisor",
            gitBranch: "autonomous-test",
            lastNTurns: [],
            openIssues: [],
            currentBranchCommits: [],
            priorDispatchesConsidered: 2,
            recentDispatchProposals: ["Calibrate the Issue #12 positive-recall gap"]
        )
        let msg = Dispatcher.userMessage(context: ctx, principles: "(stub)")
        XCTAssertTrue(msg.contains("ALREADY dispatched"),
                      "user message must surface the do-not-repeat section")
        XCTAssertTrue(msg.contains("Calibrate the Issue #12 positive-recall gap"),
                      "user message must list the recent proposal so Haiku can avoid it")
    }
}

/// Env-claim guard: the dispatcher must not justify work with a false
/// unblocking precondition ("the ANTHROPIC_API_KEY is set; sweeps are
/// unblocked" when the key is absent). The key is injected so the test is
/// deterministic regardless of CI env.
final class DispatcherEnvironmentClaimTests: XCTestCase {

    private func reject(_ p: String, _ j: String, key: String?) -> Bool {
        Dispatcher.environmentClaimRejection(proposal: p, justification: j, anthropicKey: key) != nil
    }

    func testFabricatedKeyClaimRejectedWhenAbsent() {
        XCTAssertTrue(reject("Run the Issue #12 calibration sweep",
                             "The ANTHROPIC_API_KEY is set; calibration sweeps are unblocked.",
                             key: nil))
        XCTAssertTrue(reject("Do the targeted re-sweep",
                             "Keys are set now and the sweeps are available.", key: ""))
        XCTAssertTrue(reject("Calibrate the gap", "The live-API is now enabled.", key: "   "))
    }

    func testHonestBlockedStatementPasses() {
        // The negated/honest inverse must NOT trip the guard.
        XCTAssertFalse(reject("Journal and wait",
                              "The ANTHROPIC_API_KEY is not set; sweeps are still blocked.", key: nil))
        XCTAssertFalse(reject("Skip the sweep",
                              "The key is absent, so calibration is blocked.", key: nil))
    }

    func testUnrelatedProposalPasses() {
        XCTAssertFalse(reject("Fix the inject locator for multi-session",
                              "It targets the wrong window when two sessions share the app.", key: nil))
    }

    func testTrueClaimPassesWhenKeyPresent() {
        XCTAssertFalse(reject("Run the sweep",
                              "The ANTHROPIC_API_KEY is set; sweeps are unblocked.",
                              key: "sk-ant-not-real"),
                       "a TRUE availability claim must pass when the key is present")
    }
}

/// The in-app dispatcher must READ the standing work record (Known Gaps) so it
/// proposes real backlog instead of fabricating a task. Tests the extractor.
final class DispatcherKnownGapsTests: XCTestCase {

    private func writeTrialNotes(_ body: String) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? body.write(to: dir.appendingPathComponent("trial-notes.md"), atomically: true, encoding: .utf8)
        return dir.path
    }

    func testReadsKnownGapsSectionAndStopsAtNextHeading() {
        let cwd = writeTrialNotes("""
        # Trial notes

        Some preamble that must NOT be included.

        # Known Gaps

        - Wire Known Gaps into the in-app dispatcher.
        ## A subsection that IS part of Known Gaps
        - Add a deploy-state grounding guard.

        # Some Later Section

        - This must NOT be included.
        """)
        let gaps = readKnownGaps(cwd: cwd)
        XCTAssertTrue(gaps.hasPrefix("# Known Gaps"))
        XCTAssertTrue(gaps.contains("Wire Known Gaps into the in-app dispatcher"))
        XCTAssertTrue(gaps.contains("## A subsection that IS part of Known Gaps"),
                      "## subsections stay inside Known Gaps")
        XCTAssertTrue(gaps.contains("deploy-state grounding guard"))
        XCTAssertFalse(gaps.contains("preamble"), "content before the marker is excluded")
        XCTAssertFalse(gaps.contains("This must NOT be included"), "stops at the next top-level heading")
    }

    func testNoFileOrNoSectionReturnsEmpty() {
        XCTAssertEqual(readKnownGaps(cwd: "/no/such/dir"), "")
        let cwd = writeTrialNotes("# Trial notes\n\nNo gaps section here.\n")
        XCTAssertEqual(readKnownGaps(cwd: cwd), "")
    }

    func testKnownGapsReachesTheDispatchPrompt() {
        let ctx = SessionContext(
            sessionUUID: "s", cwd: "/c", gitBranch: "b",
            lastNTurns: [], openIssues: [], currentBranchCommits: [],
            knownGaps: "# Known Gaps\n\n- Build the deploy-state guard.")
        let msg = Dispatcher.userMessage(context: ctx, principles: "(stub)")
        XCTAssertTrue(msg.contains("Build the deploy-state guard"),
                      "Known Gaps must be rendered into the dispatch prompt")
    }
}
