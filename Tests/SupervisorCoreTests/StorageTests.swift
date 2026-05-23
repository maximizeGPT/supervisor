// StorageTests.swift
//
// Migration round-trip + each store's basic CRUD against an in-memory DB.
// Heartbeat tested separately against a temp directory.

import XCTest
@testable import SupervisorCore
import GRDB

final class StorageTests: XCTestCase {

    // MARK: - Migration

    func testMigrationCreatesExpectedTables() throws {
        let db = try SupervisorDatabase.inMemory()
        try db.queue.read { conn in
            XCTAssertTrue(try conn.tableExists("sessions"))
            XCTAssertTrue(try conn.tableExists("flags"))
            XCTAssertTrue(try conn.tableExists("daily_cost"))
        }
    }

    /// v0.1.2's v2 migration: `reasoning` becomes `reasoning_technical`,
    /// and `reasoning_plain` + `asymmetry_note` columns are added. The
    /// rename + add + backfill all has to land in a single migration
    /// pass so the row is consistent at every step.
    func testV2MigrationSplitsReasoningColumns() throws {
        let db = try SupervisorDatabase.inMemory()
        try db.queue.read { conn in
            let cols = try conn.columns(in: "flags").map { $0.name }
            XCTAssertTrue(cols.contains("reasoning_plain"),
                          "expected reasoning_plain column after v2 migration; got: \(cols)")
            XCTAssertTrue(cols.contains("reasoning_technical"),
                          "expected reasoning_technical column after v2 migration; got: \(cols)")
            XCTAssertTrue(cols.contains("asymmetry_note"),
                          "expected asymmetry_note column after v2 migration; got: \(cols)")
            XCTAssertFalse(cols.contains("reasoning"),
                           "old `reasoning` column should have been renamed away; got: \(cols)")
        }
    }

