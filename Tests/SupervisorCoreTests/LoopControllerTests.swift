// LoopControllerTests.swift
//
// v0.4.0 Part C — tests for the extended §12 hard-stop state
// machine. Pure unit tests against the actor; no LLM, no SQLite, no
// engine wiring. Each hard-stop trigger gets its own test so a
// regression on any one of them is visible.

import XCTest
@testable import SupervisorCore

final class LoopControllerTests: XCTestCase {

    // MARK: - Helpers

    /// Build a fast-forward clock so the 4-hour test doesn't take 4 hours.
    private final class ClockHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ initial: Date) { _now = initial }
        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return _now
        }
        func advance(by seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            _now = _now.addingTimeInterval(seconds)
        }
    }

    private func makeController(
        clock: ClockHolder,
        consecutiveLowThreshold: Int = LoopController.defaultConsecutiveLowThreshold,
        maxLoopDuration: TimeInterval = LoopController.defaultMaxLoopDuration,
        sessionResetIdle: TimeInterval = LoopController.defaultSessionResetIdle,
        loopStore: LoopDispatchStore? = nil
    ) -> LoopController {
        LoopController(
            maxLoopDuration: maxLoopDuration,
            sessionResetIdle: sessionResetIdle,
            consecutiveLowThreshold: consecutiveLowThreshold,
            now: { clock.now },
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("loop-tests-\(UUID().uuidString).log")),
            loopStore: loopStore
        )
    }

    private func readyHigh() -> DispatchResult {
        .ready(
            prompt: "Pick up Issue #7. Do X. Stop at 75min per §12.",
            justification: "Clear scope grounded in §2e.",
            confidence: .high,
            selectedPath: .transitionToIssue,
            selectedIssueNumber: 7,
            priorDispatchesEchoed: 0,
            requiresHumanPresence: false
        )
    }

    // MARK: - Tests

    func testFirstCanDispatchReturnsProceedWithZeroPriorDispatches() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock)

        let decision = await lc.canDispatch(sessionId: "s-1")

        guard case let .proceed(prior) = decision else {
            return XCTFail("expected .proceed, got \(decision)")
        }
        XCTAssertEqual(prior, 0, "fresh session must report zero prior dispatches")
    }

    func testRecordDispatchHighIncrementsTotalAndResetsLow() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock)

        // Two lows first to load the counter.
        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "queue empty"))
        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "still empty"))
        var snap = await lc.snapshot(sessionId: "s-1")
        XCTAssertEqual(snap?.consecutiveLowCount, 2)

        // A ready-high MUST reset the counter and increment total.
        await lc.recordDispatch(sessionId: "s-1", result: readyHigh())
        snap = await lc.snapshot(sessionId: "s-1")
        XCTAssertEqual(snap?.consecutiveLowCount, 0,
                       "ready-high resets the consecutive-low counter")
        XCTAssertEqual(snap?.totalDispatches, 3)
        XCTAssertFalse(snap?.stopped ?? true)
    }

    func testThreeConsecutiveLowConfidenceTripsHardStop() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock)

        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "1"))
        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "2"))
        // Not yet stopped after 2.
        let mid = await lc.canDispatch(sessionId: "s-1")
        if case .stopped = mid { XCTFail("must NOT stop at 2 consecutive lows") }

        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "3"))
        let final = await lc.canDispatch(sessionId: "s-1")
        guard case let .stopped(reason) = final else {
            return XCTFail("expected .stopped after 3 lows, got \(final)")
        }
        XCTAssertTrue(reason.contains("no clear next step"),
                      "stop reason must explain the trigger in plain language")

        let snap = await lc.snapshot(sessionId: "s-1")
        XCTAssertEqual(snap?.stopReason, .threeConsecutiveLow)
    }

    func testErrorResultsCountTowardThreeConsecutiveLowStop() async {
        // .error from the dispatcher is functionally a low (couldn't
        // ground a decision); the loop should treat it as consecutive-low.
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock)

        await lc.recordDispatch(sessionId: "s-1", result: .error(reasoning: "parse failed"))
        await lc.recordDispatch(sessionId: "s-1", result: .error(reasoning: "haiku 503"))
        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "empty queue"))

        let snap = await lc.snapshot(sessionId: "s-1")
        XCTAssertEqual(snap?.consecutiveLowCount, 3)
        XCTAssertEqual(snap?.stopReason, .threeConsecutiveLow,
                       "two errors + one explicit low = three consecutive-low signals → stop")
    }

    func testUserPromptPausesLoop() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock)

        await lc.notePause(sessionId: "s-1", reason: .userMessage)

        let decision = await lc.canDispatch(sessionId: "s-1")
        guard case let .paused(reason) = decision else {
            return XCTFail("expected .paused, got \(decision)")
        }
        XCTAssertEqual(reason, "user_message")
    }

    func testClearPauseRestoresProceed() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock)

        await lc.notePause(sessionId: "s-1", reason: .userMessage)
        await lc.clearPause(sessionId: "s-1")

        let decision = await lc.canDispatch(sessionId: "s-1")
        if case .paused = decision { XCTFail("clearPause must restore .proceed") }
        if case .stopped = decision { XCTFail("clearPause must not stop the loop") }
    }

    func testFourHourBudgetTripsStop() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        // Use a 1-hour budget for the test so the clock-advance is small.
        let lc = makeController(clock: clock, maxLoopDuration: 3600)

        _ = await lc.canDispatch(sessionId: "s-1")  // initialize the timer
        clock.advance(by: 3601)                     // budget +1s

        let decision = await lc.canDispatch(sessionId: "s-1")
        guard case let .stopped(reason) = decision else {
            return XCTFail("expected .stopped after budget, got \(decision)")
        }
        XCTAssertTrue(reason.contains("4-hour wall-clock budget") ||
                      reason.contains("hour"),
                      "reason should explain the budget trigger: \(reason)")
    }

    func testLongIdleGapResetsSessionAndClearsFourHourStop() async {
        // The reported case: hit the 4-hour cap, step away (sleep), come back.
        // A long idle gap makes the resume a fresh Supervisor session, so the
        // sticky four_hours_elapsed stop clears and the loop proceeds again.
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock, maxLoopDuration: 3600, sessionResetIdle: 7200)

        _ = await lc.canDispatch(sessionId: "s-1")   // init the timer
        clock.advance(by: 3601)                       // exceed the 1h budget
        if case .stopped = await lc.canDispatch(sessionId: "s-1") { /* expected */ } else {
            return XCTFail("expected .stopped after exceeding the budget")
        }

        clock.advance(by: 7200)                       // idle gap >= reset threshold
        let resumed = await lc.canDispatch(sessionId: "s-1")
        guard case .proceed = resumed else {
            return XCTFail("a long idle gap must reset the session and proceed, got \(resumed)")
        }
        let snap = await lc.snapshot(sessionId: "s-1")
        XCTAssertEqual(snap?.stopped, false, "fresh session must clear the stop")
        XCTAssertNil(snap?.stopReason)
        XCTAssertEqual(snap?.totalDispatches, 0, "fresh session restarts the dispatch budget")
    }

    func testShortGapDoesNotResetAStoppedSession() async {
        // A break shorter than the reset threshold must NOT un-stick a
        // legitimately-hit 4-hour stop (runaway protection still holds during
        // continuous work).
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock, maxLoopDuration: 3600, sessionResetIdle: 7200)

        _ = await lc.canDispatch(sessionId: "s-1")
        clock.advance(by: 3601)
        _ = await lc.canDispatch(sessionId: "s-1")    // -> stopped
        clock.advance(by: 600)                         // 10 min, below threshold
        if case .stopped = await lc.canDispatch(sessionId: "s-1") { /* expected */ } else {
            XCTFail("a short gap must NOT reset a stopped session")
        }
    }

    func testExplicitStopKillFiredSticks() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock)

        await lc.stop(sessionId: "s-1", reason: .killFired)

        let decision = await lc.canDispatch(sessionId: "s-1")
        if case .stopped = decision { /* ok */ } else {
            XCTFail("kill stop must register, got \(decision)")
        }
        let snap = await lc.snapshot(sessionId: "s-1")
        XCTAssertEqual(snap?.stopReason, .killFired)
    }

    func testStoredLoopDispatchRowMappingForEachResult() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let ready = TriageEngine.storedLoopDispatchRow(
            sessionId: "s-1",
            result: readyHigh(),
            priorDispatchesConsidered: 2,
            ts: ts
        )
        XCTAssertEqual(ready.responseShape, "ready")
        XCTAssertEqual(ready.confidence, "high")
        XCTAssertEqual(ready.selectedPath, "transition_to_issue")
        XCTAssertEqual(ready.selectedIssueNumber, 7)
        XCTAssertEqual(ready.priorDispatchesConsidered, 2)
        XCTAssertFalse(ready.taskProposalHead.isEmpty)

        let low = TriageEngine.storedLoopDispatchRow(
            sessionId: "s-1",
            result: .lowConfidence(reasoning: "queue empty"),
            priorDispatchesConsidered: 5,
            ts: ts
        )
        XCTAssertEqual(low.responseShape, "lowConfidence")
        XCTAssertEqual(low.confidence, "low")
        XCTAssertEqual(low.selectedPath, "low_confidence_no_action")
        XCTAssertEqual(low.justification, "queue empty")

        let err = TriageEngine.storedLoopDispatchRow(
            sessionId: "s-1",
            result: .error(reasoning: "Haiku 503"),
            priorDispatchesConsidered: 1,
            ts: ts
        )
        XCTAssertEqual(err.responseShape, "error")
        XCTAssertNil(err.confidence)
        XCTAssertNil(err.selectedPath)
        XCTAssertEqual(err.justification, "Haiku 503")
    }

    func testSeedOnRestartPicksUpTotalFromStore() async throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop-seed-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let db = try SupervisorDatabase(path: tmpURL)
        let store = LoopDispatchStore(database: db)

        // Insert a session row (FK) and 5 dispatch rows.
        let session = StoredSession(
            id: "s-seed",
            projectHash: "-tmp",
            cwd: "/tmp",
            startedAt: Date(),
            lastSeenAt: Date(),
            jsonlPath: "/tmp/x.jsonl"
        )
        try await db.queue.write { conn in try session.insert(conn) }
        for i in 0..<5 {
            try store.insert(StoredLoopDispatch(
                sessionId: "s-seed",
                ts: Date().addingTimeInterval(Double(i)),
                responseShape: "ready",
                confidence: "high",
                selectedPath: "continue_branch",
                taskProposalHead: "dispatch \(i)"
            ))
        }

        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock, loopStore: store)

        let decision = await lc.canDispatch(sessionId: "s-seed")
        guard case let .proceed(prior) = decision else {
            return XCTFail("expected .proceed, got \(decision)")
        }
        XCTAssertEqual(prior, 5,
                       "seeded controller must report 5 prior dispatches from store")
    }

    func testUnstoredSessionReturnZeroEvenWithStore() async throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop-noseed-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let db = try SupervisorDatabase(path: tmpURL)
        let store = LoopDispatchStore(database: db)

        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock, loopStore: store)

        let decision = await lc.canDispatch(sessionId: "s-new")
        guard case let .proceed(prior) = decision else {
            return XCTFail("expected .proceed, got \(decision)")
        }
        XCTAssertEqual(prior, 0,
                       "session with no store rows must report zero")
    }

    /// Loop_dispatches table actually exists after migration v3 — a
    /// minimal smoke test that the schema isn't drifted.
    func testLoopDispatchesTableExistsAfterMigration() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop-dispatches-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let db = try SupervisorDatabase(path: tmpURL)
        let store = LoopDispatchStore(database: db)

        // Insert a session row first (FK).
        let session = StoredSession(
            id: "s-mig",
            projectHash: "-tmp",
            cwd: "/tmp",
            startedAt: Date(),
            lastSeenAt: Date(),
            jsonlPath: "/tmp/x.jsonl"
        )
        try db.queue.write { conn in try session.insert(conn) }

        try store.insert(StoredLoopDispatch(
            sessionId: "s-mig",
            ts: Date(),
            responseShape: "ready",
            confidence: "high",
            selectedPath: "continue_branch",
            taskProposalHead: "test row"
        ))

        let rows = try store.recent(sessionId: "s-mig")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.responseShape, "ready")
        XCTAssertEqual(rows.first?.confidence, "high")
        XCTAssertEqual(rows.first?.taskProposalHead, "test row")

        let count = try store.count(sessionId: "s-mig")
        XCTAssertEqual(count, 1)
    }

    // MARK: - clearConsecutiveLowStop

    func testClearConsecutiveLowStopResumesLoop() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock, consecutiveLowThreshold: 3)

        // Initialize + trigger 3 consecutive lows to stop.
        _ = await lc.canDispatch(sessionId: "s-1")
        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "a"))
        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "b"))
        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "c"))

        // Verify stopped.
        let stopped = await lc.canDispatch(sessionId: "s-1")
        guard case .stopped = stopped else {
            return XCTFail("expected stopped, got \(stopped)")
        }

        // Clear the stop.
        await lc.clearConsecutiveLowStop(sessionId: "s-1")

        // Verify loop can proceed again.
        let resumed = await lc.canDispatch(sessionId: "s-1")
        guard case .proceed = resumed else {
            return XCTFail("expected proceed after clear, got \(resumed)")
        }

        // Verify consecutive_low was reset.
        let snap = await lc.snapshot(sessionId: "s-1")
        XCTAssertEqual(snap?.consecutiveLowCount, 0)
        XCTAssertFalse(snap?.stopped ?? true)
    }

    func testClearConsecutiveLowDoesNotClearKillStop() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock)

        _ = await lc.canDispatch(sessionId: "s-1")
        await lc.stop(sessionId: "s-1", reason: .killFired)

        // Try to clear — should be a no-op for kill stops.
        await lc.clearConsecutiveLowStop(sessionId: "s-1")

        let decision = await lc.canDispatch(sessionId: "s-1")
        guard case .stopped = decision else {
            return XCTFail("kill stop must persist after clear attempt, got \(decision)")
        }
        let snap = await lc.snapshot(sessionId: "s-1")
        XCTAssertEqual(snap?.stopReason, .killFired)
    }

    func testClearConsecutiveLowDoesNotClearFourHourStop() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock, maxLoopDuration: 3600)

        _ = await lc.canDispatch(sessionId: "s-1")
        clock.advance(by: 3601)
        _ = await lc.canDispatch(sessionId: "s-1")

        // Try to clear — should be a no-op for 4-hour stops.
        await lc.clearConsecutiveLowStop(sessionId: "s-1")

        let decision = await lc.canDispatch(sessionId: "s-1")
        guard case .stopped = decision else {
            return XCTFail("4-hour stop must persist after clear attempt, got \(decision)")
        }
    }

    /// Simulates the v0.8.0 idle-detection flow: after a three-consecutive-low
    /// stop, the next idle evaluation calls clearConsecutiveLowStop before
    /// canDispatch, so the loop resumes instead of staying stuck.
    func testIdleDetectionClearsThreeLowStopBeforeCanDispatch() async {
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_700_000_000))
        let lc = makeController(clock: clock, consecutiveLowThreshold: 3)

        // Trigger the stop.
        _ = await lc.canDispatch(sessionId: "s-1")
        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "a"))
        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "b"))
        await lc.recordDispatch(sessionId: "s-1", result: .lowConfidence(reasoning: "c"))

        // Confirm stopped.
        let stopped = await lc.canDispatch(sessionId: "s-1")
        guard case .stopped = stopped else {
            return XCTFail("expected stopped, got \(stopped)")
        }

        // Simulate what TriageEngine.evaluateIdle now does:
        // clear the consecutive-low stop, then call canDispatch.
        await lc.clearConsecutiveLowStop(sessionId: "s-1")
        let afterClear = await lc.canDispatch(sessionId: "s-1")
        guard case .proceed = afterClear else {
            return XCTFail("expected proceed after idle-detection clear, got \(afterClear)")
        }
    }
}
