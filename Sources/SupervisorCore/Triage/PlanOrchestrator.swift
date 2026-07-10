// PlanOrchestrator.swift - v0.2.0 M2d-1. The plan-orchestration decision brain.
//
// The Planner (M2b) decomposes the objective into a Plan; the Generator (a
// live Claude Code session) works each step; the Evaluator (M2c) grades the
// step's real output into a Verdict. This file is the BRAIN that decides what
// the loop does NEXT given that verdict plus a few out-of-band signals:
// advance, complete, redirect-and-retry, re-plan, escalate to the human, or
// abort on a hard guardrail.
//
// It is PURE on purpose. `PlanOrchestrator.decide(...)` is a standalone struct
// method with no actor, no I/O, no LLM call, and no clock of its own - every
// input it needs is passed in (the Plan, the current step, the Verdict, and an
// `OrchestrationSignals` value carrying the inputs that are not on the plan
// itself). That makes the whole decision matrix trivially unit-testable, and
// keeps the live-path concerns (persisting the transition, pausing, notifying,
// re-planning) where they belong: the LoopController (state + persistence) and,
// later, M2d-2 (the live wiring that actually executes a decision).
//
// THE MINIMAL-OVERSIGHT POLICY (PLAN.md "Decisions", locked). Within an
// approved run the loop is autonomous: routine pass/fail and step advances
// never interrupt the human. Supervisor surfaces to the human ONLY for the five
// triggers that need true human insight:
//   1. ambiguousRequirement - the step's intent is genuinely unclear and a
//      wrong guess is costly; a human should disambiguate.
//   2. destructiveAction     - an irreversible / destructive action was
//      observed. The CLASSIFICATION of "destructive" is NOT re-implemented
//      here: it defers to DeterministicCatch (the existing irreversible-command
//      classifier). The orchestrator only consumes the boolean the caller sets
//      after running DeterministicCatch over the observed commands.
//   3. planDeparture         - the Generator went off the approved plan (the
//      approved Plan is the standing human gate, so a departure from it needs a
//      human's nod).
//   4. nonConvergence        - the step has been retried to the cap, or is not
//      making progress across attempts; looping further is unlikely to help.
//   5. safetySecurity        - a safety or security concern was surfaced.
// Everything else loops without interrupting the human.
//
// Nothing here is wired into the live loop. M2d-2 wires LoopController's
// decision methods into the live generate -> evaluate -> execute cycle.

import Foundation

// MARK: - EscalationTrigger

/// Why the orchestrator wants to surface to the human. One case per the five
/// "true human insight" triggers in PLAN.md's locked Decisions. String-coded
/// for a stable on-disk / trace representation (matches LoopStopReason).
public enum EscalationTrigger: String, Sendable, Equatable, CaseIterable {
    /// The step's requirement is genuinely ambiguous; a human should clarify
    /// before the loop guesses (a wrong guess here is costly).
    case ambiguousRequirement = "ambiguous_requirement"
    /// An irreversible / destructive action was observed. Classification is
    /// DeterministicCatch's job; this trigger only carries that it fired.
    case destructiveAction = "destructive_action"
    /// The Generator departed from the approved plan. The approved Plan is the
    /// standing human gate, so a departure needs a human's nod.
    case planDeparture = "plan_departure"
    /// The step will not converge: retried to the cap, or no score progress
    /// across attempts. Looping further is unlikely to help.
    case nonConvergence = "non_convergence"
    /// A safety or security concern was surfaced and needs a human call.
    case safetySecurity = "safety_security"
    /// v0.2.0 M5: the driven long-running session has degraded far enough
    /// (session age / transcript volume / repeated attempts on one step) that a
    /// human should decide whether to reset its context. Supervisor never
    /// auto-clears: it pauses + notifies on this trigger so the reset is a human
    /// call. Distinct from the others in that the ContextSteward (not the
    /// Evaluator/Planner) raises it, at a SAFE boundary, after a non-destructive
    /// checkpoint has already been offered.
    case contextDegradation = "context_degradation"
}

// MARK: - PlanDecision