    func testMigrationIsIdempotent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-mig-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Two opens against the same file run the migrator twice.
        _ = try SupervisorDatabase(path: tmp)
        _ = try SupervisorDatabase(path: tmp)
    }

    // MARK: - SessionStore

    func testSessionUpsertAndFetch() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = SessionStore(database: db)

        let session = StoredSession(
            id: "abc-123",
            projectHash: "-Users-main",
            cwd: "/Users/main/supervisor",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_100),
            pid: 12345,
            jsonlPath: "/Users/main/.claude/projects/-Users-main/abc-123.jsonl",
            jsonlOffset: 0
        )

        try store.upsert(session)
        let fetched = try store.fetch(id: "abc-123")
        XCTAssertEqual(fetched, session)
    }

    func testSessionUpdateOffset() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = SessionStore(database: db)

        try store.upsert(StoredSession(
            id: "s1",
            projectHash: "-Users-main",
            cwd: "/tmp/cwd",
            startedAt: Date(),
            lastSeenAt: Date(),
            jsonlPath: "/tmp/s1.jsonl",
            jsonlOffset: 0
        ))

        let prev = try store.updateOffset(sessionId: "s1", offset: 42_000)
        XCTAssertEqual(prev, 0)
        XCTAssertEqual(try store.fetch(id: "s1")?.jsonlOffset, 42_000)

        let prev2 = try store.updateOffset(sessionId: "s1", offset: 100_000)
        XCTAssertEqual(prev2, 42_000)
    }

    func testSessionAllOrderedByLastSeen() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = SessionStore(database: db)

        let now = Date()
        try store.upsert(StoredSession(
            id: "old", projectHash: "p", cwd: "/c1",
            startedAt: now.addingTimeInterval(-1000),
            lastSeenAt: now.addingTimeInterval(-1000),
            jsonlPath: "/x"
        ))
        try store.upsert(StoredSession(
            id: "new", projectHash: "p", cwd: "/c2",
            startedAt: now.addingTimeInterval(-100),
            lastSeenAt: now,
            jsonlPath: "/y"
        ))

        let all = try store.all()
        XCTAssertEqual(all.map { $0.id }, ["new", "old"])
    }

    // MARK: - FlagStore

    func testFlagInsertAndRecent() throws {
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: "sess1", projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(),
            jsonlPath: "/x"
        ))
        let store = FlagStore(database: db)
        let flag = StoredFlag(
            sessionId: "sess1",
            category: "destructive_action_pending",
            severity: .high,
            action: .notify,
            reasoningPlain: "Claude Code just ran `rm -rf /tmp/foo`. That's a temp path so this is fine, but I'm surfacing it in case it was unexpected.",
            reasoningTechnical: "rm -rf against /tmp/foo matches the destructive_action_pending category but the path is in the explicit temp-path allowlist (clause 'Do NOT fire if: destructive command is rm against /tmp/').",
            evidenceUuids: ["evt-1", "evt-2"]
        )
        try store.insert(flag)

        let recent = try store.recent(sessionId: "sess1")
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].category, "destructive_action_pending")
        XCTAssertEqual(recent[0].severity, .high)
        XCTAssertEqual(recent[0].evidenceUUIDList, ["evt-1", "evt-2"])
    }

    func testFlagMarkUserResponse() throws {
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: "s", projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"
        ))
        let store = FlagStore(database: db)
        let flag = StoredFlag(
            sessionId: "s",
            category: "fabrication",
            severity: .medium,
            action: .notify,
            reasoningPlain: "test plain",
            reasoningTechnical: "test technical"
        )
        try store.insert(flag)
        try store.markUserResponse(flagId: flag.id, response: .falsePositive)

        let recent = try store.recent(sessionId: "s")
        XCTAssertEqual(recent[0].userResponse, .falsePositive)
    }

    func testFlagCascadeOnSessionDelete() throws {
        let db = try SupervisorDatabase.inMemory()
        let sessions = SessionStore(database: db)
        let flags = FlagStore(database: db)

        try sessions.upsert(StoredSession(
            id: "s", projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"
        ))
        try flags.insert(StoredFlag(
            sessionId: "s", category: "x", severity: .low, action: .notify,
            reasoningPlain: "", reasoningTechnical: ""
        ))
        XCTAssertEqual(try flags.count(sessionId: "s"), 1)

        try sessions.delete(id: "s")
        XCTAssertEqual(try flags.count(sessionId: "s"), 0)
    }

    // MARK: - CostStore

    func testCostRecordHaikuAccumulates() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = CostStore(database: db)
        try store.recordHaiku(inputTokens: 1000, outputTokens: 200, costUSD: 0.0014)
        try store.recordHaiku(inputTokens: 500, outputTokens: 100, costUSD: 0.0007)

        let today = try store.today()
        XCTAssertEqual(today.haikuInputTokens, 1500)
        XCTAssertEqual(today.haikuOutputTokens, 300)
        XCTAssertEqual(today.estimatedCostUsd, 0.0021, accuracy: 0.0001)
    }

    func testCostRollingSevenDayCovers7Days() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = CostStore(database: db)
        let today = Date()
        try store.recordHaiku(inputTokens: 1, outputTokens: 1, costUSD: 1.0, on: today)
        try store.recordHaiku(inputTokens: 1, outputTokens: 1, costUSD: 2.0, on: today.addingTimeInterval(-86_400 * 1))
        try store.recordHaiku(inputTokens: 1, outputTokens: 1, costUSD: 3.0, on: today.addingTimeInterval(-86_400 * 6))
        // 8 days ago — outside the 7-day window.
        try store.recordHaiku(inputTokens: 1, outputTokens: 1, costUSD: 99.0, on: today.addingTimeInterval(-86_400 * 8))

        let total = try store.rollingSevenDayCostUSD(asOf: today)
        XCTAssertEqual(total, 6.0, accuracy: 0.0001)
    }

    // MARK: - Heartbeat

    func testHeartbeatWriteReadRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-hb-\(UUID().uuidString)")
            .appendingPathComponent("heartbeat.txt")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        let hbFile = HeartbeatFile(path: tmp)
        let written = Heartbeat(timestamp: Date(timeIntervalSince1970: 1_700_000_000), flags: [.axLost])
        try hbFile.write(written)
        let read = try hbFile.read()

        XCTAssertNotNil(read)
        // Compare ms-truncated timestamps (our serializer is at ms precision).
        XCTAssertEqual(
            Int64(read!.timestamp.timeIntervalSince1970 * 1000),
            Int64(written.timestamp.timeIntervalSince1970 * 1000)
        )
        XCTAssertEqual(read?.flags, [.axLost])
    }

    func testHeartbeatReadMissingReturnsNil() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).txt")
        XCTAssertNil(try HeartbeatFile(path: path).read())
    }

    func testHeartbeatAgeReportsInfinityWhenMissing() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).txt")
        XCTAssertEqual(try HeartbeatFile(path: path).ageSeconds(), .infinity)
    }

    func testHeartbeatAgeReportsRecentForFreshWrite() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-hb-age-\(UUID().uuidString)")
            .appendingPathComponent("heartbeat.txt")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        try HeartbeatFile(path: tmp).write(Heartbeat())
        let age = try HeartbeatFile(path: tmp).ageSeconds()
        XCTAssertLessThan(age, 5.0)
    }

    // MARK: - HeartbeatHealth evaluator

    func testHealthEvaluatorGreenBelow10s() {
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 0), .green)
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 9.9), .green)
    }

    func testHealthEvaluatorAmberBetween10and30() {
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 10), .amber)
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 29.9), .amber)
    }

    func testHealthEvaluatorRedAtOrAfter30s() {
        if case .red = HeartbeatHealth.evaluate(age: 30) { /* ok */ } else { XCTFail() }
        if case .red = HeartbeatHealth.evaluate(age: 9999) { /* ok */ } else { XCTFail() }
    }

    func testHealthEvaluatorRedWhenInfinite() {
        if case .red(let r) = HeartbeatHealth.evaluate(age: .infinity) {
            XCTAssertTrue(r.contains("missing"))
        } else {
            XCTFail()
        }
    }

    func testHeartbeatNoFlagsSerializesAsDash() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-hb-dash-\(UUID().uuidString)")
            .appendingPathComponent("heartbeat.txt")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        try HeartbeatFile(path: tmp).write(Heartbeat(flags: []))
        let raw = try String(contentsOf: tmp)
        XCTAssertTrue(raw.contains(" -"))
    }
}
