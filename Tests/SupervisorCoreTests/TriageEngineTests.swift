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
    // Counts every request the mock sees, so the stale-event test can
    // assert "no network at all", not just "no flag" (mirrors
    // IdleDetectionTests.requestCount).
    nonisolated(unsafe) static var requestCount: Int = 0

    override func setUp() {
        super.setUp()
        Self.canned.removeAll()
        Self.requestCount = 0
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
            costStore: nil
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
            idleCheckIntervalSeconds: 3600,   // park the idle timer; we test only the userPrompt path
            injectionLedger: ledger
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

    // MARK: - Event-age gate (backfill layer 2, 2026-07-02)

    /// A Bash tool_use stamped 10 minutes in the past is replayed history
    /// (`claude --resume` / post-compact JSONLs copy the full conversation
    /// into a fresh file the tail has no offset for). It must produce NO
    /// triage: no model call (requestCount stays flat) AND no deterministic
    /// catch — `rm -rf` IS on the catch-list, so zero decisions here proves
    /// the gate runs before the catch. A fresh event on the same session
    /// must then triage exactly as before.
    func testStaleBashEventSkipsTriageButFreshEventStillFires() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(), [:])
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-stale-\(UUID().uuidString).log")
        let trace = TraceLog(path: traceURL)
        let bus = EventBus(trace: trace)
        let client = LLMClient(provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: trace
        )
        // Injected clock (same mechanism as IdleDetectionTests) so the
        // 10-minute age is deterministic, not wall-clock-dependent.
        let clock = ClockBox(initial: Date(timeIntervalSince1970: 1_700_000_000))
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            idleCheckIntervalSeconds: 3600,   // park the idle timer
            now: { clock.now },
            trace: trace
        )
        let captured = CapturedDecisions()
        engine.onDecision = { d in captured.append(d) }
        engine.start()
        defer { engine.stop() }

        bus.publish(.sessionStart(.init(
            sessionId: "s-stale", cwd: "/Users/test", gitBranch: "main",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: clock.now
        )))
        let baseline = Self.requestCount

        // Backfill: catch-listed command, 10 minutes old.
        bus.publish(.bashToolCall(.init(
            sessionId: "s-stale", command: "rm -rf /Users/main/important",
            description: nil, toolUseId: "t-old", turnUUID: "u-old",
            ts: clock.now.addingTimeInterval(-600)
        )))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(captured.snapshot.count, 0,
                       "a stale rm -rf must not fire the deterministic catch — it already ran; got: \(captured.snapshot)")
        XCTAssertEqual(Self.requestCount, baseline,
                       "a stale event must not spend a model call")
        trace.sync()  // drain the write queue before reading the file back
        let traceText = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(traceText.contains("stale_event_skipped"),
                      "engine must trace the skip with the stale_event_skipped tag")

        // Fresh event (age 0 on the injected clock; NOT catch-listed so it
        // exercises the mocked model path) still triages normally.
        bus.publish(.bashToolCall(.init(
            sessionId: "s-stale", command: "chmod -R 000 /Users/main/important",
            description: nil, toolUseId: "t-new", turnUUID: "u-new",
            ts: clock.now
        )))
        try await captured.waitFor(count: 1, within: 3.0)
        XCTAssertEqual(captured.snapshot.first?.triggeringEvent.toolUseId, "t-new")
        XCTAssertEqual(Self.requestCount, baseline + 1,
                       "the fresh event must spend exactly one triage call")
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

    // MARK: - Failure visibility (P0-3): degraded state

    /// A 401-shaped Anthropic error envelope, the "dead API key" case.
    private static func invalidKeyErrorBody() -> Data {
        let body: [String: Any] = [
            "type": "error",
            "error": ["type": "authentication_error", "message": "invalid x-api-key"]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// Engine wired the way main.swift wires it for degraded testing:
    /// a status-capturing notifier + activity/transition logs.
    private func makeDegradedTestEngine(
        capCheck: (@Sendable () -> (cap: Double, spent: Double)?)? = nil
    ) -> (TriageEngine, EventBus, StatusSpyNotifier, ActivityLog) {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-degraded-\(UUID().uuidString).log"))
        let bus = EventBus(trace: trace)
        let client = LLMClient(provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: trace,
            capCheck: capCheck
        )
        let spy = StatusSpyNotifier()
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            notifier: spy,
            idleCheckIntervalSeconds: 3600,  // park the idle timer; we drive the bash path
            trace: trace
        )
        let log = ActivityLog()
        engine.onActivityChange = { log.all.append($0) }
        engine.onDegradedChange = { log.transitions.append(($0, $1)) }
        engine.start()
        return (engine, bus, spy, log)
    }

    private func waitUntil(
        _ timeout: TimeInterval = 3.0,
        _ what: String,
        _ cond: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    /// The full P0-3 contract in one flow: two failures stay quiet (blips
    /// happen), the third enters `.degraded` with the 401-specific reason
    /// and posts EXACTLY one notification; a fourth failure re-asserts the
    /// state but never re-notifies; the next success silently restores
    /// `.idle` (no "watching again" banner) and fires the exit transition.
    func testThreeConsecutiveFailuresEnterDegradedNotifyOnceAndSuccessResets() async throws {
        Self.canned["/v1/messages"] = (401, Self.invalidKeyErrorBody(), [:])
        let (engine, bus, spy, log) = makeDegradedTestEngine()
        defer { engine.stop() }

        // Two failures: below the threshold — no degraded state, no banner.
        publishBashCall(bus, command: "chmod -R 000 /Users/main/a", toolUseId: "t-f1")
        publishBashCall(bus, command: "chmod -R 000 /Users/main/b", toolUseId: "t-f2")
        await waitUntil(3.0, "two failed calls") { Self.requestCount >= 2 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(log.degradedReasons.isEmpty,
                      "two consecutive failures must NOT enter degraded — got \(log.all)")
        XCTAssertEqual(spy.statuses.count, 0)

        // Third failure: degraded, with the check-your-API-key reason.
        publishBashCall(bus, command: "chmod -R 000 /Users/main/c", toolUseId: "t-f3")
        await waitUntil(3.0, "degraded after third failure") { !log.degradedReasons.isEmpty }
        XCTAssertEqual(log.degradedReasons.last, "Can't reach Anthropic — check your API key")
        await waitUntil(2.0, "one degraded notification") { spy.statuses.count == 1 }
        XCTAssertEqual(spy.statuses.count, 1, "entering degraded posts exactly one notification")
        XCTAssertTrue(spy.statuses.first?.body.contains("catch-list") == true,
                      "the banner must say deterministic protections still run; got: \(spy.statuses.first?.body ?? "")")
        XCTAssertEqual(log.transitions.count, 1)
        XCTAssertEqual(log.transitions.first?.degraded, true)

        // Fourth failure: still degraded, still ONE notification (latched).
        publishBashCall(bus, command: "chmod -R 000 /Users/main/d", toolUseId: "t-f4")
        await waitUntil(3.0, "fourth failed call") { Self.requestCount >= 4 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(spy.statuses.count, 1, "per-failure re-notification is exactly the spam this latch prevents")
        XCTAssertEqual(log.transitions.count, 1, "no duplicate entry transition")

        // Recovery: one successful (all-clear) call restores idle, fires the
        // exit transition, and posts NO second banner — silence is fine.
        Self.canned["/v1/messages"] = (200, Self.haikuAllClearResponse(), [:])
        publishBashCall(bus, command: "chmod -R 000 /Users/main/e", toolUseId: "t-ok")
        await waitUntil(3.0, "recovery: exit transition + idle activity") {
            log.transitions.count == 2 && log.all.last == .idle
        }
        XCTAssertEqual(log.transitions.last?.degraded, false)
        XCTAssertEqual(log.all.last, .idle, "success must restore the idle activity")
        XCTAssertEqual(spy.statuses.count, 1, "recovery is silent — no second notification")
    }

    /// DailyCapExceededError is DISTINCT from an outage: it enters degraded
    /// immediately (no 3-strike threshold — the cap holds all day), with the
    /// cap-specific reason and its own banner copy, and it never touches the
    /// network (the gate throws before any request).
    func testDailyCapProducesCapSpecificDegradedStateWithoutNetwork() async throws {
        let (engine, bus, spy, log) = makeDegradedTestEngine(
            capCheck: { (cap: 5.0, spent: 6.10) }  // over cap
        )
        defer { engine.stop() }

        publishBashCall(bus, command: "chmod -R 000 /Users/main/x", toolUseId: "t-cap")
        await waitUntil(3.0, "cap-degraded state") { !log.degradedReasons.isEmpty }
        XCTAssertEqual(log.degradedReasons.last, "Paused at your $5.00 daily cap")
        await waitUntil(2.0, "one cap notification") { spy.statuses.count == 1 }
        XCTAssertEqual(spy.statuses.first?.title, "Supervisor paused at your daily cap")
        XCTAssertTrue(spy.statuses.first?.body.contains("catch-list") == true,
                      "cap banner must say deterministic protections remain active")
        XCTAssertTrue(spy.statuses.first?.body.contains("daily_cap_usd") == true,
                      "cap banner should point at the config knob")
        XCTAssertEqual(Self.requestCount, 0, "a capped call must never reach the network")
    }

    /// Reason mapping is pure and pinned: 401-shaped errors get the
    /// actionable API-key copy, everything else names the provider.
    /// The cap reason formats the configured dollar amount.
    func testDegradedReasonMapping() {
        XCTAssertEqual(
            TriageEngine.degradedReason(
                for: AnthropicClientError.invalidKey(message: "authentication_error"),
                provider: .anthropic),
            "Can't reach Anthropic — check your API key")
        XCTAssertEqual(
            TriageEngine.degradedReason(
                for: AnthropicClientError.network(underlying: "offline"),
                provider: .anthropic),
            "Can't reach Anthropic")
        XCTAssertEqual(
            TriageEngine.degradedReason(
                for: AnthropicClientError.serverError(status: 529, message: "overloaded"),
                provider: .deepseek),
            "Can't reach DeepSeek")
        XCTAssertEqual(TriageEngine.capDegradedReason(capUSD: 5.0),
                       "Paused at your $5.00 daily cap")
        XCTAssertEqual(TriageEngine.capDegradedReason(capUSD: 12.5),
                       "Paused at your $12.50 daily cap")
    }

    // MARK: - Degraded-state capture helpers

    final class StatusSpyNotifier: Notifying, @unchecked Sendable {
        private let lock = NSLock()
        private var inner: [(title: String, body: String)] = []
        func post(decision: TriageDecision) async -> Notifier.Outcome { .posted }
        func postStatus(title: String, body: String) async -> Notifier.Outcome {
            lock.lock(); defer { lock.unlock() }
            inner.append((title, body))
            return .posted
        }
        var statuses: [(title: String, body: String)] {
            lock.lock(); defer { lock.unlock() }
            return inner
        }
    }

    /// Both engine hooks land on the main actor, same as the test body,
    /// so a plain class is safe here.
    @MainActor
    final class ActivityLog {
        var all: [HoverViewModel.Activity] = []
        var transitions: [(degraded: Bool, reason: String?)] = []
        var degradedReasons: [String] {
            all.compactMap {
                if case let .degraded(reason) = $0 { return reason }
                return nil
            }
        }
    }

    // MARK: - Capture helper

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
        TriageEngineTests.requestCount += 1
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
