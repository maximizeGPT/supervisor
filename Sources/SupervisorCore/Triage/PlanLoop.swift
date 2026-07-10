// PlanLoop.swift - v0.2.0 M2d-2. The live plan-driver.
//
// M2b/M2c/M2d-1 built the engine pieces (Planner, Evaluator, PlanOrchestrator)
// and the persistence + pure decision brain (LoopController.decideAndRecord).
// This file is the LIVE WIRING that ties them into the idle/drive loop so an
// approved plan actually runs: it creates a plan when the toggle is on, drives
// the current step, observes the session's real output, evaluates it, asks the
// LoopController for the decision, and EXECUTES that decision via the existing
// injection / notify path.
//
// SAFETY (the whole reason this is a separate, gated unit):
//   - GATED + OPT-IN. The engine only consults this when RuntimeToggles
//     .plannerEnabled is ON. Off (the default), the engine's idle path is the
//     untouched Dispatcher path; this type is never entered.
//   - EVERY step injection rides the EXISTING marked+ledgered injection path:
//     PlanLoop never injects directly. It hands the engine a `.continue` /
//     `.notify` TriageDecision and the engine emits it through `onDecision` ->
//     InterventionRouter, which records it in the InjectionLedger before typing.
//     So the triage can never read a plan injection back as owner authorization.
//     The injection itself reads clean (no in-text banner): the no-stamp
//     decision moved all provenance to the ledger.
//   - ESCALATION = pause + notify, NEVER auto-continue. An escalate decision
//     stops the loop (LoopController.stop) and surfaces a banner; the human is
//     the only thing that resumes it.
//   - Redaction stays in LLMClient (the Planner/Evaluator inherit it) and
//     DeterministicCatch is reused verbatim for the destructive-action signal.
//
// PlanLoop owns no state of its own beyond its injected collaborators; the
// durable plan state lives in PlanStore and the per-step counters in
// LoopController. It is a coordinator, intentionally thin, so TriageEngine stays
// readable.

import Foundation

/// What PlanLoop asks the engine to DO after it has decided. The engine
/// (which owns `onDecision` + the session window + the trace) carries these
/// out; PlanLoop never touches the router or the bus directly. Keeping the
/// side effects as a returned value also makes the whole drive cycle
/// unit-testable: a test drives `driveIdleStep` / `createPlan` and asserts on
/// the returned action without a live router.
public enum PlanLoopAction: Sendable, Equatable {
    /// Do nothing this idle tick (e.g. the gate is closed, or an evaluate/replan
    /// call could not produce a usable next move). The caller falls through to
    /// whatever it would have done, or stays silent. `reason` is for the trace.
    case none(reason: String)
    /// Inject `text` into the session as a marked Supervisor turn (a plan step
    /// or a redirect). The engine builds a `.continue`/high-confidence decision
    /// so it flows through the existing marked+ledgered router path. `stepIndex`
    /// + `kind` are for the trace/banner only.
    case inject(text: String, stepIndex: Int, kind: InjectKind)
    /// Surface `message` to the human as a plain notify banner (plan ready to
    /// approve, plan complete, escalation, abort). No injection. `escalation`
    /// carries the trigger when this notify is an escalation (so the caller can
    /// also pause the loop), nil otherwise.
    case notify(message: String, escalation: EscalationTrigger?)

    /// Why an injection is being made - for the trace, not user-facing.
    public enum InjectKind: String, Sendable, Equatable {
        /// The first step of a freshly-approved plan.
        case firstStep = "first_step"
        /// The next step after the previous one passed.
        case nextStep = "next_step"
        /// A redirect: the evaluator's feedback, retrying the same step.
        case redirect
        /// The current step of a freshly re-planned plan.
        case replanStep = "replan_step"
    }
}

/// The live plan-driver. Stateless aside from its collaborators; safe to hold
/// one per engine. Not an actor - every method is async and awaits the
/// (actor-isolated) LoopController / (Sendable) Planner+Evaluator, and PlanLoop
/// itself keeps no mutable state, so there is nothing to serialize.
public struct PlanLoop: Sendable {

    private let planner: any Planning
    private let evaluator: any Evaluating
    /// The plan store. Exposed read-only so the engine can resolve a plan's
    /// session for targeting after `approvePlan` (the harness otherwise keeps the
    /// store private). All WRITES still go through PlanLoop's own methods.
    public let planStore: PlanStore
    private let loopController: LoopController
    /// v0.2.0 M5: the pure context-health classifier. Consulted ONLY at the SAFE
    /// post-pass / pre-next-step boundary (the advance branch), never mid-step.
    /// Its `.checkpoint` becomes a non-destructive handoff instruction prepended
    /// to the next step's injection (one marked + ledgered inject); its `.severe`
    /// routes through the existing escalate (pause + notify) path. Injectable so
    /// thresholds are tunable in tests; defaults to the standard steward.
    private let contextSteward: ContextSteward
    /// v0.2.0 observability (Reddit feedback A): optional unified audit log.
    /// When non-nil, the drive cycle records kind=planStep (the step being
    /// driven) and kind=verdict (the Evaluator's grade: score + feedback)
    /// ADDITIVELY. Recording never changes the drive/evaluate/decide behavior;
    /// nil disables it (tests / no DB).
    private let auditStore: AuditStore?
    private let trace: TraceLog