/// What the loop should do next for the current step, decided purely from the
/// verdict + signals. The caller (LoopController now, M2d-2's live wiring later)
/// executes the decision; the orchestrator never acts.
public enum PlanDecision: Sendable, Equatable {
    /// The current step passed; move to the next step.
    case advance
    /// The current step passed AND it was the last step; the plan is done.
    case complete
    /// The step failed but is under the retry cap and is still making progress;
    /// inject `feedback` (the Evaluator's verdict feedback) and retry the SAME
    /// step. `feedback` is carried verbatim so the live wiring injects exactly
    /// what the judge said.
    case redirect(feedback: String)
    /// New information makes the REMAINING plan look wrong; the caller should
    /// invoke Planner.replan with `reason` as the observation. (The orchestrator
    /// does not re-plan; it only signals that a re-plan is warranted.)
    case replan(reason: String)
    /// A true-human-insight trigger fired; the caller pauses the loop and
    /// notifies the human with `reason`. `trigger` says which of the five fired.
    case escalate(trigger: EscalationTrigger, reason: String)
    /// A hard guardrail tripped (budget/time exhausted); stop the loop. Distinct
    /// from `.escalate`: an abort is a terminal stop, not a request for human
    /// insight on how to proceed.
    case abort(reason: String)
}

// MARK: - OrchestrationSignals

/// The decision inputs that are NOT carried on the Plan/PlanStep themselves.
///
/// The Plan and the Verdict say what the step is and how it graded; these
/// signals say everything else the decision needs - how many times we have
/// attempted this step, whether the score is moving, whether the loop's
/// budget is spent, and the optional human-insight flags the Planner / Evaluator
/// surface (needs-human-input, off-plan, a DeterministicCatch destructive
/// observation, a safety concern, or fresh info that warrants a re-plan).
///
/// Plain value type so the whole decision is a pure function of (plan, step,
/// verdict, signals) and every branch is unit-testable with a literal.
public struct OrchestrationSignals: Sendable, Equatable {

    /// How many times THIS step has been attempted so far, INCLUDING the
    /// attempt that produced the verdict now being judged. On the first grade
    /// of a step this is 1. Compared against `maxAttemptsPerStep`.
    public var attemptsOnStep: Int

    /// The per-attempt scores recorded for THIS step so far, oldest first,
    /// including the score of the verdict now being judged as the last element.
    /// Used to detect "no progress across attempts" - if the latest score is no
    /// better than the prior one, retrying is not helping. A single-element
    /// (or empty) history counts as "improving" (we have nothing to compare a
    /// first attempt against, so we give it the benefit of the doubt under the
    /// cap).
    public var scoreHistoryForStep: [Double]

    /// Whether the loop's wall-clock / cost budget is exhausted. The
    /// LoopController owns the budget (its existing 4-hour wall-clock notion +
    /// any cost cap); it computes this and passes the boolean in, so the
    /// orchestrator stays free of any clock. True -> `.abort`.
    public var budgetExhausted: Bool

    // -- Optional human-insight flags surfaced by the Planner / Evaluator. --
    // Each maps to exactly one EscalationTrigger. All default false so callers
    // construct the common "no flags" case with just the numeric inputs.

    /// The Evaluator/Planner judged the step's requirement genuinely ambiguous;
    /// a human should disambiguate. -> escalate(.ambiguousRequirement).
    public var needsHumanInput: Bool

    /// The Generator departed from the approved plan (off-plan work observed).
    /// -> escalate(.planDeparture).
    public var offPlan: Bool

    /// An irreversible / destructive action was observed. This boolean is set by
    /// the caller AFTER running DeterministicCatch over the observed commands -
    /// the orchestrator does NOT classify destructiveness itself.
    /// -> escalate(.destructiveAction).
    public var destructiveActionObserved: Bool

    /// A safety or security concern was surfaced. -> escalate(.safetySecurity).
    public var safetyConcern: Bool

    /// New information indicates the REMAINING plan is wrong and should be
    /// re-planned (e.g. a discovered blocker, a changed precondition). When set,
    /// `replanReason` carries the observation for Planner.replan.
    /// -> replan(reason:). Distinct from the human-insight flags: a re-plan is
    /// autonomous (within the approved plan's spirit), not a human gate.
    public var newInfoWarrantsReplan: Bool

    /// The observation text to hand Planner.replan when `newInfoWarrantsReplan`
    /// is set. Ignored otherwise.
    public var replanReason: String

