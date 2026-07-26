// TrustScorecardTests.swift
//
// issue #60 metric 1 — the dismissal-rate scorecard. Pure-compute math over
// seeded rows plus the load path against an in-memory DB. Deterministic:
// fixed epoch timestamps, no live API, no network.

import XCTest
@testable import SupervisorCore

final class TrustScorecardTests: XCTestCase {

    /// A fixed "now" so window math never depends on wall-clock time.
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func flag(
        category: String,
        severity: FlagSeverity = .medium,
        response: FlagUserResponse? = nil,
        outcome: InterventionOutcomeKind? = nil,
        daysAgo: Double = 1
    ) -> StoredFlag {
        StoredFlag(
            sessionId: "s",
            ts: now.addingTimeInterval(-daysAgo * 86_400),
            category: category,
            severity: severity,
            action: .notify,
            reasoningPlain: "p",
            reasoningTechnical: "t",
            userResponse: response,
            interventionOutcome: outcome
        )
    }

    private func auditEntry(kind: AuditEntryKind, daysAgo: Double = 1) -> StoredAuditEntry {
        StoredAuditEntry(
            sessionId: "s",
            createdAt: now.addingTimeInterval(-daysAgo * 86_400),
            kind: kind,
            summary: "x"
        )
    }

    // MARK: - Per-category counts

    func testComputeCountsPerCategoryAndSeverity() {
        let scorecard = TrustScorecard.compute(
            flags: [
                flag(category: "destructive_action_pending", severity: .high, response: .approved),
                flag(category: "destructive_action_pending", severity: .medium, response: .dismissed),
                flag(category: "destructive_action_pending", severity: .low),
                flag(category: "fabrication", severity: .high),
            ],
            auditEntries: [],
            sinceDays: 30,
            now: now
        )

        XCTAssertEqual(scorecard.categories.map { $0.category },
                       ["destructive_action_pending", "fabrication"],
                       "highest-volume category leads")

        let destructive = scorecard.categories[0]
        XCTAssertEqual(destructive.total, 3)
        XCTAssertEqual(destructive.low, 1)
        XCTAssertEqual(destructive.medium, 1)
        XCTAssertEqual(destructive.high, 1)
        XCTAssertEqual(destructive.responses.approved, 1)
        XCTAssertEqual(destructive.responses.dismissed, 1)
        XCTAssertEqual(destructive.responses.noResponse, 1)

        let fabrication = scorecard.categories[1]
        XCTAssertEqual(fabrication.total, 1)
        XCTAssertEqual(fabrication.high, 1)
        XCTAssertEqual(fabrication.responses.noResponse, 1)

        XCTAssertEqual(scorecard.overall.total, 4)
        XCTAssertEqual(scorecard.overall.responded, 2)
    }

    func testEqualVolumeCategoriesSortByName() {
        let scorecard = TrustScorecard.compute(
            flags: [flag(category: "zeta"), flag(category: "alpha")],
            auditEntries: [],
            sinceDays: 30,
            now: now
        )
        XCTAssertEqual(scorecard.categories.map { $0.category }, ["alpha", "zeta"],
                       "ties break by name so the render is deterministic")
    }

    // MARK: - Dismissal rate

    /// The headline metric: dismissed + false-positive + rejected over the
    /// EXPLICITLY responded flags. A no-response flag widens `total` but never
    /// the rate — unresponded is unknown, not dismissed.
    func testDismissalRateCountsExplicitPushbackOnly() throws {
        let scorecard = TrustScorecard.compute(
            flags: [
                flag(category: "c", response: .approved),
                flag(category: "c", response: .dismissed),
                flag(category: "c", response: .falsePositive),
                flag(category: "c", response: .rejected),
                flag(category: "c", response: nil),
            ],
            auditEntries: [],
            sinceDays: 30,
            now: now
        )
        let counts = scorecard.overall
        XCTAssertEqual(counts.total, 5)
        XCTAssertEqual(counts.responded, 4, "no-response is excluded from responded")
        XCTAssertEqual(counts.noResponse, 1)
        let rate = try XCTUnwrap(counts.dismissalRate)
        XCTAssertEqual(rate, 0.75, accuracy: 0.0001,
                       "3 of 4 explicit responses pushed back")
    }

    func testDismissalRateIsNilWithoutExplicitResponses() {
        let scorecard = TrustScorecard.compute(
            flags: [flag(category: "c"), flag(category: "c")],
            auditEntries: [],
            sinceDays: 30,
            now: now
        )
        XCTAssertNil(scorecard.overall.dismissalRate,
                     "no explicit responses -> no rate, never 0% or 100% noise")
        XCTAssertEqual(scorecard.overall.noResponse, 2)
    }

    // MARK: - Intervention outcomes (issue #60 follow-up)

    /// Outcomes are counted per kind, ONLY over rows where one was recorded —
    /// a NULL (rows predating migration v10, or a decision that never reached
    /// the router's result hook) is unknown and lands in no bucket.
    func testComputeCountsInterventionOutcomesOnlyWhereRecorded() {
        let scorecard = TrustScorecard.compute(
            flags: [
                flag(category: "c", outcome: .injectSucceeded),
                flag(category: "c", outcome: .injectDegraded),
                flag(category: "c", outcome: .injectDegraded),
                flag(category: "c", outcome: .notifyOnly),
                flag(category: "c", outcome: nil),                      // predates the column
                flag(category: "c", outcome: .pauseSucceeded, daysAgo: 31),  // outside the window
            ],
            auditEntries: [],
            sinceDays: 30,
            now: now
        )
        XCTAssertEqual(scorecard.interventionOutcomes, [
            "inject_succeeded": 1,
            "inject_degraded": 2,
            "notify_only": 1,
        ], "NULL rows and out-of-window rows land in no bucket")
        XCTAssertEqual(scorecard.overall.total, 5,
                       "the outcome-less in-window flag still counts in the response totals")
    }