    public init(
        planner: any Planning,
        evaluator: any Evaluating,
        planStore: PlanStore,
        loopController: LoopController,
        contextSteward: ContextSteward = ContextSteward(),
        auditStore: AuditStore? = nil,
        trace: TraceLog = .shared
    ) {
        self.planner = planner
        self.evaluator = evaluator
        self.planStore = planStore
        self.loopController = loopController
        self.contextSteward = contextSteward
        self.auditStore = auditStore
        self.trace = trace
    }

    // MARK: - Gate helpers

    /// The plan that the drive loop should ACT on for a session: the current
    /// (latest) plan when it is approved+running, else nil. A plan that is still
    /// awaiting approval (or draft/completed/aborted) is NOT driven - the loop
    /// leaves it to the human (approval is the standing gate). This is the second
    /// half of the gate (the first being the toggle): with no approved running
    /// plan, the caller keeps the existing Dispatcher path.
    ///
    /// FIX 2: this is also the DURABLE re-entry refusal. Only `.running` is
    /// driven, so a `.paused` (escalated) or `.aborted` (terminal) plan is never
    /// re-driven - even after a Supervisor restart, when the in-memory
    /// LoopController stop is gone but the persisted plan status is not. A paused
    /// plan resumes ONLY when the human approves/resumes it (approvePlan flips it
    /// back to .running).
    public func runningPlan(sessionId: String) -> Plan? {
        guard let plan = (try? planStore.currentPlan(sessionId: sessionId)) ?? nil else { return nil }
        return plan.status == .running ? plan : nil
    }

    /// Does the session already have ANY plan (in any status)? Used to decide
    /// whether the idle path should CREATE a plan: it only creates one when there
    /// is none yet, so it never clobbers an awaiting-approval / completed plan.
    public func hasAnyPlan(sessionId: String) -> Bool {
        ((try? planStore.currentPlan(sessionId: sessionId)) ?? nil) != nil
    }

    // MARK: - Plan creation (idle, toggle on, objective present, no plan)

    /// Create an awaiting-approval plan for an idle session via the Planner, and
    /// return the notify action that tells the human a plan is ready to approve.
    /// Returns `.none` when the Planner could not ground a plan (the caller then
    /// falls back to the single-step Dispatcher, exactly as today). The plan is
    /// persisted by the Planner with status=awaitingApproval; it is NOT driven
    /// until the human approves (approvePlan).
    public func createPlan(
        sessionId: String,
        cwd: String?,
        gitBranch: String?,
        window: [SupervisorEvent]
    ) async -> PlanLoopAction {
        trace.emit("planloop", "createPlan session=\(sessionId) (toggle on, objective present, no existing plan)")
        let result = await planner.planForSession(
            sessionUUID: sessionId,
            cwd: cwd,
            gitBranch: gitBranch,
            lastNTurns: window
        )
        switch result {
        case let .planned(plan):
            trace.emit("planloop", "plan created session=\(sessionId) plan=\(plan.id) steps=\(plan.steps.count) status=\(plan.status.rawValue) - awaiting approval")
            let stepWord = plan.steps.count == 1 ? "step" : "steps"
            return .notify(
                message: "Supervisor drafted a \(plan.steps.count)-\(stepWord) plan for this session and is waiting for your approval before it starts driving. Open the panel to review and approve it.",
                escalation: nil
            )
        case let .ungrounded(reasoning):
            trace.emit("planloop", "plan ungrounded session=\(sessionId): \(reasoning.prefix(160)) - falling back to Dispatcher")
            return .none(reason: "planner_ungrounded")
        case let .error(reasoning):
            trace.emit("planloop", "plan error session=\(sessionId): \(reasoning.prefix(160)) - falling back to Dispatcher")
            return .none(reason: "planner_error")
        }
    }

    // MARK: - Approval entry point

