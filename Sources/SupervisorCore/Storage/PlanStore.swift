// PlanStore.swift — v0.2.0 M2a.
//
// CRUD on the `plans` + `plan_steps` tables (Database.swift migration
// v4). Same shape + concurrency model as the other stores (a `Sendable`
// struct over the serial DatabaseQueue; sync writes, no plan-state loss
// across a crash, matching FlagStore / LoopDispatchStore).
//
// PlanStore is the single mapping point between the GRDB record types
// (StoredPlan / StoredPlanStep in StorageModels.swift) and the domain
// types (Plan / PlanStep in Plan.swift). Callers — the Planner (M2b),
// Evaluator (M2c), and LoopController (M2d) — only ever see Plan /
// PlanStep; the row shape and the verdict-JSON (de)serialization stay
// here.
//
// M2a is persistence only; nothing below is wired into the live loop yet.

import Foundation
import GRDB

public struct PlanStore: Sendable {

    private let db: SupervisorDatabase

    public init(database: SupervisorDatabase) {
        self.db = database
    }

    // MARK: - Create

    /// Persist a new plan and all its steps in one transaction (so a
    /// crash never leaves a plan with a partial step list). The domain
    /// `Plan` is the source of truth; the steps are written in their
    /// given order with their own ids.
    public func create(_ plan: Plan) throws {
        try db.queue.write { conn in
            try Self.storedPlan(from: plan).insert(conn)
            for step in plan.steps {
                try Self.storedStep(from: step, planId: plan.id).insert(conn)
            }
        }
    }

    // MARK: - Read

    /// The current (latest) plan for a session, or nil if none exists.
    /// "Latest" = most recent `created_at` — the active run's plan.
    /// Steps are loaded and returned sorted by index.
    public func currentPlan(sessionId: String) throws -> Plan? {
        try db.queue.read { conn in
            guard let stored = try StoredPlan
                .filter(Column("session_id") == sessionId)
                .order(Column("created_at").desc)
                .fetchOne(conn)
            else { return nil }
            let steps = try Self.fetchSteps(planId: stored.id, conn: conn)
            return Self.plan(from: stored, steps: steps)
        }
    }

    /// Fetch one plan by id (with its steps), or nil if not found.
    public func plan(id: String) throws -> Plan? {
        try db.queue.read { conn in
            guard let stored = try StoredPlan.fetchOne(conn, key: id) else { return nil }
            let steps = try Self.fetchSteps(planId: id, conn: conn)
            return Self.plan(from: stored, steps: steps)
        }
    }

    // MARK: - Update steps

    /// Update one step's status, attempt count, and last verdict in
    /// place. `verdict` nil clears the column; pass the current verdict
    /// to leave it. `updated_at` is stamped to now. No-op if the step id
    /// doesn't exist.
    public func updateStep(
        stepId: String,
        status: PlanStep.Status,
        attempts: Int,
        verdict: PlanStep.Verdict?,
        now: Date = Date()
    ) throws {
        let verdictJSON = Self.encodeVerdict(verdict)
        try db.queue.write { conn in
            try conn.execute(
                sql: """
                    UPDATE plan_steps
                    SET status = ?, attempts = ?, last_verdict = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [status.rawValue, attempts, verdictJSON, now, stepId]
            )
        }
    }

    // MARK: - Update plan

    /// Update a plan's status and current step index in place.
    /// `updated_at` is stamped to now. No-op if the plan id doesn't exist.
    public func updatePlan(
        planId: String,
        status: Plan.Status,
        currentStepIndex: Int,
        now: Date = Date()
    ) throws {
        try db.queue.write { conn in
            try conn.execute(
                sql: """
                    UPDATE plans
                    SET status = ?, current_step_index = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [status.rawValue, currentStepIndex, now, planId]
            )
        }
    }

    /// Mark a plan approved — sets status to `approved` and stamps
    /// `approved_at` (the standing human gate). `updated_at` is stamped
    /// to the same instant. No-op if the plan id doesn't exist.
    public func markApproved(planId: String, at when: Date = Date()) throws {
        try db.queue.write { conn in
            try conn.execute(
                sql: """
                    UPDATE plans
                    SET status = ?, approved_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [Plan.Status.approved.rawValue, when, when, planId]
            )
        }
    }

    // MARK: - Mapping (domain <-> stored)

    private static func storedPlan(from plan: Plan) -> StoredPlan {
        StoredPlan(
            id: plan.id,
            sessionId: plan.sessionId,
            objective: plan.objective,
            status: plan.status.rawValue,
            currentStepIndex: plan.currentStepIndex,
            approvedAt: plan.approvedAt,
            createdAt: plan.createdAt,
            updatedAt: plan.updatedAt
        )
    }

    private static func storedStep(from step: PlanStep, planId: String) -> StoredPlanStep {
        StoredPlanStep(
            id: step.id,
            planId: planId,
            idx: step.index,
            title: step.title,
            objective: step.objective,
            doneCriteria: step.doneCriteria,
            status: step.status.rawValue,
            attempts: step.attempts,
            verdictJSON: encodeVerdict(step.lastVerdict),
            createdAt: step.createdAt,
            updatedAt: step.updatedAt
        )
    }

    private static func fetchSteps(planId: String, conn: Database) throws -> [StoredPlanStep] {
        try StoredPlanStep
            .filter(Column("plan_id") == planId)
            .order(Column("idx").asc)
            .fetchAll(conn)
    }

    private static func plan(from stored: StoredPlan, steps: [StoredPlanStep]) -> Plan {
        Plan(
            id: stored.id,
            sessionId: stored.sessionId,
            objective: stored.objective,
            steps: steps.map(planStep(from:)),
            // Unknown status strings degrade to draft rather than crashing
            // — forward compat with a newer writer.
            status: Plan.Status(rawValue: stored.status) ?? .draft,
            currentStepIndex: stored.currentStepIndex,
            approvedAt: stored.approvedAt,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt
        )
    }

    private static func planStep(from stored: StoredPlanStep) -> PlanStep {
        PlanStep(
            id: stored.id,
            index: stored.idx,
            title: stored.title,
            objective: stored.objective,
            doneCriteria: stored.doneCriteria,
            status: PlanStep.Status(rawValue: stored.status) ?? .pending,
            attempts: stored.attempts,
            lastVerdict: decodeVerdict(stored.verdictJSON),
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt
        )
    }

    // MARK: - Verdict JSON (de)serialization

    /// Encode a verdict to its JSON column string, or nil for no verdict.
    private static func encodeVerdict(_ verdict: PlanStep.Verdict?) -> String? {
        guard let verdict else { return nil }
        guard let data = try? JSONEncoder().encode(verdict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode a verdict from its JSON column string. A nil or malformed
    /// column degrades to nil (no verdict) rather than throwing.
    private static func decodeVerdict(_ json: String?) -> PlanStep.Verdict? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlanStep.Verdict.self, from: data)
    }
}
