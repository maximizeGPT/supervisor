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

    /// First sentence is taken whole (including its terminating period),
    /// and the second sentence is dropped.
    func testFirstSentenceOnly() {
        let label = HoverViewModel.plainLabelForFlag(
            action: .pause,
            reasoningPlain: "Paused Claude Code. It needs your attention."
        )
        XCTAssertEqual(label, "Paused Claude Code.")
    }

    /// Abbreviations like "e.g." must not be treated as sentence ends.
    func testAbbreviationDoesNotSplit() {
        let label = HoverViewModel.plainLabelForFlag(
            action: .continue,
            reasoningPlain: "Run e.g. the calibration sweep next. Then report."
        )
        XCTAssertTrue(label.contains("e.g. the calibration sweep"),
                      "abbreviation must not split the sentence; got: \(label)")
    }

    /// File paths with dots must not split the sentence.
    func testFilePathDoesNotSplit() {
        let label = HoverViewModel.plainLabelForFlag(
            action: .inject,
            reasoningPlain: "Edited config.yaml in the repo. Rebuilt after."
        )
        XCTAssertTrue(label.contains("config.yaml in the repo"),
                      "file path must not split the sentence; got: \(label)")
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

    // MARK: - Degraded state (P0-3)

    private func makeVM() -> HoverViewModel {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-label-\(UUID()).log"))
        return HoverViewModel(bus: EventBus(trace: trace), trace: trace)
    }

    /// The core honesty mapping: `.degraded`'s reason IS the hover label —
    /// never "Watching. All clear" while the engine can't reach its model.
    func testEnterDegradedSetsActivityAndReasonAsLabel() {
        let vm = makeVM()
        vm.enterDegraded(reason: "Can't reach Anthropic — check your API key")
        XCTAssertEqual(vm.activity, .degraded(reason: "Can't reach Anthropic — check your API key"))
        XCTAssertEqual(vm.plainLabel, "Can't reach Anthropic — check your API key")
        XCTAssertEqual(vm.detailLabel, "")
    }

    /// A retry attempt must not flash "Checking something..." over the
    /// degraded state — that reads as recovered when it isn't. The state
    /// holds until a call actually succeeds.
    func testTriageStartedHoldsDegradedState() {
        let vm = makeVM()
        vm.enterDegraded(reason: "Can't reach Anthropic")
        vm.triageStarted()
        XCTAssertEqual(vm.activity, .degraded(reason: "Can't reach Anthropic"))
        XCTAssertEqual(vm.plainLabel, "Can't reach Anthropic")
    }

    /// A successful (no-flag) triage batch is the recovery signal: idle
    /// activity, "All clear" label, no residue.
    func testTriageFinishedNoFlagClearsDegraded() {
        let vm = makeVM()
        vm.enterDegraded(reason: "Can't reach Anthropic")
        vm.triageFinishedNoFlag()
        XCTAssertEqual(vm.activity, .idle)
        XCTAssertEqual(vm.plainLabel, "Watching. All clear")
        // And triageStarted works normally again (no stale degraded hold).
        vm.triageStarted()
        XCTAssertEqual(vm.activity, .triaging)
    }

    /// A deterministic-catch flag can fire WHILE degraded (the catch-list
    /// needs no model). Its acknowledge must settle back to the amber
    /// degraded state, never to a green "All clear" the engine can't back up.
    func testAcknowledgeFlagSettlesBackToDegradedNotAllClear() {
        let vm = makeVM()
        vm.enterDegraded(reason: "Paused at your $5.00 daily cap")
        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: "About to delete things.")
        vm.acknowledgeFlag()
        XCTAssertEqual(vm.activity, .degraded(reason: "Paused at your $5.00 daily cap"))
        XCTAssertEqual(vm.plainLabel, "Paused at your $5.00 daily cap")
    }

    /// The engine's recovery hook (clearDegraded) restores idle silently.
    func testClearDegradedRestoresIdle() {
        let vm = makeVM()
        vm.enterDegraded(reason: "Can't reach DeepSeek")
        vm.clearDegraded()
        XCTAssertEqual(vm.activity, .idle)
        XCTAssertEqual(vm.plainLabel, "Watching. All clear")
        // Idempotent when not degraded.
        vm.clearDegraded()
        XCTAssertEqual(vm.activity, .idle)
    }

    // MARK: - Paused-state honesty (F11)

    /// The core honesty mapping: paused says "Supervisor paused", never
    /// "All clear", and paints the amber (.degraded) presentation — a green
    /// dot over a dormant engine would be the product lying.
    func testPausedSetsLabelAndAmberDotNotAllClear() {
        let vm = makeVM()
        vm.reflectSupervisorPaused(true)
        XCTAssertEqual(vm.plainLabel, HoverViewModel.pausedLabel)
        XCTAssertNotEqual(vm.plainLabel, "Watching. All clear")
        XCTAssertEqual(vm.activity, .degraded(reason: HoverViewModel.pausedLabel))
    }

    /// Un-pausing restores the green "All clear" idle state.
    func testUnpauseRestoresAllClear() {
        let vm = makeVM()
        vm.reflectSupervisorPaused(true)
        vm.reflectSupervisorPaused(false)
        XCTAssertEqual(vm.activity, .idle)
        XCTAssertEqual(vm.plainLabel, "Watching. All clear")
    }

    /// Precedence: a genuine network-degraded state ("can't watch") is a more
    /// urgent truth than "paused" — paused must not overwrite it.
    func testNetworkDegradedOutranksPaused() {
        let vm = makeVM()
        vm.enterDegraded(reason: "Can't reach Anthropic")
        vm.reflectSupervisorPaused(true)
        XCTAssertEqual(vm.plainLabel, "Can't reach Anthropic")
        XCTAssertEqual(vm.activity, .degraded(reason: "Can't reach Anthropic"))
    }

    /// Precedence: a live safety flag outranks paused — pausing must not stomp
    /// an active "about to delete things" flag.
    func testSafetyFlagOutranksPaused() {
        let vm = makeVM()
        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: "About to delete things.")
        vm.reflectSupervisorPaused(true)
        guard case .flagged = vm.activity else {
            return XCTFail("paused must not overwrite a live flag; got \(vm.activity)")
        }
    }
}