    /// Approve a plan and return the action that injects its CURRENT step (the
    /// first step to drive). The M3 UI calls this from the panel's Approve
    /// button; it is also directly testable. Sets the plan approved+running and
    /// marks the current step active, then returns the inject action for the
    /// current step's objective (which the caller emits through the marked
    /// injection path). Returns `.none` when the plan id is unknown, the plan is
    /// not in an approvable state, or it has no current step.
    ///
    /// - `planId`: the plan to approve.
    /// - `now`: timestamp for the persisted approval + status writes.
    @discardableResult
    public func approvePlan(planId: String, now: Date = Date()) async -> PlanLoopAction {
        guard let plan = (try? planStore.plan(id: planId)) ?? nil else {
            trace.emit("planloop", "approvePlan: unknown plan id=\(planId)")
            return .none(reason: "unknown_plan")
        }
        // Only an awaiting-approval (or approved-but-not-started, defensively)
        // plan can be approved into running. A running/completed/aborted plan is
        // left alone so a double-approve is a no-op.
        //
        // FIX 2: `.paused` is ALSO approvable here - this is the explicit human
        // RESUME path. An escalation persisted the plan .paused (durably refusing
        // auto-drive across a restart); approving/resuming it re-injects its
        // current step and flips it back to .running, so the human's nod is the
        // only thing that lifts the pause. `.aborted` is terminal and stays out.
        guard plan.status == .awaitingApproval || plan.status == .approved || plan.status == .draft || plan.status == .paused else {
            trace.emit("planloop", "approvePlan: plan=\(planId) not approvable (status=\(plan.status.rawValue))")
            return .none(reason: "not_approvable")
        }
        guard let step = plan.currentStep else {
            trace.emit("planloop", "approvePlan: plan=\(planId) has no current step (index=\(plan.currentStepIndex), steps=\(plan.steps.count))")
            return .none(reason: "no_current_step")
        }

        // Stamp approval, then move the plan to running with the current step
        // active. markApproved sets status=approved + approved_at; updatePlan then
        // flips it to running (we keep approved_at). The step goes active so the
        // observation window is anchored from "now" (the inject we are about to
        // make is the step's start).
        try? planStore.markApproved(planId: planId, at: now)
        try? planStore.updatePlan(planId: planId, status: .running, currentStepIndex: plan.currentStepIndex, now: now)
        try? planStore.updateStep(stepId: step.id, status: .active, attempts: step.attempts, verdict: step.lastVerdict, now: now)

        trace.emit("planloop", "approvePlan: plan=\(planId) -> running, injecting first step index=\(step.index) title=\(step.title.prefix(48))")
        // v0.2.0 M6: frame the first step's spec with the standing criteria bar
        // (general always, design bar when the step looks like UI work) so the
        // Generator is steered up front. Same marked + ledgered inject path.
        return .inject(text: Self.steeredSpec(for: step), stepIndex: step.index, kind: .firstStep)
    }

    // MARK: - Drive + evaluate cycle (idle, approved running plan)

