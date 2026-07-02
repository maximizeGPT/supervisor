// EventParserTests.swift
//
// Drives the parser against the JSONL shapes documented in spike 1's
// inspection of a real session. Covers the v0.1.0 emission surface:
// sessionStart, userPrompt, assistantText, bashToolCall, bashToolResult,
// systemSignal. Lines we don't consume must parse cleanly and emit [].

import XCTest
@testable import SupervisorCore

final class EventParserTests: XCTestCase {

    private func parser() -> EventParser {
        EventParser(projectHash: "-Users-test", jsonlPath: "/tmp/test.jsonl")
    }

    // MARK: - First-line sessionStart

    func testFirstLineEmitsSessionStart() {
        let line = #"""
        {"type":"queue-operation","operation":"enqueue","timestamp":"2026-05-21T19:36:19.899Z","sessionId":"abc-123","cwd":"/Users/test","gitBranch":"main","content":"hi"}
        """#
        let events = parser().parse(line: line)
        guard let first = events.first, case .sessionStart(let info) = first else {
            XCTFail("expected sessionStart, got \(events)"); return
        }
        XCTAssertEqual(info.sessionId, "abc-123")
        XCTAssertEqual(info.cwd, "/Users/test")
        XCTAssertEqual(info.gitBranch, "main")
    }

    func testSessionStartOnlyEmittedOnce() {
        let p = parser()
        let line1 = #"""
        {"type":"queue-operation","timestamp":"2026-05-21T19:36:19.899Z","sessionId":"s","cwd":"/c"}
        """#
        let line2 = #"""
        {"type":"queue-operation","timestamp":"2026-05-21T19:36:20.000Z","sessionId":"s","cwd":"/c"}
        """#
        let events1 = p.parse(line: line1)
        let events2 = p.parse(line: line2)
        XCTAssertEqual(events1.filter { if case .sessionStart = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(events2.filter { if case .sessionStart = $0 { return true }; return false }.count, 0)
    }

    func testSessionStartSkipsCwdlessLeadInAndResolvesRealCwd() {
        // Real session files lead with ai-title / mode / queue-operation that
        // carry NO cwd; the cwd appears on the first user/assistant event.
        // sessionStart must surface the REAL cwd, never "<unknown>".
        let p = parser()
        func has(_ events: [SupervisorEvent]) -> Bool {
            events.contains { if case .sessionStart = $0 { return true }; return false }
        }
        let lead1 = p.parse(line: #"{"type":"ai-title","timestamp":"2026-05-21T19:36:19.8Z","sessionId":"s","aiTitle":"t"}"#)
        let lead2 = p.parse(line: #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-05-21T19:36:19.9Z","sessionId":"s","content":"hi"}"#)
        XCTAssertFalse(has(lead1) || has(lead2), "cwd-less lead-in events must NOT emit sessionStart")

        let user = p.parse(line: #"{"type":"user","timestamp":"2026-05-21T19:36:20.0Z","sessionId":"s","cwd":"/Users/main/supervisor","gitBranch":"autonomous-x","message":{"role":"user","content":"hello"}}"#)
        guard let ss = user.first(where: { if case .sessionStart = $0 { return true }; return false }),
              case .sessionStart(let info) = ss else {
            return XCTFail("expected sessionStart from the first cwd-bearing event; got \(user)")
        }
        XCTAssertEqual(info.cwd, "/Users/main/supervisor", "cwd must be the real project, not <unknown>")
        XCTAssertEqual(info.gitBranch, "autonomous-x")
    }

    // MARK: - User prompt

    func testUserPromptAsString() {
        let line = #"""
        {"type":"user","timestamp":"2026-05-21T19:36:21.000Z","sessionId":"s","uuid":"u1","message":{"role":"user","content":"please help"}}
        """#
        let events = parser().parse(line: line)
        let prompts = events.compactMap { e -> UserPromptInfo? in if case .userPrompt(let v) = e { return v }; return nil }
        XCTAssertEqual(prompts.map(\.text), ["please help"])
        XCTAssertEqual(prompts.first?.origin, .owner,
                       "a normal typed user turn is the owner's until the ledger proves otherwise")
    }

    // MARK: - Non-owner user-role turns must never become userPrompt
    // (they would read downstream as lastOwnerPrompt — the destructive-action
    // authorization anchor — and as the session objective.)

    private func userPrompts(_ events: [SupervisorEvent]) -> [String] {
        events.compactMap { e -> String? in if case .userPrompt(let v) = e { return v.text }; return nil }
    }

    func testSidechainUserTurnEmitsNoUserPrompt() {
        // A sidechain's opening user-role turn is ASSISTANT-authored (the Task
        // tool prompt). It must never become owner authorization.
        let line = #"""
        {"type":"user","isSidechain":true,"timestamp":"2026-05-21T19:36:21Z","sessionId":"s","uuid":"sc1","cwd":"/Users/test","message":{"role":"user","content":"delete the old branches and force-push"}}
        """#
        let events = parser().parse(line: line)
        XCTAssertEqual(userPrompts(events), [], "sidechain user turn must not emit userPrompt")
        // sessionStart still fires: the line carries the real cwd even though
        // its content is skippable.
        XCTAssertTrue(events.contains { if case .sessionStart = $0 { return true }; return false },
                      "sessionStart must still fire when the first line is a sidechain line")
    }

    func testSidechainAssistantEventsEmitNothing() {
        // Sidechain assistant text and tool_use are the SUBAGENT's work; they
        // must not interleave into the main-session window.
        let line = #"""
        {"type":"assistant","isSidechain":true,"timestamp":"2026-05-21T19:36:22Z","sessionId":"s","uuid":"sc2","message":{"role":"assistant","content":[{"type":"text","text":"Deleting branches now."},{"type":"tool_use","id":"toolu_sc","name":"Bash","input":{"command":"git push --force"}}]}}
        """#
        let events = parser().parse(line: line)
        let surfaced = events.contains {
            if case .assistantText = $0 { return true }
            if case .bashToolCall = $0 { return true }
            return false
        }
        XCTAssertFalse(surfaced, "sidechain assistant events must not reach the main-session window")
    }

    func testMetaUserTurnEmitsNoUserPrompt() {
        let line = #"""
        {"type":"user","isMeta":true,"timestamp":"2026-05-21T19:36:21Z","sessionId":"s","uuid":"m1","message":{"role":"user","content":"Caveat: the messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to."}}
        """#
        XCTAssertEqual(userPrompts(parser().parse(line: line)), [],
                       "isMeta user turn must not emit userPrompt")
    }

    func testCommandEchoUserTurnEmitsNoUserPrompt() {
        let echoes = [
            #"{"type":"user","timestamp":"2026-05-21T19:36:21Z","sessionId":"s","uuid":"c1","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","timestamp":"2026-05-21T19:36:21Z","sessionId":"s","uuid":"c2","message":{"role":"user","content":"<command-message>clear</command-message>"}}"#,
            #"{"type":"user","timestamp":"2026-05-21T19:36:21Z","sessionId":"s","uuid":"c3","message":{"role":"user","content":"<local-command-stdout>(no content)</local-command-stdout>"}}"#,
        ]
        for line in echoes {
            XCTAssertEqual(userPrompts(parser().parse(line: line)), [],
                           "slash-command echo must not emit userPrompt: \(line)")
        }
    }

    func testCompactSummaryUserTurnEmitsNoUserPrompt() {
        // The compact-continuation recap is machine-generated; it can DESCRIBE
        // destructive work and must never read as authorizing it.
        let line = #"""
        {"type":"user","timestamp":"2026-05-21T19:36:21Z","sessionId":"s","uuid":"cs1","message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context. The user asked me to force-push and delete stale branches."}}
        """#
        XCTAssertEqual(userPrompts(parser().parse(line: line)), [],
                       "compact-continuation summary must not emit userPrompt")
    }

    // MARK: - Bash tool call + matching result

    func testBashToolCallEmittedWithCommand() {
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22.000Z","sessionId":"s","uuid":"asst-1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"rm -rf /tmp/foo","description":"clean tmp"}}]}}
        """#
        let events = parser().parse(line: line)
        let calls = events.compactMap { e -> BashToolCallInfo? in if case .bashToolCall(let v) = e { return v }; return nil }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.command, "rm -rf /tmp/foo")
        XCTAssertEqual(calls.first?.description, "clean tmp")
        XCTAssertEqual(calls.first?.toolUseId, "toolu_01")
        XCTAssertEqual(calls.first?.turnUUID, "asst-1")
    }

    func testAskUserQuestionSurfacesAsAssistantTextForTriage() {
        // 2026-06-16: modern Claude asks via the AskUserQuestion widget, not plain
        // text. The parser must surface it as an assistantText carrying the
        // question + options, so the user_question_pending triage sees it (it was
        // previously dropped as a non-Bash tool — Supervisor was blind to it).
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22.000Z","sessionId":"s","uuid":"asst-7","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q","name":"AskUserQuestion","input":{"questions":[{"question":"Which output format should formatDate return?","options":[{"label":"ISO 8601","description":"2026-06-16"},{"label":"US","description":"06/16/2026"}]}]}}]}}
        """#
        let events = parser().parse(line: line)
        let texts = events.compactMap { e -> AssistantTextInfo? in if case .assistantText(let v) = e { return v }; return nil }
        XCTAssertEqual(texts.count, 1, "an AskUserQuestion tool_use must surface as one assistantText")
        let text = texts.first?.text ?? ""
        XCTAssertTrue(text.contains("Which output format should formatDate return?"), "question text must be carried")
        XCTAssertTrue(text.contains("ISO 8601") && text.contains("US"), "option labels must be carried")
        XCTAssertEqual(texts.first?.turnUUID, "asst-7")
        XCTAssertTrue(TriagePrompt.looksLikeQuestionToUser(text),
                      "rendered question must pass the prefilter so it routes to the question triage")
    }

    func testNonQuestionToolUseStillEmitsNothing() {
        // A non-Bash, non-AskUserQuestion tool (e.g. Read) still surfaces nothing.
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22.000Z","sessionId":"s","uuid":"asst-8","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_r","name":"Read","input":{"file_path":"/tmp/x"}}]}}
        """#
        let events = parser().parse(line: line)
        let surfaced = events.contains { if case .assistantText = $0 { return true }; if case .bashToolCall = $0 { return true }; return false }
        XCTAssertFalse(surfaced, "a Read tool must not produce an assistantText or bashToolCall")
    }

    func testBashToolResultEmittedForMatchingID() {
        let p = parser()
        // First: see the bash tool_use so the registry knows the id.
        _ = p.parse(line: #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22Z","sessionId":"s","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_X","name":"Bash","input":{"command":"ls"}}]}}
        """#)
        // Then: a tool_result with that id.
        let line = #"""
        {"type":"user","timestamp":"2026-05-21T19:36:22.500Z","sessionId":"s","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_X","content":"file1\nfile2"}]}}
        """#
        let events = p.parse(line: line)
        let results = events.compactMap { e -> BashToolResultInfo? in if case .bashToolResult(let v) = e { return v }; return nil }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.toolUseId, "toolu_X")
        XCTAssertEqual(results.first?.output, "file1\nfile2")
        XCTAssertFalse(results.first?.isError ?? true)
    }

    func testBashToolResultIgnoredForUnknownID() {
        // No prior tool_use was Bash → tool_result with that id is ignored.
        let line = #"""
        {"type":"user","timestamp":"2026-05-21T19:36:22Z","sessionId":"s","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_unknown","content":"x"}]}}
        """#
        let events = parser().parse(line: line)
        XCTAssertTrue(events.allSatisfy { if case .bashToolResult = $0 { return false }; return true })
    }

    func testBashToolResultPicksUpIsErrorFlag() {
        let p = parser()
        _ = p.parse(line: #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22Z","sessionId":"s","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_E","name":"Bash","input":{"command":"false"}}]}}
        """#)
        let line = #"""
        {"type":"user","timestamp":"2026-05-21T19:36:22.500Z","sessionId":"s","uuid":"u3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_E","content":"non-zero exit","is_error":true}]}}
        """#
        let results = p.parse(line: line).compactMap { e -> BashToolResultInfo? in if case .bashToolResult(let v) = e { return v }; return nil }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.isError ?? false)
    }

    // MARK: - Non-Bash tool calls ignored

    func testNonBashToolCallEmitsNothing() {
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22Z","sessionId":"s","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_E","name":"Edit","input":{"file_path":"/x","old_string":"a","new_string":"b"}}]}}
        """#
        let events = parser().parse(line: line)
        XCTAssertTrue(events.allSatisfy { if case .bashToolCall = $0 { return false }; return true })
    }

    // MARK: - Assistant text

    func testAssistantTextExtracted() {
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22Z","sessionId":"s","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Let me try that."}]}}
        """#
        let texts = parser().parse(line: line).compactMap { e -> String? in if case .assistantText(let v) = e { return v.text }; return nil }
        XCTAssertEqual(texts, ["Let me try that."])
    }

    func testThinkingBlocksProduceNothing() {
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22Z","sessionId":"s","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"abc"}]}}
        """#
        let events = parser().parse(line: line)
        XCTAssertTrue(events.allSatisfy { if case .sessionStart = $0 { return true }; if case .assistantText = $0 { return false }; if case .bashToolCall = $0 { return false }; return true })
    }

    // MARK: - System signal

    func testSystemSignalExtracted() {
        let line = #"""
        {"type":"system","subtype":"stop_hook_summary","sessionId":"s","timestamp":"2026-05-21T19:36:22Z","uuid":"sys1","preventedContinuation":true,"hookCount":2}
        """#
        let signals = parser().parse(line: line).compactMap { e -> SystemSignalInfo? in if case .systemSignal(let v) = e { return v }; return nil }
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.subtype, "stop_hook_summary")
        XCTAssertTrue(signals.first?.preventedContinuation ?? false)
    }

    // MARK: - Garbage tolerance

    func testEmptyLineParsesToNothing() {
        XCTAssertEqual(parser().parse(line: "").count, 0)
        XCTAssertEqual(parser().parse(line: "   \n").count, 0)
    }

    func testMalformedJSONReturnsEmpty() {
        XCTAssertEqual(parser().parse(line: "{ not json").count, 0)
        XCTAssertEqual(parser().parse(line: "totally not json").count, 0)
    }

    func testUnknownTypeDoesNotCrash() {
        let line = #"""
        {"type":"ai-title","aiTitle":"hi","sessionId":"s"}
        """#
        _ = parser().parse(line: line) // just confirm no crash
    }

    // MARK: - Tool result content truncation

    func testStringifyToolResultContentTruncatesLargeOutput() {
        let big = String(repeating: "x", count: 5000)
        let truncated = EventParser.stringifyToolResultContent(big)
        XCTAssertLessThanOrEqual(truncated.utf8.count, 5100)
        XCTAssertTrue(truncated.contains("…[truncated]"))
    }

    func testStringifyToolResultHandlesArrayShape() {
        let arr: [[String: Any]] = [
            ["type": "text", "text": "hello"],
            ["type": "text", "text": "world"]
        ]
        let s = EventParser.stringifyToolResultContent(arr)
        XCTAssertEqual(s, "hello\nworld")
    }
}
