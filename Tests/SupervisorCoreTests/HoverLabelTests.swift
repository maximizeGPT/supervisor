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

    // MARK: - Flagged label survives background bus events (RC fix #2)

    private func makeVM() -> (HoverViewModel, EventBus) {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-label-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        return (HoverViewModel(bus: bus, trace: trace), bus)
    }

    /// A background `.bashToolCall` fires constantly on a busy session. It must
    /// NOT repaint "Running a command" over a live paused/degraded (flagged)
    /// headline — the flag owns the hover until resolved. The tool-call counter
    /// still increments (it is unconditional).
    func testPausedLabelSurvivesBashToolCallEvent() async {
        let (vm, bus) = makeVM()
        vm.flagRaised(severity: .high, action: .pause,
                      reasoningPlain: "Can't reach Anthropic. Paused Claude Code.")
        let pausedLabel = vm.plainLabel
        XCTAssertTrue(vm.isPaused)

        bus.publish(.bashToolCall(BashToolCallInfo(
            sessionId: "s1", command: "ls -la", description: nil,
            toolUseId: "t1", turnUUID: "u1", ts: Date()
        )))
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(vm.plainLabel, pausedLabel,
            "a bashToolCall must not overwrite a paused/flagged headline")
        XCTAssertEqual(vm.toolCallCount, 1,
            "the tool-call counter must still increment while flagged")
    }

    /// A `.sessionStart` for a DIFFERENT session must not clear/mask a still
    /// paused session's headline, and the pause stays pinned to its own session
    /// (RC fix #3).
    func testNewSessionDoesNotMaskPausedLabel() async {
        let (vm, bus) = makeVM()
        // Session A starts, then pauses.
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "A", cwd: "/Users/main/a", gitBranch: nil,
            projectHash: "h", jsonlPath: "/tmp/a.jsonl", ts: Date()
        )))
        try? await Task.sleep(nanoseconds: 60_000_000)
        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: "Paused A.")
        let pausedLabel = vm.plainLabel

        // Session B starts while A is still paused.
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "B", cwd: "/Users/main/b", gitBranch: nil,
            projectHash: "h", jsonlPath: "/tmp/b.jsonl", ts: Date()
        )))
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(vm.plainLabel, pausedLabel,
            "a new session must not repaint the paused headline to idle")
        XCTAssertTrue(vm.isPaused, "the pause must survive a different session's start")
        XCTAssertEqual(vm.pausedSessionId, "A", "the pause stays pinned to session A")
        XCTAssertEqual(vm.pausedSessionCwd, "/Users/main/a",
            "resume must target the PAUSED session's cwd, not the latest session's")
    }

    /// Finding 5 (HIGH): the pause must pin the session the ENGINE flagged, even
    /// when a DIFFERENT session started most recently. Ordering that reproduces
    /// the wrong-action bug: A starts, then B starts (so `currentSessionId == B`),
    /// THEN the engine raises a pause for A. Before the fix `flagRaised` pinned
    /// `currentSessionId` (= B), so Resume sent SIGCONT to B (never stopped) while
    /// A stayed SIGSTOP'd with no working Resume. The engine now threads A's
    /// identity into `flagRaised`, so the pin — and the resume target — is A.
    func testPauseFlagPinsFlaggedSessionNotLatestStarted() async {
        let (vm, bus) = makeVM()

        // Session A starts.
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "A", cwd: "/Users/main/a", gitBranch: nil,
            projectHash: "h", jsonlPath: "/tmp/a.jsonl", ts: Date()
        )))
        try? await Task.sleep(nanoseconds: 60_000_000)

        // Session B starts LATER, so it is now the most-recently-started session.
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "B", cwd: "/Users/main/b", gitBranch: nil,
            projectHash: "h", jsonlPath: "/tmp/b.jsonl", ts: Date()
        )))
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(vm.currentSessionId, "B",
            "precondition: B is the most-recently-started session")

        // The engine flags a PAUSE for the OLDER session A, threading A's identity
        // (this is exactly what the TriageEngine call sites now supply).
        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: "Paused A.",
                      flaggedSessionId: "A", flaggedSessionCwd: "/Users/main/a")

        XCTAssertTrue(vm.isPaused)
        XCTAssertEqual(vm.pausedSessionId, "A",
            "the pause must pin the FLAGGED session A, not the last-started B")
        XCTAssertEqual(vm.pausedSessionCwd, "/Users/main/a",
            "the pinned cwd must be A's, not B's")

        // Resume must drive session A (its cwd), not B.
        var resumedCwd: String?
        vm.resumeHandler = { cwd in
            resumedCwd = cwd
            return true
        }
        vm.resumePausedSession()
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(resumedCwd, "/Users/main/a",
            "Resume must SIGCONT the paused session A, never the never-stopped B")
    }
}
