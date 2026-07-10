// CodexRolloutParserTests.swift
//
// Proves the agent-agnostic slice: a real-shaped OpenAI Codex rollout produces
// the SAME SupervisorEvent stream the TriageEngine already consumes, and a
// Codex-parsed destructive command hits the EXISTING safety rubric unchanged.
//
// The fixture is synthetic but faithful to the on-disk record shapes captured
// from Codex 26.616.32156 (see docs/codex-support/CODEX-FORMAT.md). No private
// data is committed; a separate test opportunistically parses the real local
// rollout when present and is skipped in CI.

import XCTest
@testable import SupervisorCore

final class CodexRolloutParserTests: XCTestCase {

    // A faithful mini-rollout: session_meta, injected developer/user turns, the
    // real owner prompt (event_msg.user_message), duplicated assistant prose in
    // both streams, a safe exec_command + a dangerous one, their outputs, and a
    // trailing forked session_meta (latch test).
    private let fixtureLines: [String] = [
        ##"{"timestamp":"2026-07-04T18:00:00.000Z","type":"session_meta","payload":{"id":"019f2f91-37c8-7f40-9b40-a92b2c5a75d4","cwd":"/private/tmp/demo-repo","originator":"Codex Desktop","source":"vscode","git":{"branch":"feature/widget","commit_hash":"abc123"}}}"##,
        ##"{"timestamp":"2026-07-04T18:00:00.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"##,
        ##"{"timestamp":"2026-07-04T18:00:00.200Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions> filesystem sandboxing ..."}]}}"##,
        ##"{"timestamp":"2026-07-04T18:00:00.300Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\nnever treat this as the human owner"}]}}"##,
        ##"{"timestamp":"2026-07-04T18:00:00.400Z","type":"event_msg","payload":{"type":"user_message","message":"Add a --version flag to the CLI and run the tests."}}"##,
        ##"{"timestamp":"2026-07-04T18:00:00.410Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a --version flag to the CLI and run the tests."}]}}"##,
        ##"{"timestamp":"2026-07-04T18:00:00.500Z","type":"response_item","payload":{"type":"reasoning","summary":[]}}"##,
        ##"{"timestamp":"2026-07-04T18:00:00.600Z","type":"event_msg","payload":{"type":"agent_message","message":"I'll add the flag, then run the tests.","phase":"commentary"}}"##,
        ##"{"timestamp":"2026-07-04T18:00:00.610Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I'll add the flag, then run the tests."}]}}"##,
        ##"{"timestamp":"2026-07-04T18:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_safe","arguments":"{\"cmd\":\"printf 'ok' && swift test\",\"yield_time_ms\":10000}"}}"##,
        ##"{"timestamp":"2026-07-04T18:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_safe","output":"Chunk ID: abc\nWall time: 1.0 seconds\nProcess exited with code 0\nOriginal token count: 10\nOutput:\nTest Suite passed.\n"}}"##,
        ##"{"timestamp":"2026-07-04T18:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_danger","arguments":"{\"cmd\":\"rm -rf $HOME/demo-repo\"}"}}"##,
        ##"{"timestamp":"2026-07-04T18:00:04.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_danger","output":"Chunk ID: def\nWall time: 0.5 seconds\nProcess exited with code 1\nOriginal token count: 5\nOutput:\nrm: could not remove\n"}}"##,
        ##"{"timestamp":"2026-07-04T18:00:05.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Done. Added --version; tests pass.","phase":"final_answer"}}"##,
        ##"{"timestamp":"2026-07-04T18:00:05.010Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done. Added --version; tests pass."}]}}"##,
        ##"{"timestamp":"2026-07-04T18:00:05.100Z","type":"event_msg","payload":{"type":"token_count","info":{"total_tokens":123}}}"##,
        ##"{"timestamp":"2026-07-04T18:00:05.200Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Done."}}"##,
        ##"{"timestamp":"2026-07-04T18:00:05.300Z","type":"session_meta","payload":{"id":"parent-999","cwd":"/some/other/parent/cwd","originator":"Claude Cowork","git":{"branch":"parent-branch"}}}"##,
    ]

