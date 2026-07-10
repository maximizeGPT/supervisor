// LoopController.swift — v0.4.0 Part C.
//
// Per-session state machine that enforces the extended §12 hard stops
// for the autonomous-dispatch loop. The loop is:
//
//   worker idle → rubric fires worker_idle_post_completion → engine
//   asks LoopController "is the loop OK to keep running?" → if yes,
//   dispatcher runs → LoopController records the result → engine
//   hands the candidate to the router (which injects on high
//   confidence). The cycle resumes when the next idle event fires.
//
// The LoopController owns four pieces of state per session:
//
//   1. The loop-start timestamp (when did this run begin?). Used for
//      the 4-hour wall-clock hard-stop.
//   2. The consecutive-low counter. Resets to zero on every
//      ready-high / ready-medium / ready-low (ready is signal even
//      at low). Increments on lowConfidence/error returns.
//      Trips the hard-stop at 3.
//   3. The paused flag. Set when a user prompt arrives (the human
//      took the wheel; loop holds until they explicitly resume) OR
//      when the rubric fires user_question_pending (the worker is
//      waiting on the user to answer; loop holds rather than racing
//      to dispatch).
//   4. The stopped flag. Set when a kill action fires, when 4 hours
//      elapse, when three consecutive lows in a row, or when the
//      caller invokes stop(reason:) explicitly. Once stopped, the
//      session's loop never dispatches again (a new session starts
//      fresh).
//
// The controller is the loop's source of truth for the
// `prior_dispatches_considered` counter passed to the Dispatcher: it
// returns the current count of dispatches recorded for this session.
//
// Loop decisions and dispatch records flow through `loop_dispatches`
// in SQLite; LoopController writes to that table on every dispatcher
// result and queries it on startup (a Supervisor restart should pick
// up the counter, not reset it to zero mid-loop). v0.4.0 Part C
// persists everything; the in-memory state is a cache, not the source
// of truth.

import Foundation

// MARK: - Loop decisions

/// What the engine asks LoopController on every idle fire.
public enum LoopDecision: Sendable, Equatable {
    /// Proceed: call the Dispatcher with this `priorDispatchesConsidered`.
    case proceed(priorDispatchesConsidered: Int)
    /// Pause: surface a banner but don't dispatch. `reason` is the
    /// human-readable explanation for the trace + banner. The engine
    /// degrades the candidate to a plain notify (no Dispatcher call).
    case paused(reason: String)
    /// Stop: the loop has hit a hard-stop. Same engine behavior as
    /// .paused (notify, no dispatch), but the LoopController will
    /// keep returning .stopped on every subsequent idle until a
    /// new session begins or stop is explicitly cleared.
    case stopped(reason: String)
}

/// Why the loop stopped — recorded so the post-mortem can see WHICH
/// §12 trigger fired. Stable string raw values land in the trace.
public enum LoopStopReason: String, Sendable, Equatable {
    case killFired = "kill_fired"
    case fourHoursElapsed = "four_hours_elapsed"
    case threeConsecutiveLow = "three_consecutive_low_confidence"
    case explicitStop = "explicit_stop"
    /// The session objective is built — the loop finished on success, not on a
    /// hard stop. The cleaner termination the drive-to-objective slice adds: the
    /// loop stops because the thing is DONE, not because it ran out of ideas.
    case objectiveComplete = "objective_complete"

    /// Human-readable, shown to the owner (the raw value is for logs/traces).
    public var display: String {
        switch self {
        case .killFired:
            return "Claude Code is no longer running, so there's nothing to dispatch into."
        case .fourHoursElapsed:
            return "it's been running for 4 hours straight. It resets on its own after a couple of hours idle (or relaunch Supervisor to reset now)."
        case .threeConsecutiveLow:
            return "three dispatches in a row found no clear next step, so it's waiting for new direction."
        case .explicitStop:
            return "it was stopped manually."
        case .objectiveComplete:
            return "the session's objective is built, so the loop finished. Give it a new objective to start it again."
        }
    }
}

public enum LoopPauseReason: String, Sendable, Equatable {
    case userMessage = "user_message"
    case userQuestionPending = "user_question_pending"
}

// MARK: - The controller

