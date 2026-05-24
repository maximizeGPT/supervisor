// RecoveryDocWriterTests.swift — v0.1.6 A6.
//
// Coverage:
//   - Doc file is created synchronously at write() return (proves it's
//     ready before the router sends SIGSTOP/SIGTERM).
//   - Filename format is `<ISO8601>-<uuid-short>-<action>.md`.
//   - Doc contains all required sections per the v0.1.6 spec.
//   - Pause-action doc has pause-specific recovery guidance (kill -CONT,
//     YES/NO/UNSURE branches).
//   - Kill-action doc has kill-specific recovery guidance (start new
//     claude, do-not-retry the command, prompt template).
//   - JSONL window edge cases: empty window, fewer than 10 tool calls.
//   - Retention: more than `retentionLimit` files → oldest deleted.

import XCTest
@testable import SupervisorCore

final class RecoveryDocWriterTests: XCTestCase {

    private func makeTempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-test-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeDecision(
        sessionId: String = "2457a4cf-7485-48cf-9c62-336711978936",
        cwd: String? = "/Users/main/project",
        category: String = "destructive_action_pending",
        severity: FlagSeverity = .high,
        action: FlagAction = .pause,
        reasoningPlain: String = "Claude Code is about to delete /Users/main/work. That's not a temp path; pausing.",
        reasoningTechnical: String = "rm -rf /Users/main/work matches destructive_action_pending rubric clause.",
        asymmetryNote: String? = "If I pause and I'm wrong, you lose 5s; if I don't pause, you lose the dir.",
        matchedCommand: String = "rm -rf /Users/main/work",
        recentEvents: [SupervisorEvent] = [],
        lastUserPrompt: String? = "Clean up the build directory."
    ) -> TriageDecision {
        TriageDecision(
            sessionId: sessionId,
            cwd: cwd,
            candidate: TriageCandidate(
                category: category, severity: severity, matchedCommand: matchedCommand,
                action: action, reasoningPlain: reasoningPlain,
                reasoningTechnical: reasoningTechnical, asymmetryNote: asymmetryNote
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: sessionId, command: matchedCommand, description: nil,
                toolUseId: "t1", turnUUID: "u1", ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                   cache_creation_input_tokens: nil,
                                   cache_read_input_tokens: nil),
            model: "haiku",
            prePost: .preExecution,
            recentEvents: recentEvents,
            lastUserPrompt: lastUserPrompt
        )
    }

    // MARK: - File creation + naming