    // MARK: - Window filtering

    func testSinceWindowExcludesOlderRows() {
        let scorecard = TrustScorecard.compute(
            flags: [
                flag(category: "c", daysAgo: 1),
                flag(category: "c", daysAgo: 29.5),
                flag(category: "c", daysAgo: 31),        // outside the window
            ],
            auditEntries: [
                auditEntry(kind: .block, daysAgo: 2),
                auditEntry(kind: .block, daysAgo: 40),   // outside the window
                auditEntry(kind: .autoAnswer, daysAgo: 5),
            ],
            sinceDays: 30,
            now: now
        )
        XCTAssertEqual(scorecard.overall.total, 2, "the 31-day-old flag is out of window")
        XCTAssertEqual(scorecard.actionsTaken, ["block": 1, "autoAnswer": 1],
                       "audit entries obey the same cutoff")
    }

    // MARK: - Load path (real rows, in-memory DB)

    func testLoadAggregatesRealRowsFromDatabase() throws {
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: "s", projectHash: "p", cwd: "/c",
            startedAt: now, lastSeenAt: now, jsonlPath: "/x"))

        let flags = FlagStore(database: db)
        let recent = flag(category: "destructive_action_pending", severity: .high, daysAgo: 1)
        try flags.insert(recent)
        let old = flag(category: "destructive_action_pending", daysAgo: 90)          // out of window
        try flags.insert(old)
        // Exercise the REAL response write path the hover panel uses.
        try flags.markUserResponse(flagId: recent.id, response: .dismissed)
        // ... and the REAL outcome write path the Notifier result hook uses
        // (issue #60 follow-up). The out-of-window row gets one too, to prove
        // the cutoff applies to outcomes as well.
        try flags.markInterventionOutcome(flagId: recent.id, outcome: .pauseSucceeded)
        try flags.markInterventionOutcome(flagId: old.id, outcome: .killSucceeded)

        let audit = AuditStore(database: db)
        try audit.record(auditEntry(kind: .block, daysAgo: 2))
        try audit.record(auditEntry(kind: .block, daysAgo: 90))                      // out of window

        let scorecard = try TrustScorecard.load(database: db, sinceDays: 30, now: now)

        XCTAssertEqual(scorecard.categories.count, 1)
        XCTAssertEqual(scorecard.categories[0].category, "destructive_action_pending")
        XCTAssertEqual(scorecard.categories[0].total, 1, "the 90-day-old flag is out of window")
        XCTAssertEqual(scorecard.categories[0].high, 1)
        XCTAssertEqual(scorecard.overall.dismissed, 1, "markUserResponse round-trips into the scorecard")
        let rate = try XCTUnwrap(scorecard.overall.dismissalRate)
        XCTAssertEqual(rate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(scorecard.actionsTaken, ["block": 1])
        XCTAssertEqual(scorecard.interventionOutcomes, ["pause_succeeded": 1],
                       "markInterventionOutcome round-trips into the scorecard; the 90-day-old outcome is out of window")
    }

    func testEmptyDatabaseScoresHonestly() throws {
        let db = try SupervisorDatabase.inMemory()
        let scorecard = try TrustScorecard.load(database: db, sinceDays: 30, now: now)
        XCTAssertTrue(scorecard.categories.isEmpty)
        XCTAssertEqual(scorecard.overall.total, 0)
        XCTAssertNil(scorecard.overall.dismissalRate)
        XCTAssertTrue(scorecard.actionsTaken.isEmpty)
        XCTAssertTrue(scorecard.interventionOutcomes.isEmpty)
        XCTAssertTrue(scorecard.render().contains("no flags recorded in this window"),
                      "empty DB renders an explicit empty line, not a bare table")
        XCTAssertTrue(scorecard.render().contains("intervention outcomes (flags.intervention_outcome): none recorded in window"),
                      "an empty outcome set says so explicitly instead of omitting the section")
    }

    // MARK: - Render

    func testRenderShowsCountsRateAndHonestLimits() {
        let scorecard = TrustScorecard.compute(
            flags: [
                flag(category: "destructive_action_pending", severity: .high, response: .dismissed, outcome: .pauseSucceeded),
                flag(category: "destructive_action_pending", severity: .high, response: .approved),
            ],
            auditEntries: [auditEntry(kind: .block)],
            sinceDays: 30,
            now: now
        )
        let out = scorecard.render()
        XCTAssertTrue(out.contains("destructive_action_pending"))
        XCTAssertTrue(out.contains("50.0%"), "1 of 2 explicit responses dismissed")
        XCTAssertTrue(out.contains("block=1"))
        XCTAssertTrue(out.contains("pause_succeeded=1"),
                      "the outcome section renders the recorded kinds")
        XCTAssertTrue(out.contains("flags predating the column have none"),
                      "the render is honest that pre-v10 rows carry no outcome")
        XCTAssertTrue(out.contains("NOT counted as dismissed"),
                      "the render is explicit that no-response never inflates the rate")
        XCTAssertTrue(out.contains("NOT recorded as a response"),
                      "the render is explicit that a plain banner tap is engagement, not approval")
    }
}
