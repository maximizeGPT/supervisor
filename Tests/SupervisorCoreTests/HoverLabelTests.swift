// HoverLabelTests.swift
//
// Regression tests for HoverViewModel.plainLabelForFlag, the function
// that builds the short action-log label shown in the expanded panel's
// RECENT ACTIONS list.

import XCTest
@testable import SupervisorCore

@MainActor
final class HoverLabelTests: XCTestCase {

    /// The bug the owner caught on screen: a version like "v0.8.3" has
    /// decimal points, and the old first-sentence split on a bare "."
    /// clipped "shipping v0.8.3" down to "shipping v0", which read as
    /// "version 0". The split must break on ". " (period + space), not on
    /// a decimal point inside a token.
    func testVersionNumberIsNotClippedAtDecimalPoint() {
        let label = HoverViewModel.plainLabelForFlag(
            action: .selfExtend,
            reasoningPlain: "The worker finished shipping v0.8.3 about 25s ago. Next: signing."
        )
        XCTAssertTrue(label.contains("v0.8.3"),
                      "version must survive the first-sentence split; got: \(label)")
        XCTAssertFalse(label.hasSuffix("v0"),
                       "label must not clip to 'v0'; got: \(label)")
    }

    /// First sentence ends at ". " (period + space), not at a decimal.
    func testFirstSentenceSplitsOnPeriodSpace() {
        let label = HoverViewModel.plainLabelForFlag(
            action: .pause,
            reasoningPlain: "Paused Claude Code. It needs your attention."
        )
        XCTAssertEqual(label, "Paused Claude Code")
    }

    /// No ". " in the text means the whole string is the first sentence
    /// (subject to the 60-char cap).
    func testNoSentenceBoundaryKeepsWholeString() {
        let label = HoverViewModel.plainLabelForFlag(
            action: .inject,
            reasoningPlain: "Answered a question for the worker"
        )
        XCTAssertEqual(label, "Answered a question for the worker")
    }

    /// Long first sentences are capped with an ellipsis.
    func testLongFirstSentenceIsCapped() {
        let long = String(repeating: "x", count: 100)
        let label = HoverViewModel.plainLabelForFlag(action: .continue, reasoningPlain: long)
        XCTAssertEqual(label.count, 60)            // 57 + "..."
        XCTAssertTrue(label.hasSuffix("..."))
    }

    /// Empty reasoning falls back to the per-action generic label.
    func testEmptyReasoningUsesGenericLabel() {
        let label = HoverViewModel.plainLabelForFlag(action: .pause, reasoningPlain: nil)
        XCTAssertEqual(label, "Paused Claude Code. Needs your attention.")
    }
}
