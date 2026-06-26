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
    /// Supervisor fired a pause intervention (a risky action was flagged). The
    /// worker is being interrupted, so the drive loop must HOLD for this session
    /// — otherwise the worker goes idle post-interrupt and the loop immediately
    /// re-drives it (the 2026-06-16 "it stopped and then Supervisor injected
    /// something else" case). Unlike .userMessage this is NOT operator presence,
    /// so it never stamps lastOwnerMessageAt and never clears a hard stop.
    case safetyPause = "safety_pause"
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
    }

    private var sessions: [String: SessionState] = [:]

    private let maxLoopDuration: TimeInterval
    private let sessionResetIdle: TimeInterval
    private let ownerPresenceBackoff: TimeInterval
    private let consecutiveLowThreshold: Int
    private let trace: TraceLog
    private let now: @Sendable () -> Date
    private let seedCount: ((String) -> Int)?
    /// Owner toggle: is the 4-hour wall-clock cap turned off? Defaults to the
    /// live RuntimeToggles marker; injectable so tests exercise the gate without
    /// writing the real marker (which the running app would pick up).
    private let loopCapDisabled: @Sendable () -> Bool
    /// Owner toggle (demo): when true, canDispatch skips the owner-presence backoff
    /// so the loop drives the moment a session goes idle, even though the operator
    /// just messaged. Injectable so tests exercise it without a real marker.
    private let ownerPresenceBackoffDisabled: @Sendable () -> Bool

    public init(
        maxLoopDuration: TimeInterval = LoopController.defaultMaxLoopDuration,
        sessionResetIdle: TimeInterval = LoopController.defaultSessionResetIdle,
        ownerPresenceBackoff: TimeInterval = LoopController.defaultOwnerPresenceBackoff,
        consecutiveLowThreshold: Int = LoopController.defaultConsecutiveLowThreshold,
        now: @escaping @Sendable () -> Date = { Date() },
        loopCapDisabled: @escaping @Sendable () -> Bool = { RuntimeToggles.loopCapDisabled },
        ownerPresenceBackoffDisabled: @escaping @Sendable () -> Bool = { RuntimeToggles.ownerPresenceBackoffDisabled },
        trace: TraceLog = .shared,
        loopStore: LoopDispatchStore? = nil
    ) {
        self.maxLoopDuration = maxLoopDuration
        self.sessionResetIdle = sessionResetIdle
        self.ownerPresenceBackoff = ownerPresenceBackoff
        self.consecutiveLowThreshold = consecutiveLowThreshold
        self.trace = trace
        self.now = now
        self.loopCapDisabled = loopCapDisabled
        self.ownerPresenceBackoffDisabled = ownerPresenceBackoffDisabled
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
        if !ownerPresenceBackoffDisabled(),
           let lastOwner = state.lastOwnerMessageAt,
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
            // New owner DIRECTION (a real user message / pending question) clears a
            // "ran out of grounded work" stop so the loop re-engages. A SAFETY pause
            // must NOT — it's holding a risky session, not giving new direction — so
            // it leaves a stopped session stopped (already held) and returns.
            guard reason != .safetyPause, state.stopReason == .threeConsecutiveLow else { return }
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
