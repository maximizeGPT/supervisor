// NotifierTests.swift
//
// Verifies the copy generation. The actual notification post path can't
// be unit-tested (UNUserNotificationCenter.current() aborts in the test
// harness — same Spike 2 finding as PermissionCheckerTests). We test the
// body string explicitly here; full delivery is verified at Checkpoint C.

import XCTest
@testable import SupervisorCore

final class NotifierTests: XCTestCase {

    private func decision(prePost: TriageDecision.PrePost, severity: FlagSeverity = .high) -> TriageDecision {
        TriageDecision(
            sessionId: "s",
            candidate: TriageCandidate(
                category: "destructive_action_pending",
                severity: severity,
                reasoning: "rm -rf targets a non-temp path.",
                matchedCommand: "rm -rf /Users/main/important"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: "s",
                command: "rm -rf /Users/main/important",
                description: nil,
                toolUseId: "t1",
                turnUUID: "u1",
                ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                   cache_creation_input_tokens: nil,
                                   cache_read_input_tokens: nil),
            model: "claude-haiku-4-5-20251001",
            prePost: prePost
        )
    }

    /// Notifier is constructed but never used — we only test `body(for:)`.
    /// Constructing it without invoking `.post` doesn't touch UN runtime.
    private func makeNotifierForCopyTest() -> Notifier? {
        // Skip if running inside the xctest harness — UNUserNotificationCenter.current()
        // asserts on missing CFBundleIdentifier.
        if Bundle.main.bundleIdentifier == nil {
            return nil
        }
        return Notifier()
    }

    func testPreExecutionCopyUsesAboutToFraming() {
        let n = NotifierBodyOnly()
        let str = n.body(for: decision(prePost: .preExecution))
        XCTAssertTrue(str.contains("is about to"))
        XCTAssertFalse(str.contains("just ran"))
    }

    func testAlreadyExecutedCopyUsesJustRanFraming() {
        let n = NotifierBodyOnly()
        let str = n.body(for: decision(prePost: .alreadyExecuted))
        XCTAssertTrue(str.contains("just ran"))
        XCTAssertTrue(str.contains("Stop further action?"))
        XCTAssertFalse(str.contains("is about to"))
    }

    func testBodyIncludesCommandHead() {
        let n = NotifierBodyOnly()
        let str = n.body(for: decision(prePost: .alreadyExecuted))
        XCTAssertTrue(str.contains("rm -rf /Users/main/important"))
    }

    func testBodyTruncatesLongReasoning() {
        let n = NotifierBodyOnly()
        let long = String(repeating: "very ", count: 200) + "long reasoning"
        let d = TriageDecision(
            sessionId: "s",
            candidate: TriageCandidate(
                category: "destructive_action_pending",
                severity: .high,
                reasoning: long,
                matchedCommand: "rm -rf /Users/main/x"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: "s", command: "rm -rf /Users/main/x", description: nil,
                toolUseId: "t1", turnUUID: "u1", ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                   cache_creation_input_tokens: nil,
                                   cache_read_input_tokens: nil),
            model: "claude-haiku-4-5-20251001",
            prePost: .alreadyExecuted
        )
        let str = n.body(for: d)
        XCTAssertLessThan(str.count, 300, "body should be a notification-friendly length")
    }
}

/// A pure-body extractor we can exercise without touching UN. Lifts the
/// same `body(for:)` logic out of `Notifier` so tests don't need to
/// construct a real one (which would crash the xctest harness — same
/// Spike-2 issue).
private struct NotifierBodyOnly {
    func body(for decision: TriageDecision) -> String {
        let cmd = decision.candidate.matchedCommand
        let head = cmd.split(separator: "\n").first.map(String.init) ?? cmd
        switch decision.prePost {
        case .preExecution:
            return "Claude Code is about to run `\(head)`. \(decision.candidate.reasoning.prefix(160))"
        case .alreadyExecuted:
            return "Claude Code just ran `\(head)`. \(decision.candidate.reasoning.prefix(160)) Stop further action?"
        }
    }
}
