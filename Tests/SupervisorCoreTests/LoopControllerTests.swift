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
        maxLoopDuration: TimeInterval = LoopController.defaultMaxLoopDuration
    ) -> LoopController {
        LoopController(
            maxLoopDuration: maxLoopDuration,
            consecutiveLowThreshold: consecutiveLowThreshold,
            now: { clock.now },
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("loop-tests-\(UUID().uuidString).log"))
        )
    }

    private func readyHigh() -> DispatchResult {
        .ready(
            prompt: "Pick up Issue #7. Do X. Stop at 75min per §12.",
            justification: "Clear scope grounded in §2e.",
            confidence: .high,
            selectedPath: .transitionToIssue,
            selectedIssueNumber: 7,
            priorDispatchesEchoed: 0
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
        XCTAssertTrue(reason.contains("three_consecutive_low_confidence"),
                      "stop reason must name the trigger")

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
}
