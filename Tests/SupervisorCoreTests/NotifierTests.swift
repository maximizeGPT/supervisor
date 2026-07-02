// NotifierTests.swift
//
// Verifies the v0.1.2 banner shape: `Notifier.bannerPrefix` + Haiku's
// `reasoning_plain`, with no copy synthesis. The actual notification
// post path can't be unit-tested (UNUserNotificationCenter.current()
// aborts in the test harness — same Spike 2 finding as
// PermissionCheckerTests). Full delivery is verified at Checkpoint C.

import XCTest
import UserNotifications
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

    // MARK: - Actionable notifications (F8)
    //
    // The notification-posting path can't be unit-tested (UNUserNotification-
    // Center.current() aborts in the harness — see the file header). The
    // action/category/thread/userInfo pieces are pure, so they ARE tested here.

    func testThreadIdentifierIsPerSessionStable() {
        let a1 = Notifier.threadIdentifier(sessionId: "abc")
        let a2 = Notifier.threadIdentifier(sessionId: "abc")
        let b = Notifier.threadIdentifier(sessionId: "xyz")
        XCTAssertEqual(a1, a2, "same session must map to the same thread (so flags coalesce)")
        XCTAssertNotEqual(a1, b, "different sessions must map to different threads")
        XCTAssertTrue(a1.contains("abc"))
    }

    func testCategoryIdentifierMapsOutcomesToActionableCategories() {
        XCTAssertEqual(Notifier.categoryIdentifier(for: .pauseSucceeded(pid: 1, recoveryDocPath: nil)),
                       Notifier.categoryPaused)
        XCTAssertEqual(Notifier.categoryIdentifier(for: .killSucceeded(recoveryDocPath: nil)),
                       Notifier.categoryStopped)
        XCTAssertEqual(Notifier.categoryIdentifier(for: .injectDegraded(intendedText: "x", reason: "y")),
                       Notifier.categoryAnswer)
        XCTAssertEqual(Notifier.categoryIdentifier(for: .continueProposedMedium(proposal: "p", justification: "j")),
                       Notifier.categoryProposal)
        // Nothing-to-tap outcomes carry no category.
        XCTAssertNil(Notifier.categoryIdentifier(for: .notifyOnly))
        XCTAssertNil(Notifier.categoryIdentifier(for: .injectSucceeded(pid: 1, bytes: 2)))
        XCTAssertNil(Notifier.categoryIdentifier(for: .continueFired(pid: 1, bytes: 2, promptHead: "h")))
    }

    func testCategoriesCarryTheRightActions() {
        let cats = Notifier.categories()
        func actions(_ id: String) -> [String] {
            (cats.first { $0.identifier == id }?.actions ?? []).map { $0.identifier }
        }
        XCTAssertEqual(Set(actions(Notifier.categoryPaused)),
                       [Notifier.actionResume, Notifier.actionOpenRecoveryDoc],
                       "paused banner offers Resume + Open recovery doc")
        XCTAssertEqual(actions(Notifier.categoryStopped), [Notifier.actionOpenRecoveryDoc])
        XCTAssertEqual(actions(Notifier.categoryAnswer), [Notifier.actionCopyAnswer])
        XCTAssertEqual(actions(Notifier.categoryProposal), [Notifier.actionCopyAnswer])
    }

    func testUserInfoCarriesActionPayloads() {
        let doc = URL(fileURLWithPath: "/tmp/recovery/r.md")
        let pause = Notifier.userInfo(
            sessionId: "s", cwd: "/repo",
            outcome: .pauseSucceeded(pid: 1, recoveryDocPath: doc))
        XCTAssertEqual(pause[Notifier.userInfoSessionId], "s")
        XCTAssertEqual(pause[Notifier.userInfoCwd], "/repo", "Resume needs the cwd")
        XCTAssertEqual(pause[Notifier.userInfoRecoveryDoc], "/tmp/recovery/r.md")

        let answer = Notifier.userInfo(
            sessionId: "s", cwd: nil,
            outcome: .injectDegraded(intendedText: "PASTE ME", reason: "no ax"))
        XCTAssertEqual(answer[Notifier.userInfoAnswer], "PASTE ME",
                       "Copy answer needs the intended text (no longer buried in a truncated banner)")
        XCTAssertNil(answer[Notifier.userInfoCwd])

        let proposal = Notifier.userInfo(
            sessionId: "s", cwd: nil,
            outcome: .continueProposedMedium(proposal: "do the thing", justification: "j"))
        XCTAssertEqual(proposal[Notifier.userInfoAnswer], "do the thing")
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
