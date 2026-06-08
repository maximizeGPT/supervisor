import XCTest
@testable import SupervisorCore

/// Task 1 (integrity): Supervisor must never claim an action it didn't take.
/// The hover action log + live label are driven by `actionForOutcome`, mapping
/// the REAL intervention outcome (not intent) to what gets reported. These tests
/// force each outcome through that mapping and assert the report is honest — a
/// degraded inject says it couldn't place the answer and hands the user the text,
/// it never says "answered".
final class InjectClaimHonestyTests: XCTestCase {

    func testInjectSucceededClaimsAnswered() {
        let r = HoverViewModel.actionForOutcome(.injectSucceeded(pid: 123, bytes: 42))
        XCTAssertEqual(r?.action, .inject)
        XCTAssertEqual(r?.label, "Answered a question for Claude Code")
    }

    func testDegradedInjectNeverClaimsAnswered() {
        let r = HoverViewModel.actionForOutcome(
            .injectDegraded(intendedText: "the answer text", reason: "desktop_targeting_failed")
        )
        let label = r?.label ?? ""
        XCTAssertFalse(
            label.localizedCaseInsensitiveContains("answered"),
            "a degraded inject must NOT claim it answered: \"\(label)\""
        )
        XCTAssertTrue(
            label.localizedCaseInsensitiveContains("couldn't"),
            "must say it couldn't place the answer: \"\(label)\""
        )
        XCTAssertTrue(
            label.localizedCaseInsensitiveContains("banner") || label.localizedCaseInsensitiveContains("paste"),
            "must point the user to the text to paste: \"\(label)\""
        )
    }

    func testLowConfidenceContinueRecordsNoAction() {
        // "waiting for direction" is NOT an action taken; the old eager record
        // wrongly logged it as "Sent Claude Code its next task".
        XCTAssertNil(HoverViewModel.actionForOutcome(.continueLowConfidence(reasoning: "couldn't decide")))
    }

    func testFiredVsProposedContinueAreDistinct() {
        XCTAssertEqual(
            HoverViewModel.actionForOutcome(.continueFired(pid: 1, bytes: 2, promptHead: "do x"))?.label,
            "Sent Claude Code its next task"
        )
        let proposed = HoverViewModel.actionForOutcome(.continueProposedMedium(proposal: "do x", justification: "y"))
        XCTAssertEqual(proposed?.action, .continue)
        XCTAssertFalse(
            (proposed?.label ?? "").localizedCaseInsensitiveContains("sent"),
            "a medium-confidence proposal was NOT sent — it's surfaced for the user"
        )
    }

    func testNotifyAndDegradedSignalsRecordNoFalseAction() {
        // notify isn't an "action taken"; a degraded pause/kill arrives as
        // .notifyOnly, so nothing ever claims it paused/stopped something.
        XCTAssertNil(HoverViewModel.actionForOutcome(.notifyOnly))
        // a real pause/kill DOES get recorded.
        XCTAssertEqual(HoverViewModel.actionForOutcome(.pauseSucceeded(pid: 9, recoveryDocPath: nil))?.action, .pause)
        XCTAssertEqual(HoverViewModel.actionForOutcome(.killSucceeded(recoveryDocPath: nil))?.action, .kill)
    }
}
