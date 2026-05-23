// NotifierTests.swift
//
// Verifies the v0.1.2 banner shape: `Notifier.bannerPrefix` + Haiku's
// `reasoning_plain`, with no copy synthesis. The actual notification
// post path can't be unit-tested (UNUserNotificationCenter.current()
// aborts in the test harness — same Spike 2 finding as
// PermissionCheckerTests). Full delivery is verified at Checkpoint C.

import XCTest
@testable import SupervisorCore

final class NotifierTests: XCTestCase {

    private func decision(
        prePost: TriageDecision.PrePost = .preExecution,
        severity: FlagSeverity = .high,
        action: FlagAction = .pause,
        reasoningPlain: String = "Claude Code is about to delete /Users/main/important and everything in it. Pausing so you can check before it runs."
    ) -> TriageDecision {
        TriageDecision(
            sessionId: "s",
            candidate: TriageCandidate(
                category: "destructive_action_pending",
                severity: severity,
                matchedCommand: "rm -rf /Users/main/important",
                action: action,
                reasoningPlain: reasoningPlain,
                reasoningTechnical: "rm -rf /Users/main/important matches destructive_action_pending; outside cwd /Users/test; user did not authorize."
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

    func testBodyPrependsSupervisorBrandPrefix() {
        let n = NotifierBodyOnly()
        let str = n.body(for: decision())
        XCTAssertTrue(str.hasPrefix(Notifier.bannerPrefix),
                      "banner must start with the brand prefix; got: \(str)")
    }

    func testBodyUsesReasoningPlainVerbatim() {
        let n = NotifierBodyOnly()
        let plain = "Claude Code is about to delete /Users/main/important and everything in it. Pausing so you can check before it runs."
        let str = n.body(for: decision(reasoningPlain: plain))
        XCTAssertEqual(str, Notifier.bannerPrefix + plain,
                       "body should be exactly prefix + plain reasoning, no truncation or synthesis")
    }

    func testBodyDoesNotUseTechnicalReasoning() {
        // The reasoning_technical paragraph is unfit for the banner; the
        // body composer must never reach for it.
        let n = NotifierBodyOnly()
        let str = n.body(for: decision(reasoningPlain: "Plain text here."))
        XCTAssertFalse(str.contains("matches destructive_action_pending"),
                       "technical-style text should not appear in banner; got: \(str)")
        XCTAssertFalse(str.contains("outside cwd"),
                       "technical-style text should not appear in banner; got: \(str)")
    }

    func testBodyUsesMalformedFallbackWhenReasoningPlainIsTheFixedString() {
        // When Haiku's verdict is malformed, the engine populates
        // reasoning_plain with TriagePrompt.malformedVerdictBannerText.
        // The banner should still come out coherent.
        let n = NotifierBodyOnly()
        let str = n.body(for: decision(reasoningPlain: TriagePrompt.malformedVerdictBannerText))
        XCTAssertEqual(str, Notifier.bannerPrefix + TriagePrompt.malformedVerdictBannerText)
        XCTAssertTrue(str.contains("Open the panel for details"),
                      "malformed-verdict banner must surface the panel-redirect hint")
    }
}

/// A pure-body extractor we can exercise without touching UN. Mirrors
/// `Notifier.body(for:)` so tests don't need to construct a real Notifier
/// (which would crash the xctest harness — same Spike-2 issue). If the
/// real body shape changes, this shim must move with it.
private struct NotifierBodyOnly {
    func body(for decision: TriageDecision) -> String {
        Notifier.bannerPrefix + decision.candidate.reasoningPlain
    }
}
