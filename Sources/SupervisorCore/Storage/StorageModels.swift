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
    // Action ladder per PRINCIPLES.md §3d, lightest → heaviest:
    //   - notify:   banner only; user decides
    //   - inject:   types ≤200 chars (engineering-answer or rewritten taste
    //               question) into the worker's input
    //   - continue: types a NEW TASK PROMPT (multi-paragraph) into the
    //               worker's input when the worker is idle post-completion.
    //               Heavier than inject because it triggers hours of
    //               follow-on work; lighter than pause because it doesn't
    //               stop the session. v0.4.0+.
    //   - pause:    SIGSTOP — freezes the worker; recoverable
    //   - kill:     SIGTERM — terminates the worker; not recoverable
    //   - selfExtend: v0.5.0. SelfExtender diagnoses dispatch failures
    //                 and produces a fix prompt. Heavier than continue
    //                 (it modifies Supervisor's own infrastructure) but
    //                 lighter than pause (the session stays alive).
    case notify, inject, `continue`, selfExtend, pause, kill
}

public enum FlagUserResponse: String, Codable, Sendable, CaseIterable {
    case approved, dismissed, falsePositive = "false_positive", rejected
}

/// issue #60 follow-up: the payload-free, string-coded kind of a real
/// `InterventionOutcome`, persisted on `flags.intervention_outcome`
/// (migration v10). One case per InterventionOutcome case — the associated
/// values (PIDs, intended text, doc paths) stay in the trace/banner where
/// they already live; the scorecard only needs WHICH outcome happened.
/// String-coded snake_case for a stable on-disk representation (same
/// pattern as FlagSeverity / FlagAction / FlagUserResponse). Like those
/// enums, decoding an UNKNOWN raw value throws and fails the row fetch —
/// adding a case is a forward migration concern, not silently absorbed.
public enum InterventionOutcomeKind: String, Codable, Sendable, CaseIterable {
    case notifyOnly = "notify_only"
    case pauseSucceeded = "pause_succeeded"
    case killSucceeded = "kill_succeeded"
    case injectSucceeded = "inject_succeeded"
    case injectDegraded = "inject_degraded"
    case screenRecordingDenied = "screen_recording_denied"
    case continueFired = "continue_fired"
    case continueProposedMedium = "continue_proposed_medium"
    case continueLowConfidence = "continue_low_confidence"
    case queued
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
    /// issue #60 follow-up: what the intervention ACTUALLY did (migration v10),
    /// written after the fact by FlagStore.markInterventionOutcome from the
    /// Notifier's result hook. nil = no outcome recorded (rows predating the
    /// column, or a decision that never reached the router's result hook).
    public var interventionOutcome: InterventionOutcomeKind?

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
        interventionOutcome: InterventionOutcomeKind? = nil,
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
        self.interventionOutcome = interventionOutcome
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
        case interventionOutcome = "intervention_outcome"
        case haikuInputTokens = "haiku_input_tokens"
        case haikuOutputTokens = "haiku_output_tokens"
        case sonnetInputTokens = "sonnet_input_tokens"
        case sonnetOutputTokens = "sonnet_output_tokens"
    }
}

// MARK: - Loop dispatch (v0.4.0 Part C)

/// One row of the `loop_dispatches` ledger — recorded every time the
/// Dispatcher returns a result. The LoopController writes these and
/// queries the recent rows to (a) decide the
/// `prior_dispatches_considered` count for the NEXT dispatch, and
/// (b) check the "3 consecutive low-confidence" hard-stop condition.
///
/// `responseShape` is the source of truth for which DispatchResult
/// case fired: "ready" | "lowConfidence" | "error". For "ready" rows,
/// confidence + selectedPath + (optional) selectedIssueNumber are
/// populated. For "lowConfidence" rows, confidence is set to "low"
/// and selectedPath to "low_confidence_no_action". For "error" rows,
/// confidence is nil and the justification holds the error reason.
public struct StoredLoopDispatch: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "loop_dispatches"

    public var id: Int64?
    public var sessionId: String
    public var ts: Date
    public var responseShape: String                   // ready | lowConfidence | error
    public var confidence: String?                     // high | medium | low — nil for error
    public var selectedPath: String?                   // continue_branch | transition_to_issue | low_confidence_no_action
    public var selectedIssueNumber: Int?
    public var taskProposalHead: String                // first ~200 chars of next_task_proposal
    public var justification: String
    public var priorDispatchesConsidered: Int          // value at input time
    public var haikuInputTokens: Int?
    public var haikuOutputTokens: Int?

    public init(
        id: Int64? = nil,
        sessionId: String,
        ts: Date = Date(),
        responseShape: String,
        confidence: String? = nil,
        selectedPath: String? = nil,
        selectedIssueNumber: Int? = nil,
        taskProposalHead: String = "",
        justification: String = "",
        priorDispatchesConsidered: Int = 0,
        haikuInputTokens: Int? = nil,
        haikuOutputTokens: Int? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.ts = ts
        self.responseShape = responseShape
        self.confidence = confidence
        self.selectedPath = selectedPath
        self.selectedIssueNumber = selectedIssueNumber
        self.taskProposalHead = taskProposalHead
        self.justification = justification
        self.priorDispatchesConsidered = priorDispatchesConsidered
        self.haikuInputTokens = haikuInputTokens
        self.haikuOutputTokens = haikuOutputTokens
    }

    /// GRDB hook — let SQLite assign the integer id on insert.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case ts
        case responseShape = "response_shape"
        case confidence
        case selectedPath = "selected_path"
        case selectedIssueNumber = "selected_issue_number"
        case taskProposalHead = "task_proposal_head"
        case justification
        case priorDispatchesConsidered = "prior_dispatches_considered"
        case haikuInputTokens = "haiku_input_tokens"
        case haikuOutputTokens = "haiku_output_tokens"
    }
}

