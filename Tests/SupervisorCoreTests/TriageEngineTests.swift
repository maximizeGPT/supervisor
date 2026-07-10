// TriageEngineTests.swift
//
// End-to-end test of the triage layer with a mocked Anthropic. Drives
// EventBus, asserts the engine called the API, decoded the record_triage
// response, and emitted the right TriageDecision (or no decision on
// all-clear).

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class TriageEngineTests: XCTestCase {

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]

    override func setUp() {
        super.setUp()
        Self.canned.removeAll()
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TriageMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeEngine() -> (TriageEngine, EventBus, CapturedDecisions) {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-tests-\(UUID().uuidString).log")))
        let client = LLMClient(provider: .anthropic, 
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("triage-client-\(UUID().uuidString).log"))
        )
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            supervisorPausedRead: { false },  // hermetic: ignore the REAL pause marker
            // Honest-health: this harness runs the REAL 1s background idle loop
            // (default interval + start()). A no-op recorder keeps that loop's
            // behavior identical while guaranteeing the test run never stamps the
            // real global engine-progress.txt liveness token (which would flip a
            // production status bar to lying GREEN over a hung engine).
            recordEngineProgress: {}
        )
        let captured = CapturedDecisions()
        engine.onDecision = { d in captured.append(d) }
        engine.start()
        return (engine, bus, captured)
    }

    private func publishBashCall(
        _ bus: EventBus,
        command: String,
        sessionId: String = "s1",
        toolUseId: String = "t1"
    ) {
        bus.publish(.sessionStart(.init(
            sessionId: sessionId, cwd: "/Users/test", gitBranch: "main",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: Date()
        )))
        bus.publish(.userPrompt(.init(
            sessionId: sessionId, text: "clean up", ts: Date()
        )))
        bus.publish(.bashToolCall(.init(
            sessionId: sessionId, command: command, description: nil,
            toolUseId: toolUseId, turnUUID: "u1", ts: Date()
        )))
    }

    // Fix C (2026-06-15): Supervisor's OWN injected user turns must NOT count as
    // the operator taking the wheel. If they did, the loop would clear its own
    // 3-strikes stop and refresh its presence backoff on every injection — the
    // loop out-voting its own kill switch (the thrash that drove this session).
    // The engine correlates each userPrompt against the InjectionLedger before
    // pausing the loop; a self-injected turn is ignored, a real operator turn
    // pauses + stamps presence.
    func testSelfInjectedUserPromptDoesNotPauseLoopButRealOneDoes() async throws {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("fixc-\(UUID().uuidString).log")))
        let client = LLMClient(provider: .anthropic, apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("fixc-client-\(UUID().uuidString).log")))
        let ledger = InjectionLedger()
        let lc = LoopController(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("fixc-loop-\(UUID().uuidString).log")))
        let engine = TriageEngine(
            client: client, bus: bus, model: "claude-haiku-4-5-20251001",
            windowSize: 30, costStore: nil,
            loopController: lc,
            supervisorPausedRead: { false },  // hermetic: ignore the REAL pause marker
            idleCheckIntervalSeconds: 3600,   // park the idle timer; we test only the userPrompt path
            injectionLedger: ledger,
            recordEngineProgress: {}          // honest-health: never stamp the real liveness token
        )
        engine.start()

        let session = "fixc-session"

        // A Supervisor injection: record it (as the router does), then replay it
        // as the user turn it lands as. The engine must recognize it as its own.
        let injected = SupervisorInjectionMarker.wrap("Pick up Issue #7 and keep going. 75 min cap.")
        let t = Date()
        ledger.record(sessionId: session, text: injected, at: t)
        bus.publish(.userPrompt(.init(sessionId: session, text: injected, ts: t.addingTimeInterval(1))))
        try await Task.sleep(nanoseconds: 500_000_000)
        let afterInjected = await lc.snapshot(sessionId: session)
        XCTAssertNotEqual(afterInjected?.paused, true,
            "a Supervisor-injected turn must NOT pause the loop — it is not the operator")
        XCTAssertNil(afterInjected?.lastOwnerMessageAt,
            "a Supervisor-injected turn must NOT stamp operator presence")

        // A genuine operator turn (not in the ledger) MUST pause + stamp presence.
        bus.publish(.userPrompt(.init(sessionId: session, text: "hey, do X instead please", ts: Date())))
        try await Task.sleep(nanoseconds: 500_000_000)
        let afterReal = await lc.snapshot(sessionId: session)
        XCTAssertEqual(afterReal?.paused, true,
            "a real operator message must pause the loop")
        XCTAssertNotNil(afterReal?.lastOwnerMessageAt,
            "a real operator message must stamp operator presence (drives the backoff)")
    }

    // Conflict-fix (2026-07-03): consume() gates the loop-STATE mutations on event
    // age. A months-old replayed event (a `claude --resume` / post-compact copy)
    // must NOT un-stick a stopped loop (stale userPrompt -> notePause) or clear a
    // live pause (stale bashToolCall -> clearPause). Fresh events still mutate.
    func testStaleReplayedEventsDoNotMutateLoopState() async throws {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-\(UUID().uuidString).log")))
        let client = LLMClient(provider: .anthropic, apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("stale-client-\(UUID().uuidString).log")))
        let lc = LoopController(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-loop-\(UUID().uuidString).log")))
        let engine = TriageEngine(
            client: client, bus: bus, model: "claude-haiku-4-5-20251001",
            windowSize: 30, costStore: nil,
            loopController: lc,
            supervisorPausedRead: { false },  // hermetic: ignore the REAL pause marker
            idleCheckIntervalSeconds: 3600,   // park the idle timer
            injectionLedger: InjectionLedger(),
            recordEngineProgress: {})         // honest-health: never stamp the real liveness token
        engine.start()
        defer { engine.stop() }

        let session = "stale-session"
        let stale = Date().addingTimeInterval(-3600)  // 1h old > 120s threshold
        let fresh = Date()

        // 1. Loop hard-stopped on three-consecutive-low.
        await lc.stop(sessionId: session, reason: .threeConsecutiveLow)

        // 2. A STALE replayed operator prompt must NOT clear that stop.
        bus.publish(.userPrompt(.init(sessionId: session, text: "old direction", ts: stale)))
        try await Task.sleep(nanoseconds: 300_000_000)
        var snap = await lc.snapshot(sessionId: session)
        XCTAssertEqual(snap?.stopped, true, "a stale userPrompt must NOT clear a hard stop")
        XCTAssertEqual(snap?.stopReason, .threeConsecutiveLow)

        // 3. A FRESH operator prompt DOES clear the three-low stop and pauses.
        bus.publish(.userPrompt(.init(sessionId: session, text: "new direction", ts: fresh)))
        try await Task.sleep(nanoseconds: 300_000_000)
        snap = await lc.snapshot(sessionId: session)
        XCTAssertNotEqual(snap?.stopped, true, "a fresh userPrompt clears the three-low stop")
        XCTAssertEqual(snap?.paused, true, "a fresh operator prompt pauses the loop")

        // 4. A STALE bashToolCall must NOT clear the live pause.
        bus.publish(.bashToolCall(.init(sessionId: session, command: "echo hi", description: nil,
                                        toolUseId: "stale-tc", turnUUID: "u", ts: stale)))
        try await Task.sleep(nanoseconds: 300_000_000)
        snap = await lc.snapshot(sessionId: session)
        XCTAssertEqual(snap?.paused, true, "a stale bashToolCall must NOT clear a live pause")

        // 5. A FRESH bashToolCall clears the pause (the worker resumed now).
        bus.publish(.bashToolCall(.init(sessionId: session, command: "echo hi2", description: nil,
                                        toolUseId: "fresh-tc", turnUUID: "u", ts: Date())))
        try await Task.sleep(nanoseconds: 300_000_000)
        snap = await lc.snapshot(sessionId: session)
        XCTAssertNotEqual(snap?.paused, true, "a fresh bashToolCall clears the pause")
    }

    // Helper: a record_triage response that returns one flag.
    private static func haikuFlagResponse(
        severity: String = "high",
        action: String = "pause",
        reasoningPlain: String = "Claude Code is about to strip every permission off /Users/main/important and everything in it with chmod -R 000. That's not a temp path, so I'm pausing the session — you can resume from the panel if it was deliberate.",
        reasoningTechnical: String = "chmod -R 000 /Users/main/important matches the destructive_action_pending rubric clause for 'a recursive permission-strip against a path outside the session cwd /Users/test'. Severity high because the path is outside the documented temp-path allowlist; user prompt did not authorize it.",
        asymmetryNote: String? = "If I pause and I'm wrong, you lose ~5s; if I don't pause and I'm wrong, /Users/main/important is left unreadable until you chmod it back.",
        includeAllFields: Bool = true
    ) -> Data {
        var candidate: [String: Any] = [
            "category": "destructive_action_pending",
            "severity": severity,
            "matched_command": "chmod -R 000 /Users/main/important"
        ]
        if includeAllFields {
            candidate["recommended_action"] = action
            candidate["reasoning_plain"] = reasoningPlain
            candidate["reasoning_technical"] = reasoningTechnical
            if let n = asymmetryNote { candidate["asymmetry_note"] = n }
        }
        let body: [String: Any] = [
            "id": "msg_01",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_resp",
                "name": "record_triage",
                "input": [
                    "candidates": [candidate]
                ]
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 500, "output_tokens": 80]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // Helper: empty candidates (Haiku says all-clear).
    private static func haikuAllClearResponse() -> Data {
        let body: [String: Any] = [
            "id": "msg_02",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_resp",
                "name": "record_triage",
                "input": ["candidates": [] as [Any]]
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 480, "output_tokens": 10]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Tests

    func testBashCallProducesFlagWhenHaikuFires() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        // chmod -R 000 is destructive (recursively unreadable) but NOT on the
        // deterministic catch-list, so it exercises the mocked Haiku path
        // instead of short-circuiting on the catch. (rm -rf would fire the
        // catch before the model ever runs — see DeterministicCatch.)
        publishBashCall(bus, command: "chmod -R 000 /Users/main/important")

        try await captured.waitFor(count: 1, within: 3.0)
        XCTAssertEqual(captured.snapshot.count, 1)
        let candidate = try XCTUnwrap(captured.snapshot.first?.candidate)
        XCTAssertEqual(candidate.severity, .high)
        XCTAssertEqual(candidate.category, "destructive_action_pending")
        XCTAssertTrue(candidate.matchedCommand.contains("chmod"))
        XCTAssertEqual(candidate.action, .pause)
        XCTAssertTrue(candidate.reasoningPlain.contains("permission"),
                      "reasoningPlain should describe the action in plain English; got: \(candidate.reasoningPlain)")
        XCTAssertTrue(candidate.reasoningTechnical.contains("rubric"),
                      "reasoningTechnical should cite the rubric; got: \(candidate.reasoningTechnical)")
        XCTAssertNotNil(candidate.asymmetryNote, "asymmetry note should be passed through when present")
    }

    func testMalformedVerdictFallsBackToFixedBannerString() async throws {
        // Haiku response missing reasoning_plain and reasoning_technical
        // and recommended_action — i.e., a degraded verdict shape that
        // still has category + severity + matched_command. The engine
        // must still fire the flag, with a fixed fallback banner string
        // and recommendedAction = .notify.
        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(includeAllFields: false), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        // chmod -R 000: destructive but not on the catch-list, so the degraded
        // Haiku verdict (no reasoning/action) drives the fallback under test.
        publishBashCall(bus, command: "chmod -R 000 /Users/main/x")

        try await captured.waitFor(count: 1, within: 3.0)
        let candidate = try XCTUnwrap(captured.snapshot.first?.candidate)
        XCTAssertEqual(candidate.action, .notify,
                       "missing recommended_action should fall back to notify, not pause/kill")
        XCTAssertEqual(candidate.reasoningPlain, TriagePrompt.malformedVerdictBannerText,
                       "missing reasoning_plain should fall back to the fixed banner text, NOT to reasoning_technical")
        XCTAssertEqual(candidate.reasoningTechnical, "",
                       "missing reasoning_technical should leave an empty string, not a synthesized value")
        XCTAssertNil(candidate.asymmetryNote)
    }

    func testReasoningRunsThroughRedactor() async throws {
        // If Haiku ever invents a secret-shaped string in its reasoning,
        // the redactor pass on the inbound text catches it before it
        // lands on the banner or the database. This mirrors the
        // outbound redaction the AnthropicClient already enforces — same
        // protection, opposite direction.
        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(
            reasoningPlain: "Claude Code is about to commit sk-ant-api03-LEAKED_KEY_LOOKING_VALUE to the repo, which would expose your Anthropic key.",
            reasoningTechnical: "Bash command head matches 'git commit'; tool_use input shows .env in scope. The literal key sk-ant-api03-LEAKED_KEY_LOOKING_VALUE was in the staged diff."
        ), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        publishBashCall(bus, command: "git commit -am 'add .env'")

        try await captured.waitFor(count: 1, within: 3.0)
        let candidate = try XCTUnwrap(captured.snapshot.first?.candidate)
        XCTAssertFalse(candidate.reasoningPlain.contains("sk-ant-api03-LEAKED_KEY_LOOKING_VALUE"),
                       "reasoning_plain leaked a secret-shaped string through the redactor: \(candidate.reasoningPlain)")
        XCTAssertFalse(candidate.reasoningTechnical.contains("sk-ant-api03-LEAKED_KEY_LOOKING_VALUE"),
                       "reasoning_technical leaked a secret-shaped string through the redactor: \(candidate.reasoningTechnical)")
    }

    func testAllClearProducesNoFlag() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuAllClearResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        publishBashCall(bus, command: "rm -rf /tmp/foo")  // tmp is fine — Haiku says no

        // Wait a bit to make sure the call completes.
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(captured.snapshot.count, 0, "tmp paths should not flag — got: \(captured.snapshot)")
    }

    func testHaikuNetworkFailureDoesNotCrash() async throws {
        // No canned response → URLProtocol returns a network error.
        Self.canned.removeAll()
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        // chmod -R 000: destructive but not on the catch-list, so this reaches
        // the (now failing) Haiku call instead of short-circuiting on the catch.
        publishBashCall(bus, command: "chmod -R 000 /Users/main/x")

        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(captured.snapshot.count, 0)
        // No assertions on engine state — main contract: no crash.
    }

    func testTriageDecisionIncludesPrePostState() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        // Bash call WITHOUT a matching result → preExecution mode.
        publishBashCall(bus, command: "rm -rf /Users/main/x")
        try await captured.waitFor(count: 1, within: 3.0)
        XCTAssertEqual(captured.snapshot.first?.prePost, .preExecution)
    }

    // MARK: - v0.3.1 Issue #6: per-session cwd cache

    /// Helper: a record_triage response that fires user_question_pending
    /// with question_type=engineering + action=inject. Used to drive the
    /// cwd-resolution path through the engine's downgrade logic.
    private static func haikuQuestionFlagResponse(action: String = "inject") -> Data {
        let candidate: [String: Any] = [
            "category": "user_question_pending",
            "severity": "medium",
            "matched_command": "Should I use sysctl or lsof?",
            "recommended_action": action,
            "reasoning_plain": "Claude Code asked the user a question about PID discovery.",
            "reasoning_technical": "user_question_pending fired on assistant text containing a choice between two engineering approaches.",
            "question_type": "engineering",
        ]
        let body: [String: Any] = [
            "id": "msg_question",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_question",
                "name": "record_triage",
                "input": ["candidates": [candidate]]
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 500, "output_tokens": 80]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// Cache-HIT path: sessionStart was observed, the window has rolled
    /// past it (many events), then assistantText fires a question.
    /// Engine should resolve cwd from `sessionCwd` and emit a decision
    /// with cwd populated + action=.inject.
    func testAssistantTextResolvesCwdFromSessionCacheAfterWindowRoll() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuQuestionFlagResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        let sessionId = "s-cache-hit"
        let knownCwd = "/Users/main/test-project"

        // 1. Publish sessionStart — engine caches cwd.
        bus.publish(.sessionStart(.init(
            sessionId: sessionId, cwd: knownCwd, gitBranch: "main",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: Date()
        )))

        // 2. Fill the window past 30 events so sessionStart rolls off.
        //    Using bashToolResult events (non-triage-triggering) to
        //    pad without driving primary triage calls.
        for i in 0..<35 {
            bus.publish(.bashToolResult(.init(
                sessionId: sessionId, toolUseId: "fill-\(i)",
                output: "pad event \(i)", isError: false, ts: Date()
            )))
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        // 3. Fire the assistantText event. Prefilter passes ("?")
        bus.publish(.assistantText(.init(
            sessionId: sessionId,
            text: "Should I use sysctl or lsof for the PID lookup?",
            turnUUID: "u-q1",
            ts: Date()
        )))

        try await captured.waitFor(count: 1, within: 5.0)
        let decision = captured.snapshot.first!
        XCTAssertEqual(decision.candidate.category, "user_question_pending")
        XCTAssertEqual(decision.cwd, knownCwd,
                       "cache hit must populate decision.cwd from sessionCwd[sessionId] even though the window has rolled past sessionStart")
        // Without a QuestionAnswerer wired in, the action stays whatever
        // Haiku returned. We requested .inject in the canned response.
        XCTAssertEqual(decision.candidate.action, .inject,
                       "cwd resolved → action remains .inject (no engine downgrade)")
    }

    /// Cache-MISS path: sessionStart was NEVER observed for this
    /// session. assistantText fires. Engine emits the new
    /// `assistant_text.no_cwd_session_start_not_seen` trace tag AND
    /// downgrades the .inject candidate to .notify so the router
    /// never emits the misleading `no_cwd_on_decision` reason.
    func testAssistantTextDowngradesToNotifyWhenCwdUnresolvable() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuQuestionFlagResponse(), [:])
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-cache-miss-\(UUID().uuidString).log")
        let trace = TraceLog(path: traceURL)
        let bus = EventBus(trace: trace)
        let client = LLMClient(provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: trace
        )
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            supervisorPausedRead: { false },  // hermetic: ignore the REAL pause marker
            // Honest-health: default 1s background loop runs here — no-op the
            // engine-progress recorder so the test never touches the real token.
            recordEngineProgress: {},
            trace: trace
        )
        let captured = CapturedDecisions()
        engine.onDecision = { d in captured.append(d) }
        engine.start()
        defer { engine.stop() }

        let sessionId = "s-no-session-start"

        // NO sessionStart published. assistantText fires cold.
        bus.publish(.assistantText(.init(
            sessionId: sessionId,
            text: "Should I use sysctl or lsof for the PID lookup?",
            turnUUID: "u-q1",
            ts: Date()
        )))

        try await captured.waitFor(count: 1, within: 5.0)
        let decision = captured.snapshot.first!
        XCTAssertNil(decision.cwd, "no source for cwd → decision.cwd is nil")
        // The engine's downgrade kicks in.
        XCTAssertEqual(decision.candidate.action, .notify,
                       "cwd unresolvable + Haiku said .inject → engine downgrades to .notify")

        // Trace assertions: new tag fires; old router degraded-inject
        // tag does NOT fire (because the action was downgraded before
        // the router saw it).
        let traceText = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(traceText.contains("assistant_text.no_cwd_session_start_not_seen"),
                      "engine must emit the discriminating cache-miss trace tag")
        XCTAssertTrue(traceText.contains("downgrade .inject → .notify"),
                      "engine must trace the downgrade decision")
        // The router-level no_cwd_on_decision tag fires for inject-action
        // decisions with no cwd. By downgrading BEFORE the router sees
        // the decision, the router never emits that tag — the cause is
        // already discriminated at the engine level.
        XCTAssertFalse(traceText.contains("intervention.inject.degraded reason=no_cwd_on_decision"),
                       "router degradation tag must NOT fire — engine handled the case upstream")
    }

    func testWindowsRetainContextForFollowupQueries() async throws {
        // First call: all-clear. Second call: flag. The window should still
        // include the first call's events when evaluating the second, so
        // the prompt has continuity.
        Self.canned["/v1/messages"] = (200, Self.haikuAllClearResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        publishBashCall(bus, command: "ls /tmp", toolUseId: "t-ls")
        try await Task.sleep(nanoseconds: 500_000_000)

        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(), [:])
        publishBashCall(bus, command: "rm -rf /Users/main/important", toolUseId: "t-rm")
        try await captured.waitFor(count: 1, within: 3.0)
        XCTAssertEqual(captured.snapshot.count, 1)
        XCTAssertEqual(captured.snapshot.first?.triggeringEvent.toolUseId, "t-rm")
    }

    // MARK: - Capture helper

    // MARK: - Deterministic-catch restart-replay dedupe (launch-audit fix)

    /// A SessionTail resumes from the last PERSISTED offset, so an engine
    /// restart replays the trailing transcript events. The deterministic catch
    /// used to re-fire on the replayed tool_use and post a second identical
    /// destructive-action banner. With the sqlite dedupe ledger: the first
    /// engine fires + notifies; a second engine (the restart) sees the SAME
    /// toolUseId and stays silent; a genuinely NEW destructive event on the
    /// second engine still fires.
    func testDeterministicCatchDoesNotReNotifyReplayedEventAfterRestart() async throws {
        let tmpDb = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-catch-dedupe-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpDb) }
        let db = try SupervisorDatabase(path: tmpDb)
        let auditStore = AuditStore(database: db)

        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-catch-dedupe-\(UUID().uuidString).log"))
        let bus = EventBus(trace: trace)

        func makeEngineWithLedger() -> (TriageEngine, CapturedDecisions) {
            let client = LLMClient(provider: .anthropic,
                apiKey: "sk-ant-test",
                redactor: DefaultRedactor(),
                baseURL: URL(string: "https://mock.anthropic.test")!,
                session: mockSession(),
                traceLog: trace
            )
            let engine = TriageEngine(
                client: client, bus: bus, model: "claude-haiku-4-5-20251001",
                windowSize: 30, costStore: nil,
                auditStore: auditStore,
                supervisorPausedRead: { false },  // hermetic: ignore the REAL pause marker
                idleCheckIntervalSeconds: 3600,   // park the idle timer
                recordEngineProgress: {},         // never stamp the real liveness token
                trace: trace
            )
            let captured = CapturedDecisions()
            engine.onDecision = { d in captured.append(d) }
            return (engine, captured)
        }

        // Engine 1 (pre-restart): the catch fires and notifies once. No canned
        // HTTP response exists — the catch must short-circuit the model.
        let (engine1, captured1) = makeEngineWithLedger()
        engine1.start()
        publishBashCall(bus, command: "git reset --hard", sessionId: "s-replay", toolUseId: "toolu-replayed")
        try await captured1.waitFor(count: 1, within: 4.0)
        XCTAssertEqual(captured1.snapshot.first?.candidate.category, "destructive_action_pending")
        engine1.stop()

        // Engine 2 (the restart): the tail re-delivers the SAME event from the
        // persisted offset. It must NOT produce a second decision.
        let (engine2, captured2) = makeEngineWithLedger()
        engine2.start()
        publishBashCall(bus, command: "git reset --hard", sessionId: "s-replay", toolUseId: "toolu-replayed")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(captured2.snapshot.count, 0,
                       "a replayed catch (same toolUseId) must not re-notify after a restart")

        // A NEVER-seen destructive event must still fire on the restarted
        // engine — dedupe is keyed on identity, not age or command text.
        publishBashCall(bus, command: "git reset --hard", sessionId: "s-replay", toolUseId: "toolu-genuinely-new")
        try await captured2.waitFor(count: 1, within: 4.0)
        XCTAssertEqual(captured2.snapshot.first?.candidate.category, "destructive_action_pending")
        engine2.stop()
    }

    final class CapturedDecisions: @unchecked Sendable {
        private let lock = NSLock()
        private var inner: [TriageDecision] = []
        func append(_ d: TriageDecision) {
            lock.lock(); defer { lock.unlock() }
            inner.append(d)
        }
        var snapshot: [TriageDecision] {
            lock.lock(); defer { lock.unlock() }
            return inner
        }
        func waitFor(count target: Int, within seconds: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if snapshot.count >= target { return }
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            XCTFail("timed out waiting for \(target) decisions; got \(snapshot.count)")
        }
    }
}