    /// Drive one idle tick for a session with an approved running plan: collect
    /// the activity since the current step was injected, build the Observation,
    /// run DeterministicCatch over the observed commands, evaluate the step,
    /// decide via the LoopController, and return the action that EXECUTES the
    /// decision. This is the heart of the generate -> evaluate -> execute cycle.
    ///
    /// - `plan`: the approved running plan (caller passes `runningPlan`).
    /// - `sessionId` / `cwd`: the session being driven.
    /// - `window`: the engine's recent event window for the session (used as the
    ///   raw stream to slice the step's observation out of).
    /// - `stepInjectedAt`: when the current step was injected, from the
    ///   InjectionLedger; events at/after this are the step's activity. nil means
    ///   "no recorded injection for the current step" - we fall back to the whole
    ///   window (best effort) and note it in the trace.
    /// - `now`: timestamp for persisted transitions (injectable for tests).
    /// - `consecutiveUngradableTicks`: how many PRIOR consecutive idle ticks on
    ///   THIS step already returned `.none(no_ground_truth_yet)` (the engine owns
    ///   this counter in its per-session idle state and resets it when the step
    ///   changes or real ground truth appears). FIX 5 uses it to bound the skip:
    ///   once this-tick's skip would reach `maxUngradableTicksBeforeEscalate`, the
    ///   step is escalated (pause + notify) instead of skipped forever.
    public func driveIdleStep(
        plan: Plan,
        sessionId: String,
        cwd: String?,
        window: [SupervisorEvent],
        stepInjectedAt: Date?,
        consecutiveUngradableTicks: Int = 0,
        now: Date = Date()
    ) async -> PlanLoopAction {
        guard let step = plan.currentStep else {
            trace.emit("planloop", "drive: plan=\(plan.id) has no current step (index=\(plan.currentStepIndex)); nothing to drive")
            return .none(reason: "no_current_step")
        }

        // a. Observation since the step was injected: slice the window to events
        //    at/after the injection timestamp, then distill via the M2c builder.
        let sinceEvents = Self.eventsSince(stepInjectedAt, in: window)
        if stepInjectedAt == nil {
            trace.emit("planloop", "drive: no recorded inject time for step=\(step.index); observing the full window (\(window.count) events)")
        }
        let observation = ObservationBuilder.build(from: sinceEvents, stepTitle: step.title)
        trace.emit("planloop", "drive: session=\(sessionId) plan=\(plan.id) step=\(step.index) obs_commands=\(observation.commands.count) obs_errors=\(observation.errors.count) noGroundTruth=\(observation.hasNoGroundTruth)")

        // FIX 2 (adversarial review): do NOT grade an EMPTY observation window when
        // we KNOW when the step was injected. Right after a step is injected
        // (firstStep/advance/redirect), an idle tick can arrive before the Generator
        // has run anything SINCE the inject anchor. The window then has no ground
        // truth, and grading emptiness yields a conservative fail -> a spurious
        // redirect + a wasted attempt. Skip the evaluate/decide cycle this tick and
        // stay silent (no inject, no notify, no attempt increment - decideAndRecord
        // is what bumps the counter, and we return before it). A later idle tick
        // with real activity grades the step.
        //
        // Gated on stepInjectedAt != nil: the skip is meaningful only when there is
        // a real "since the injection" anchor. With no recorded inject time we are
        // already on the best-effort whole-window fallback (see above), where an
        // empty window carries no "nothing happened since inject" signal - so we
        // leave that path's grading behavior unchanged.
        if stepInjectedAt != nil && observation.hasNoGroundTruth {
            // FIX 5: bound the skip. A step done purely via Write/Edit produces no
            // Bash and no file-change events (the pipeline emits Bash only today),
            // so hasNoGroundTruth holds EVERY tick and this branch would loop
            // forever - the step never grades, advances, or escalates until the 6h
            // dormancy sweep. Once we have skipped it for K consecutive ticks,
            // stop skipping: pause the loop + persist the plan paused + notify a
            // human that the step is inject-anchored but ungradable. `+ 1` counts
            // THIS tick's skip alongside the prior ones the engine has tallied.
            if consecutiveUngradableTicks + 1 >= Self.maxUngradableTicksBeforeEscalate {
                await loopController.stop(sessionId: sessionId, reason: .explicitStop)
                try? planStore.updatePlan(planId: plan.id, status: .paused, currentStepIndex: step.index, now: now)
                trace.emit("planloop", "drive: session=\(sessionId) plan=\(plan.id) step=\(step.index) - ungradable for \(consecutiveUngradableTicks + 1) consecutive ticks (no observable ground truth); pausing + escalating (edit-only or unobservable step)")
                return .notify(
                    message: "Supervisor paused the plan and needs your input: step \(step.index + 1) (\(step.title)) has produced no observable ground truth (no commands ran and no file changes were captured) for \(consecutiveUngradableTicks + 1) checks, so it cannot be graded automatically. Confirm it is done, give direction, or resume the plan.",
                    escalation: .nonConvergence
                )
            }
            trace.emit("planloop", "drive: session=\(sessionId) plan=\(plan.id) step=\(step.index) - no ground truth since inject anchor; skipping the grade this tick (no redirect, no attempt spent; ungradable streak=\(consecutiveUngradableTicks + 1)/\(Self.maxUngradableTicksBeforeEscalate))")
            return .none(reason: "no_ground_truth_yet")
        }

        // b. DeterministicCatch over the OBSERVED commands -> destructive signal.
        //    Reused verbatim (not re-implemented); a hit on any observed command
        //    sets destructiveActionObserved so the orchestrator escalates.
        let destructive = Self.observedDestructive(observation)
        if let caught = destructive {
            trace.emit("planloop", "drive: destructive observed step=\(step.index) pattern=\(caught.pattern) -> will escalate")
        }

        // FIX 3 (SAFETY signal): screen the observed commands for a non-destructive
        // harmful shape (network-exec / exfil / persistence / sudo / force-push)
        // the destructive family does not cover. A hit sets safetyConcern so the
        // orchestrator escalates .safetySecurity.
        let safety = Self.observedSafetyConcern(observation)
        if let safety {
            trace.emit("planloop", "drive: safety concern observed step=\(step.index) reason=\(safety) -> will escalate")
        }

        // c. Evaluate the step against its rubric on the ground truth.
        let verdict = await evaluator.evaluate(step: step, observation: observation)

        // v0.2.0 observability A: record the step being driven and the verdict
        // (score + feedback) ADDITIVELY. Best-effort; never blocks the cycle.
        recordPlanStepAudit(sessionId: sessionId, plan: plan, step: step, observation: observation, now: now)
        recordVerdictAudit(sessionId: sessionId, step: step, verdict: verdict, now: now)

        // d. Decide + persist the transition via the LoopController (M2d-1). The
        //    controller owns the per-step attempt/score counters; we only pass
        //    the out-of-band signals the live driver can actually observe.
        //
        //    WIRED signals (FIX 3): destructiveActionObserved (DeterministicCatch)
        //    and safetyConcern (InjectionSafetyScreen over observed commands) - both
        //    are PRECISE deny-list classifiers, so they never mis-flag ordinary work.
        //    NOT wired here (documented so no dead "we'll pause for X" guarantee):
        //      - offPlan / .planDeparture: a RELIABLE off-plan detector needs a
        //        semantic judgement of "is this work about the step?". A deterministic
        //        lexical heuristic mis-fires on ordinary work - e.g. `swift build` on a
        //        "SwiftUI view compiles" step shares no literal token yet is exactly
        //        on-plan - and pausing a healthy plan is worse than not detecting
        //        departure, so the live driver does NOT raise it. The orchestrator
        //        branch stays a valid contract for a future caller with a real (LLM)
        //        departure signal.
        //      - needsHumanInput / .ambiguousRequirement: likewise needs a semantic
        //        judgement the deterministic drive tick does not make.
        //      - newInfoWarrantsReplan / .replan: intentionally DORMANT + safe-by-
        //        default (see replanAndInject) - re-gated for human approval, never
        //        auto-resumed - so the driver does not raise it either.
        let signals = OrchestrationSignals(
            attemptsOnStep: 0,  // overridden by the controller from its own counter
            destructiveActionObserved: destructive != nil,
            safetyConcern: safety != nil
        )
        let outcome = await loopController.decideAndRecord(
            sessionId: sessionId, plan: plan, step: step, verdict: verdict,
            extraSignals: signals, now: now
        )

        // e. Execute the decision via the existing infra.
        return await execute(
            decision: outcome.decision,
            plan: plan, step: step, sessionId: sessionId, cwd: cwd,
            observation: observation, window: window, now: now
        )
    }

