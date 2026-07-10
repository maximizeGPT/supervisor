// AuditStore.swift - v0.2.0 observability (Reddit feedback A).
//
// Inserts and queries against the `audit_entries` table (Database.swift
// migration v5) - the unified, skimmable audit spine. Same shape +
// concurrency model as FlagStore / LoopDispatchStore / PlanStore: a
// `Sendable` struct over the serial DatabaseQueue, sync write at record time
// so an audit row is never lost across a crash (the whole point of an audit
// trail is that it survives the action it describes).
//
// This store does NOT reinvent logging. Supervisor already writes a raw trace
// (TraceLog) and structured ledgers (flags, loop_dispatches, the
// InjectionLedger); AuditStore is the HUMAN-READABLE, per-action record built
// alongside them, wired ADDITIVELY into the same hooks. `record(_:)` is called
// from the existing decision sites; `entries(sessionId:limit:)` and
// `allEntries(limit:)` read them back (the latter feeds SessionReportExporter,
// PART C).

import Foundation
import GRDB

public struct AuditStore: Sendable {

    private let db: SupervisorDatabase

    public init(database: SupervisorDatabase) {
        self.db = database
    }

    /// Record one audit entry. Sync write (no audit-row loss across a crash,
    /// matching FlagStore). Discardable: most call sites fire-and-forget.
    public func record(_ entry: StoredAuditEntry) throws {
        try db.queue.write { conn in
            try entry.insert(conn)
        }
    }

    /// Recent audit entries for one session, newest first. Default limit 200 -
    /// generous enough for the live activity surface and an export bundle while
    /// still bounding the scan on a long run.
    public func entries(sessionId: String, limit: Int = 200) throws -> [StoredAuditEntry] {
        try db.queue.read { conn in
            try StoredAuditEntry
                .filter(Column("session_id") == sessionId)
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    /// Recent audit entries across all sessions, newest first. Used by surfaces
    /// that show a global activity feed; per-session reads use `entries(...)`.
    public func allEntries(limit: Int = 200) throws -> [StoredAuditEntry] {
        try db.queue.read { conn in
            try StoredAuditEntry
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    /// Count of audit entries (optionally scoped to one session).
    public func count(sessionId: String? = nil) throws -> Int {
        try db.queue.read { conn in
            var request = StoredAuditEntry.all()
            if let sessionId {
                request = request.filter(Column("session_id") == sessionId)
            }
            return try request.fetchCount(conn)
        }
    }

    // MARK: - Deterministic-catch dedupe (v8, launch-audit fix 2026-07)

    /// How long a caught event uuid stays in the dedupe ledger. Replays come
    /// from offset-resume after a restart — minutes-old, not days-old — so a
    /// week is generous while keeping the table permanently tiny.
    public static let deterministicCatchRetention: TimeInterval = 7 * 86_400

    /// Has this event (by tool_use uuid) already fired a deterministic catch?
    /// The TriageEngine consults this before re-notifying, so a transcript
    /// line replayed after an engine restart cannot post a second identical
    /// destructive-action banner. A uuid never seen returns false — a
    /// genuinely NEW destructive event always fires.
    public func hasDeterministicCatch(eventUuid: String) throws -> Bool {
        try db.queue.read { conn in
            try Int.fetchOne(
                conn,
                sql: "SELECT COUNT(*) FROM deterministic_catches WHERE event_uuid = ?",
                arguments: [eventUuid]
            ) ?? 0 > 0
        }
    }

    /// Record that a deterministic catch fired (and was notified) for this
    /// event uuid. Sync write, same crash-survival rationale as `record(_:)` —
    /// the dedupe is only useful if it outlives the restart. Prunes rows past
    /// the retention window on the same write so the ledger stays bounded.
    public func recordDeterministicCatch(eventUuid: String, sessionId: String, at ts: Date) throws {
        try db.queue.write { conn in
            try conn.execute(
                sql: "INSERT OR REPLACE INTO deterministic_catches (event_uuid, session_id, ts) VALUES (?, ?, ?)",
                arguments: [eventUuid, sessionId, ts]
            )
            try conn.execute(
                sql: "DELETE FROM deterministic_catches WHERE ts < ?",
                arguments: [ts.addingTimeInterval(-Self.deterministicCatchRetention)]
            )
        }
    }
}