// MARK: - URLProtocol mock

private final class TriageMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = TriageEngineTests.canned[path] else {
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

// MARK: - detectWorkerStopped unit tests

@MainActor
final class DetectWorkerStoppedTests: XCTestCase {

    private let now = Date()

    func testGatePassesWhenAssistantEndsWithTextOnly() {
        let events: [SupervisorEvent] = [
            .userPrompt(.init(sessionId: "s1", text: "do the thing", ts: now)),
            .assistantText(.init(sessionId: "s1", text: "All tests pass. Pushed.", turnUUID: "u1", ts: now)),
        ]
        XCTAssertTrue(TriageEngine.detectWorkerStopped(in: events))
    }

    func testGateBlocksWhenAssistantEndsWithToolUse() {
        let events: [SupervisorEvent] = [
            .userPrompt(.init(sessionId: "s1", text: "do the thing", ts: now)),
            .assistantText(.init(sessionId: "s1", text: "Running tests now.", turnUUID: "u1", ts: now)),
            .bashToolCall(.init(sessionId: "s1", command: "swift test", description: nil, toolUseId: "t1", turnUUID: "u1", ts: now)),
        ]
        XCTAssertFalse(TriageEngine.detectWorkerStopped(in: events))
    }

    func testGateBlocksWhenLastBlockIsToolUseAfterText() {
        let events: [SupervisorEvent] = [
            .assistantText(.init(sessionId: "s1", text: "Let me check.", turnUUID: "u1", ts: now)),
            .assistantText(.init(sessionId: "s1", text: "Looking at the file.", turnUUID: "u2", ts: now)),
            .bashToolCall(.init(sessionId: "s1", command: "cat /tmp/x", description: nil, toolUseId: "t2", turnUUID: "u2", ts: now)),
        ]
        XCTAssertFalse(TriageEngine.detectWorkerStopped(in: events))
    }

