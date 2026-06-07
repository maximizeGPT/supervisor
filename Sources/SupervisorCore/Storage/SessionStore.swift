// SessionStore.swift
//
// CRUD on the sessions table. Read-heavy: each tail persists an offset
// every 30s. Write side is small.

import Foundation
import GRDB

public struct SessionStore: Sendable {

    private let db: SupervisorDatabase

    public init(database: SupervisorDatabase) {
        self.db = database
    }

    public func upsert(_ session: StoredSession) throws {
        try db.queue.write { conn in
            try session.save(conn)
        }
    }

    public func fetch(id: String) throws -> StoredSession? {
        try db.queue.read { conn in
            try StoredSession.fetchOne(conn, key: id)
        }
    }

    public func all() throws -> [StoredSession] {
        try db.queue.read { conn in
            try StoredSession
                .order(Column("last_seen_at").desc)
                .fetchAll(conn)
        }
    }

    /// Persist a new offset. Called by `SessionTail` every 30s. Returns the
    /// previous offset (for trace logging) or nil if the session is new.
    @discardableResult
    public func updateOffset(sessionId: String, offset: Int64) throws -> Int64? {
        try db.queue.write { conn in
            let previous = try StoredSession.fetchOne(conn, key: sessionId)?.jsonlOffset
            try conn.execute(
                sql: "UPDATE sessions SET jsonl_offset = ?, last_seen_at = ? WHERE id = ?",
                arguments: [offset, Date(), sessionId]
            )
            return previous
        }
    }

    /// Replace the `<resolving>` placeholder with the real cwd once a
    /// cwd-bearing event surfaces it (EventParser/SessionTail). Best-effort;
    /// a no-op if the session row doesn't exist yet.
    public func updateResolvedCwd(sessionId: String, cwd: String) throws {
        try db.queue.write { conn in
            try conn.execute(
                sql: "UPDATE sessions SET cwd = ? WHERE id = ?",
                arguments: [cwd, sessionId]
            )
        }
    }

    public func delete(id: String) throws {
        _ = try db.queue.write { conn in
            try StoredSession.deleteOne(conn, key: id)
        }
    }
}
