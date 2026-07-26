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

    // MARK: - Clipboard-claim honesty (the setString-can-fail bug)

    func testDegradedInjectBodyClaimsClipboardOnlyWhenCopySucceeded() {
        let d = decision()
        let answer = "the full answer text to paste"

        let copied = Notifier.composeBody(
            for: d, outcome: .injectDegraded(intendedText: answer, reason: "locator_nil", copiedToClipboard: true))
        XCTAssertTrue(copied.contains("copied it to your clipboard"),
                      "a successful copy earns the clipboard claim: \(copied)")

        let failed = Notifier.composeBody(
            for: d, outcome: .injectDegraded(intendedText: answer, reason: "locator_nil", copiedToClipboard: false))
        XCTAssertFalse(failed.contains("copied it to your clipboard"),
                       "a FAILED setString must not claim the clipboard: \(failed)")
        XCTAssertTrue(failed.contains(answer),
                      "when the clipboard failed, the banner must carry the answer itself: \(failed)")
    }

    func testScreenRecordingDeniedBodyClaimsClipboardOnlyWhenCopySucceeded() {
        let d = decision()
        let answer = "paste-this proposal"

        let copied = Notifier.composeBody(
            for: d, outcome: .screenRecordingDenied(intendedText: answer, copiedToClipboard: true))
        XCTAssertTrue(copied.contains("on your clipboard"), "got: \(copied)")

        let failed = Notifier.composeBody(
            for: d, outcome: .screenRecordingDenied(intendedText: answer, copiedToClipboard: false))
        XCTAssertFalse(failed.contains("on your clipboard"),
                       "must not point at a clipboard it never wrote: \(failed)")
        XCTAssertTrue(failed.contains(answer), "the text must still reach the owner: \(failed)")
        XCTAssertTrue(failed.contains("Screen Recording"),
                      "the actionable permission callout survives the clipboard fallback: \(failed)")
    }

    func testContinueProposedMediumBodyMentionsClipboardOnlyWhenCopied() {
        let d = decision()
        let proposal = "Run the release checklist next."

        let degraded = Notifier.composeBody(
            for: d, outcome: .continueProposedMedium(proposal: proposal, justification: "j", copiedToClipboard: true))
        XCTAssertTrue(degraded.contains("on your clipboard"), "got: \(degraded)")

        let genuine = Notifier.composeBody(
            for: d, outcome: .continueProposedMedium(proposal: proposal, justification: "j", copiedToClipboard: false))
        XCTAssertFalse(genuine.contains("clipboard"),
                       "a proposal that never touched the clipboard must not mention it: \(genuine)")
        XCTAssertTrue(genuine.contains(proposal))
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

    // MARK: - Outcome-kind persistence mapping (issue #60 follow-up)

    /// Every InterventionOutcome case maps to its payload-free persisted kind,
    /// and the on-disk raw values are the stable snake_case contract the trust
    /// scorecard buckets on. (The enum has associated values so CaseIterable
    /// can't sweep it — each case is asserted explicitly; a new case breaks
    /// the `kind` switch at compile time anyway.)
    func testInterventionOutcomeKindMapsEveryCaseStably() {
        XCTAssertEqual(InterventionOutcome.notifyOnly.kind, .notifyOnly)
        XCTAssertEqual(InterventionOutcome.pauseSucceeded(pid: 1, recoveryDocPath: nil).kind, .pauseSucceeded)
        XCTAssertEqual(InterventionOutcome.killSucceeded(recoveryDocPath: nil).kind, .killSucceeded)
        XCTAssertEqual(InterventionOutcome.injectSucceeded(pid: 1, bytes: 2).kind, .injectSucceeded)
        XCTAssertEqual(InterventionOutcome.injectDegraded(intendedText: "t", reason: "r", copiedToClipboard: false).kind, .injectDegraded)
        XCTAssertEqual(InterventionOutcome.screenRecordingDenied(intendedText: "t", copiedToClipboard: false).kind, .screenRecordingDenied)
        XCTAssertEqual(InterventionOutcome.continueFired(pid: 1, bytes: 2, promptHead: "h").kind, .continueFired)
        XCTAssertEqual(InterventionOutcome.continueProposedMedium(proposal: "p", justification: "j", copiedToClipboard: false).kind, .continueProposedMedium)
        XCTAssertEqual(InterventionOutcome.continueLowConfidence(reasoning: "r").kind, .continueLowConfidence)
        XCTAssertEqual(InterventionOutcome.queued(promptHead: "h").kind, .queued)

        XCTAssertEqual(InterventionOutcomeKind.notifyOnly.rawValue, "notify_only")
        XCTAssertEqual(InterventionOutcomeKind.injectDegraded.rawValue, "inject_degraded")
        XCTAssertEqual(InterventionOutcomeKind.screenRecordingDenied.rawValue, "screen_recording_denied")
        XCTAssertEqual(InterventionOutcomeKind.queued.rawValue, "queued")
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
