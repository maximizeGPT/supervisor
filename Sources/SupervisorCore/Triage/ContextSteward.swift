// ContextSteward.swift - v0.2.0 M5. The long-running context steward.
//
// Anthropic's "Harness design for long-running apps" calls for a deliberate
// strategy when a driven session runs long enough that its context degrades:
// reset the context, but only after the live progress has been written into a
// DURABLE artifact (a structured handoff), so nothing is lost. This type is the
// DECISION half of that principle for Supervisor's plan harness: given the
// session signals that are actually available, it says whether the run is still
// healthy, warrants a non-destructive checkpoint (write progress to a file so a
// later reset is safe), or has degraded so far that a human should decide on a
// reset.
//
// WHAT IT IS NOT. It does NOT clear context, does NOT inject, does NOT touch the
// loop. It is a pure, testable classifier: (signals, thresholds) -> Decision.
// The live wiring (PlanLoop) turns a `.checkpoint` into a marked + ledgered
// non-destructive checkpoint injection, and a `.severe` into the existing
// escalate (pause + notify) path. The steward NEVER recommends auto-clearing:
// the most it asks for on its own is a SAFE write-progress-to-a-file checkpoint;
// a real context reset is a human call, surfaced as `.severe`.
//
// THE SIGNALS (all REAL - nothing invented). Claude Code's JSONL gives Supervisor
// no token counter, so the steward reasons about long-horizon RISK from the
// signals that DO exist on the live path:
//   - sessionAgeSeconds: how long the driven session has been alive (derived by
//     the caller from the earliest event timestamp in the window vs. now). The
//     primary wall-clock proxy for "this run has gone long".
//   - eventCount: how many events are in the caller's recent window for the
//     session - a coarse proxy for transcript volume / turn count.
//   - attemptsOnThisStep: how many times the current step has been attempted
//     (from the LoopController's per-step counter). Repeated attempts on one step
//     are where a session spins and its context fills with dead ends.
// These are deliberately coarse: the point is a SAFE, conservative nudge to
// checkpoint before a hypothetical reset, not a precise context-budget meter.

import Foundation

/// The signals the steward classifies. A plain value type so the whole decision
/// is a pure function of (signals, thresholds) and every branch is unit-testable
/// with a literal. The caller (PlanLoop) fills these from the live session state
/// at a SAFE boundary.
public struct ContextSignals: Sendable, Equatable {

    /// How long the driven session has been alive, in seconds. The caller derives
    /// this from the earliest event timestamp it has for the session vs. now; 0
    /// (or negative, clamped) when the age cannot be determined, which reads as
    /// "young" and never trips a threshold on its own.
    public var sessionAgeSeconds: TimeInterval

    /// Number of events in the caller's recent window for the session. A coarse
    /// proxy for how much transcript the run has accumulated.
    public var eventCount: Int

    /// How many times the CURRENT step has been attempted so far (the
    /// LoopController per-step counter). High values mean the run is spinning on
    /// one step, which is exactly when context fills with dead ends.
    public var attemptsOnThisStep: Int

    public init(
        sessionAgeSeconds: TimeInterval,
        eventCount: Int,
        attemptsOnThisStep: Int
    ) {
        self.sessionAgeSeconds = sessionAgeSeconds
        self.eventCount = eventCount
        self.attemptsOnThisStep = attemptsOnThisStep
    }
}

/// The steward's three-way verdict. The caller maps each to a SAFE action:
///   - ok:         no change (continue the loop as normal).
///   - checkpoint: warrants a non-destructive handoff checkpoint - inject (via
///                 the marked + ledgered path) an instruction to write current
///                 progress + remaining steps to a file, then continue normally.
///                 NEVER a context clear.
///   - severe:     degradation is severe enough that a human should decide on a
///                 reset. The caller escalates (pause + notify); it does NOT
///                 auto-continue and NEVER auto-clears.
public enum ContextDecision: Sendable, Equatable {
    case ok
    case checkpoint(reason: String)
    case severe(reason: String)
}

/// The pure context-health classifier. `assess(...)` maps `ContextSignals` to a
/// `ContextDecision` using the thresholds held on the value (tunable via init).
/// No actor, no I/O, no clock - fully determined by its inputs.
///
/// PRECEDENCE (top-to-bottom in `assess`). Severe outranks checkpoint outranks
/// ok: once any signal is in the SEVERE band the steward asks for a human reset
/// decision regardless of the others; otherwise any signal in the CHECKPOINT
/// band warrants a (safe, non-destructive) checkpoint; otherwise the run is ok.
///
///   1. severe: session age >= severeAgeSeconds
///              OR event count >= severeEventCount
///              OR attempts-on-step >= severeAttemptsOnStep
///   2. checkpoint: session age >= checkpointAgeSeconds
///                  OR event count >= checkpointEventCount
///                  OR attempts-on-step >= checkpointAttemptsOnStep
///   3. ok: otherwise
public struct ContextSteward: Sendable {

    // -- Checkpoint-band thresholds (a SAFE, non-destructive nudge). --

    /// Session age (seconds) at/above which a checkpoint is warranted. Default
    /// 2 hours: long enough that a real run has accumulated meaningful state worth
    /// persisting before any reset, well under the loop's 4-hour outer cap.
    public static let defaultCheckpointAgeSeconds: TimeInterval = 2 * 60 * 60

