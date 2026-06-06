// FlagStore.swift
//
// Inserts and queries against the flags table. Sync write at flag
// creation per DESIGN.md §11.2 — no flag loss across a crash.

import Foundation
import GRDB

public struct FlagStore: Sendable {

    private let db: SupervisorDatabase

    public init(database: SupervisorDatabase) {
        self.db = database
    }

    public func insert(_ flag: StoredFlag) throws {
        try db.queue.write { conn in
            try flag.insert(conn)
        }
    }

    public func recent(sessionId: String? = nil, limit: Int = 50) throws -> [StoredFlag] {
        try db.queue.read { conn in
            var request = StoredFlag.order(Column("ts").desc).limit(limit)
            if let sessionId {
                request = request.filter(Column("session_id") == sessionId)
            }
            return try request.fetchAll(conn)
        }
    }

    public func markUserResponse(flagId: String, response: FlagUserResponse) throws {
        try db.queue.write { conn in
            try conn.execute(
                sql: "UPDATE flags SET user_response = ? WHERE id = ?",
                arguments: [response.rawValue, flagId]
            )
        }
    }

    public func count(sessionId: String? = nil) throws -> Int {
        try db.queue.read { conn in
            var request = StoredFlag.all()
            if let sessionId {
                request = request.filter(Column("session_id") == sessionId)
            }
            return try request.fetchCount(conn)
        }
    }

    /// Idle gap that separates one "work window" from the next. A break longer
    /// than this between flags starts a fresh window, so a launch after a pause
    /// shows a small number rather than the all-time total.
    public static let workWindowIdleGap: TimeInterval = 60 * 60  // 60 minutes

    /// Count flags in the CURRENT work window — the most recent contiguous run
    /// of flags with no inter-flag gap >= `idleGap`. Returns 0 when the most
    /// recent flag is itself older than `idleGap` (a fresh launch after a
    /// break). This is the badge's "this work session" number; the all-time
    /// total stays in `count()` and the DB is never modified (display is
    /// scoped, not deleted).
    public func countCurrentWorkWindow(
        idleGap: TimeInterval = FlagStore.workWindowIdleGap,
        now: Date
    ) throws -> Int {
        try db.queue.read { conn in
            // Newest-first timestamps. A real work window is small; the cap
            // just bounds the scan if the flags table is huge.
            let timestamps = try Date.fetchAll(
                conn, sql: "SELECT ts FROM flags ORDER BY ts DESC LIMIT 20000"
            )
            guard let mostRecent = timestamps.first else { return 0 }
            // Fresh window: the last flag predates the idle gap, so the current
            // window has no flags yet.
            if now.timeIntervalSince(mostRecent) >= idleGap { return 0 }
            var count = 1
            var prev = mostRecent
            for ts in timestamps.dropFirst() {
                if prev.timeIntervalSince(ts) >= idleGap { break }
                count += 1
                prev = ts
            }
            return count
        }
    }
}