    func testGateHandlesEmptyWindowGracefully() {
        XCTAssertFalse(TriageEngine.detectWorkerStopped(in: []))
    }

    func testGateHandlesNoAssistantMessagesGracefully() {
        let events: [SupervisorEvent] = [
            .userPrompt(.init(sessionId: "s1", text: "hello", ts: now)),
        ]
        XCTAssertFalse(TriageEngine.detectWorkerStopped(in: events))
    }
}

/// cwd-exclusivity gate (2026-06-13): repo grounding (git branch/commits) may be
/// attributed to a session ONLY when it is the sole live worker in that cwd —
/// otherwise a co-located session's git state bleeds into this session's
/// answer/dispatch (the tweet-engine bleed). These lock the pure decision.
final class CwdExclusivityGateTests: XCTestCase {
    func testSoleLiveSessionKeepsCwdForGrounding() {
        XCTAssertEqual(
            TriageEngine.groundingCwd("/Users/main/supervisor", liveSessionsInCwd: 1),
            "/Users/main/supervisor",
            "a solo session is the rightful owner of its cwd's git state"
        )
    }

    func testSharedCwdOmitsGrounding() {
        XCTAssertNil(
            TriageEngine.groundingCwd("/Users/main/supervisor", liveSessionsInCwd: 2),
            "with >1 live session in the cwd, repo grounding MUST be omitted (no cross-session bleed)"
        )
        XCTAssertNil(TriageEngine.groundingCwd("/Users/main/supervisor", liveSessionsInCwd: 5))
    }

    func testNilOrEmptyCwdPassesThroughUnchanged() {
        // Nothing to gate — a missing cwd already means no repo grounding.
        XCTAssertNil(TriageEngine.groundingCwd(nil, liveSessionsInCwd: 1))
        XCTAssertEqual(TriageEngine.groundingCwd("", liveSessionsInCwd: 3), "")
    }

    func testZeroCountTreatedAsSole_noFalseOmit() {
        // Defensive: a 0 reading (store empty/race) must not over-gate a real
        // solo session into losing its grounding. <=1 keeps the cwd.
        XCTAssertEqual(
            TriageEngine.groundingCwd("/Users/main/supervisor", liveSessionsInCwd: 0),
            "/Users/main/supervisor"
        )
    }

}
