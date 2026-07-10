// Plan.swift — v0.2.0 M2a. The Planner/Evaluator harness state model.
//
// A `Plan` is Supervisor's decomposition of a session's objective (the
// through-line read by SessionObjective) into an ordered list of
// `PlanStep`s. Each step carries the spec to inject (objective), the
// rubric the Evaluator grades against (doneCriteria), and its own
// lifecycle status + attempt count + last verdict.
//
// These are the in-memory DOMAIN types. Persistence mirrors them in the
// `plans` + `plan_steps` tables (Database.swift migration v4) via the
// GRDB record types in StorageModels.swift; PlanStore maps between the
// two. The split keeps the domain model free of GRDB column-name and
// row-id concerns: the engine reasons in Plan/PlanStep, the store deals
// in StoredPlan/StoredPlanStep.
//
// M2a is model + persistence ONLY. The Planner that produces a Plan
// (M2b), the Evaluator that fills verdicts (M2c), and the LoopController
// lifecycle that advances steps (M2d) come later. Nothing here is wired
// into the live loop yet.

import Foundation

// MARK: - PlanStep

/// One step of a Plan: a unit of work with a spec to inject and a rubric
/// to grade against. Value type — Codable + Sendable like the rest of
/// the triage model layer.
public struct PlanStep: Codable, Sendable, Equatable, Identifiable {

    /// One step's lifecycle. String-coded for forward compat and a
    /// stable on-disk representation (matches FlagSeverity / FlagAction).
    ///   - pending:  not started
    ///   - active:   currently injected, the Generator is working it
    ///   - passed:   the Evaluator graded it pass
    ///   - failed:   the Evaluator graded it fail (terminal for the step
    ///               once attempts are exhausted)
    ///   - retrying: failed but being re-attempted (redirect + retry)
    ///   - skipped:  bypassed (re-plan dropped it, or a guardrail)
    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending, active, passed, failed, retrying, skipped
    }

    /// The Evaluator's most recent grade for this step. Nested value
    /// type so a step carries its last verdict inline. Persisted as a
    /// JSON column on plan_steps (mirrors the evidence_uuids
    /// JSON-in-column precedent for a small owned value).
    public struct Verdict: Codable, Sendable, Equatable {
        public var passed: Bool
        public var score: Double
        public var feedback: String

        public init(passed: Bool, score: Double, feedback: String) {
            self.passed = passed
            self.score = score
            self.feedback = feedback
        }
    }

    /// Stable identity — survives reordering, re-plans, and persistence.
    public var id: String
    /// Position in the plan's ordered step list (0-based).
    public var index: Int
    /// Short human title for the step (shown in the Plan view later).
    public var title: String
    /// The step spec injected into the Generator — what to build.
    public var objective: String
    /// The rubric text the Evaluator grades the observed output against.
    public var doneCriteria: String
    public var status: Status
    /// How many times this step has been attempted (incremented on retry).
    public var attempts: Int
    /// The Evaluator's last grade, or nil if never graded.
    public var lastVerdict: Verdict?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        index: Int,
        title: String,
        objective: String,
        doneCriteria: String,
        status: Status = .pending,
        attempts: Int = 0,
        lastVerdict: Verdict? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.objective = objective
        self.doneCriteria = doneCriteria
        self.status = status
        self.attempts = attempts
        self.lastVerdict = lastVerdict
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Plan

/// A session's decomposed objective: an ordered list of steps plus the
/// lifecycle status of the plan as a whole. One plan per active run; the
/// latest plan for a session is the current one (PlanStore.currentPlan).
public struct Plan: Codable, Sendable, Equatable, Identifiable {

    /// The plan's lifecycle, distinct from a step's.
    ///   - draft:            built but not yet surfaced
    ///   - awaitingApproval: surfaced to the human for the one-time gate
    ///   - approved:         human approved; not yet started
    ///   - running:          the loop is driving the steps
    ///   - paused:           an escalation (human-insight trigger) fired and the
    ///                       loop was stopped for a human call. Distinct from
    ///                       `.running`: the harness REFUSES to auto-drive a
    ///                       paused plan, so it survives a Supervisor restart as a
    ///                       durable "do not resume until the human approves"
    ///                       gate (the in-memory LoopController stop does not).
    ///                       Resumed via the approve/resume path (approvePlan).
    ///   - completed:        all steps done — terminal success
    ///   - aborted:          a guardrail tripped or the human stopped it —
    ///                       TERMINAL, never auto-resumed.
    public enum Status: String, Codable, Sendable, CaseIterable {
        case draft, awaitingApproval, approved, running, paused, completed, aborted
    }

    /// Stable identity — survives persistence and re-plans.
    public var id: String
    /// The session this plan drives (StoredSession.id / JSONL uuid).
    public var sessionId: String
    /// The through-line: the session's objective, in plain text.
    public var objective: String
    /// The ordered steps. Kept sorted by `index` by the store on load.
    public var steps: [PlanStep]
    public var status: Status
    /// Index into `steps` of the step the loop is on (0-based).
    public var currentStepIndex: Int
    /// When the human approved the plan, or nil if not yet approved.
    public var approvedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        objective: String,
        steps: [PlanStep] = [],
        status: Status = .draft,
        currentStepIndex: Int = 0,
        approvedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.objective = objective
        self.steps = steps
        self.status = status
        self.currentStepIndex = currentStepIndex
        self.approvedAt = approvedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The step the loop is currently on, or nil if the index is out of
    /// range (empty plan, or completed past the last step).
    public var currentStep: PlanStep? {
        guard currentStepIndex >= 0, currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }
}