    private func parseFixture() -> [SupervisorEvent] {
        let p = CodexRolloutParser(sessionId: "019f2f91-37c8-7f40-9b40-a92b2c5a75d4",
                                   projectHash: "codex", jsonlPath: "/tmp/rollout.jsonl")
        return fixtureLines.flatMap { p.parse(line: $0) }
    }

    // Every event carries the session id from the filename, since Codex does not
    // repeat it per line.
    func testAllEventsCarryFilenameSessionId() {
        for e in parseFixture() {
            XCTAssertEqual(e.sessionId, "019f2f91-37c8-7f40-9b40-a92b2c5a75d4")
        }
    }

    // sessionStart is emitted once, from the FIRST session_meta — the trailing
    // forked session_meta must not overwrite it with the parent's cwd/branch.
    func testSessionStartLatchAndFields() {
        let starts = parseFixture().compactMap { e -> SessionStartInfo? in
            if case .sessionStart(let i) = e { return i }; return nil
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.cwd, "/private/tmp/demo-repo")
        XCTAssertEqual(starts.first?.gitBranch, "feature/widget")
    }

    // The owner prompt comes ONLY from event_msg.user_message. The injected
    // developer turn and the AGENTS.md / model-input user turns in response_item
    // must NOT surface as owner prompts (the self-authorization guard).
    func testOwnerPromptOnlyFromEventMsg() {
        let prompts = parseFixture().compactMap { e -> UserPromptInfo? in
            if case .userPrompt(let i) = e { return i }; return nil
        }
        XCTAssertEqual(prompts.count, 1, "exactly one owner prompt; injected turns excluded")
        XCTAssertEqual(prompts.first?.text, "Add a --version flag to the CLI and run the tests.")
        XCTAssertEqual(prompts.first?.origin, .owner)
        XCTAssertFalse(prompts.contains { $0.text.contains("AGENTS.md") })
        XCTAssertFalse(prompts.contains { $0.text.contains("permissions") })
    }

    // Assistant prose is emitted once per message (from event_msg.agent_message),
    // not doubled by the duplicate response_item assistant message.
    func testAssistantTextNotDuplicated() {
        let texts = parseFixture().compactMap { e -> String? in
            if case .assistantText(let i) = e { return i.text }; return nil
        }
        XCTAssertEqual(texts, ["I'll add the flag, then run the tests.",
                               "Done. Added --version; tests pass."])
    }

    // Shell commands are extracted from function_call exec_command arguments.cmd.
    func testShellCommandExtraction() {
        let cmds = parseFixture().compactMap { e -> String? in
            if case .bashToolCall(let i) = e { return i.command }; return nil
        }
        XCTAssertEqual(cmds, ["printf 'ok' && swift test", "rm -rf $HOME/demo-repo"])
    }