public actor LoopController {

    /// Default §12-extended hard-stop budget: 4 hours of wall-clock
    /// time per loop. Per PRINCIPLES §12 (session-level cap is 75min)
    /// — but the LOOP can span multiple sessions back-to-back; the
    /// 4-hour budget is an outer safety net for the loop itself.
    public static let defaultMaxLoopDuration: TimeInterval = 4 * 60 * 60

    /// Default consecutive-low threshold for the hard-stop: 3.
    /// Calibrated to the v0.4.0 spec — a third low in a row is
    /// signal the dispatcher can't ground decisions in the work
    /// queue, not signal that we should keep trying.
    public static let defaultConsecutiveLowThreshold: Int = 3

    /// Fresh-session reset threshold: if the worker has been idle for at
    /// least this long, the human stepped away (closed the laptop, slept),
    /// so the next dispatch attempt is treated as a BRAND-NEW Supervisor
    /// session — the 4-hour budget restarts instead of ticking through an
    /// overnight pause. Chosen longer than the 75-min single-task cap (§12)
    /// so it never trips mid-work, and far shorter than a sleep. Mirrors
    /// apply_idle_reset in the Python dispatch hook.
    public static let defaultSessionResetIdle: TimeInterval = 2 * 60 * 60

    /// Default owner-presence backoff (2026-06-15). After the operator sends a
    /// REAL message, the loop holds off autonomously driving for this long, so it
    /// never types over a present, actively-steering operator. It resumes only
    /// once the operator has gone quiet for the window — i.e. they've actually
    /// stepped away, which is the condition the drive feature exists for.
    /// Supervisor's own injected turns never reach notePause(.userMessage) — the
    /// engine correlates them against the InjectionLedger first — so this only
    /// ever reflects genuine operator activity; the loop cannot refresh it by
    /// injecting (the thrash that drove the supervisor's own session on
    /// 2026-06-15).
    public static let defaultOwnerPresenceBackoff: TimeInterval = 10 * 60

    /// v0.2.0 M5: how many advanced steps must pass after a context checkpoint
    /// injection before another is allowed for the SAME plan. The cooldown stops a
    /// long-running session from re-injecting a "write a progress checkpoint"
    /// instruction at every step boundary once it crosses a steward threshold.
    /// Default 3: checkpoint, then skip the next three boundaries.
    public static let defaultCheckpointCooldownSteps = 3

    private struct SessionState {
        var loopStartedAt: Date
        var lastSeenAt: Date
        var consecutiveLowCount: Int
        var totalDispatches: Int
        var paused: Bool
        var pauseReason: String?
        var stopped: Bool
        var stopReason: LoopStopReason?
        /// When the operator last sent a REAL message (never a Supervisor
        /// injection). Drives the owner-presence backoff in canDispatch. nil until
        /// the first genuine operator turn. Defaulted so the existing
        /// SessionState(...) construction sites need no change.
        var lastOwnerMessageAt: Date? = nil
        /// v0.2.0 M2d-1: per-step attempt counts for the active plan, keyed by
        /// PlanStep.id. Incremented each time a step is graded (decideAndRecord).
        /// The orchestrator reads the count to apply the max-attempts guardrail;
        /// the count is also the source for the persisted PlanStep.attempts.
        /// Defaulted empty so the existing SessionState(...) sites need no change.
        var stepAttempts: [String: Int] = [:]
        /// v0.2.0 M2d-1: the per-step score history for the active plan, keyed by
        /// PlanStep.id, oldest first. Feeds the orchestrator's no-progress
        /// detector (scoreStalled). Defaulted empty.
        var stepScores: [String: [Double]] = [:]
        /// v0.2.0 M5: the plan step index at which the context steward last
        /// injected a non-destructive handoff checkpoint, keyed by plan id. Used
        /// to enforce the checkpoint COOLDOWN: a fresh checkpoint is suppressed
        /// until at least `checkpointCooldownSteps` steps have advanced past it,
        /// so a long run cannot spam checkpoint injections at every boundary. nil
        /// (absent) until the first checkpoint for a plan. In-memory like the idle
        /// counters (a checkpoint is a within-run nudge; a Supervisor restart
        /// re-arming it is harmless). Defaulted empty so existing SessionState(...)
        /// construction sites need no change.
        var lastCheckpointStepIndexByPlan: [String: Int] = [:]
    }

    private var sessions: [String: SessionState] = [:]

    private let maxLoopDuration: TimeInterval
    private let sessionResetIdle: TimeInterval
    private let ownerPresenceBackoff: TimeInterval
    private let consecutiveLowThreshold: Int
    /// v0.2.0 M5: how many advanced steps must pass after a context checkpoint
    /// before another is allowed for the same plan (the cooldown). Injectable so
    /// tests can shorten it; defaults to the standard value.
    private let checkpointCooldownSteps: Int
    private let trace: TraceLog
    private let now: @Sendable () -> Date
    private let seedCount: ((String) -> Int)?
    /// v0.2.0 M2a: read-only access to the persisted plan for a session.
    /// Injected like `loopStore` (optional, off by default) so M2a wires
    /// the type in without changing any existing call site. M2d-1 adds the
    /// plan-orchestration decision methods (decideAndRecord) that read +
    /// write through this store; the live execution of a decision (inject,
    /// notify, replan) is M2d-2. nil when no PlanStore is wired.
    private let planStore: PlanStore?
    /// v0.2.0 M2d-1: the pure plan-orchestration decision brain. The
    /// controller OWNS one orchestrator + the per-step attempt counters and
    /// asks it for a `PlanDecision` on every graded step. Injectable so its
    /// guardrails (max attempts/step) are tunable; defaults to the standard
    /// PlanOrchestrator.
    private let orchestrator: PlanOrchestrator
    /// Owner toggle: is the 4-hour wall-clock cap turned off? Defaults to the
    /// live RuntimeToggles marker; injectable so tests exercise the gate without
    /// writing the real marker (which the running app would pick up).
    private let loopCapDisabled: @Sendable () -> Bool

    public init(
        maxLoopDuration: TimeInterval = LoopController.defaultMaxLoopDuration,
        sessionResetIdle: TimeInterval = LoopController.defaultSessionResetIdle,
        ownerPresenceBackoff: TimeInterval = LoopController.defaultOwnerPresenceBackoff,
        consecutiveLowThreshold: Int = LoopController.defaultConsecutiveLowThreshold,
        checkpointCooldownSteps: Int = LoopController.defaultCheckpointCooldownSteps,
        now: @escaping @Sendable () -> Date = { Date() },
        loopCapDisabled: @escaping @Sendable () -> Bool = { RuntimeToggles.loopCapDisabled },
        trace: TraceLog = .shared,
        loopStore: LoopDispatchStore? = nil,
        planStore: PlanStore? = nil,
        orchestrator: PlanOrchestrator = PlanOrchestrator()
    ) {
        self.maxLoopDuration = maxLoopDuration
        self.sessionResetIdle = sessionResetIdle
        self.ownerPresenceBackoff = ownerPresenceBackoff
        self.consecutiveLowThreshold = consecutiveLowThreshold
        self.checkpointCooldownSteps = checkpointCooldownSteps
        self.trace = trace
        self.now = now
        self.loopCapDisabled = loopCapDisabled
        self.planStore = planStore
        self.orchestrator = orchestrator
        if let store = loopStore {
            self.seedCount = { sessionId in
                (try? store.count(sessionId: sessionId)) ?? 0
            }
        } else {
            self.seedCount = nil
        }
    }

    // MARK: - Engine-facing API

    /// Ask "is the loop allowed to dispatch right now?" Engine calls
    /// this BEFORE the Dispatcher; if the return is .paused or
    /// .stopped, the engine skips the Dispatcher call entirely and
    /// degrades the candidate to a plain notify.
    ///
    /// Side effect: lazily initializes per-session state on first
    /// call. The loop-start timestamp is "first time we evaluated
    /// this session," which is the right anchor — Supervisor doesn't
    /// know when the human started the worker.
    public func canDispatch(sessionId: String) -> LoopDecision {
        let nowTs = now()
        var state: SessionState
        if let existing = sessions[sessionId] {
            state = existing
        } else {
            let seeded = seedCount?(sessionId) ?? 0
            state = SessionState(
                loopStartedAt: nowTs,
                lastSeenAt: nowTs,
                consecutiveLowCount: 0,
                totalDispatches: seeded,
                paused: false,
                pauseReason: nil,
                stopped: false,
                stopReason: nil
            )
            if seeded > 0 {
                trace.emit("loop", "SEEDED session=\(sessionId) totalDispatches=\(seeded) from store")
            }
        }

        // Fresh-session reset: a long idle gap means the human stepped away,
        // so this resume is a BRAND-NEW Supervisor session — restart the
        // 4-hour clock and clear the sticky stop + counters rather than keep
        // ticking through an overnight pause. Runs BEFORE the .stopped check
        // so it un-sticks a prior four_hours_elapsed stop. (Mirrors
        // apply_idle_reset in the Python hook.) A new session has
        // lastSeenAt == nowTs, so its gap is 0 and it never resets here.
        if nowTs.timeIntervalSince(state.lastSeenAt) >= sessionResetIdle {
            trace.emit("loop", "session_reset_after_idle session=\(sessionId) idle_gap=\(Int(nowTs.timeIntervalSince(state.lastSeenAt)))s was_stopped=\(state.stopped)")
            state.loopStartedAt = nowTs
            state.stopped = false
            state.stopReason = nil
            state.totalDispatches = 0
            state.consecutiveLowCount = 0
        }
        state.lastSeenAt = nowTs

        // Owner toggle: if the 4-hour cap is turned off, un-stick a session the
        // cap previously stopped — so flipping the toggle resumes the loop
        // instead of needing a relaunch. Only clears the four_hours_elapsed stop;
        // kill and three-consecutive-low stops stand.
        if loopCapDisabled(), state.stopped, state.stopReason == .fourHoursElapsed {
            state.stopped = false
            state.stopReason = nil
            trace.emit("loop", "cleared four_hours_elapsed stop (loop cap disabled by owner) session=\(sessionId)")
        }

        // .stopped sticks. Check it before anything else.
        if state.stopped {
            sessions[sessionId] = state
            let why = state.stopReason?.display ?? "an earlier stop."
            return .stopped(reason: "Supervisor paused: \(why)")
        }

        // 4-hour budget check — skipped when the owner disabled the loop cap
        // (the loop-cap-disabled toggle, for long sessions / the screen-record
        // demo). The other hard stops still apply.
        if !loopCapDisabled(),
           nowTs.timeIntervalSince(state.loopStartedAt) >= maxLoopDuration {
            state.stopped = true
            state.stopReason = .fourHoursElapsed
            sessions[sessionId] = state
            trace.emit("loop", "STOPPED session=\(sessionId) reason=four_hours_elapsed elapsed=\(Int(nowTs.timeIntervalSince(state.loopStartedAt)))s")
            return .stopped(reason: "Supervisor paused: \(LoopStopReason.fourHoursElapsed.display)")
        }

        // Paused (transient — clearable by an explicit resume call).
        if state.paused {
            let reason = state.pauseReason ?? "unknown"
            sessions[sessionId] = state
            return .paused(reason: reason)
        }

        // Owner-presence backoff (2026-06-15): a real operator message arrived
        // within the backoff window, so the operator is present and steering —
        // hold off autonomously driving over them. lastOwnerMessageAt is set only
        // by notePause(.userMessage), which the engine never calls for Supervisor's
        // own injected turns, so the loop can't refresh this by injecting. Returned
        // as .paused, which the engine treats as SILENT — no banner spam. Resumes
        // once the operator has been quiet for the window (they've stepped away —
        // the condition the drive feature is for).
        if let lastOwner = state.lastOwnerMessageAt,
           nowTs.timeIntervalSince(lastOwner) < ownerPresenceBackoff {
            sessions[sessionId] = state
            return .paused(reason: "operator active \(Int(nowTs.timeIntervalSince(lastOwner)))s ago (presence backoff)")
        }

        sessions[sessionId] = state
        return .proceed(priorDispatchesConsidered: state.totalDispatches)
    }

    /// Called by the engine AFTER the Dispatcher returns. Updates the
    /// consecutive-low counter, the total dispatch count, and checks
    /// the 3-low hard-stop. Idempotent for non-ready/non-low rows
    /// (errors increment consecutive-low too — an error is "we
    /// couldn't ground a decision," which is functionally a low).
    public func recordDispatch(
        sessionId: String,
        result: DispatchResult
    ) {
        let nowTs = now()
        var state = sessions[sessionId] ?? SessionState(
            loopStartedAt: nowTs,
            lastSeenAt: nowTs,
            consecutiveLowCount: 0,
            totalDispatches: seedCount?(sessionId) ?? 0,
            paused: false,
            pauseReason: nil,
            stopped: false,
            stopReason: nil
        )
        state.totalDispatches += 1

        switch result {
        case let .ready(_, _, conf, _, _, _, _) where conf != .low:
            // Forward progress — reset the consecutive-low counter.
            state.consecutiveLowCount = 0
            trace.emit("loop", "recorded ready session=\(sessionId) confidence=\(conf.rawValue) total=\(state.totalDispatches)")
        case .ready(_, _, .low, _, _, _, _),
             .lowConfidence,
             .error:
            // Both "ready at low confidence" (the defensive case that
            // bypasses the Dispatcher's normalize) and explicit
            // .lowConfidence count toward the threshold. .error is
            // functionally equivalent — the dispatcher couldn't
            // ground a decision.
            state.consecutiveLowCount += 1
            trace.emit("loop", "recorded low/error session=\(sessionId) consecutive_low=\(state.consecutiveLowCount)/\(consecutiveLowThreshold) total=\(state.totalDispatches)")

            if state.consecutiveLowCount >= consecutiveLowThreshold {
                state.stopped = true
                state.stopReason = .threeConsecutiveLow
                trace.emit("loop", "STOPPED session=\(sessionId) reason=three_consecutive_low_confidence (counter hit \(state.consecutiveLowCount))")
            }
        case .objectiveComplete:
            // Objective met — terminal success, not a low. Reset the
            // consecutive-low counter; the engine stops the loop separately
            // (stop(reason: .objectiveComplete)) so the stop reads as "done".
            state.consecutiveLowCount = 0
            trace.emit("loop", "recorded objective_complete session=\(sessionId) total=\(state.totalDispatches)")
        @unknown default:
            break
        }

        sessions[sessionId] = state
    }

    /// Called by the engine when a userPrompt event arrives — the
    /// human is back in the chat, loop should pause until they
    /// explicitly resume (or a new session starts).
    public func notePause(sessionId: String, reason: LoopPauseReason) {
        let nowTs = now()
        var state = sessions[sessionId] ?? SessionState(
            loopStartedAt: nowTs,
            lastSeenAt: nowTs,
            consecutiveLowCount: 0,
            totalDispatches: seedCount?(sessionId) ?? 0,
            paused: false,
            pauseReason: nil,
            stopped: false,
            stopReason: nil
        )
        // A three-consecutive-low stop means the loop ran out of grounded
        // work. A fresh user message is NEW DIRECTION — clear that (and ONLY
        // that) stop so the loop re-engages after the human's input. Kill and
        // 4-hour stops are terminal and stay.
        if state.stopped {
            guard state.stopReason == .threeConsecutiveLow else { return }
            state.stopped = false
            state.stopReason = nil
            state.consecutiveLowCount = 0
            trace.emit("loop", "cleared three_consecutive_low stop on new user direction session=\(sessionId)")
        }
        // A REAL operator message marks the operator as present: stamp it so the
        // presence backoff (canDispatch) holds the loop off until they go quiet.
        // Only genuine operator turns reach here — the engine excludes Supervisor's
        // own injected turns via the InjectionLedger before calling notePause — so
        // the loop can never refresh this by injecting.
        if reason == .userMessage {
            state.lastOwnerMessageAt = nowTs
        }
        state.paused = true
        state.pauseReason = reason.rawValue
        sessions[sessionId] = state
        trace.emit("loop", "PAUSED session=\(sessionId) reason=\(reason.rawValue)")
    }

    /// Clear the paused flag — caller is asserting the user has
    /// re-authorized the loop. Engine calls this when the worker
    /// emits new tool_use or assistantText after a user message
    /// (i.e. the worker resumed on its own).
    public func clearPause(sessionId: String) {
        guard var state = sessions[sessionId], state.paused else { return }
        state.paused = false
        state.pauseReason = nil
        sessions[sessionId] = state
        trace.emit("loop", "RESUMED session=\(sessionId)")
    }

    /// Clear a previous three_consecutive_low stop so the loop can
    /// resume. Called when the engine discovers actionable work that
    /// the previous dispatcher calls missed (e.g. new commits arrived,
    /// Known Gaps updated). Does NOT clear kills or 4-hour stops —
    /// those are genuine hard stops, not false signals.
    public func clearConsecutiveLowStop(sessionId: String) {
        guard var state = sessions[sessionId],
              state.stopped,
              state.stopReason == .threeConsecutiveLow
        else { return }
        state.stopped = false
        state.stopReason = nil
        state.consecutiveLowCount = 0
        sessions[sessionId] = state
        trace.emit("loop", "CLEARED consecutive-low stop session=\(sessionId) — resuming loop")
    }

    /// Force-stop a session's loop. Called by the engine when the
    /// router fires a kill action (the worker is gone — the loop
    /// has nothing to dispatch INTO).
    public func stop(sessionId: String, reason: LoopStopReason) {
        var state = sessions[sessionId] ?? SessionState(
            loopStartedAt: now(),
            lastSeenAt: now(),
            consecutiveLowCount: 0,
            totalDispatches: seedCount?(sessionId) ?? 0,
            paused: false,
            pauseReason: nil,
            stopped: false,
            stopReason: nil
        )
        state.stopped = true
        state.stopReason = reason
        sessions[sessionId] = state
        trace.emit("loop", "STOPPED session=\(sessionId) reason=\(reason.rawValue)")
    }

    // MARK: - Plan state (v0.2.0 M2a — read-only accessor)

    /// The current (latest) persisted plan for a session, or nil if no
    /// PlanStore is wired or the session has no plan yet. M2a exposes
    /// only this read accessor; producing a plan (M2b) and driving its
    /// steps (M2d) come later. A store read error degrades to nil
    /// (best-effort, like the rest of the loop's reads).
    public func currentPlan(sessionId: String) -> Plan? {
        guard let planStore else { return nil }
        return (try? planStore.currentPlan(sessionId: sessionId)) ?? nil
    }

    // MARK: - Plan orchestration (v0.2.0 M2d-1 - decide + record the transition)

    /// The outcome of grading a step and running the orchestrator: the pure
    /// `decision` plus the plan/step state that was PERSISTED as a result. The
    /// caller (M2d-2's live wiring) reads `decision` to know what to do next
    /// (inject feedback, advance, pause + notify, replan, stop) - but those
    /// LIVE actions are M2d-2; M2d-1 only computes the decision and records the
    /// resulting plan/step state transition.
    public struct OrchestrationOutcome: Sendable, Equatable {
        /// What the orchestrator decided (advance / complete / redirect /
        /// replan / escalate / abort).
        public let decision: PlanDecision
        /// The step status written for the graded step (e.g. passed, retrying,
        /// failed). nil if no plan/step state was persisted (no store wired).
        public let recordedStepStatus: PlanStep.Status?
        /// The plan status written (e.g. running, completed, aborted), or nil if
        /// nothing was persisted.
        public let recordedPlanStatus: Plan.Status?
        /// The plan's current-step index written (advanced on `.advance`, held
        /// otherwise), or nil if nothing was persisted.
        public let recordedCurrentStepIndex: Int?
        /// The attempt count written for the graded step (the per-step counter
        /// after this grade), or nil if nothing was persisted.
        public let recordedAttempts: Int?

        public init(
            decision: PlanDecision,
            recordedStepStatus: PlanStep.Status? = nil,
            recordedPlanStatus: Plan.Status? = nil,
            recordedCurrentStepIndex: Int? = nil,
            recordedAttempts: Int? = nil
        ) {
            self.decision = decision
            self.recordedStepStatus = recordedStepStatus
            self.recordedPlanStatus = recordedPlanStatus
            self.recordedCurrentStepIndex = recordedCurrentStepIndex
            self.recordedAttempts = recordedAttempts
        }
    }

    /// Grade-time entry point: given the Evaluator's `verdict` for `step` of the
    /// session's current plan, bump the per-step attempt counter + score
    /// history, ask the owned PlanOrchestrator for a `PlanDecision`, then PERSIST
    /// the resulting plan/step state transition via PlanStore. Returns the
    /// decision plus what was written.
    ///
    /// This does NOT execute the decision on the live path: it does NOT call
    /// TriageEngine, the Injector, the Notifier, or any LLM (Planner.replan).
    /// Executing a decision live - injecting the redirect feedback, advancing
    /// the Generator to the next step, pausing + notifying on escalate, invoking
    /// Planner.replan - is M2d-2. The persisted state is the durable record the
    /// live wiring will act on.
    ///
    /// - `sessionId`: the session whose loop + plan this is.
    /// - `plan`: the current plan (the caller passes the plan it graded against;
    ///   typically `currentPlan(sessionId:)`). Its `steps`/`currentStepIndex`
    ///   are used for advance/complete decisions.
    /// - `step`: the step that was graded.
    /// - `verdict`: the Evaluator's verdict for that step.
    /// - `extraSignals`: optional human-insight / budget flags to fold into the
    ///   decision (offPlan, needsHumanInput, destructiveActionObserved,
    ///   safetyConcern, budgetExhausted, newInfoWarrantsReplan + replanReason).
    ///   The attempt count and score history are filled by the controller from
    ///   its own per-step state; any values on the passed-in signals for those
    ///   two fields are overridden. Defaults to "no extra flags".
    /// - `now`: timestamp for the persisted `updated_at` columns (injectable for
    ///   deterministic tests).
    @discardableResult
    public func decideAndRecord(
        sessionId: String,
        plan: Plan,
        step: PlanStep,
        verdict: PlanStep.Verdict,
        extraSignals: OrchestrationSignals? = nil,
        now: Date? = nil
    ) -> OrchestrationOutcome {
        let nowTs = now ?? self.now()
        var state = sessions[sessionId] ?? SessionState(
            loopStartedAt: nowTs,
            lastSeenAt: nowTs,
            consecutiveLowCount: 0,
            totalDispatches: seedCount?(sessionId) ?? 0,
            paused: false,
            pauseReason: nil,
            stopped: false,
            stopReason: nil
        )

        // Bump the per-step attempt counter (this grade IS an attempt) and append
        // this verdict's score to the step's history. These are the controller's
        // source of truth for the orchestrator's guardrail inputs; they override
        // whatever the caller put on `extraSignals` for those two fields.
        let attempts = (state.stepAttempts[step.id] ?? 0) + 1
        state.stepAttempts[step.id] = attempts
        var scores = state.stepScores[step.id] ?? []
        scores.append(verdict.score)
        state.stepScores[step.id] = scores
        sessions[sessionId] = state

        // Assemble the signals: controller-owned counters + the caller's flags.
        let base = extraSignals ?? OrchestrationSignals(attemptsOnStep: attempts)
        let signals = OrchestrationSignals(
            attemptsOnStep: attempts,
            scoreHistoryForStep: scores,
            budgetExhausted: base.budgetExhausted,
            needsHumanInput: base.needsHumanInput,
            offPlan: base.offPlan,
            destructiveActionObserved: base.destructiveActionObserved,
            safetyConcern: base.safetyConcern,
            newInfoWarrantsReplan: base.newInfoWarrantsReplan,
            replanReason: base.replanReason
        )

        let decision = orchestrator.decide(
            plan: plan, currentStep: step, verdict: verdict, signals: signals
        )

        trace.emit("loop", "orchestrate session=\(sessionId) plan=\(plan.id) step=\(step.index) attempts=\(attempts) verdict_passed=\(verdict.passed) score=\(String(format: "%.2f", verdict.score)) decision=\(Self.decisionTag(decision))")

        // Map the decision to the persisted plan/step transition, then write it.
        // No live action is taken here (no inject/notify/replan/LLM) - that is
        // M2d-2. Each branch leaves a // M2d-2: TODO at the live-action seam.
        return record(
            decision: decision,
            sessionId: sessionId,
            plan: plan,
            step: step,
            verdict: verdict,
            attempts: attempts,
            now: nowTs
        )
    }

    /// Persist the plan/step state implied by a decision, and return the
    /// outcome. Private - the only caller is `decideAndRecord`. Degrades to a
    /// "decision only, nothing persisted" outcome when no PlanStore is wired (so
    /// the pure decision is still usable without storage, as the tests need).
    private func record(
        decision: PlanDecision,
        sessionId: String,
        plan: Plan,
        step: PlanStep,
        verdict: PlanStep.Verdict,
        attempts: Int,
        now: Date
    ) -> OrchestrationOutcome {
        guard let planStore else {
            // No store: the orchestrator's decision still stands; we just have
            // nowhere to record the transition. The caller gets the decision.
            return OrchestrationOutcome(decision: decision)
        }

        // Helper to write the graded step's status/attempts/verdict.
        func writeStep(_ status: PlanStep.Status) {
            try? planStore.updateStep(
                stepId: step.id, status: status, attempts: attempts,
                verdict: verdict, now: now
            )
        }
        // Helper to write the plan's status + current-step index.
        func writePlan(_ status: Plan.Status, currentStepIndex: Int) {
            try? planStore.updatePlan(
                planId: plan.id, status: status,
                currentStepIndex: currentStepIndex, now: now
            )
        }

        switch decision {
        case .advance:
            // Step passed; mark it passed and move the plan's cursor to the next
            // step (the plan stays running).
            writeStep(.passed)
            let nextIndex = step.index + 1
            writePlan(.running, currentStepIndex: nextIndex)
            // M2d-2: inject the next step's spec into the Generator and observe.
            return OrchestrationOutcome(
                decision: decision,
                recordedStepStatus: .passed,
                recordedPlanStatus: .running,
                recordedCurrentStepIndex: nextIndex,
                recordedAttempts: attempts
            )

        case .complete:
            // Last step passed; mark it passed and the plan completed. The
            // current-step index holds at the last step.
            writeStep(.passed)
            writePlan(.completed, currentStepIndex: step.index)
            // M2d-2: stop the loop with a "plan complete" terminal reason and
            // notify the human the objective is built.
            return OrchestrationOutcome(
                decision: decision,
                recordedStepStatus: .passed,
                recordedPlanStatus: .completed,
                recordedCurrentStepIndex: step.index,
                recordedAttempts: attempts
            )

        case .redirect:
            // Step failed but is being re-attempted: status retrying, plan holds
            // on the same step.
            writeStep(.retrying)
            writePlan(.running, currentStepIndex: step.index)
            // M2d-2: inject the verdict feedback as a redirect and re-run the
            // same step.
            return OrchestrationOutcome(
                decision: decision,
                recordedStepStatus: .retrying,
                recordedPlanStatus: .running,
                recordedCurrentStepIndex: step.index,
                recordedAttempts: attempts
            )

        case .replan:
            // The remaining plan looks wrong. Record the graded step's verdict
            // (status reflects the verdict: passed-but-replan keeps passed, else
            // failed) and hold the plan running; the actual re-plan is M2d-2.
            let stepStatus: PlanStep.Status = verdict.passed ? .passed : .failed
            writeStep(stepStatus)
            writePlan(.running, currentStepIndex: step.index)
            // M2d-2: call Planner.replan(existing:observation:cwd:) with the
            // decision's reason and swap in the revised plan.
            return OrchestrationOutcome(
                decision: decision,
                recordedStepStatus: stepStatus,
                recordedPlanStatus: .running,
                recordedCurrentStepIndex: step.index,
                recordedAttempts: attempts
            )

        case .escalate:
            // A human-insight trigger fired. Persist the step's verdict-derived
            // status; the plan stays running (the human decides next). The PAUSE
            // + NOTIFY are M2d-2 - M2d-1 only records the state.
            let stepStatus: PlanStep.Status = verdict.passed ? .passed : .failed
            writeStep(stepStatus)
            writePlan(.running, currentStepIndex: step.index)
            // M2d-2: pause the loop (stop/notePause) and notify the human with
            // the escalation trigger + reason.
            return OrchestrationOutcome(
                decision: decision,
                recordedStepStatus: stepStatus,
                recordedPlanStatus: .running,
                recordedCurrentStepIndex: step.index,
                recordedAttempts: attempts
            )

        case .abort:
            // A hard guardrail tripped. Mark the step's verdict-derived status
            // and the plan aborted (terminal).
            let stepStatus: PlanStep.Status = verdict.passed ? .passed : .failed
            writeStep(stepStatus)
            writePlan(.aborted, currentStepIndex: step.index)
            // M2d-2: stop the loop (stop(reason:)) and notify the human the run
            // was aborted on a guardrail.
            return OrchestrationOutcome(
                decision: decision,
                recordedStepStatus: stepStatus,
                recordedPlanStatus: .aborted,
                recordedCurrentStepIndex: step.index,
                recordedAttempts: attempts
            )
        }
    }

    // MARK: - Context steward state (v0.2.0 M5 - checkpoint cooldown + signals)

    /// How many times the given step has been attempted so far for this session,
    /// from the controller's per-step counter (the same counter decideAndRecord
    /// bumps). 0 if the session/step is unknown. The context steward reads this as
    /// one of its long-horizon-risk signals (repeated attempts on one step). Pure
    /// read - no state change.
    public func attemptsOnStep(sessionId: String, stepId: String) -> Int {
        sessions[sessionId]?.stepAttempts[stepId] ?? 0
    }

    /// Is a context checkpoint currently SUPPRESSED for `planId` by the cooldown?
    /// True when a checkpoint was injected within the last `checkpointCooldownSteps`
    /// advanced steps (i.e. `atStepIndex` is still within the cooldown window after
    /// the last checkpoint's step index). False when no checkpoint has fired for the
    /// plan yet, or enough steps have advanced past it. The context steward consults
    /// this at a SAFE boundary so it cannot re-fire a checkpoint every step. Pure
    /// read - no state change.
    public func checkpointCooldownActive(sessionId: String, planId: String, atStepIndex: Int) -> Bool {
        guard let last = sessions[sessionId]?.lastCheckpointStepIndexByPlan[planId] else { return false }
        return atStepIndex - last < checkpointCooldownSteps
    }

    /// Record that the context steward injected a non-destructive checkpoint for
    /// `planId` at `atStepIndex`, arming the cooldown. Lazily initializes the
    /// session state (like the other record* methods) so a checkpoint can be the
    /// first thing recorded for a session. In-memory only (a checkpoint is a
    /// within-run nudge).
    public func recordCheckpoint(sessionId: String, planId: String, atStepIndex: Int) {
        let nowTs = now()
        var state = sessions[sessionId] ?? SessionState(
            loopStartedAt: nowTs,
            lastSeenAt: nowTs,
            consecutiveLowCount: 0,
            totalDispatches: seedCount?(sessionId) ?? 0,
            paused: false,
            pauseReason: nil,
            stopped: false,
            stopReason: nil
        )
        state.lastCheckpointStepIndexByPlan[planId] = atStepIndex
        sessions[sessionId] = state
        trace.emit("loop", "context checkpoint recorded session=\(sessionId) plan=\(planId) at_step_index=\(atStepIndex) (cooldown \(checkpointCooldownSteps) steps)")
    }

    /// Short stable tag for a decision, for the trace line. Not user-facing.
    private static func decisionTag(_ decision: PlanDecision) -> String {
        switch decision {
        case .advance: return "advance"
        case .complete: return "complete"
        case .redirect: return "redirect"
        case .replan: return "replan"
        case let .escalate(trigger, _): return "escalate:\(trigger.rawValue)"
        case .abort: return "abort"
        }
    }

    /// Inspect — used by tests and post-mortems. Returns nil if the
    /// session has never been seen.
    public func snapshot(sessionId: String) -> LoopSnapshot? {
        guard let state = sessions[sessionId] else { return nil }
        return LoopSnapshot(
            loopStartedAt: state.loopStartedAt,
            lastSeenAt: state.lastSeenAt,
            consecutiveLowCount: state.consecutiveLowCount,
            totalDispatches: state.totalDispatches,
            paused: state.paused,
            pauseReason: state.pauseReason,
            stopped: state.stopped,
            stopReason: state.stopReason,
            lastOwnerMessageAt: state.lastOwnerMessageAt
        )
    }
}

/// Snapshot of one session's loop state. Read-only; for tests +
/// post-mortems + future UI surfacing.
public struct LoopSnapshot: Sendable, Equatable {
    public let loopStartedAt: Date
    public let lastSeenAt: Date
    public let consecutiveLowCount: Int
    public let totalDispatches: Int
    public let paused: Bool
    public let pauseReason: String?
    public let stopped: Bool
    public let stopReason: LoopStopReason?
    public let lastOwnerMessageAt: Date?
}
