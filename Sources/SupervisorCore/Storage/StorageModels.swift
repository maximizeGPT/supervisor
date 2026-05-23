// Models.swift
//
// Domain types for the v0.1.0 storage layer. Schema is in Database.swift's
// migration v1; these structs mirror it. Conform to GRDB's Codable record
// protocols so the column mapping is automatic.

import Foundation
import GRDB

// MARK: - Severity / Action enums (string-coded for forward compat).

public enum FlagSeverity: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}

public enum FlagAction: String, Codable, Sendable, CaseIterable {
    case notify, inject, pause, kill
}

public enum FlagUserResponse: String, Codable, Sendable, CaseIterable {
    case approved, dismissed, falsePositive = "false_positive"
}

// MARK: - Session

public struct StoredSession: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "sessions"

    public var id: String              // UUID from JSONL
    public var projectHash: String     // e.g. "-Users-main"
    public var cwd: String
    public var startedAt: Date
    public var lastSeenAt: Date
    public var pid: Int?
    public var jsonlPath: String
    public var jsonlOffset: Int64

    public init(
        id: String,
        projectHash: String,
        cwd: String,
        startedAt: Date,
        lastSeenAt: Date,
        pid: Int? = nil,
        jsonlPath: String,
        jsonlOffset: Int64 = 0
    ) {
        self.id = id
        self.projectHash = projectHash
        self.cwd = cwd
        self.startedAt = startedAt
        self.lastSeenAt = lastSeenAt
        self.pid = pid
        self.jsonlPath = jsonlPath
        self.jsonlOffset = jsonlOffset
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectHash = "project_hash"
        case cwd
        case startedAt = "started_at"
        case lastSeenAt = "last_seen_at"
        case pid
        case jsonlPath = "jsonl_path"
        case jsonlOffset = "jsonl_offset"
    }
}

// MARK: - Flag

public struct StoredFlag: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "flags"

    public var id: String
    public var sessionId: String
    public var ts: Date
    public var category: String
    public var severity: FlagSeverity
    public var action: FlagAction                // Haiku's recommended_action
    public var reasoningPlain: String            // v0.1.2: banner-fit
    public var reasoningTechnical: String        // v0.1.2: engineer-fit (renamed from `reasoning`)
    public var asymmetryNote: String?            // v0.1.2: optional asymmetry-of-being-wrong note
    public var evidenceUuids: String             // JSON-encoded array; v0.1.x small enough not to need a join table
    public var userResponse: FlagUserResponse?

    public var haikuInputTokens: Int?
    public var haikuOutputTokens: Int?
    public var sonnetInputTokens: Int?
    public var sonnetOutputTokens: Int?

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        ts: Date = Date(),
        category: String,
        severity: FlagSeverity,
        action: FlagAction,
        reasoningPlain: String,
        reasoningTechnical: String,
        asymmetryNote: String? = nil,
        evidenceUuids: [String] = [],
        userResponse: FlagUserResponse? = nil,
        haikuInputTokens: Int? = nil,
        haikuOutputTokens: Int? = nil,
        sonnetInputTokens: Int? = nil,
        sonnetOutputTokens: Int? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.ts = ts
        self.category = category
        self.severity = severity
        self.action = action
        self.reasoningPlain = reasoningPlain
        self.reasoningTechnical = reasoningTechnical
        self.asymmetryNote = asymmetryNote
        // Persist as a JSON array string. Empty array becomes "[]".
        let data = (try? JSONEncoder().encode(evidenceUuids)) ?? Data("[]".utf8)
        self.evidenceUuids = String(data: data, encoding: .utf8) ?? "[]"
        self.userResponse = userResponse
        self.haikuInputTokens = haikuInputTokens
        self.haikuOutputTokens = haikuOutputTokens
        self.sonnetInputTokens = sonnetInputTokens
        self.sonnetOutputTokens = sonnetOutputTokens
    }

    /// Decode the evidence UUIDs back into a strongly typed array.
    public var evidenceUUIDList: [String] {
        guard let data = evidenceUuids.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case ts
        case category
        case severity
        case action
        case reasoningPlain = "reasoning_plain"
        case reasoningTechnical = "reasoning_technical"
        case asymmetryNote = "asymmetry_note"
        case evidenceUuids = "evidence_uuids"
        case userResponse = "user_response"
        case haikuInputTokens = "haiku_input_tokens"
        case haikuOutputTokens = "haiku_output_tokens"
        case sonnetInputTokens = "sonnet_input_tokens"
        case sonnetOutputTokens = "sonnet_output_tokens"
    }
}

// MARK: - Daily cost rollup

public struct StoredDailyCost: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "daily_cost"

    public var date: String                  // YYYY-MM-DD
    public var haikuInputTokens: Int
    public var haikuOutputTokens: Int
    public var sonnetInputTokens: Int
    public var sonnetOutputTokens: Int
    public var estimatedCostUsd: Double

    public init(
        date: String,
        haikuInputTokens: Int = 0,
        haikuOutputTokens: Int = 0,
        sonnetInputTokens: Int = 0,
        sonnetOutputTokens: Int = 0,
        estimatedCostUsd: Double = 0
    ) {
        self.date = date
        self.haikuInputTokens = haikuInputTokens
        self.haikuOutputTokens = haikuOutputTokens
        self.sonnetInputTokens = sonnetInputTokens
        self.sonnetOutputTokens = sonnetOutputTokens
        self.estimatedCostUsd = estimatedCostUsd
    }

    enum CodingKeys: String, CodingKey {
        case date
        case haikuInputTokens = "haiku_input_tokens"
        case haikuOutputTokens = "haiku_output_tokens"
        case sonnetInputTokens = "sonnet_input_tokens"
        case sonnetOutputTokens = "sonnet_output_tokens"
        case estimatedCostUsd = "estimated_cost_usd"
    }
}