// MARK: - Plan + PlanStep (v0.2.0 M2a)

/// One row of the `plans` table — a session's decomposed objective.
/// Mirrors the domain `Plan` (Plan.swift) minus the steps, which live
/// in `plan_steps` (normalized, FK + cascade, matching the
/// sessions/flags/loop_dispatches pattern). PlanStore maps between this
/// record and the domain `Plan`; nothing else touches the Stored* types.
///
/// `status` and `currentStepIndex` are updated in place as the loop
/// advances. `approvedAt` is set once, when the human approves the plan
/// (the standing human gate from the v0.2.0 Decisions).
public struct StoredPlan: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "plans"

    public var id: String
    public var sessionId: String
    public var objective: String
    public var status: String                  // draft | awaitingApproval | approved | running | completed | aborted
    public var currentStepIndex: Int
    public var approvedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        sessionId: String,
        objective: String,
        status: String,
        currentStepIndex: Int = 0,
        approvedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.objective = objective
        self.status = status
        self.currentStepIndex = currentStepIndex
        self.approvedAt = approvedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case objective
        case status
        case currentStepIndex = "current_step_index"
        case approvedAt = "approved_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// One row of the `plan_steps` table — a single step of a plan. FK to
/// `plans` with cascade delete so removing a plan drops its steps.
///
/// The Evaluator's last verdict is stored as a JSON column
/// (`last_verdict`), mirroring the `evidence_uuids` JSON-in-column
/// precedent on `flags` for a small owned nested value — a verdict is
/// only ever read/written as a whole, so a join table would be overkill.
/// `verdictJSON` is the raw column; the typed accessor decodes it.
public struct StoredPlanStep: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "plan_steps"

    public var id: String
    public var planId: String
    public var idx: Int                         // position in the plan (0-based)
    public var title: String
    public var objective: String
    public var doneCriteria: String
    public var status: String                   // pending | active | passed | failed | retrying | skipped
    public var attempts: Int
    public var verdictJSON: String?             // JSON-encoded PlanStep.Verdict, nil if never graded
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        planId: String,
        idx: Int,
        title: String,
        objective: String,
        doneCriteria: String,
        status: String,
        attempts: Int = 0,
        verdictJSON: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.planId = planId
        self.idx = idx
        self.title = title
        self.objective = objective
        self.doneCriteria = doneCriteria
        self.status = status
        self.attempts = attempts
        self.verdictJSON = verdictJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case planId = "plan_id"
        case idx
        case title
        case objective
        case doneCriteria = "done_criteria"
        case status
        case attempts
        case verdictJSON = "last_verdict"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Audit entry (v0.2.0 observability - Reddit feedback A)

/// The kind of action an audit entry records. String-coded for forward
/// compat + a stable on-disk representation (matches FlagAction /
/// PlanStep.Status). One value per Supervisor action the audit spine captures:
///   - autoAnswer: Supervisor answered a question Claude Code asked (the
///                 headline trust-evidence case - the question, the context it
///                 drew on, the authorizing rule, and the answer).
///   - block:      Supervisor caught a destructive command and paused/blocked
///                 (the "receipt": command + target path + risk reason).
///   - nudge:      the stall watchdog sent a check-in nudge (carries the PART B
///                 failure-mode classification).
///   - planStep:   a plan step was driven/injected (the step + its context).
///   - verdict:    the Evaluator graded a step (the score + feedback).
public enum AuditEntryKind: String, Codable, Sendable, CaseIterable {
    case autoAnswer
    case block
    case nudge
    case planStep
    case verdict
    /// A code-review observation (v0.3.x REVIEW dimension): a substantive issue
    /// ReviewEngine spotted in the code a worker wrote — a baked-in wrong
    /// assumption, an overlooked edge case, a line that misses something, logic
    /// that contradicts an earlier session decision. Distinct from `block` (which
    /// stopped a destructive action): a review is INFORMATIONAL, never an
    /// intervention, and surfaces in the Activity tab (pull), not a banner (push).
    /// The finding's file lives in `targetPath`, severity/confidence in
    /// `classification`, and the "why it matters" in `riskReason`.
    case review
}