    /// Map a PlanDecision to the live action that carries it out. Persistence of
    /// the transition already happened in decideAndRecord; this only produces the
    /// inject/notify side effect and the terminal loop-state changes (complete /
    /// escalate pause / abort).
    private func execute(
        decision: PlanDecision,
        plan: Plan,
        step: PlanStep,
        sessionId: String,
        cwd: String?,
        observation: Observation,
        window: [SupervisorEvent],
        now: Date
    ) async -> PlanLoopAction {
        switch decision {
        case .advance:
            // The step passed; the controller already advanced the cursor +
            // marked the step passed. Inject the NEXT step (now the current one).
            // Re-read the plan so we see the advanced cursor + can mark the new
            // step active. If there is somehow no next step, treat as complete.
            guard let next = nextStep(after: step, sessionId: sessionId) else {
                trace.emit("planloop", "advance: no next step after index=\(step.index); treating as complete session=\(sessionId)")
                return .notify(message: Self.completeMessage(plan: plan), escalation: nil)
            }

            // v0.2.0 M5 - THE SAFE BOUNDARY. The step just passed and we are about
            // to inject the next one (never mid-step). Consult the context steward
            // on the long-running-session signals. Three outcomes:
            //   - .severe: do NOT inject the next step; ESCALATE (pause + notify)
            //     so the HUMAN decides whether to reset context. Never auto-clear.
            //   - .checkpoint (cooldown clear): PREPEND a non-destructive
            //     "write progress to a file" instruction to the next step's
            //     injection (one marked + ledgered inject), arm the cooldown, then
            //     advance normally.
            //   - .ok (or .checkpoint suppressed by cooldown): inject the next step
            //     exactly as before.
            let stewardAction = await stewardCheckpointOrEscalate(
                plan: plan, nextStep: next, sessionId: sessionId,
                window: window, now: now
            )
            switch stewardAction {
            case let .escalate(reason):
                // Route through the SAME escalate path the orchestrator uses: pause
                // the loop (stop) and notify; no auto-continue, no next-step inject,
                // no /clear. FIX 2: persist the plan .paused (durable across restart,
                // like the orchestrator escalate branch) so runningPlan() refuses to
                // re-drive it until the human resumes. The cursor was already advanced
                // to `next` by decideAndRecord, so the human resumes at the next step.
                await loopController.stop(sessionId: sessionId, reason: .explicitStop)
                try? planStore.updatePlan(planId: plan.id, status: .paused, currentStepIndex: next.index, now: now)
                trace.emit("planloop", "escalate(contextDegradation): session=\(sessionId) - loop paused + plan persisted PAUSED at safe boundary before step=\(next.index), notifying human (no auto-continue, no clear)")
                return .notify(
                    message: "Supervisor paused the plan and needs your input: \(reason)",
                    escalation: .contextDegradation
                )
            case let .checkpoint(preamble):
                // Mark the next step active (its window anchors from this combined
                // inject) and inject ONE marked + ledgered injection composing,
                // in order: the M6 standing criteria bar (the quality frame), the
                // M5 transient checkpoint note (write progress to HANDOFF.md), then
                // the next step's objective. The two preambles are distinct blocks
                // and each appears exactly once. The cooldown was armed inside
                // stewardCheckpointOrEscalate.
                try? planStore.updateStep(stepId: next.id, status: .active, attempts: next.attempts, verdict: next.lastVerdict, now: now)
                trace.emit("planloop", "advance+checkpoint: session=\(sessionId) injecting criteria bar + non-destructive checkpoint then next step index=\(next.index)")
                return .inject(text: Self.steeredSpec(for: next, checkpointNote: preamble), stepIndex: next.index, kind: .nextStep)
            case .none:
                break  // fall through to the normal next-step inject below
            }

            try? planStore.updateStep(stepId: next.id, status: .active, attempts: next.attempts, verdict: next.lastVerdict, now: now)
            trace.emit("planloop", "advance: session=\(sessionId) injecting next step index=\(next.index) title=\(next.title.prefix(48))")
            // v0.2.0 M6: frame the next step's spec with the standing criteria bar.
            return .inject(text: Self.steeredSpec(for: next), stepIndex: next.index, kind: .nextStep)

        case .complete:
            // Last step passed; plan is completed (persisted). Stop driving this
            // session's loop cleanly and notify the human the objective is built.
            await loopController.stop(sessionId: sessionId, reason: .objectiveComplete)
            trace.emit("planloop", "complete: session=\(sessionId) plan=\(plan.id) - objective built, loop stopped")
            return .notify(message: Self.completeMessage(plan: plan), escalation: nil)

        case let .redirect(feedback):
            // The step failed but is being re-attempted under the cap. Inject the
            // evaluator's feedback verbatim as a retry on the SAME step.
            let text = feedback.isEmpty
                ? "The previous attempt did not meet this step's done-criteria. Re-attempt it and make sure the criteria are explicitly met, then stop."
                : feedback
            trace.emit("planloop", "redirect: session=\(sessionId) step=\(step.index) injecting evaluator feedback (\(text.utf8.count) bytes)")
            return .inject(text: text, stepIndex: step.index, kind: .redirect)

        case let .replan(reason):
            // New info makes the remaining plan look wrong. Re-plan via the
            // Planner, then inject the revised plan's CURRENT step. If the
            // re-plan cannot ground, hold (notify) rather than injecting nothing.
            return await replanAndInject(existing: plan, reason: reason, sessionId: sessionId, cwd: cwd, now: now)

        case let .escalate(trigger, reason):
            // A true-human-insight trigger fired. PAUSE the loop (stop) and
            // notify; do NOT auto-continue. The human is the only resume.
            //
            // FIX 2: the in-memory loopController.stop does NOT survive a Supervisor
            // restart, and decideAndRecord persisted the plan .running on escalate -
            // so after a restart runningPlan() would re-drive the very step that was
            // escalated (stepAttempts reset), re-escalate, forever. Persist the plan
            // .paused so the DURABLE status is the gate: runningPlan() refuses to
            // drive a paused plan, and only an explicit human resume/approve
            // (approvePlan) puts it back to .running. Hold the cursor on the same
            // step so the human resumes exactly where it paused.
            await loopController.stop(sessionId: sessionId, reason: .explicitStop)
            try? planStore.updatePlan(planId: plan.id, status: .paused, currentStepIndex: step.index, now: now)
            trace.emit("planloop", "escalate: session=\(sessionId) trigger=\(trigger.rawValue) - loop paused + plan persisted PAUSED (survives restart), notifying human (no auto-continue)")
            return .notify(message: "Supervisor paused the plan and needs your input: \(reason)", escalation: trigger)

        case let .abort(reason):
            // A hard guardrail tripped. The plan is aborted (TERMINAL); stop the
            // loop and notify. Distinct from escalate: never auto-resumed.
            // decideAndRecord already persisted .aborted; re-assert it here so the
            // terminal status holds even if this branch is ever reached without the
            // controller having recorded it.
            await loopController.stop(sessionId: sessionId, reason: .explicitStop)
            try? planStore.updatePlan(planId: plan.id, status: .aborted, currentStepIndex: step.index, now: now)
            trace.emit("planloop", "abort: session=\(sessionId) plan=\(plan.id) - \(reason) - plan persisted ABORTED (terminal)")
            return .notify(message: "Supervisor stopped the plan: \(reason)", escalation: nil)
        }
    }

