// StallClassifierTests.swift - v0.2.0 observability (Reddit feedback B).
//
// The stall failure-mode classifier is a PURE function over the
// AsyncWorkScanner's signals, so every branch is asserted with literal Scans.
// We also exercise the scanner end (classify over fixture transcript lines)
// to confirm the PART B signals are actually extracted from real-shaped JSONL.

import XCTest
@testable import SupervisorCore

final class StallClassifierTests: XCTestCase {

    private let classifier = StallClassifier()

    private func scan(
        outstanding: Bool = true,
        launchCount: Int = 1,
        unpaired: Int = 1,
        subAgent: Bool = false,
        awaitingInput: Bool = false,
        rateLimit: Bool = false,
        crash: Bool = false
    ) -> AsyncWorkScanner.Scan {
        AsyncWorkScanner.Scan(
            outstanding: outstanding, launchCount: launchCount, unpairedCount: unpaired,
            observedModel: nil, lastOutstandingIsSubAgent: subAgent,
            awaitingInputSignal: awaitingInput, rateLimitSignal: rateLimit, crashSignal: crash
        )
    }

    // MARK: - Precedence

    func testCrashWinsOverEverything() {
        let s = scan(subAgent: true, awaitingInput: true, rateLimit: true, crash: true)
        XCTAssertEqual(classifier.classify(scan: s), .crashed)
    }

    func testRateLimitedWhenNoCrash() {
        let s = scan(subAgent: true, awaitingInput: true, rateLimit: true, crash: false)
        XCTAssertEqual(classifier.classify(scan: s), .rateLimited)
    }

    func testAwaitingInputWhenNoCrashOrRateLimit() {
        let s = scan(subAgent: true, awaitingInput: true, rateLimit: false, crash: false)
        XCTAssertEqual(classifier.classify(scan: s), .awaitingInput)
    }

    func testSubAgentFanoutWhenLastOutstandingIsSubAgent() {
        let s = scan(subAgent: true)
        XCTAssertEqual(classifier.classify(scan: s), .subAgentFanout)
    }

    func testBgTaskSilentIsTheDefaultLabelledCase() {
        let s = scan(subAgent: false)
        XCTAssertEqual(classifier.classify(scan: s), .bgTaskSilent)
    }

    func testBgTaskSilentEvenIfNotOutstandingButLaunchesSeen() {
        // launchCount > 0 still labels bgTaskSilent (the watchdog only calls this
        // when it has decided to nudge, i.e. there IS outstanding work).
        let s = scan(outstanding: false, launchCount: 2, unpaired: 0)
        XCTAssertEqual(classifier.classify(scan: s), .bgTaskSilent)
    }

    func testUnknownWhenNothingOutstandingAndNoLaunches() {
        let s = scan(outstanding: false, launchCount: 0, unpaired: 0)
        XCTAssertEqual(classifier.classify(scan: s), .unknown)
    }

    func testEveryCaseHasAHumanReason() {
        for c in StallClassification.allCases {
            XCTAssertFalse(c.humanReason.isEmpty, "\(c) must have a human reason for the audit summary")
        }
    }

    // MARK: - Scanner signal extraction (the source of the classifier's inputs)

    func testScannerExtractsRateLimitMarkerFromToolResult() {
        let lines = [
            assistantBgBash(id: "t1", ts: "2026-06-27T10:00:00.000Z"),
            toolResult(id: "t1", ts: "2026-06-27T10:00:05.000Z", text: "Error 429: rate limit exceeded, retry later"),
        ]
        let s = AsyncWorkScanner.classify(lines: lines, now: iso("2026-06-27T10:10:00.000Z"), lookbackSeconds: 4 * 3600)
        XCTAssertTrue(s.rateLimitSignal)
        XCTAssertEqual(classifier.classify(scan: s), .rateLimited)
    }

    func testScannerExtractsCrashMarkerFromToolResult() {
        let lines = [
            assistantBgBash(id: "t1", ts: "2026-06-27T10:00:00.000Z"),
            toolResult(id: "t1", ts: "2026-06-27T10:00:05.000Z", text: "worker.py: Segmentation fault (core dumped)"),
        ]
        let s = AsyncWorkScanner.classify(lines: lines, now: iso("2026-06-27T10:10:00.000Z"), lookbackSeconds: 4 * 3600)
        XCTAssertTrue(s.crashSignal)
        XCTAssertEqual(classifier.classify(scan: s), .crashed)
    }

    func testScannerDetectsAwaitingInputOnTrailingQuestion() {
        // A sub-agent launched, then the assistant ended on a question with no
        // user reply: the stall is an input wait, not a dead sub-agent.
        let lines = [
            assistantSubAgent(id: "t1", ts: "2026-06-27T10:00:00.000Z"),
            assistantText(ts: "2026-06-27T10:00:30.000Z", text: "Which database should I use, Postgres or SQLite?"),
        ]
        let s = AsyncWorkScanner.classify(lines: lines, now: iso("2026-06-27T10:10:00.000Z"), lookbackSeconds: 4 * 3600)
        XCTAssertTrue(s.awaitingInputSignal)
        XCTAssertEqual(classifier.classify(scan: s), .awaitingInput)
    }

    func testScannerFlagsSubAgentAsLastOutstanding() {
        let lines = [
            assistantSubAgent(id: "t1", ts: "2026-06-27T10:00:00.000Z"),
        ]
        let s = AsyncWorkScanner.classify(lines: lines, now: iso("2026-06-27T10:05:00.000Z"), lookbackSeconds: 4 * 3600)
        XCTAssertTrue(s.outstanding)
        XCTAssertTrue(s.lastOutstandingIsSubAgent)
        XCTAssertEqual(classifier.classify(scan: s), .subAgentFanout)
    }

    func testScannerBackgroundBashIsBgTaskSilentNotSubAgent() {
        let lines = [
            assistantBgBash(id: "t1", ts: "2026-06-27T10:00:00.000Z"),
        ]
        let s = AsyncWorkScanner.classify(lines: lines, now: iso("2026-06-27T10:05:00.000Z"), lookbackSeconds: 4 * 3600)
        XCTAssertTrue(s.outstanding)
        XCTAssertFalse(s.lastOutstandingIsSubAgent)
        XCTAssertEqual(classifier.classify(scan: s), .bgTaskSilent)
    }

    // MARK: - Fixture builders (mirror the real Claude Code JSONL shape)

    private func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? Date()
    }

    private func assistantBgBash(id: String, ts: String) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"claude","content":[{"type":"tool_use","id":"\(id)","name":"Bash","input":{"command":"./long.sh","run_in_background":true}}]}}
        """
    }

    private func assistantSubAgent(id: String, ts: String) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"claude","content":[{"type":"tool_use","id":"\(id)","name":"Task","input":{"description":"do work"}}]}}
        """
    }

    private func assistantText(ts: String, text: String) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"claude","content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func toolResult(id: String, ts: String, text: String) -> String {
        """
        {"type":"user","timestamp":"\(ts)","message":{"content":[{"type":"tool_result","tool_use_id":"\(id)","content":"\(text)"}]}}
        """
    }
}