/// One row of the `audit_entries` table (Database.swift migration v5) - the
/// unified, skimmable audit spine. `summary` is always present (the one-line
/// human-readable account); the remaining fields are OPTIONAL structured
/// columns a given `kind` fills in. `detail` is a free-form JSON blob for
/// anything extra a kind needs without a schema change (mirrors the
/// flags.evidence_uuids / plan_steps.last_verdict JSON-in-column precedent).
///
/// Written ADDITIVELY from the existing hooks (QuestionAnswerer, the
/// DeterministicCatch block path, the stall watchdog, PlanLoop/Evaluator);
/// recording a row never changes those hooks' behavior. SessionReportExporter
/// (PART C) reads these back to assemble the replay bundle.
public struct StoredAuditEntry: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "audit_entries"

    public var id: String
    public var sessionId: String
    public var createdAt: Date
    public var kind: AuditEntryKind
    public var summary: String

    // Optional structured fields - a given kind populates the relevant subset.
    public var question: String?            // autoAnswer
    public var contextUsed: String?         // autoAnswer
    public var authorizingRule: String?     // autoAnswer
    public var command: String?             // block
    public var targetPath: String?          // block
    public var riskReason: String?          // block
    public var classification: String?      // nudge (PART B stall failure-mode)
    public var detail: String?              // JSON blob for anything extra

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        createdAt: Date = Date(),
        kind: AuditEntryKind,
        summary: String,
        question: String? = nil,
        contextUsed: String? = nil,
        authorizingRule: String? = nil,
        command: String? = nil,
        targetPath: String? = nil,
        riskReason: String? = nil,
        classification: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.kind = kind
        self.summary = summary
        self.question = question
        self.contextUsed = contextUsed
        self.authorizingRule = authorizingRule
        self.command = command
        self.targetPath = targetPath
        self.riskReason = riskReason
        self.classification = classification
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case createdAt = "created_at"
        case kind
        case summary
        case question
        case contextUsed = "context_used"
        case authorizingRule = "authorizing_rule"
        case command
        case targetPath = "target_path"
        case riskReason = "risk_reason"
        case classification
        case detail
    }
}

// MARK: - Review finding (v0.3.x REVIEW dimension)

/// One row of the `review_findings` table (Database.swift migration v6): a
/// code-quality observation ReviewEngine produced for a file a worker edited.
///
/// This ledger exists for DEDUP first (a `fingerprint` UNIQUE column, so the
/// same issue on the same file is surfaced once, not re-flagged every turn the
/// worker keeps editing it) and for a durable record of every finding — including
/// ones stored below the surfacing bar (`surfaced == false`), so tuning the noise
/// gate never loses data. Surfaced findings are ALSO written to `audit_entries`
/// as kind `.review` for the Activity timeline; this table is the review-specific
/// spine, the way `loop_dispatches` is the dispatch spine.
///
/// Mirrors the store shape of FlagStore / AuditStore: a `Sendable` GRDB record
/// over the serial DatabaseQueue.
public struct StoredReviewFinding: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {

    public static let databaseTableName = "review_findings"

    public var id: String
    public var sessionId: String
    public var createdAt: Date
    /// Stable dedup key: hash of (sessionId, filePath, normalized title). UNIQUE
    /// in the schema so an `insertIfNew` is a cheap, race-free "seen before?".
    public var fingerprint: String
    public var filePath: String
    public var toolName: String                 // Edit | Write | MultiEdit
    public var turnUUID: String
    public var category: String                 // incorrect_assumption | missed_edge_case | ...
    public var severity: FlagSeverity           // low | medium | high (reuses the flag vocabulary)
    public var confidence: String               // low | medium | high (EngineeringAnswer.Confidence.rawValue)
    public var title: String                    // one-line plain-language finding
    public var detail: String                   // the technical "why it matters"
    public var lineHint: String?                // optional code/line reference
    /// Whether this finding cleared the noise gate and was shown to the owner
    /// (Activity tab + audit entry). Sub-bar findings persist here with false so
    /// the gate can be tuned without losing what was seen.
    public var surfaced: Bool

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        createdAt: Date = Date(),
        fingerprint: String,
        filePath: String,
        toolName: String,
        turnUUID: String,
        category: String,
        severity: FlagSeverity,
        confidence: String,
        title: String,
        detail: String,
        lineHint: String? = nil,
        surfaced: Bool
    ) {
        self.id = id
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.fingerprint = fingerprint
        self.filePath = filePath
        self.toolName = toolName
        self.turnUUID = turnUUID
        self.category = category
        self.severity = severity
        self.confidence = confidence
        self.title = title
        self.detail = detail
        self.lineHint = lineHint
        self.surfaced = surfaced
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case createdAt = "created_at"
        case fingerprint
        case filePath = "file_path"
        case toolName = "tool_name"
        case turnUUID = "turn_uuid"
        case category
        case severity
        case confidence
        case title
        case detail
        case lineHint = "line_hint"
        case surfaced
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
