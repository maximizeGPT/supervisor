// StallWatchdogTests.swift
//
// v0.2.0 M7 - the background-task / stall watchdog. Pure-layer tests for the
// three units that have no I/O:
//
//   1. StallWatchdog (pure decision): .ok / .checkIn / .escalate over the
//      observed per-session signals, at and across the interval, with the
//      documented precedence (not-stalled > already-escalated-hold > check-in >
//      escalate). nudgeCount gates check-in vs. escalate; movement (modeled here
//      as nudgeCount reset by the caller) re-opens check-in.
//   2. WatchdogPolicy (pure): default 30m, per-model overrides by family
//      substring, nil/unknown -> default. Model-awareness is honored.
//   3. AsyncWorkScanner.classify (pure over transcript lines): a background Bash
//      and a sub-agent launch are detected; an unpaired launch is outstanding; a
//      paired-and-then-progressed launch is NOT; the opportunistic model id is
//      read.
//
// No network, no files - classify() is fed JSONL lines directly. The engine-level
// wiring (gating, marked+ledgered nudge, suppression, escalation) is covered in
// StallWatchdogEngineTests.

import XCTest
@testable import SupervisorCore

final class StallWatchdogTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - StallWatchdog (pure decision)

    /// Outstanding async work + silence past the interval, no nudges yet -> checkIn.
    func testStallFiresCheckInAfterIntervalWithOutstandingWork() {
        let wd = StallWatchdog()
        let signals = WatchdogSignals(
            lastActivityTime: t0, asyncWorkOutstanding: true,
            nudgeCount: 0, escalatedStopped: false)
        // 31 minutes of silence, 30m interval.
        let decision = wd.assess(signals: signals, now: t0.addingTimeInterval(31 * 60), interval: 30 * 60)
        guard case .checkIn = decision else { return XCTFail("expected .checkIn, got \(decision)") }
    }

    /// Below the interval -> ok, even with outstanding work.
    func testNoFireBeforeInterval() {
        let wd = StallWatchdog()
        let signals = WatchdogSignals(
            lastActivityTime: t0, asyncWorkOutstanding: true,
            nudgeCount: 0, escalatedStopped: false)
        let decision = wd.assess(signals: signals, now: t0.addingTimeInterval(29 * 60), interval: 30 * 60)
        XCTAssertEqual(decision, .ok, "29m < 30m interval: not stalled yet")
    }

    /// Exactly at the interval boundary -> fires (>=).
    func testFiresExactlyAtInterval() {
        let wd = StallWatchdog()
        let signals = WatchdogSignals(
            lastActivityTime: t0, asyncWorkOutstanding: true,
            nudgeCount: 0, escalatedStopped: false)
        let decision = wd.assess(signals: signals, now: t0.addingTimeInterval(30 * 60), interval: 30 * 60)
        guard case .checkIn = decision else { return XCTFail("expected .checkIn at the boundary, got \(decision)") }
    }

    /// No outstanding async work -> ok regardless of how long the silence is. The
    /// watchdog never fires on a healthy session that simply finished.
    func testNoFireWithoutOutstandingWork() {
        let wd = StallWatchdog()
        let signals = WatchdogSignals(
            lastActivityTime: t0, asyncWorkOutstanding: false,
            nudgeCount: 0, escalatedStopped: false)
        let decision = wd.assess(signals: signals, now: t0.addingTimeInterval(10 * 60 * 60), interval: 30 * 60)
        XCTAssertEqual(decision, .ok, "no async work outstanding: nothing to nudge")
    }

    /// nudgeCount climbs 0,1,2 -> checkIn each time; at 3 (the cap) -> escalate.
    func testThreeNudgesThenEscalate() {
        let wd = StallWatchdog()  // default maxNudges = 3
        let now = t0.addingTimeInterval(60 * 60)
        for n in 0..<3 {
            let s = WatchdogSignals(lastActivityTime: t0, asyncWorkOutstanding: true, nudgeCount: n, escalatedStopped: false)
            guard case .checkIn = wd.assess(signals: s, now: now, interval: 30 * 60) else {
                return XCTFail("nudge \(n) should be .checkIn")
            }
        }
        let atCap = WatchdogSignals(lastActivityTime: t0, asyncWorkOutstanding: true, nudgeCount: 3, escalatedStopped: false)
        guard case .escalate = wd.assess(signals: atCap, now: now, interval: 30 * 60) else {
            return XCTFail("at nudgeCount == maxNudges the verdict must be .escalate")
        }
    }

    /// Once escalated (escalatedStopped == true), the verdict is .ok (the hold) -
    /// no second escalate, no further nudges - until movement clears the flag.
    func testEscalatedStateHoldsNoFurtherFire() {
        let wd = StallWatchdog()
        let s = WatchdogSignals(lastActivityTime: t0, asyncWorkOutstanding: true, nudgeCount: 5, escalatedStopped: true)
        XCTAssertEqual(wd.assess(signals: s, now: t0.addingTimeInterval(60 * 60), interval: 30 * 60), .ok,
                       "an already-escalated stall holds (no repeat notify)")
    }

    /// Movement resets nudgeCount (modeled by the caller): a reset-to-0 stall
    /// re-opens with .checkIn rather than staying escalated.
    func testMovementResetReopensCheckIn() {
        let wd = StallWatchdog()
        // After movement the engine sets nudgeCount=0 + escalatedStopped=false.
        let reset = WatchdogSignals(lastActivityTime: t0.addingTimeInterval(40 * 60), asyncWorkOutstanding: true, nudgeCount: 0, escalatedStopped: false)
        // New stall window from the new activity time.
        let decision = wd.assess(signals: reset, now: t0.addingTimeInterval(40 * 60 + 31 * 60), interval: 30 * 60)
        guard case .checkIn = decision else { return XCTFail("after a movement reset the cycle re-opens at .checkIn") }
    }

    /// A custom (smaller) cap is honored.
    func testCustomMaxNudges() {
        let wd = StallWatchdog(maxNudges: 1)
        let now = t0.addingTimeInterval(60 * 60)
        guard case .checkIn = wd.assess(signals: .init(lastActivityTime: t0, asyncWorkOutstanding: true, nudgeCount: 0, escalatedStopped: false), now: now, interval: 30 * 60) else {
            return XCTFail("nudge 0 should be .checkIn")
        }
        guard case .escalate = wd.assess(signals: .init(lastActivityTime: t0, asyncWorkOutstanding: true, nudgeCount: 1, escalatedStopped: false), now: now, interval: 30 * 60) else {
            return XCTFail("with maxNudges=1, nudgeCount 1 escalates")
        }
    }

    // MARK: - WatchdogPolicy (model-aware interval)

    func testPolicyDefaultIs30Minutes() {
        let p = WatchdogPolicy()
        XCTAssertEqual(p.interval(forModel: nil), 30 * 60, "nil model -> 30m default")
        XCTAssertEqual(p.interval(forModel: ""), 30 * 60, "empty model -> 30m default")
        XCTAssertEqual(p.interval(forModel: "some-unknown-model"), 30 * 60, "unrecognized -> 30m default")
    }

    func testPolicyModelAwareOverrides() {
        let p = WatchdogPolicy()
        // Family substring matching, any build of the family.
        XCTAssertEqual(p.interval(forModel: "claude-haiku-4-5-20251001"), 20 * 60, "haiku family -> 20m")
        XCTAssertEqual(p.interval(forModel: "claude-sonnet-4-5"), 30 * 60, "sonnet family -> 30m")
        XCTAssertEqual(p.interval(forModel: "claude-opus-4-8"), 45 * 60, "opus family -> 45m")
        XCTAssertEqual(p.interval(forModel: "CLAUDE-OPUS-4-1-20250805"), 45 * 60, "matching is case-insensitive")
    }

    func testPolicyCustomTable() {
        let p = WatchdogPolicy(defaultInterval: 10 * 60, overrides: [("kimi", TimeInterval(5 * 60))])
        XCTAssertEqual(p.interval(forModel: "kimi-k2-0905-preview"), 5 * 60, "custom override honored")
        XCTAssertEqual(p.interval(forModel: "deepseek-chat"), 10 * 60, "custom default honored")
    }

    // MARK: - AsyncWorkScanner.classify (pure over transcript lines)

    private func assistantBgBashLine(id: String, ts: String) -> String {
        let obj: [String: Any] = [
            "type": "assistant", "sessionId": "s", "uuid": "u-\(id)", "timestamp": ts,
            "message": ["model": "claude-opus-4-8", "content": [[
                "type": "tool_use", "id": id, "name": "Bash",
                "input": ["command": "sleep 9999", "run_in_background": true]]]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func assistantSubAgentLine(id: String, ts: String, name: String = "Task") -> String {
        let obj: [String: Any] = [
            "type": "assistant", "sessionId": "s", "uuid": "u-\(id)", "timestamp": ts,
            "message": ["model": "claude-opus-4-8", "content": [[
                "type": "tool_use", "id": id, "name": name,
                "input": ["description": "do a thing", "prompt": "go"]]]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func toolResultLine(id: String, ts: String) -> String {
        let obj: [String: Any] = [
            "type": "user", "sessionId": "s", "timestamp": ts,
            "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "done"]]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func assistantTextLine(ts: String) -> String {
        let obj: [String: Any] = [
            "type": "assistant", "sessionId": "s", "uuid": "u-text", "timestamp": ts,
            "message": ["model": "claude-opus-4-8", "content": [["type": "text", "text": "continuing"]]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    let lookback = AsyncWorkScanner.defaultLookbackSeconds

    /// An UNPAIRED background-Bash launch (no tool_result) is outstanding.
    func testUnpairedBackgroundBashIsOutstanding() {
        let lines = [assistantBgBashLine(id: "bg1", ts: "2026-06-26T10:00:00.000Z")]
        let scan = AsyncWorkScanner.classify(lines: lines, now: Date(), lookbackSeconds: lookback)
        XCTAssertTrue(scan.outstanding, "an unpaired background bash is outstanding")
        XCTAssertEqual(scan.launchCount, 1)
        XCTAssertEqual(scan.unpairedCount, 1)
        XCTAssertEqual(scan.observedModel, "claude-opus-4-8", "the model is read opportunistically")
    }

    /// An UNPAIRED sub-agent (Task) launch is outstanding.
    func testUnpairedSubAgentIsOutstanding() {
        let lines = [assistantSubAgentLine(id: "ta1", ts: "2026-06-26T10:00:00.000Z", name: "Task")]
        let scan = AsyncWorkScanner.classify(lines: lines, now: Date(), lookbackSeconds: lookback)
        XCTAssertTrue(scan.outstanding)
        XCTAssertEqual(scan.unpairedCount, 1)
    }

    /// "Agent" is also recognized as a sub-agent launch.
    func testAgentToolNameRecognized() {
        let lines = [assistantSubAgentLine(id: "ag1", ts: "2026-06-26T10:00:00.000Z", name: "Agent")]
        let scan = AsyncWorkScanner.classify(lines: lines, now: Date(), lookbackSeconds: lookback)
        XCTAssertTrue(scan.outstanding)
    }

    /// A launch that COMPLETED (tool_result) and was then followed by further
    /// progress (assistant text) is NOT outstanding: it is paired AND something
    /// happened after it.
    func testPairedAndProgressedIsNotOutstanding() {
        let lines = [
            assistantBgBashLine(id: "bg1", ts: "2026-06-26T10:00:00.000Z"),
            toolResultLine(id: "bg1", ts: "2026-06-26T10:00:05.000Z"),
            assistantTextLine(ts: "2026-06-26T10:00:06.000Z"),
        ]
        let scan = AsyncWorkScanner.classify(lines: lines, now: Date(), lookbackSeconds: lookback)
        XCTAssertFalse(scan.outstanding, "paired + progressed launch is done, not outstanding")
        XCTAssertEqual(scan.unpairedCount, 0)
        XCTAssertEqual(scan.launchCount, 1)
    }

    /// No async launches at all -> not outstanding (a plain text-only transcript).
    func testNoLaunchesNotOutstanding() {
        let lines = [assistantTextLine(ts: "2026-06-26T10:00:00.000Z")]
        let scan = AsyncWorkScanner.classify(lines: lines, now: Date(), lookbackSeconds: lookback)
        XCTAssertFalse(scan.outstanding)
        XCTAssertEqual(scan.launchCount, 0)
    }

    /// Heuristic-fallback arm: a background launch with NO tool_result and nothing
    /// after it (the detached-task case) is outstanding via recency even though it
    /// could not be positively paired - as long as it is within the lookback.
    func testRecencyHeuristicCatchesDetachedTask() {
        let lines = [
            assistantTextLine(ts: "2026-06-26T09:59:00.000Z"),
            assistantBgBashLine(id: "bg1", ts: "2026-06-26T10:00:00.000Z"),
            // No result, no further activity.
        ]
        let scan = AsyncWorkScanner.classify(lines: lines, now: Date(), lookbackSeconds: lookback)
        XCTAssertTrue(scan.outstanding, "a recent detached launch with nothing after it is treated as outstanding")
    }

    /// A regular (foreground) Bash is NOT a background launch and does not count.
    func testForegroundBashIsNotAsyncWork() {
        let obj: [String: Any] = [
            "type": "assistant", "sessionId": "s", "uuid": "u1", "timestamp": "2026-06-26T10:00:00.000Z",
            "message": ["model": "claude-opus-4-8", "content": [[
                "type": "tool_use", "id": "fg1", "name": "Bash",
                "input": ["command": "ls"]]]],  // no run_in_background
        ]
        let line = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        let scan = AsyncWorkScanner.classify(lines: [line], now: Date(), lookbackSeconds: lookback)
        XCTAssertFalse(scan.outstanding, "a foreground bash is not async work")
        XCTAssertEqual(scan.launchCount, 0)
    }
}
