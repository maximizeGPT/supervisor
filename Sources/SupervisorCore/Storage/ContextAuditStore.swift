// ContextAuditStore.swift — persistence for Context Wiki audit runs.
//
// One row per audit (migration v6 `context_audits`). Mirrors the shape +
// concurrency model of AuditStore / FlagStore: a `Sendable` struct over the
// serial DatabaseQueue, sync write at record time. Unlike those, an audit is
// keyed to a PROJECT ROOT, not a live session — so there is no session_id FK.
//
// The summary columns make "how bloated is this project, is it improving over
// time" a cheap query; `report_json` keeps the full `AuditReport` verbatim so a
// past run can be re-rendered (wiki/schema/recommendations) without re-scanning.

import Foundation
import GRDB

/// A persisted audit summary + the full report JSON. `report` decodes the blob
/// back into a live `AuditReport`.
public struct StoredContextAudit: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "context_audits"

    public var id: String
    public var root: String
    public var generatedAt: Date
    public var sourceCount: Int
    public var textLines: Int
    public var duplicateBlocks: Int
    public var reclaimableLines: Int
    public var recommendationCount: Int
    public var topSeverity: String
    public var usedLLM: Bool
    public var reportJSON: String

    enum CodingKeys: String, CodingKey {
        case id
        case root
        case generatedAt = "generated_at"
        case sourceCount = "source_count"
        case textLines = "text_lines"
        case duplicateBlocks = "duplicate_blocks"
        case reclaimableLines = "reclaimable_lines"
        case recommendationCount = "recommendation_count"
        case topSeverity = "top_severity"
        case usedLLM = "used_llm"
        case reportJSON = "report_json"
    }

    public init(
        id: String = UUID().uuidString,
        root: String,
        generatedAt: Date,
        sourceCount: Int,
        textLines: Int,
        duplicateBlocks: Int,
        reclaimableLines: Int,
        recommendationCount: Int,
        topSeverity: String,
        usedLLM: Bool,
        reportJSON: String
    ) {
        self.id = id
        self.root = root
        self.generatedAt = generatedAt
        self.sourceCount = sourceCount
        self.textLines = textLines
        self.duplicateBlocks = duplicateBlocks
        self.reclaimableLines = reclaimableLines
        self.recommendationCount = recommendationCount
        self.topSeverity = topSeverity
        self.usedLLM = usedLLM
        self.reportJSON = reportJSON
    }

    /// Encode a live report into a stored row. Throws only if the report can't be
    /// JSON-encoded (it always can — every field is Codable).
    public static func from(_ report: AuditReport, id: String = UUID().uuidString) throws -> StoredContextAudit {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(report), encoding: .utf8) ?? "{}"
        return StoredContextAudit(
            id: id,
            root: report.root,
            generatedAt: report.generatedAt,
            sourceCount: report.metrics.totalSources,
            textLines: report.metrics.totalProseLines,
            duplicateBlocks: report.metrics.duplicateBlocks.count,
            reclaimableLines: report.totalReclaimableLines,
            recommendationCount: report.recommendations.count,
            topSeverity: report.topSeverity.rawValue,
            usedLLM: report.usedLLM,
            reportJSON: json
        )
    }

    /// Decode the stored `report_json` back into a live report, or nil if the
    /// blob is empty/corrupt.
    public func report() -> AuditReport? {
        guard let data = reportJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AuditReport.self, from: data)
    }
}

public struct ContextAuditStore: Sendable {

    private let db: SupervisorDatabase

    public init(database: SupervisorDatabase) {
        self.db = database
    }

    /// Persist one audit run. Sync write (an audit that isn't recorded may as
    /// well not have happened). Returns the stored row.
    @discardableResult
    public func record(_ report: AuditReport, id: String = UUID().uuidString) throws -> StoredContextAudit {
        let row = try StoredContextAudit.from(report, id: id)
        try db.queue.write { conn in try row.insert(conn) }
        return row
    }

    /// The most recent audit for a given root, or nil if none.
    public func latest(root: String) throws -> StoredContextAudit? {
        try db.queue.read { conn in
            try StoredContextAudit
                .filter(Column("root") == root)
                .order(Column("generated_at").desc)
                .fetchOne(conn)
        }
    }

    /// Audit history for a root, newest first — the "is it getting better" trail.
    public func history(root: String, limit: Int = 50) throws -> [StoredContextAudit] {
        try db.queue.read { conn in
            try StoredContextAudit
                .filter(Column("root") == root)
                .order(Column("generated_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    /// Most recent audits across all roots, newest first.
    public func all(limit: Int = 100) throws -> [StoredContextAudit] {
        try db.queue.read { conn in
            try StoredContextAudit
                .order(Column("generated_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }
}