    // MARK: - Context steward (v0.2.0 M5 - safe checkpoint / escalate at advance)

    /// The internal outcome of consulting the context steward at the advance
    /// boundary. Mapped by `execute`'s `.advance` branch to a PlanLoopAction.
    private enum StewardOutcome: Sendable, Equatable {
        /// Inject the next step normally (steward said ok, OR a checkpoint was
        /// suppressed by the cooldown). No side effect.
        case none
        /// A non-destructive checkpoint is warranted and the cooldown is clear:
        /// prepend `preamble` to the next step's injection. The cooldown has ALREADY
        /// been armed by the time this is returned.
        case checkpoint(preamble: String)
        /// Severe degradation: ESCALATE (pause + notify) with `reason`. The caller
        /// does NOT inject the next step and does NOT auto-clear.
        case escalate(reason: String)
    }

    /// Consult the context steward at the SAFE post-pass / pre-next-step boundary.
    /// Builds the long-running-session signals from the live state (session age
    /// from the earliest event in the window vs `now`; the recent event count; the
    /// attempts on the NEXT step from the LoopController), asks the steward, and
    /// maps the verdict:
    ///   - .severe -> .escalate (the caller pauses + notifies; never auto-clears).
    ///   - .checkpoint, cooldown CLEAR -> arm the cooldown + return a non-destructive
    ///     checkpoint preamble to prepend to the next step's injection.
    ///   - .checkpoint, cooldown ACTIVE -> .none (suppressed; do not re-checkpoint).
    ///   - .ok -> .none.
    /// Pure aside from reading the LoopController state and (on a fresh checkpoint)
    /// arming the cooldown; it performs NO injection itself.
    private func stewardCheckpointOrEscalate(
        plan: Plan,
        nextStep: PlanStep,
        sessionId: String,
        window: [SupervisorEvent],
        now: Date
    ) async -> StewardOutcome {
        // Session age: earliest event timestamp we have for the session vs now. With
        // an empty window the age is 0 (reads as "young", trips nothing on its own).
        let earliest = window.map(\.timestamp).min()
        let ageSeconds = earliest.map { now.timeIntervalSince($0) } ?? 0
        // attemptsOnStep here reads the ABOUT-TO-START next step (not the step that
        // just passed), so under fire the attempts signal is conservative by design:
        // a fresh next step reads 0 attempts, never inflating the steward's verdict.
        let attemptsOnNext = await loopController.attemptsOnStep(sessionId: sessionId, stepId: nextStep.id)
        let signals = ContextSignals(
            sessionAgeSeconds: ageSeconds,
            eventCount: window.count,
            attemptsOnThisStep: attemptsOnNext
        )
        let decision = contextSteward.assess(signals)
        switch decision {
        case .ok:
            return .none
        case let .severe(reason):
            trace.emit("planloop", "steward: session=\(sessionId) SEVERE age=\(Int(ageSeconds))s events=\(window.count) attempts=\(attemptsOnNext) -> escalate(contextDegradation)")
            return .escalate(reason: reason)
        case let .checkpoint(reason):
            // Cooldown gate: do not re-checkpoint within the cooldown window.
            if await loopController.checkpointCooldownActive(sessionId: sessionId, planId: plan.id, atStepIndex: nextStep.index) {
                trace.emit("planloop", "steward: session=\(sessionId) checkpoint warranted but SUPPRESSED by cooldown (next step index=\(nextStep.index)) - injecting next step normally")
                return .none
            }
            await loopController.recordCheckpoint(sessionId: sessionId, planId: plan.id, atStepIndex: nextStep.index)
            trace.emit("planloop", "steward: session=\(sessionId) CHECKPOINT age=\(Int(ageSeconds))s events=\(window.count) attempts=\(attemptsOnNext): \(reason.prefix(120))")
            return .checkpoint(preamble: Self.checkpointInstruction)
        }
    }

