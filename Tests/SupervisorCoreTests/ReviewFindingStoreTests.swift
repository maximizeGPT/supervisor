// ReviewFindingStoreTests.swift
//
// v0.3.x REVIEW dimension — the dedup ledger. The store's core guarantee is
// that the same finding on the same file records once (so it surfaces once),
// enforced by the UNIQUE fingerprint. Also covers the surfaced-only read and
// the deterministic, normalization-collapsing fingerprint.

import XCTest
import GRDB
@testable import SupervisorCore

final class ReviewFindingStoreTests: XCTestCase {

    private func seededStore() throws -> (SupervisorDatabase, ReviewFindingStore) {
        let db = try SupervisorDatabase.inMemory()
        // review_findings has a FK to sessions; seed one.
        try SessionStore(database: db).upsert(StoredSession(
            id: "sess-1", projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        return (db, ReviewFindingStore(database: db))
    }

    private func finding(
        sessionId: String = "sess-1",
        filePath: String = "/c/A.swift",
        title: String = "Off-by-one in the loop bound",
        surfaced: Bool = true
    ) -> StoredReviewFinding {
        StoredReviewFinding(
            sessionId: sessionId,
            fingerprint: ReviewFindingStore.fingerprint(sessionId: sessionId, filePath: filePath, title: title),
            filePath: filePath,
            toolName: "Edit",
            turnUUID: "u1",
            category: "missed_edge_case",
            severity: .medium,
            confidence: "high",
            title: title,
            detail: "The loop uses <= where < is required.",
            surfaced: surfaced)
    }

    // MARK: - Dedup

    func testInsertIfNewIsTrueThenFalseForSameFingerprint() throws {
        let (_, store) = try seededStore()
        XCTAssertTrue(try store.insertIfNew(finding()), "first insert is new")
        XCTAssertFalse(try store.insertIfNew(finding()), "same finding dedups to false")
        XCTAssertEqual(try store.count(sessionId: "sess-1"), 1, "only one row persisted")
    }

    func testDifferentTitleOrFileIsNotADuplicate() throws {
        let (_, store) = try seededStore()
        XCTAssertTrue(try store.insertIfNew(finding(title: "Off-by-one in the loop bound")))
        XCTAssertTrue(try store.insertIfNew(finding(title: "Nil deref when the list is empty")), "different title is new")
        XCTAssertTrue(try store.insertIfNew(finding(filePath: "/c/B.swift")), "same title, different file is new")
        XCTAssertEqual(try store.count(sessionId: "sess-1"), 3)
    }

    // MARK: - Fingerprint

    func testFingerprintIsDeterministicAndNormalizes() {
        let a = ReviewFindingStore.fingerprint(sessionId: "s", filePath: "/f.swift", title: "Off-by-one in the loop")
        let b = ReviewFindingStore.fingerprint(sessionId: "s", filePath: "/f.swift", title: "  OFF-BY-ONE   in the   loop ")
        XCTAssertEqual(a, b, "case + whitespace differences collapse to one fingerprint")

        let c = ReviewFindingStore.fingerprint(sessionId: "s", filePath: "/f.swift", title: "A different problem")
        XCTAssertNotEqual(a, c, "genuinely different titles differ")
    }

    // MARK: - Surfaced-only read

    func testRecentReturnsSurfacedOnlyByDefault() throws {
        let (_, store) = try seededStore()
        _ = try store.insertIfNew(finding(title: "Surfaced one", surfaced: true))
        _ = try store.insertIfNew(finding(title: "Below the bar", surfaced: false))

        let surfaced = try store.recent(sessionId: "sess-1")
        XCTAssertEqual(surfaced.count, 1)
        XCTAssertEqual(surfaced.first?.title, "Surfaced one")

        let all = try store.recent(sessionId: "sess-1", surfacedOnly: false)
        XCTAssertEqual(all.count, 2, "the full set includes sub-bar findings")
    }
}