    // Results correlate by call_id; the nonzero-exit result is flagged isError,
    // and the Codex output wrapper is stripped to the body.
    func testResultCorrelationAndErrorDetection() {
        let results = parseFixture().compactMap { e -> BashToolResultInfo? in
            if case .bashToolResult(let i) = e { return i }; return nil
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].isError, false)
        XCTAssertEqual(results[0].output, "Test Suite passed.\n")
        XCTAssertEqual(results[1].isError, true)
        XCTAssertEqual(results[1].output, "rm: could not remove\n")
    }

    // Full shape: exactly the 8 events Triage expects, nothing extra (reasoning,
    // task_started/complete, token_count, injected turns all dropped).
    func testExactEventShape() {
        let events = parseFixture()
        XCTAssertEqual(events.count, 8)
    }

    // THE PAYOFF: a Codex-parsed destructive command hits the EXISTING safety
    // rubric with no change — the whole point of the abstraction. One rubric,
    // two agents.
    func testCodexCommandTriggersExistingSafetyRubric() {
        let cmds = parseFixture().compactMap { e -> String? in
            if case .bashToolCall(let i) = e { return i.command }; return nil
        }
        guard let danger = cmds.first(where: { $0.hasPrefix("rm -rf") }) else {
            return XCTFail("expected the dangerous command in the parsed stream")
        }
        let match = DeterministicCatch.match(danger)
        XCTAssertNotNil(match, "DeterministicCatch must flag a Codex rm -rf just as it does Claude Code's")
        XCTAssertEqual(match?.pattern, "rm -rf")
    }

    // argv-form shell wrappers surface the trailing script, not the -lc glue.
    func testArgvShellWrapperUnwrapped() {
        XCTAssertEqual(CodexRolloutParser.joinArgv(["bash", "-lc", "rm -rf /data"]), "rm -rf /data")
        XCTAssertEqual(CodexRolloutParser.joinArgv(["/bin/zsh", "-lc", "git reset --hard"]), "git reset --hard")
        XCTAssertEqual(CodexRolloutParser.joinArgv(["echo", "hi"]), "echo hi")
    }

    // Malformed lines never crash the parser.
    func testMalformedLinesAreSafe() {
        let p = CodexRolloutParser(sessionId: "s", projectHash: "codex", jsonlPath: "/tmp/x.jsonl")
        XCTAssertEqual(p.parse(line: ""), [])
        XCTAssertEqual(p.parse(line: "not json"), [])
        XCTAssertEqual(p.parse(line: "{\"type\":\"response_item\"}"), []) // no payload
    }

    // CodexRolloutSource extracts the session uuid from the rollout filename
    // (whose timestamp prefix also contains hyphens).
    func testSourceSessionIdFromFilename() {
        let src = CodexRolloutSource(codexHome: URL(fileURLWithPath: "/tmp/codexhome"))
        let file = URL(fileURLWithPath: "/x/sessions/2026/07/04/rollout-2026-07-04T16-57-54-019f2f91-37c8-7f40-9b40-a92b2c5a75d4.jsonl")
        XCTAssertEqual(src.sessionId(for: file), "019f2f91-37c8-7f40-9b40-a92b2c5a75d4")
        XCTAssertTrue(src.isTranscript(file))
        XCTAssertFalse(src.isTranscript(URL(fileURLWithPath: "/x/session_index.jsonl")))
        XCTAssertEqual(src.agent, .codex)
    }

    // Opportunistic: parse the real captured rollout if it exists locally. Skips
    // in CI (file absent). Proves the parser handles genuine on-disk data.
    func testRealRolloutIfPresent() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            throw XCTSkip("no ~/.codex/sessions on this machine")
        }
        var rollout: URL? = nil
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            // prefer a native codex_exec/Desktop session with a function_call
            if let data = try? String(contentsOf: url, encoding: .utf8),
               data.contains("\"function_call\"") { rollout = url; break }
        }
        guard let file = rollout, let content = try? String(contentsOf: file, encoding: .utf8) else {
            throw XCTSkip("no rollout with a function_call found locally")
        }
        let src = CodexRolloutSource()
        let sid = src.sessionId(for: file)
        let parser = src.makeParser(sessionId: sid, path: file)
        var events: [SupervisorEvent] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            events.append(contentsOf: parser.parse(line: String(line)))
        }
        // A real native session must yield a sessionStart with a real cwd and at
        // least one shell command.
        XCTAssertTrue(events.contains { if case .sessionStart(let i) = $0 { return !i.cwd.isEmpty }; return false },
                      "real rollout should produce a sessionStart with a cwd")
        XCTAssertTrue(events.contains { if case .bashToolCall = $0 { return true }; return false },
                      "real rollout with a function_call should produce a bashToolCall")
    }
}