    /// The non-destructive handoff checkpoint instruction. Prepended to the next
    /// step's injection at a safe boundary when the steward warrants a checkpoint.
    /// It NEVER asks for a context clear: it asks the Generator to WRITE its
    /// progress + the remaining plan to a durable file so the run can resume
    /// cleanly if context is later reset (the harness "structured artifacts for
    /// state" principle). Plain, no em dashes.
    static let checkpointInstruction =
        "Checkpoint before continuing: this session has been running a while, so append your current progress and the remaining plan steps to a HANDOFF.md file in the repo (create it if absent) so we can resume cleanly if the context is reset. Do not clear or compact anything yourself. Once the checkpoint is written, continue with the step below."

    // MARK: - Criteria steering (v0.2.0 M6 - standing quality bar at step start)

    /// Compose the text injected for a step's spec: the M6 standing criteria bar
    /// (general always; the design bar appended when the step looks like UI work),
    /// then an OPTIONAL M5 transient checkpoint note, then the step's own
    /// objective. The criteria bar FRAMES the spec (it leads); the checkpoint note
    /// is a distinct transient block in the middle; the objective is the work. Each
    /// piece appears exactly once, separated by a blank line, so the composition is
    /// clean with or without the checkpoint. Pure; the result still rides the
    /// existing marked + ledgered inject path unchanged.
    ///
    /// - `step`: the step whose objective is being injected.
    /// - `checkpointNote`: the M5 checkpoint preamble when the steward warranted a
    ///   checkpoint at this advance boundary, else nil (the common case).
    static func steeredSpec(for step: PlanStep, checkpointNote: String? = nil) -> String {
        var parts = [CriteriaSteering.preamble(for: step)]
        if let checkpointNote, !checkpointNote.isEmpty {
            parts.append(checkpointNote)
        }
        parts.append(step.objective)
        return parts.joined(separator: "\n\n")
    }

    /// Re-plan an in-flight plan and return a NOTIFY that re-gates the revised
    /// plan for human approval. Holds (notify) when the re-plan cannot ground.
    ///
    /// FIX 3 (adversarial review): a re-plan is now SAFE-BY-DEFAULT. The previous
    /// behavior silently flipped the revised plan to .running and auto-injected its
    /// current step - which would change what the human approved without re-asking.
    /// The approved plan is the standing human gate, so a materially revised plan
    /// must clear that gate again: the revised plan is left awaitingApproval (the
    /// state Planner.replan persists it in) and the human is notified to review +
    /// approve it via the existing approvePlan path. No auto-inject here.
    ///
    /// NOTE: this whole branch is currently DORMANT - nothing sets
    /// newInfoWarrantsReplan, so the orchestrator never returns .replan today (see
    /// the guard + test). It is hardened now so that when a future milestone DOES
    /// enable replan, it re-gates rather than auto-resuming. A future milestone may
    /// choose to auto-resume MINOR, in-scope replans without re-approval; that is a
    /// deliberate later decision, not this one.
    private func replanAndInject(
        existing: Plan,
        reason: String,
        sessionId: String,
        cwd: String?,
        now: Date
    ) async -> PlanLoopAction {
        trace.emit("planloop", "replan: session=\(sessionId) existing=\(existing.id) reason=\(reason.prefix(120))")
        let result = await planner.replan(existing: existing, observation: reason, cwd: cwd)
        switch result {
        case let .planned(newPlan):
            // Planner.replan persists the revised plan as awaitingApproval. Keep it
            // there (do NOT flip to running, do NOT inject): re-gate it through the
            // human approval path, consistent with "the approved plan is the
            // standing human gate". The loop was already stopped on the escalate/
            // abort that could precede this; the revised plan resumes only when the
            // human approves it (approvePlan).
            trace.emit("planloop", "replan: session=\(sessionId) -> revised plan=\(newPlan.id) left awaitingApproval (re-gated for human approval, NOT auto-resumed)")
            return .notify(
                message: "Supervisor re-planned this session based on new information and drafted a revised plan. It is waiting for your approval before driving it. Open the panel to review and approve.",
                escalation: nil
            )
        case let .ungrounded(reasoning):
            trace.emit("planloop", "replan ungrounded session=\(sessionId): \(reasoning.prefix(160)) - holding the existing plan")
            return .notify(message: "Supervisor wanted to re-plan this session but could not ground a revised plan, so it is holding. Open the panel to give direction.", escalation: nil)
        case let .error(reasoning):
            trace.emit("planloop", "replan error session=\(sessionId): \(reasoning.prefix(160)) - holding")
            return .none(reason: "replan_error")
        }
    }

    // MARK: - Step lookup

