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

    func testCountCurrentWorkWindowScopesToRecentRun() throws {
        // The badge must show the current work window, NOT the all-time total
        // (the 13k bug). A work window = the most recent contiguous run of
        // flags with no gap >= 60 min; after an idle gap, a fresh launch is 0.
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: "s", projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        let store = FlagStore(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func mk(_ secondsAgo: TimeInterval) -> StoredFlag {
            StoredFlag(sessionId: "s", ts: now.addingTimeInterval(-secondsAgo),
                       category: "c", severity: .medium, action: .notify,
                       reasoningPlain: "p", reasoningTechnical: "t")
        }
        // Current window: 3 flags within minutes of now and each other.
        try store.insert(mk(60)); try store.insert(mk(120)); try store.insert(mk(180))
        // Older burst, after a >60 min gap.
        try store.insert(mk(7200)); try store.insert(mk(7260))

        XCTAssertEqual(try store.count(), 5, "all-time count stays unscoped")
        XCTAssertEqual(try store.countCurrentWorkWindow(now: now), 3,
                       "work window = the recent contiguous run, not all-time")
        // A launch long after the last flag = fresh window = 0.
        XCTAssertEqual(try store.countCurrentWorkWindow(now: now.addingTimeInterval(2 * 3600)), 0,
                       "after an idle gap the current window is empty")
        // Empty table = 0.
        let empty = FlagStore(database: try SupervisorDatabase.inMemory())
        XCTAssertEqual(try empty.countCurrentWorkWindow(now: now), 0)
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

    /// issue #60 follow-up: the v10 migration adds the nullable
    /// intervention_outcome column, and a freshly inserted flag reads NULL
    /// (no outcome recorded) rather than some default bucket.
    func testV10MigrationAddsInterventionOutcomeColumn() throws {
        let db = try SupervisorDatabase.inMemory()
        try db.queue.read { conn in
            let cols = try conn.columns(in: "flags").map { $0.name }
            XCTAssertTrue(cols.contains("intervention_outcome"),
                          "expected intervention_outcome column after v10 migration; got: \(cols)")
        }
        try seedSession(db, id: "s")
        let store = FlagStore(database: db)
        let flag = StoredFlag(
            sessionId: "s", category: "c", severity: .low, action: .notify,
            reasoningPlain: "p", reasoningTechnical: "t"
        )
        try store.insert(flag)
        XCTAssertNil(try store.recent(sessionId: "s")[0].interventionOutcome,
                     "a flag with no recorded outcome must read nil, never a default bucket")
    }

    /// issue #60 follow-up: markInterventionOutcome round-trips the executor's
    /// real result onto the flag row, and a later result overwrites (last
    /// banner wins), mirroring markUserResponse's shape.
    func testFlagMarkInterventionOutcome() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSession(db, id: "s")
        let store = FlagStore(database: db)
        let flag = StoredFlag(
            sessionId: "s", category: "user_question_pending", severity: .medium,
            action: .inject, reasoningPlain: "p", reasoningTechnical: "t"
        )
        try store.insert(flag)

        try store.markInterventionOutcome(flagId: flag.id, outcome: .injectDegraded)
        XCTAssertEqual(try store.recent(sessionId: "s")[0].interventionOutcome, .injectDegraded)

        // A re-delivered outcome for the same flag overwrites (last result wins).
        try store.markInterventionOutcome(flagId: flag.id, outcome: .injectSucceeded)
        XCTAssertEqual(try store.recent(sessionId: "s")[0].interventionOutcome, .injectSucceeded)

        // An unknown flag id is a silent no-op, not an error.
        try store.markInterventionOutcome(flagId: "nope", outcome: .queued)
        XCTAssertEqual(try store.recent(sessionId: "s").count, 1)
    }

    /// issue #60 follow-up: the banner-dismiss path (markUserResponseIfUnset)
    /// records a response only when none exists — it must never overwrite an
    /// explicit panel click, while markUserResponse (the panel path) still can.
    func testFlagMarkUserResponseIfUnsetNeverOverwrites() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSession(db, id: "s")
        let store = FlagStore(database: db)
        let flag = StoredFlag(
            sessionId: "s", category: "c", severity: .medium, action: .notify,
            reasoningPlain: "p", reasoningTechnical: "t"
        )
        try store.insert(flag)

        // Unset -> the banner dismissal lands.
        try store.markUserResponseIfUnset(flagId: flag.id, response: .dismissed)
        XCTAssertEqual(try store.recent(sessionId: "s")[0].userResponse, .dismissed)

        // Already set -> a later banner dismissal must NOT clobber it.
        try store.markUserResponse(flagId: flag.id, response: .falsePositive)
        try store.markUserResponseIfUnset(flagId: flag.id, response: .dismissed)
        XCTAssertEqual(try store.recent(sessionId: "s")[0].userResponse, .falsePositive,
                       "a banner dismissal is weaker than an explicit panel response and must not overwrite it")

        // An unknown flag id (e.g. a dismissed banner from a pre-v10 build
        // whose row carries no id match) is a silent no-op, not an error.
        XCTAssertNoThrow(try store.markUserResponseIfUnset(flagId: "no-such-flag", response: .dismissed))
        XCTAssertEqual(try store.recent(sessionId: "s")[0].userResponse, .falsePositive)
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

    // MARK: - PlanStore (v0.2.0 M2a)

    /// Helper: a session row to satisfy the plans.session_id FK.
    private func seedSession(_ db: SupervisorDatabase, id: String) throws {
        try SessionStore(database: db).upsert(StoredSession(
            id: id, projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"
        ))
    }

    /// create -> currentPlan -> updateStep -> reload, asserting each hop.
    func testPlanCreateLoadUpdateStepRoundTrip() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSession(db, id: "sess-plan")
        let store = PlanStore(database: db)

        let plan = Plan(
            id: "plan-1",
            sessionId: "sess-plan",
            objective: "Ship the planner harness",
            steps: [
                PlanStep(id: "step-0", index: 0, title: "Model",
                         objective: "Add Plan + PlanStep", doneCriteria: "types compile"),
                PlanStep(id: "step-1", index: 1, title: "Store",
                         objective: "Add PlanStore", doneCriteria: "round-trip passes"),
            ],
            status: .draft,
            currentStepIndex: 0
        )
        try store.create(plan)

        // Load the current plan and assert the round-trip is faithful.
        let loaded = try XCTUnwrap(try store.currentPlan(sessionId: "sess-plan"))
        XCTAssertEqual(loaded.id, "plan-1")
        XCTAssertEqual(loaded.objective, "Ship the planner harness")
        XCTAssertEqual(loaded.status, .draft)
        XCTAssertEqual(loaded.steps.map { $0.id }, ["step-0", "step-1"], "steps come back ordered by index")
        XCTAssertEqual(loaded.steps[0].status, .pending)
        XCTAssertNil(loaded.steps[0].lastVerdict)

        // Update step 0: pass it with a verdict and a second attempt.
        try store.updateStep(
            stepId: "step-0",
            status: .passed,
            attempts: 2,
            verdict: PlanStep.Verdict(passed: true, score: 0.91, feedback: "criteria met")
        )

        // Reload and assert the step update persisted, including the
        // JSON-column verdict round-trip.
        let reloaded = try XCTUnwrap(try store.currentPlan(sessionId: "sess-plan"))
        let step0 = try XCTUnwrap(reloaded.steps.first { $0.id == "step-0" })
        XCTAssertEqual(step0.status, .passed)
        XCTAssertEqual(step0.attempts, 2)
        let verdict = try XCTUnwrap(step0.lastVerdict)
        XCTAssertEqual(verdict.passed, true)
        XCTAssertEqual(verdict.score, 0.91, accuracy: 0.0001)
        XCTAssertEqual(verdict.feedback, "criteria met")
        // The untouched step is unchanged.
        XCTAssertEqual(reloaded.steps.first { $0.id == "step-1" }?.status, .pending)
    }

    /// updatePlan + markApproved persist plan-level state.
    func testPlanUpdatePlanAndMarkApproved() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSession(db, id: "s")
        let store = PlanStore(database: db)
        try store.create(Plan(id: "p", sessionId: "s", objective: "obj",
                              steps: [PlanStep(index: 0, title: "t",
                                               objective: "o", doneCriteria: "d")],
                              status: .draft))

        try store.updatePlan(planId: "p", status: .running, currentStepIndex: 1)
        var loaded = try XCTUnwrap(try store.plan(id: "p"))
        XCTAssertEqual(loaded.status, .running)
        XCTAssertEqual(loaded.currentStepIndex, 1)
        XCTAssertNil(loaded.approvedAt)

        let approvedAt = Date(timeIntervalSince1970: 1_700_000_500)
        try store.markApproved(planId: "p", at: approvedAt)
        loaded = try XCTUnwrap(try store.plan(id: "p"))
        XCTAssertEqual(loaded.status, .approved)
        XCTAssertEqual(loaded.approvedAt?.timeIntervalSince1970 ?? 0,
                       approvedAt.timeIntervalSince1970, accuracy: 1.0)
    }

    /// currentPlan returns the most recently created plan for a session.
    func testPlanCurrentReturnsLatest() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSession(db, id: "s")
        let store = PlanStore(database: db)
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let late = Date(timeIntervalSince1970: 1_700_001_000)
        try store.create(Plan(id: "old", sessionId: "s", objective: "old",
                              createdAt: early, updatedAt: early))
        try store.create(Plan(id: "new", sessionId: "s", objective: "new",
                              createdAt: late, updatedAt: late))
        XCTAssertEqual(try store.currentPlan(sessionId: "s")?.id, "new")
        // No plan for an unknown session.
        XCTAssertNil(try store.currentPlan(sessionId: "nope"))
    }

    /// Steps cascade-delete when their plan's session is deleted.
    func testPlanStepsCascadeOnSessionDelete() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSession(db, id: "s")
        let store = PlanStore(database: db)
        try store.create(Plan(id: "p", sessionId: "s", objective: "o",
                              steps: [PlanStep(index: 0, title: "t",
                                               objective: "o", doneCriteria: "d")]))
        try SessionStore(database: db).delete(id: "s")
        XCTAssertNil(try store.plan(id: "p"))
        try db.queue.read { conn in
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM plan_steps"), 0,
                           "plan_steps should cascade away with the plan")
        }
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

    // MARK: - AuditStore (v0.2.0 observability A)

    /// v5 migration creates the audit_entries table with the expected columns.
    func testV5MigrationCreatesAuditEntriesTable() throws {
        let db = try SupervisorDatabase.inMemory()
        try db.queue.read { conn in
            XCTAssertTrue(try conn.tableExists("audit_entries"))
            let cols = try conn.columns(in: "audit_entries").map { $0.name }
            for expected in [
                "id", "session_id", "created_at", "kind", "summary",
                "question", "context_used", "authorizing_rule",
                "command", "target_path", "risk_reason", "classification", "detail",
            ] {
                XCTAssertTrue(cols.contains(expected), "audit_entries missing column \(expected); got \(cols)")
            }
        }
    }

    /// record -> entries round-trip is faithful across all the optional
    /// structured fields, and entries come back newest-first.
    func testAuditStoreRecordAndFetchRoundTrip() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSession(db, id: "sess-audit")
        let store = AuditStore(database: db)

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // An auto-answer with the full justification trail.
        let answer = StoredAuditEntry(
            id: "a-1", sessionId: "sess-audit", createdAt: t0,
            kind: .autoAnswer,
            summary: "Answered Claude Code's question: Yes, commit it",
            question: "Should I commit this?",
            contextUsed: "PRINCIPLES.md + live repo context",
            authorizingRule: "§1c"
        )
        // A destructive block "receipt".
        let block = StoredAuditEntry(
            id: "a-2", sessionId: "sess-audit", createdAt: t0.addingTimeInterval(10),
            kind: .block,
            summary: "Paused before `git reset --hard`",
            command: "git reset --hard",
            targetPath: "/repo",
            riskReason: "git reset --hard: discards all uncommitted and staged changes"
        )
        // A nudge carrying the PART B classification.
        let nudge = StoredAuditEntry(
            id: "a-3", sessionId: "sess-audit", createdAt: t0.addingTimeInterval(20),
            kind: .nudge,
            summary: "Nudged a stalled session",
            classification: StallClassification.subAgentFanout.rawValue
        )
        try store.record(answer)
        try store.record(block)
        try store.record(nudge)

        XCTAssertEqual(try store.count(sessionId: "sess-audit"), 3)

        let entries = try store.entries(sessionId: "sess-audit")
        XCTAssertEqual(entries.map { $0.id }, ["a-3", "a-2", "a-1"], "newest-first")

        // The auto-answer round-trips every field.
        let gotAnswer = try XCTUnwrap(entries.first { $0.id == "a-1" })
        XCTAssertEqual(gotAnswer.kind, .autoAnswer)
        XCTAssertEqual(gotAnswer.question, "Should I commit this?")
        XCTAssertEqual(gotAnswer.contextUsed, "PRINCIPLES.md + live repo context")
        XCTAssertEqual(gotAnswer.authorizingRule, "§1c")
        XCTAssertNil(gotAnswer.command, "an auto-answer leaves block-only fields nil")

        // The block receipt round-trips.
        let gotBlock = try XCTUnwrap(entries.first { $0.id == "a-2" })
        XCTAssertEqual(gotBlock.kind, .block)
        XCTAssertEqual(gotBlock.command, "git reset --hard")
        XCTAssertEqual(gotBlock.targetPath, "/repo")
        XCTAssertEqual(gotBlock.riskReason, "git reset --hard: discards all uncommitted and staged changes")

        // The nudge classification round-trips.
        let gotNudge = try XCTUnwrap(entries.first { $0.id == "a-3" })
        XCTAssertEqual(gotNudge.classification, "subAgentFanout")
    }

    /// Audit entries cascade-delete with their session (the FK + cascade).
    func testAuditEntriesCascadeOnSessionDelete() throws {
        let db = try SupervisorDatabase.inMemory()
        let sessions = SessionStore(database: db)
        try seedSession(db, id: "sess-cascade")
        let store = AuditStore(database: db)
        try store.record(StoredAuditEntry(
            sessionId: "sess-cascade", kind: .nudge, summary: "x"))
        XCTAssertEqual(try store.count(sessionId: "sess-cascade"), 1)

        try sessions.delete(id: "sess-cascade")
        XCTAssertEqual(try store.count(sessionId: "sess-cascade"), 0)
    }

    // MARK: - Deterministic-catch dedupe ledger (v8, launch-audit fix)

    func testV8MigrationCreatesDeterministicCatchesTable() throws {
        let db = try SupervisorDatabase.inMemory()
        try db.queue.read { conn in
            XCTAssertTrue(try conn.tableExists("deterministic_catches"))
            let cols = try conn.columns(in: "deterministic_catches").map { $0.name }
            XCTAssertTrue(cols.contains("event_uuid"))
            XCTAssertTrue(cols.contains("session_id"))
            XCTAssertTrue(cols.contains("ts"))
        }
    }

    func testDeterministicCatchDedupeRoundTrip() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = AuditStore(database: db)

        XCTAssertFalse(try store.hasDeterministicCatch(eventUuid: "toolu-1"),
                       "an unseen event uuid must read false — a new destructive event always fires")

        try store.recordDeterministicCatch(eventUuid: "toolu-1", sessionId: "s1", at: Date())
        XCTAssertTrue(try store.hasDeterministicCatch(eventUuid: "toolu-1"),
                      "a recorded catch must dedupe on replay")

        // A different event is untouched by the first record.
        XCTAssertFalse(try store.hasDeterministicCatch(eventUuid: "toolu-2"))

        // Re-recording the same uuid is idempotent (INSERT OR REPLACE), not an error.
        try store.recordDeterministicCatch(eventUuid: "toolu-1", sessionId: "s1", at: Date())
        XCTAssertTrue(try store.hasDeterministicCatch(eventUuid: "toolu-1"))
    }

    /// The ledger must survive a process restart — that IS the fix. In-memory
    /// would trivially pass dedupe within one process, so use a file-backed DB
    /// and re-open it.
    func testDeterministicCatchSurvivesReopen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-catch-dedupe-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db1 = try SupervisorDatabase(path: tmp)
        try AuditStore(database: db1).recordDeterministicCatch(
            eventUuid: "toolu-restart", sessionId: "s1", at: Date())

        let db2 = try SupervisorDatabase(path: tmp)
        XCTAssertTrue(try AuditStore(database: db2).hasDeterministicCatch(eventUuid: "toolu-restart"),
                      "the dedupe row must be visible after a re-open (engine restart)")
    }

    /// Rows older than the retention window are pruned on the next write, so
    /// the ledger stays bounded; rows inside the window survive the same write.
    func testDeterministicCatchRetentionPrunesOldRows() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = AuditStore(database: db)
        let now = Date()

        // One row just past retention, one comfortably inside it.
        try store.recordDeterministicCatch(
            eventUuid: "toolu-old", sessionId: "s1",
            at: now.addingTimeInterval(-AuditStore.deterministicCatchRetention - 60))
        try store.recordDeterministicCatch(
            eventUuid: "toolu-recent", sessionId: "s1",
            at: now.addingTimeInterval(-60))

        // The pruning write.
        try store.recordDeterministicCatch(eventUuid: "toolu-new", sessionId: "s1", at: now)

        XCTAssertFalse(try store.hasDeterministicCatch(eventUuid: "toolu-old"),
                       "a row past the retention window must be pruned by a later write")
        XCTAssertTrue(try store.hasDeterministicCatch(eventUuid: "toolu-recent"),
                      "a row inside the retention window must survive the prune")
        XCTAssertTrue(try store.hasDeterministicCatch(eventUuid: "toolu-new"))
    }
}