    public init(
        attemptsOnStep: Int,
        scoreHistoryForStep: [Double] = [],
        budgetExhausted: Bool = false,
        needsHumanInput: Bool = false,
        offPlan: Bool = false,
        destructiveActionObserved: Bool = false,
        safetyConcern: Bool = false,
        newInfoWarrantsReplan: Bool = false,
        replanReason: String = ""
    ) {
        self.attemptsOnStep = attemptsOnStep
        self.scoreHistoryForStep = scoreHistoryForStep
        self.budgetExhausted = budgetExhausted
        self.needsHumanInput = needsHumanInput
        self.offPlan = offPlan
        self.destructiveActionObserved = destructiveActionObserved
        self.safetyConcern = safetyConcern
        self.newInfoWarrantsReplan = newInfoWarrantsReplan
        self.replanReason = replanReason
    }

    /// True when the latest attempt's score did NOT improve on the previous
    /// attempt's - the "no progress across attempts" signal. With fewer than two
    /// scores there is nothing to compare, so it is NOT stalled (a first attempt
    /// gets the benefit of the doubt under the cap). A strictly-greater test
    /// means an equal score counts as no progress (a redirect that moved nothing
    /// is not progress).
    public var scoreStalled: Bool {
        guard scoreHistoryForStep.count >= 2 else { return false }
        let latest = scoreHistoryForStep[scoreHistoryForStep.count - 1]
        let previous = scoreHistoryForStep[scoreHistoryForStep.count - 2]
        return latest <= previous
    }
}

// MARK: - PlanOrchestrator

/// The pure decision brain. `decide(...)` maps (plan, current step, verdict,
/// signals) to a `PlanDecision`. No actor, no I/O, no LLM, no clock - fully
/// determined by its inputs, so the whole matrix is unit-testable.
///
/// PRECEDENCE (documented and enforced top-to-bottom in `decide`). Higher items
/// win over lower ones even when both could apply - in particular a
/// safety/security or destructive-action escalation OUTRANKS a passing verdict,
/// so a step that "passed" but tripped a destructive observation still escalates
/// rather than advancing:
///
///   1. abort on budget/time exhausted            (a hard guardrail beats all)
///   2. escalate safetySecurity                   (safety call, even over a pass)
///   3. escalate destructiveAction                (irreversible action, over a pass)
///   4. escalate ambiguousRequirement             (human must disambiguate)
///   5. escalate planDeparture                    (off the approved gate)
///   6. replan on new info                        (remaining plan is wrong)
///   7. verdict passed  -> advance / complete     (routine forward progress)
///   8. verdict failed, under cap, still improving -> redirect + retry
///   9. verdict failed, at cap OR not progressing -> escalate nonConvergence
///
/// Rationale for ordering the safety-class triggers (1-5) ABOVE the
/// pass/advance branch (7): the whole point of minimal-oversight is that the
/// loop is autonomous EXCEPT for the handful of calls that need a human. A
/// destructive or unsafe action does not become acceptable because the step's
/// rubric happened to pass; the human still needs to see it. Budget (1) is first
/// because once the loop is out of budget there is nothing left to do but stop,
/// regardless of any other signal.
public struct PlanOrchestrator: Sendable {

    /// Max attempts for a single step before the loop stops retrying it and
    /// escalates non-convergence. Default 3 (the M2d-1 spec; mirrors the
    /// consecutive-low threshold's "third strike" calibration). Tunable via init.
    public static let defaultMaxAttemptsPerStep = 3

    public let maxAttemptsPerStep: Int

    public init(maxAttemptsPerStep: Int = PlanOrchestrator.defaultMaxAttemptsPerStep) {
        self.maxAttemptsPerStep = maxAttemptsPerStep
    }