    /// Recent-window event count at/above which a checkpoint is warranted.
    /// Default 120: a coarse "this transcript is getting large" mark.
    public static let defaultCheckpointEventCount = 120

    /// Attempts on the current step at/above which a checkpoint is warranted.
    /// Default 2: a step on its second+ attempt is starting to spin; checkpoint
    /// so its progress survives a possible reset. (Sits below the orchestrator's
    /// 3-attempt non-convergence cap - this is a nudge, not the stop.)
    public static let defaultCheckpointAttemptsOnStep = 2

    // -- Severe-band thresholds (ESCALATE - a human decides on a reset). --

    /// Session age (seconds) at/above which degradation is severe. Default
    /// 3.5 hours (12600s): approaching the loop's 4-hour outer cap, where a long
    /// run is at real risk of context degradation and a human should weigh a reset.
    public static let defaultSevereAgeSeconds: TimeInterval = 3 * 60 * 60 + 30 * 60

    /// Recent-window event count at/above which degradation is severe. Default
    /// 240: roughly double the checkpoint mark.
    public static let defaultSevereEventCount = 240

    /// Attempts on the current step at/above which degradation is severe. Default
    /// 3: the run has burned the full attempt budget on one step (mirrors the
    /// orchestrator's non-convergence cap), a strong long-horizon-trouble signal.
    public static let defaultSevereAttemptsOnStep = 3

    public let checkpointAgeSeconds: TimeInterval
    public let checkpointEventCount: Int
    public let checkpointAttemptsOnStep: Int
    public let severeAgeSeconds: TimeInterval
    public let severeEventCount: Int
    public let severeAttemptsOnStep: Int

    public init(
        checkpointAgeSeconds: TimeInterval = ContextSteward.defaultCheckpointAgeSeconds,
        checkpointEventCount: Int = ContextSteward.defaultCheckpointEventCount,
        checkpointAttemptsOnStep: Int = ContextSteward.defaultCheckpointAttemptsOnStep,
        severeAgeSeconds: TimeInterval = ContextSteward.defaultSevereAgeSeconds,
        severeEventCount: Int = ContextSteward.defaultSevereEventCount,
        severeAttemptsOnStep: Int = ContextSteward.defaultSevereAttemptsOnStep
    ) {
        self.checkpointAgeSeconds = checkpointAgeSeconds
        self.checkpointEventCount = checkpointEventCount
        self.checkpointAttemptsOnStep = checkpointAttemptsOnStep
        self.severeAgeSeconds = severeAgeSeconds
        self.severeEventCount = severeEventCount
        self.severeAttemptsOnStep = severeAttemptsOnStep
    }

    /// Classify the run's context health from `signals`. Pure: same inputs ->
    /// same output. See the type-level PRECEDENCE doc for the ordering.
    public func assess(_ signals: ContextSignals) -> ContextDecision {
        let age = max(0, signals.sessionAgeSeconds)
        let events = max(0, signals.eventCount)
        let attempts = max(0, signals.attemptsOnThisStep)

        // 1. Severe band: any one signal at/above its severe threshold means the
        //    run has degraded far enough that a human should decide on a reset.
        //    Outranks checkpoint and ok - we do NOT silently checkpoint a clearly
        //    degraded run, we surface it.
        var severeReasons: [String] = []
        if age >= severeAgeSeconds {
            severeReasons.append("the session has been running about \(Self.hoursLabel(age)) (at/over the \(Self.hoursLabel(severeAgeSeconds)) severe mark)")
        }
        if events >= severeEventCount {
            severeReasons.append("the recent transcript is very large (\(events) events, at/over the \(severeEventCount) severe mark)")
        }
        if attempts >= severeAttemptsOnStep {
            severeReasons.append("the current step has been attempted \(attempts) times (at/over the \(severeAttemptsOnStep)-attempt severe mark)")
        }
        if !severeReasons.isEmpty {
            return .severe(reason: "Context looks severely degraded for this long-running session: " + severeReasons.joined(separator: "; ") + ". A reset may be warranted; pausing for you to decide rather than continuing or auto-clearing.")
        }

        // 2. Checkpoint band: any one signal at/above its checkpoint threshold
        //    warrants a SAFE, non-destructive handoff checkpoint before the next
        //    step, so progress survives a possible later reset.
        var checkpointReasons: [String] = []
        if age >= checkpointAgeSeconds {
            checkpointReasons.append("session age about \(Self.hoursLabel(age))")
        }
        if events >= checkpointEventCount {
            checkpointReasons.append("a large recent transcript (\(events) events)")
        }
        if attempts >= checkpointAttemptsOnStep {
            checkpointReasons.append("the current step is on attempt \(attempts)")
        }
        if !checkpointReasons.isEmpty {
            return .checkpoint(reason: "Long-running session (" + checkpointReasons.joined(separator: ", ") + "); writing a non-destructive progress checkpoint so the run can resume cleanly if context is reset.")
        }

        // 3. Healthy.
        return .ok
    }

    // MARK: - Labels (for reasons; not user-gating)

    /// A compact "Xh" / "Ym" label for a duration, for the human-readable reason.
    private static func hoursLabel(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 {
            let hours = seconds / 3600
            return String(format: "%.1fh", hours)
        }
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes)m"
    }
}
