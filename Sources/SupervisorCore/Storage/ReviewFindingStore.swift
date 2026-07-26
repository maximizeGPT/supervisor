// ReviewFindingStore.swift — v0.3.x REVIEW dimension.
//
// Insert + query against the `review_findings` table (Database.swift migration
// v6). Same shape + concurrency model as FlagStore / AuditStore: a `Sendable`
// struct over the serial DatabaseQueue.
//
// The store's job beyond persistence is DEDUP: `insertIfNew` relies on the
// UNIQUE `fingerprint` column so the same issue on the same file is recorded
// (and therefore surfaced) exactly once, even as the worker keeps editing that
// file across turns. That is the noise guard that keeps ReviewEngine from
// re-flagging a known observation every turn.

import Foundation
import GRDB

public struct ReviewFindingStore: Sendable {

    private let db: SupervisorDatabase

    public init(database: SupervisorDatabase) {
        self.db = database
    }

    /// Insert a finding IFF its fingerprint hasn't been seen. Returns true when a
    /// new row was written (the caller should surface it), false when the
    /// fingerprint already existed (a duplicate — stay silent). Race-free: the
    /// UNIQUE index + `onConflict: .ignore` makes concurrent inserts of the same
    /// fingerprint collapse to one, and `changesCount` reports whether THIS call
    /// was the one that wrote.
    @discardableResult
    public func insertIfNew(_ finding: StoredReviewFinding) throws -> Bool {
        try db.queue.write { conn in
            try finding.insert(conn, onConflict: .ignore)
            return conn.changesCount > 0
        }
    }

    /// Whether a fingerprint has already been recorded for the session.
    public func exists(fingerprint: String) throws -> Bool {
        try db.queue.read { conn in
            try StoredReviewFinding
                .filter(Column("fingerprint") == fingerprint)
                .fetchCount(conn) > 0
        }
    }

    /// Recent findings for one session, newest first. Default to surfaced-only —
    /// the Activity surface and the report want what the owner actually saw; pass
    /// `surfacedOnly: false` for tuning/inspection of the full set.
    public func recent(sessionId: String, limit: Int = 50, surfacedOnly: Bool = true) throws -> [StoredReviewFinding] {
        try db.queue.read { conn in
            var request = StoredReviewFinding
                .filter(Column("session_id") == sessionId)
            if surfacedOnly {
                request = request.filter(Column("surfaced") == true)
            }
            return try request
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    /// Count of findings for a session (optionally surfaced-only).
    public func count(sessionId: String? = nil, surfacedOnly: Bool = false) throws -> Int {
        try db.queue.read { conn in
            var request = StoredReviewFinding.all()
            if let sessionId {
                request = request.filter(Column("session_id") == sessionId)
            }
            if surfacedOnly {
                request = request.filter(Column("surfaced") == true)
            }
            return try request.fetchCount(conn)
        }
    }

    // MARK: - Fingerprint

    /// Deterministic dedup key for a finding. Combines the session, the file, and
    /// a NORMALIZED title (lowercased, whitespace-collapsed, capped) so trivial
    /// rewordings of the same observation collapse to one fingerprint. Uses the
    /// shared stable FNV-1a hash (NOT Swift's `Hasher`, which is per-run
    /// randomized and would break persistence-based dedup across launches).
    public static func fingerprint(sessionId: String, filePath: String, title: String) -> String {
        let normTitle = title
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .prefix(120)
        let key = "\(sessionId)\u{1F}\(filePath)\u{1F}\(normTitle)"
        return StableHash.fnv1a64Hex(key)
    }
}
