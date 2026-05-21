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
}