    func testWriteCreatesFileSynchronously() throws {
        let dir = makeTempDir("sync")
        defer { cleanup(dir) }
        let writer = RecoveryDocWriter(directory: dir,
                                       trace: TraceLog(path: dir.appendingPathComponent("trace.log")))
        let url = writer.write(decision: makeDecision(), action: .pause, pid: 1234)
        XCTAssertNotNil(url, "writer should return a URL")
        // Critical: file must exist by the time write() returns — the router
        // signals immediately after this call returns and the file MUST
        // already be on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path),
                      "recovery doc must exist on disk by the time write() returns (before signal lands)")
    }

    func testFilenameFormat() throws {
        let dir = makeTempDir("filename")
        defer { cleanup(dir) }
        let writer = RecoveryDocWriter(directory: dir)
        let url = writer.write(decision: makeDecision(), action: .kill, pid: 9999)
        let name = url!.lastPathComponent
        // <ISO8601-no-colons>-<uuid-short-8>-<action>.md
        // Example: 2026-05-23T19-08-42Z-2457a4cf-kill.md
        XCTAssertTrue(name.hasSuffix("-kill.md"), "filename must end in -<action>.md; got \(name)")
        XCTAssertTrue(name.contains("2457a4cf"), "filename must include short session id; got \(name)")
        XCTAssertFalse(name.contains(":"), "filename must not contain colons (filesystem-safe); got \(name)")
    }

    // MARK: - Required sections

    func testDocContainsAllRequiredSections() throws {
        let dir = makeTempDir("sections")
        defer { cleanup(dir) }
        let writer = RecoveryDocWriter(directory: dir)
        let url = writer.write(decision: makeDecision(), action: .pause, pid: 4242)
        let body = try String(contentsOf: url!, encoding: .utf8)

        // Required v0.1.6 sections per the spec
        XCTAssertTrue(body.contains("# Intervention recovery: pause on session"),
                      "must have the spec'd H1 with action + session")
        XCTAssertTrue(body.contains("## What happened"), "must have 'What happened' section")
        XCTAssertTrue(body.contains("## What Claude Code was doing"), "must have 'What Claude Code was doing' section")
        XCTAssertTrue(body.contains("## What to do next"), "must have 'What to do next' section")
        // Required fields surfaced
        XCTAssertTrue(body.contains("destructive_action_pending"), "must surface category")
        XCTAssertTrue(body.contains("Severity"), "must surface severity field")
        XCTAssertTrue(body.contains("Clean up the build directory"), "must surface the user's prompt")
        XCTAssertTrue(body.contains("rm -rf /Users/main/work"), "must surface the matched command")
        XCTAssertTrue(body.contains("PID **4242**"), "must surface the PID in the pause-recovery section")
        // Asymmetry note included when present
        XCTAssertTrue(body.contains("Asymmetry note"), "must include asymmetry section when note is present")
    }

    func testDocOmitsAsymmetrySectionWhenNoteIsAbsent() throws {
        let dir = makeTempDir("noasym")
        defer { cleanup(dir) }
        let writer = RecoveryDocWriter(directory: dir)
        let url = writer.write(decision: makeDecision(asymmetryNote: nil),
                                action: .pause, pid: 1)
        let body = try String(contentsOf: url!, encoding: .utf8)
        XCTAssertFalse(body.contains("Asymmetry note"),
                       "must not surface an empty asymmetry section when no note present")
    }

    // MARK: - Action-specific recovery guidance

    func testPauseRecoveryHasKillCONTAndDecisionBranches() throws {
        let dir = makeTempDir("pauseguide")
        defer { cleanup(dir) }
        let writer = RecoveryDocWriter(directory: dir)
        let url = writer.write(decision: makeDecision(), action: .pause, pid: 5555)
        let body = try String(contentsOf: url!, encoding: .utf8)
        XCTAssertTrue(body.contains("kill -CONT 5555"), "pause section must show kill -CONT with PID baked in")
        XCTAssertTrue(body.contains("If YES"), "pause section must offer YES branch")
        XCTAssertTrue(body.contains("If NO"), "pause section must offer NO branch")
        XCTAssertTrue(body.contains("If UNSURE"), "pause section must offer UNSURE branch")
        XCTAssertTrue(body.contains("Supervisor paused you on"), "must include the prompt-template the user pastes back")
    }

    func testKillRecoveryHasStartNewClaudeAndDoNotRetry() throws {
        let dir = makeTempDir("killguide")
        defer { cleanup(dir) }
        let writer = RecoveryDocWriter(directory: dir)
        let url = writer.write(decision: makeDecision(), action: .kill, pid: 8888)
        let body = try String(contentsOf: url!, encoding: .utf8)
        XCTAssertTrue(body.contains("Claude Code session is dead"),
                      "kill section must announce session is dead")
        XCTAssertTrue(body.contains("start a new `claude`"),
                      "kill section must direct user to start a new claude session")
        XCTAssertTrue(body.contains("Do NOT retry the specific action"),
                      "kill section must warn against retrying the triggering command")
        XCTAssertTrue(body.contains("rm -rf /Users/main/work"),
                      "kill section must surface the do-not-retry command")
    }

    // MARK: - JSONL window edge cases

    func testEmptyWindowProducesPlaceholder() throws {
        let dir = makeTempDir("emptywin")
        defer { cleanup(dir) }
        let writer = RecoveryDocWriter(directory: dir)
        let url = writer.write(decision: makeDecision(recentEvents: []),
                                action: .pause, pid: 1)
        let body = try String(contentsOf: url!, encoding: .utf8)
        XCTAssertTrue(body.contains("No prior tool calls in the window"),
                      "empty window must produce a clear placeholder, not crash")
    }

    func testWindowWithFewerThan10ToolCallsIsHandled() throws {
        let dir = makeTempDir("fewcalls")
        defer { cleanup(dir) }
        let ts = Date()
        let events: [SupervisorEvent] = [
            .userPrompt(.init(sessionId: "s", text: "do the thing", ts: ts.addingTimeInterval(-30))),
            .bashToolCall(.init(sessionId: "s", command: "ls", description: nil,
                                 toolUseId: "t1", turnUUID: "u1", ts: ts.addingTimeInterval(-20))),
            .bashToolCall(.init(sessionId: "s", command: "cat README.md", description: nil,
                                 toolUseId: "t2", turnUUID: "u2", ts: ts.addingTimeInterval(-10))),
        ]
        let writer = RecoveryDocWriter(directory: dir)
        let url = writer.write(decision: makeDecision(recentEvents: events),
                                action: .pause, pid: 1)
        let body = try String(contentsOf: url!, encoding: .utf8)
        XCTAssertTrue(body.contains("`ls`"), "must surface ls command")
        XCTAssertTrue(body.contains("`cat README.md`"), "must surface cat command")
        XCTAssertFalse(body.contains("No prior tool calls"),
                       "non-empty window must not show the empty placeholder")
    }

    // MARK: - Retention

    func testRetentionDropsOldestBeyondLimit() throws {
        let dir = makeTempDir("retention")
        defer { cleanup(dir) }
        let writer = RecoveryDocWriter(directory: dir, retentionLimit: 3)

        // Write 5 docs. Limit is 3 → 2 oldest get pruned each write past
        // the threshold. Final state: exactly 3 docs (the 3 newest).
        for i in 0..<5 {
            let d = makeDecision(sessionId: "sess\(i)abcd-uuid-here")
            _ = writer.write(decision: d, action: .pause, pid: pid_t(1000 + i))
            // Sleep a tick so creationDate ordering is deterministic
            usleep(50_000)
        }

        let fm = FileManager.default
        let files = (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(files.count, 3, "retention should leave exactly 3 files (the limit)")
    }
}
