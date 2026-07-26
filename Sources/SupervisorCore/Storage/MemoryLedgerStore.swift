// MemoryLedgerStore.swift — persistence for Second Brain iterations.
//
// One row per optimizer iteration (migration v9 `second_brain_ledgers`).
// Mirrors ContextAuditStore exactly: a `Sendable` struct over the serial
// DatabaseQueue, sync write at record time, keyed to a PROJECT ROOT (no
// session_id FK — the brain outlives any one session).
//
// The delta columns make "is the brain growing / converging" a cheap SQL read;
// `ledger_json` keeps the full `MemoryLedger` verbatim so `latest(root:)` is
// the loop's resume point (the next iteration starts from the last persisted
// ledger) and any past state can be re-rendered without re-distilling.

import Foundation
import GRDB

/// A persisted iteration summary + the full ledger JSON. `ledger()` decodes the
/// blob back into a live `MemoryLedger`.
public struct StoredMemoryLedger: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "second_brain_ledgers"

    public var id: String
    public var root: String
    public var generatedAt: Date
    public var iteration: Int
    public var addedCount: Int
    public var confirmedCount: Int
    public var mergedCount: Int
    public var retiredCount: Int
    public var activeEntries: Int
    public var ledgerJSON: String

    enum CodingKeys: String, CodingKey {
        case id
        case root
        case generatedAt = "generated_at"
        case iteration
        case addedCount = "added_count"
        case confirmedCount = "confirmed_count"
        case mergedCount = "merged_count"
        case retiredCount = "retired_count"
        case activeEntries = "active_entries"
        case ledgerJSON = "ledger_json"
    }

    public init(
        id: String = UUID().uuidString,
        root: String,
        generatedAt: Date,
        iteration: Int,
        addedCount: Int,
        confirmedCount: Int,
        mergedCount: Int,
        retiredCount: Int,
        activeEntries: Int,
        ledgerJSON: String
    ) {
        self.id = id
        self.root = root
        self.generatedAt = generatedAt
        self.iteration = iteration
        self.addedCount = addedCount
        self.confirmedCount = confirmedCount
        self.mergedCount = mergedCount
        self.retiredCount = retiredCount
        self.activeEntries = activeEntries
        self.ledgerJSON = ledgerJSON
    }

    /// Encode a live ledger + its iteration's delta into a stored row. Throws
    /// only if the ledger can't be JSON-encoded (it always can — every field is
    /// Codable).
    public static func from(
        _ ledger: MemoryLedger,
        delta: IterationDelta,
        id: String = UUID().uuidString
    ) throws -> StoredMemoryLedger {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(ledger), encoding: .utf8) ?? "{}"
        return StoredMemoryLedger(
            id: id,
            root: ledger.root,
            generatedAt: ledger.updatedAt,
            iteration: ledger.iteration,
            addedCount: delta.added,
            confirmedCount: delta.confirmed,
            mergedCount: delta.merged,
            retiredCount: delta.retired,
            activeEntries: delta.activeTotal,
            ledgerJSON: json
        )
    }

    /// Decode the stored `ledger_json` back into a live ledger, or nil if the
    /// blob is empty/corrupt.
    public func ledger() -> MemoryLedger? {
        guard let data = ledgerJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MemoryLedger.self, from: data)
    }
}

public struct MemoryLedgerStore: Sendable {

    private let db: SupervisorDatabase

    public init(database: SupervisorDatabase) {
        self.db = database
    }

    /// Persist one iteration. Sync write (an iteration that isn't recorded may
    /// as well not have happened — the next run would silently restart from the
    /// prior state). Returns the stored row.
    @discardableResult
    public func record(_ ledger: MemoryLedger, delta: IterationDelta, id: String = UUID().uuidString) throws -> StoredMemoryLedger {
        let row = try StoredMemoryLedger.from(ledger, delta: delta, id: id)
        try db.queue.write { conn in try row.insert(conn) }
        return row
    }

    /// The most recent iteration for a given root, or nil if none — the loop's
    /// resume point.
    public func latest(root: String) throws -> StoredMemoryLedger? {
        try db.queue.read { conn in
            try StoredMemoryLedger
                .filter(Column("root") == root)
                .order(Column("generated_at").desc)
                .fetchOne(conn)
        }
    }

    /// Iteration history for a root, newest first — the "is the brain
    /// improving" trail.
    public func history(root: String, limit: Int = 50) throws -> [StoredMemoryLedger] {
        try db.queue.read { conn in
            try StoredMemoryLedger
                .filter(Column("root") == root)
                .order(Column("generated_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    /// Most recent iterations across all roots, newest first.
    public func all(limit: Int = 100) throws -> [StoredMemoryLedger] {
        try db.queue.read { conn in
            try StoredMemoryLedger
                .order(Column("generated_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }
}
