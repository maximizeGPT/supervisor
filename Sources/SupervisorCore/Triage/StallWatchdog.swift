// StallWatchdog.swift - v0.2.0 M7. The background-task / stall watchdog.
//
// A DEFAULT-ON safety net, INDEPENDENT of the plan loop. When a watched session
// has launched a background task (a `run_in_background` Bash) OR sub-agents
// (Task/Agent tool calls) and then the main chat goes silent for a model-aware
// interval, the worker may be blocked waiting on async work that has stalled or
// died. The watchdog injects a gentle "checking in" nudge to probe / revive it,
// repeats each interval, and after ~3 no-movement nudges NOTIFIES the human and
// STOPS nudging (until the session moves again, which resets). It NEVER auto-kills
// or restarts anything - the most it does is inject a question and, at the cap,
// post a notification.
//
// WHAT THIS TYPE IS. The pure DECISION half: given the per-session signals that
// the engine can actually observe, it returns .ok / .checkIn / .escalate. It does
// NOT inject, does NOT notify, does NOT read a clock or any I/O. The engine
// (checkIdleStates) supplies `now` and the observed signals and carries out the
// resulting action through the existing marked + ledgered inject path (.checkIn)
// or the Notifier (.escalate). Mirrors ContextSteward / PlanOrchestrator: a value
// type whose every branch is unit-testable with literals.
//
// THE STALL CONDITION. now - lastActivity >= interval WHILE asyncWorkOutstanding.
// `asyncWorkOutstanding` is supplied by AsyncWorkScanner (a detached task's live
// token count is not observable, so token size is only a soft hint there, never a
// required trigger). Below the interval, or with no outstanding async work, the
// verdict is .ok and nothing happens. nudgeCount gates check-in vs. escalate:
// .checkIn while nudgeCount < maxNudges (default 3); .escalate at the cap. New
// activity (the engine clears/lowers nudgeCount when lastActivity advances and
// the escalated-stop flag) resets the cycle.

import Foundation

/// The per-session signals the watchdog classifies. A plain value type so the
/// whole decision is a pure function of its inputs. The engine fills these from
/// the live idle state at tick time.
public struct WatchdogSignals: Sendable, Equatable {

    /// Timestamp of the last observed activity for the session (the engine's
    /// `lastEventTs`). Silence is `now - lastActivity`.
    public var lastActivityTime: Date

    /// True when the session has an OUTSTANDING background task or sub-agent
    /// (a launch observed with no matching completion, and no later progress).
    /// Supplied by AsyncWorkScanner. The ONLY required trigger alongside silence;
    /// token size is a soft hint inside the scanner, not surfaced here.
    public var asyncWorkOutstanding: Bool

    /// How many check-in nudges have already been sent for the CURRENT stall
    /// (reset to 0 by the engine when the session moves again). At/over the
    /// policy's cap the verdict becomes .escalate instead of another .checkIn.
    public var nudgeCount: Int

    /// True once the watchdog has escalated for this stall and is therefore
    /// holding (no more nudges) until the session moves. The engine sets this
    /// when it carries out an .escalate and clears it on new activity. Passed in
    /// so the decision stays pure: an already-escalated stall returns .ok (the
    /// hold), never a second escalate.
    public var escalatedStopped: Bool

    public init(
        lastActivityTime: Date,
        asyncWorkOutstanding: Bool,
        nudgeCount: Int,
        escalatedStopped: Bool
    ) {
        self.lastActivityTime = lastActivityTime
        self.asyncWorkOutstanding = asyncWorkOutstanding
        self.nudgeCount = nudgeCount
        self.escalatedStopped = escalatedStopped
    }
}

/// The watchdog's three-way verdict. The engine maps each to a SAFE action:
///   - ok:       do nothing (not stalled, no outstanding async work, or already
///               escalated and holding).
///   - checkIn:  inject ONE gentle marked + ledgered "checking in" nudge, then
///               bump nudgeCount + stamp the nudge time.
///   - escalate: the nudge budget is spent with no movement - NOTIFY the human
///               and STOP nudging (set escalatedStopped) until the session moves.
///               NEVER auto-kills.
public enum WatchdogDecision: Sendable, Equatable {
    case ok
    case checkIn(reason: String)
    case escalate(reason: String)
}

/// The pure stall classifier. `assess(signals:now:interval:)` maps the observed
/// per-session signals to a `WatchdogDecision`. No actor, no I/O, no ambient
/// clock - fully determined by its inputs (the caller passes `now` and the
/// model-aware `interval` from WatchdogPolicy).
///
/// PRECEDENCE (top-to-bottom in `assess`):
///   1. Not stalled -> .ok. Stalled == asyncWorkOutstanding AND
///      (now - lastActivity) >= interval. If either is false, .ok.
///   2. Stalled but already escalated (escalatedStopped) -> .ok. The escalate
///      already fired and we hold until movement; never a second notify.
///   3. Stalled, not yet escalated, nudgeCount < maxNudges -> .checkIn.
///   4. Stalled, not yet escalated, nudgeCount >= maxNudges -> .escalate.
public struct StallWatchdog: Sendable {

    /// Number of check-in nudges sent before escalating. Default 3 per the spec
    /// ("after ~3 nudges with no movement, notify the human and STOP nudging").
    public static let defaultMaxNudges = 3

    /// The nudge budget for this stall before escalation. Tunable via init.
    public let maxNudges: Int

    public init(maxNudges: Int = StallWatchdog.defaultMaxNudges) {
        self.maxNudges = maxNudges
    }

    /// Classify the session's stall state. Pure: same inputs -> same output.
    /// See the type-level PRECEDENCE doc for the ordering.
    ///
    /// - `signals`: the observed per-session signals.
    /// - `now`: the engine's tick clock (injected so tests drive time).
    /// - `interval`: the model-aware silence threshold (from WatchdogPolicy).
    public func assess(signals: WatchdogSignals, now: Date, interval: TimeInterval) -> WatchdogDecision {
        // 1. Stall gate: BOTH outstanding async work AND silence past the interval.
        //    Either missing means there is nothing for the watchdog to do.
        guard signals.asyncWorkOutstanding else { return .ok }
        let silence = now.timeIntervalSince(signals.lastActivityTime)
        guard silence >= interval else { return .ok }

        // 2. Already escalated for this stall: hold (no second notify, no more
        //    nudges) until the session moves and the engine clears the flag.
        if signals.escalatedStopped { return .ok }

        let mins = Self.minutesLabel(interval)
        let silenceMins = Self.minutesLabel(silence)

        // 3. Still within the nudge budget: check in.
        if signals.nudgeCount < maxNudges {
            return .checkIn(reason: "A background task or sub-agents are outstanding and the session has been silent about \(silenceMins) (>= the \(mins) check-in interval); sending a gentle check-in nudge (\(signals.nudgeCount + 1) of \(maxNudges)).")
        }

        // 4. Budget spent with no movement: escalate (notify + stop nudging).
        return .escalate(reason: "A background task may have stalled: the session has been silent about \(silenceMins) with outstanding async work after \(maxNudges) check-in nudges produced no movement. Notifying you and pausing the nudges until the session moves again.")
    }

    // MARK: - Labels (for reasons; not user-gating)

    /// A compact "Nm" / "X.Yh" label for a duration, for the human-readable reason.
    private static func minutesLabel(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            return String(format: "%.1fh", s / 3600)
        }
        let minutes = Int((s / 60).rounded())
        return "\(minutes)m"
    }
}
