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

    private struct SessionState {
        let loopStartedAt: Date
        var consecutiveLowCount: Int
        var totalDispatches: Int
        var paused: Bool
        var pauseReason: String?
        var stopped: Bool
        var stopReason: LoopStopReason?
    }

    private var sessions: [String: SessionState] = [:]

    private let maxLoopDuration: TimeInterval
    private let consecutiveLowThreshold: Int
    private let trace: TraceLog
    private let now: @Sendable () -> Date

    public init(
        maxLoopDuration: TimeInterval = LoopController.defaultMaxLoopDuration,
        consecutiveLowThreshold: Int = LoopController.defaultConsecutiveLowThreshold,
        now: @escaping @Sendable () -> Date = { Date() },
        trace: TraceLog = .shared
    ) {
        self.maxLoopDuration = maxLoopDuration
        self.consecutiveLowThreshold = consecutiveLowThreshold
        self.trace = trace
        self.now = now
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
        var state = sessions[sessionId] ?? SessionState(
            loopStartedAt: nowTs,
            consecutiveLowCount: 0,
            totalDispatches: 0,
            paused: false,
            pauseReason: nil,
            stopped: false,
            stopReason: nil
        )

        // .stopped sticks. Check it before anything else.
        if state.stopped {
            let reason = state.stopReason?.rawValue ?? "unknown"
            sessions[sessionId] = state
            return .stopped(reason: "Loop previously stopped: \(reason).")
        }

        // 4-hour budget check.
        if nowTs.timeIntervalSince(state.loopStartedAt) >= maxLoopDuration {
            state.stopped = true
            state.stopReason = .fourHoursElapsed
            sessions[sessionId] = state
            trace.emit("loop", "STOPPED session=\(sessionId) reason=four_hours_elapsed elapsed=\(Int(nowTs.timeIntervalSince(state.loopStartedAt)))s")
            return .stopped(reason: "Loop exceeded 4-hour wall-clock budget.")
        }

        // Paused (transient — clearable by an explicit resume call).
        if state.paused {
            let reason = state.pauseReason ?? "unknown"
            sessions[sessionId] = state
            return .paused(reason: reason)
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
            consecutiveLowCount: 0,
            totalDispatches: 0,
            paused: false,
            pauseReason: nil,
            stopped: false,
            stopReason: nil
        )
        state.totalDispatches += 1

        switch result {
        case let .ready(_, _, conf, _, _, _) where conf != .low:
            // Forward progress — reset the consecutive-low counter.
            state.consecutiveLowCount = 0
            trace.emit("loop", "recorded ready session=\(sessionId) confidence=\(conf.rawValue) total=\(state.totalDispatches)")
        case .ready(_, _, .low, _, _, _),
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
        @unknown default:
            break
        }

        sessions[sessionId] = state
    }

    /// Called by the engine when a userPrompt event arrives — the
    /// human is back in the chat, loop should pause until they
    /// explicitly resume (or a new session starts).
    public func notePause(sessionId: String, reason: LoopPauseReason) {
        var state = sessions[sessionId] ?? SessionState(
            loopStartedAt: now(),
            consecutiveLowCount: 0,
            totalDispatches: 0,
            paused: false,
            pauseReason: nil,
            stopped: false,
            stopReason: nil
        )
        // Don't override .stopped — once stopped, paused is meaningless.
        if state.stopped { return }
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

    /// Force-stop a session's loop. Called by the engine when the
    /// router fires a kill action (the worker is gone — the loop
    /// has nothing to dispatch INTO).
    public func stop(sessionId: String, reason: LoopStopReason) {
        var state = sessions[sessionId] ?? SessionState(
            loopStartedAt: now(),
            consecutiveLowCount: 0,
            totalDispatches: 0,
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
            consecutiveLowCount: state.consecutiveLowCount,
            totalDispatches: state.totalDispatches,
            paused: state.paused,
            pauseReason: state.pauseReason,
            stopped: state.stopped,
            stopReason: state.stopReason
        )
    }
}

/// Snapshot of one session's loop state. Read-only; for tests +
/// post-mortems + future UI surfacing.
public struct LoopSnapshot: Sendable, Equatable {
    public let loopStartedAt: Date
    public let consecutiveLowCount: Int
    public let totalDispatches: Int
    public let paused: Bool
    public let pauseReason: String?
    public let stopped: Bool
    public let stopReason: LoopStopReason?
}