    /// The step AFTER `step` in the (re-read) current plan, or nil if `step` was
    /// the last. Re-reads from the store so it reflects the cursor advance that
    /// decideAndRecord just persisted.
    private func nextStep(after step: PlanStep, sessionId: String) -> PlanStep? {
        guard let plan = (try? planStore.currentPlan(sessionId: sessionId)) ?? nil else { return nil }
        return plan.steps.first { $0.index == step.index + 1 }
    }

    // MARK: - Observation windowing + destructive scan (static, pure, testable)

    /// Slice `window` to the events at or after `since`. With `since == nil` the
    /// whole window is returned (best-effort fallback when no inject time is
    /// known). Events are assumed in arrival order; we filter by timestamp so an
    /// out-of-order arrival cannot leak pre-step activity into the observation.
    static func eventsSince(_ since: Date?, in window: [SupervisorEvent]) -> [SupervisorEvent] {
        guard let since else { return window }
        return window.filter { $0.timestamp >= since }
    }

    /// Run DeterministicCatch over every observed command and return the first
    /// match, or nil. The classification is DeterministicCatch's (reused, not
    /// re-implemented); this only feeds the orchestrator's destructive signal.
    static func observedDestructive(_ observation: Observation) -> DeterministicCatch.Match? {
        for command in observation.commands {
            if let match = DeterministicCatch.match(command.command) { return match }
        }
        return nil
    }

    /// FIX 3 (SAFETY signal). Screen every observed command through the shared
    /// InjectionSafetyScreen (reused verbatim, not re-implemented) and return the
    /// FIRST non-destructive block reason, or nil. A `destructive_command(...)`
    /// block is deliberately SKIPPED here: that harm class is already carried by
    /// `destructiveActionObserved` (DeterministicCatch), and double-classifying it
    /// as a safety concern would flip the escalation trigger from
    /// `.destructiveAction` to `.safetySecurity`. What this catches that the
    /// destructive family does NOT: network-exec (`curl … | sh`), credential
    /// exfiltration, persistence primitives, sudo, force-push — the injection-
    /// screen shapes. When set, the orchestrator escalates `.safetySecurity`.
    static func observedSafetyConcern(_ observation: Observation) -> String? {
        for command in observation.commands {
            if case let .block(reason) = InjectionSafetyScreen.screen(command.command) {
                if reason.hasPrefix("destructive_command") { continue }
                return reason
            }
        }
        return nil
    }

    /// FIX 5. Consecutive no-ground-truth idle ticks tolerated on an inject-anchored
    /// step before the harness ESCALATES instead of skipping forever. A step done
    /// purely via Write/Edit (no Bash, no file-change events in the pipeline today)
    /// has `hasNoGroundTruth == true` every tick, so without this bound the harness
    /// returns `.none(no_ground_truth_yet)` indefinitely and the step never grades,
    /// advances, or escalates until the 6h dormancy sweep. At the cap we pause +
    /// notify so a human can look, rather than silently stalling.
    static let maxUngradableTicksBeforeEscalate = 5

    // MARK: - v0.2.0 observability A: audit recording (additive, best-effort)

    /// Record the plan step currently being driven (step index/title + the
    /// observed command/error counts). No-op without an auditStore; a write
    /// failure is logged and swallowed so the drive cycle is never broken.
    private func recordPlanStepAudit(
        sessionId: String,
        plan: Plan,
        step: PlanStep,
        observation: Observation,
        now: Date
    ) {
        guard let auditStore else { return }
        let detail = "{\"plan_id\":\"\(plan.id)\",\"step_index\":\(step.index),\"attempts\":\(step.attempts),\"observed_commands\":\(observation.commands.count),\"observed_errors\":\(observation.errors.count)}"
        let entry = StoredAuditEntry(
            sessionId: sessionId,
            createdAt: now,
            kind: .planStep,
            summary: "Drove plan step \(step.index + 1)/\(plan.steps.count): \(step.title.prefix(120))",
            detail: detail
        )
        do { try auditStore.record(entry) } catch {
            trace.emit("audit", "record planStep FAILED session=\(sessionId) error=\(error)")
        }
    }

    /// Record the Evaluator's verdict for a step (passed + score + feedback).
    private func recordVerdictAudit(
        sessionId: String,
        step: PlanStep,
        verdict: PlanStep.Verdict,
        now: Date
    ) {
        guard let auditStore else { return }
        let scoreStr = String(format: "%.2f", verdict.score)
        let entry = StoredAuditEntry(
            sessionId: sessionId,
            createdAt: now,
            kind: .verdict,
            summary: "Graded step \"\(step.title.prefix(80))\": \(verdict.passed ? "passed" : "not yet") (score \(scoreStr)). \(verdict.feedback.prefix(160))",
            detail: "{\"step_id\":\"\(step.id)\",\"passed\":\(verdict.passed),\"score\":\(scoreStr)}"
        )
        do { try auditStore.record(entry) } catch {
            trace.emit("audit", "record verdict FAILED session=\(sessionId) error=\(error)")
        }
    }

    // MARK: - Copy

    private static func completeMessage(plan: Plan) -> String {
        "Supervisor finished the plan for this session - all \(plan.steps.count) steps passed. The objective is built; give it a new objective to start a new plan."
    }
}