    /// Decide the next loop action for `currentStep` of `plan` given its
    /// `verdict` and the out-of-band `signals`. Pure: same inputs -> same
    /// output, every time. See the type-level PRECEDENCE doc for the ordering;
    /// the branches below are in that exact order.
    public func decide(
        plan: Plan,
        currentStep: PlanStep,
        verdict: PlanStep.Verdict,
        signals: OrchestrationSignals
    ) -> PlanDecision {

        // 1. Hard guardrail: out of budget/time. Nothing else can run, so this
        //    beats every other signal (including a pass, a redirect, an
        //    escalation). The loop stops.
        if signals.budgetExhausted {
            return .abort(reason: "Loop budget exhausted (wall-clock/cost cap reached) while on step \(currentStep.index + 1) of \(plan.steps.count). Stopping the run.")
        }

        // 2. Safety / security. A human call, and it outranks a passing verdict:
        //    a step that graded pass but surfaced a safety concern still
        //    escalates rather than advancing.
        if signals.safetyConcern {
            return .escalate(
                trigger: .safetySecurity,
                reason: "A safety or security concern was surfaced on step \(currentStep.index + 1) (\(currentStep.title)). Pausing for a human call before continuing."
            )
        }

        // 3. Destructive / irreversible action. The destructiveActionObserved
        //    flag is set by the caller from DeterministicCatch's classification
        //    (NOT re-derived here). Outranks a passing verdict for the same
        //    reason as safety.
        if signals.destructiveActionObserved {
            return .escalate(
                trigger: .destructiveAction,
                reason: "An irreversible or destructive action was observed on step \(currentStep.index + 1) (\(currentStep.title)) (flagged by the deterministic catch-list). Pausing for human review before it proceeds."
            )
        }

        // 4. Ambiguous requirement. The step's intent is genuinely unclear; a
        //    wrong autonomous guess is costly, so a human disambiguates.
        if signals.needsHumanInput {
            return .escalate(
                trigger: .ambiguousRequirement,
                reason: "Step \(currentStep.index + 1) (\(currentStep.title)) has an ambiguous requirement that needs a human to clarify before the loop proceeds."
            )
        }

        // 5. Plan departure. The Generator went off the approved plan; the
        //    approved Plan is the standing human gate, so a departure needs a
        //    human's nod.
        if signals.offPlan {
            return .escalate(
                trigger: .planDeparture,
                reason: "The session departed from the approved plan on step \(currentStep.index + 1) (\(currentStep.title)). Pausing so a human can confirm the change to the approved plan."
            )
        }

        // 6. New info warrants a re-plan: the REMAINING plan looks wrong. This
        //    is autonomous (still within the approved plan's spirit), so it sits
        //    below the human-gate triggers but above routine advance/redirect -
        //    a re-plan supersedes acting on a now-stale step.
        if signals.newInfoWarrantsReplan {
            let reason = signals.replanReason.isEmpty
                ? "New information indicates the remaining plan no longer fits; re-planning the remainder."
                : signals.replanReason
            return .replan(reason: reason)
        }

        // 7. Routine forward progress: the step passed. Advance to the next
        //    step, or complete the plan if this was the last one.
        if verdict.passed {
            return isLastStep(plan: plan, step: currentStep) ? .complete : .advance
        }

        // -- The step FAILED below this point. --

        // 8. Failed, but under the attempt cap AND still making progress: inject
        //    the verdict feedback and retry the same step. "Still making
        //    progress" = the score is not stalled (latest > previous, or this is
        //    an early attempt with nothing to compare). Carry the feedback
        //    verbatim so the live wiring injects exactly what the judge said.
        if signals.attemptsOnStep < maxAttemptsPerStep && !signals.scoreStalled {
            return .redirect(feedback: verdict.feedback)
        }

        // 9. Failed AND (at/over the attempt cap OR not progressing across
        //    attempts): escalate non-convergence. Looping further is unlikely to
        //    help, so surface to the human rather than burn attempts. The reason
        //    names which of the two conditions tripped.
        let why: String
        if signals.attemptsOnStep >= maxAttemptsPerStep {
            why = "reached the \(maxAttemptsPerStep)-attempt cap without passing"
        } else {
            why = "is not making progress across attempts (score did not improve)"
        }
        return .escalate(
            trigger: .nonConvergence,
            reason: "Step \(currentStep.index + 1) (\(currentStep.title)) \(why). Pausing for human direction rather than retrying further."
        )
    }

    // MARK: - Helpers

    /// True when `step` is the last step of `plan` (by index against the step
    /// count). Used to choose `.complete` over `.advance` on a pass.
    private func isLastStep(plan: Plan, step: PlanStep) -> Bool {
        step.index >= plan.steps.count - 1
    }
}
