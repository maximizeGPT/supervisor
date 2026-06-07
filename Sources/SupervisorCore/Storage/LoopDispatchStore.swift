// LoopDispatchStore.swift — v0.4.0 Part C.
//
// Inserts and queries against the `loop_dispatches` table. Same shape
// as FlagStore (sync write per DESIGN.md §11.2 — no dispatch row loss
// across a crash). Used by LoopController to (a) write every
// dispatch result for the post-mortem trail and (b) read the recent
// rows back at startup so a Supervisor restart picks up the
// dispatch counter instead of resetting to zero.

import Foundation
import GRDB

public struct LoopDispatchStore: Sendable {

    private let db: SupervisorDatabase

    public init(database: SupervisorDatabase) {
        self.db = database
    }

    @discardableResult
    public func insert(_ row: StoredLoopDispatch) throws -> Int64 {
        var inserted = row
        try db.queue.write { conn in
            try inserted.insert(conn)
        }
        // didInsert sets id; return it for callers that want the
        // newly-created row's primary key.
        return inserted.id ?? 0
    }

    /// Recent dispatches for one session, newest first. Default limit
    /// 50 — well above the 3-consecutive-low check and the running
    /// post-mortem reader.
    public func recent(sessionId: String, limit: Int = 50) throws -> [StoredLoopDispatch] {
        try db.queue.read { conn in
            try StoredLoopDispatch
                .filter(Column("session_id") == sessionId)
                .order(Column("ts").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    /// Count of dispatches for one session (any shape). Used by
    /// LoopController to seed `prior_dispatches_considered` after a
    /// Supervisor restart.
    public func count(sessionId: String) throws -> Int {
        try db.queue.read { conn in
            try StoredLoopDispatch
                .filter(Column("session_id") == sessionId)
                .fetchCount(conn)
        }
    }
}

// MARK: - DispatchHistoryReading (stale-loop guard)

extension LoopDispatchStore: DispatchHistoryReading {
    /// Recent `ready` proposal heads for the session, newest first, capped at
    /// `limit`. Only ready dispatches carry a real `next_task_proposal` — low/
    /// error rows have an empty head and are skipped. Over-fetches (×4) before
    /// filtering so a run heavy on low-confidence idles still surfaces the last
    /// few real proposals. A read error degrades to [] (best-effort context).
    public func recentProposalHeads(sessionId: String, limit: Int) -> [String] {
        guard let rows = try? recent(sessionId: sessionId, limit: max(limit * 4, limit)) else {
            return []
        }
        return rows
            .filter { $0.responseShape == "ready" && !$0.taskProposalHead.isEmpty }
            .prefix(limit)
            .map { $0.taskProposalHead }
    }
}
