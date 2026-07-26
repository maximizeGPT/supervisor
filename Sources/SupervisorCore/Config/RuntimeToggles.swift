// RuntimeToggles.swift — owner-facing on/off switches the running app reads live.
//
// Each toggle is a marker file under Application Support/Supervisor (existence =
// ON), so flipping one takes effect WITHOUT a rebuild and survives a relaunch.
// Mirrors the established `TriageEngine.autoDispatchDisabled` pattern. The hover
// panel's buttons call the setters; the LoopController / TriageEngine read the
// getters on their hot paths.
//
// Reads are `nonisolated static` so any actor/thread can consult them cheaply.

import Foundation

public enum RuntimeToggles {

    private static var markerDir: URL {
        // ConfigPaths.resolvedHome, not homeDirectoryForCurrentUser: a
        // SUPERVISOR_HOME-isolated instance (E2E harness) must read/write ITS
        // OWN markers — with the raw home here, a test instance would flip the
        // LIVE app's pause/dispatch markers (the worst cross-instance leak).
        ConfigPaths.resolvedHome
            .appendingPathComponent("Library/Application Support/Supervisor", isDirectory: true)
    }

    /// `dir` defaults to the real Application Support marker dir; tests pass a
    /// temp dir so a round-trip never creates a real marker the running app
    /// would pick up.
    nonisolated static func isOn(_ name: String, dir: URL? = nil) -> Bool {
        let base = dir ?? markerDir
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path)
    }

    static func setOn(_ name: String, _ on: Bool, dir: URL? = nil) {
        let base = dir ?? markerDir
        let url = base.appendingPathComponent(name)
        if on {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 4-hour loop cap

    /// When ON, the LoopController's 4-hour wall-clock hard stop is DISABLED — the
    /// loop runs as long as it stays productive (for long sessions / the
    /// give-it-one-prompt screen-record demo). The other stops still apply: a
    /// kill, three-consecutive-low, and the pause-on-user-message are unaffected.
    nonisolated public static var loopCapDisabled: Bool { isOn(loopCapMarker) }
    public static func setLoopCapDisabled(_ on: Bool) { setOn(loopCapMarker, on) }
    private static let loopCapMarker = "loop-cap-disabled.marker"

    // MARK: - Background-task / stall watchdog (v0.2.0 M7) - DEFAULT ON

    /// The stall watchdog is a DEFAULT-ON safety net (it revives a stalled main
    /// session when a background task or sub-agents have gone silent past a
    /// model-aware interval). Like `loopCapDisabled`, it uses a DISABLE marker:
    /// the feature is ACTIVE unless `watchdog-disabled.marker` is present, so the
    /// default build runs it without any marker, and the owner turns it OFF by
    /// touching the marker (no rebuild, survives relaunch). The global
    /// `supervisorPaused` marker still suppresses it (the engine checks both): a
    /// paused supervisor nudges nothing.
    nonisolated public static var watchdogDisabled: Bool { isOn(watchdogMarker) }
    public static func setWatchdogDisabled(_ on: Bool) { setOn(watchdogMarker, on) }
    private static let watchdogMarker = "watchdog-disabled.marker"

    /// Convenience: the watchdog is ENABLED when its disable marker is absent.
    /// The engine reads this (default true). Phrasing it positively keeps the
    /// default-on intent obvious at the call site.
    nonisolated public static var watchdogEnabled: Bool { !watchdogDisabled }

    /// Test seam: read the watchdog disable marker against an explicit dir so a
    /// round-trip never creates the real marker the running app would pick up.
    nonisolated static func watchdogDisabled(dir: URL) -> Bool { isOn(watchdogMarker, dir: dir) }
    static func setWatchdogDisabled(_ on: Bool, dir: URL) { setOn(watchdogMarker, on, dir: dir) }

    // MARK: - Global pause

    /// When ON, Supervisor is globally PAUSED — the engine processes no events:
    /// no triage, no dispatch, no inject, no API spend. The watcher goes dormant
    /// (not gone) and resumes the moment it's turned back off. Distinct from
    /// `autoDispatchDisabled` (which only silences the continue/dispatch path).
    nonisolated public static var supervisorPaused: Bool { isOn(pausedMarker) }
    public static func setSupervisorPaused(_ on: Bool) { setOn(pausedMarker, on) }
    private static let pausedMarker = "supervisor-paused.marker"

    /// Test seam: read/write the global pause marker against an explicit dir so
    /// a round-trip never touches the REAL marker the running app reads — a test
    /// engaging the pause must not pause the live app, and its cleanup must not
    /// delete an owner-engaged pause. (The public getter/setter intentionally
    /// target the real Application Support dir.)
    nonisolated static func supervisorPaused(dir: URL) -> Bool { isOn(pausedMarker, dir: dir) }
    static func setSupervisorPaused(_ on: Bool, dir: URL) { setOn(pausedMarker, on, dir: dir) }

    // MARK: - Planner/Evaluator harness (v0.2.0 M2d-2) - opt-in, default OFF

    /// When ON, the idle/drive path runs the v0.2.0 Planner + Evaluator harness
    /// instead of the single-shot Dispatcher: an idle session with a captured
    /// objective and no plan gets an awaiting-approval Plan (surfaced for the
    /// human to approve), and an approved running plan is driven step-by-step
    /// (inject the step, observe, evaluate, decide advance/redirect/replan/
    /// escalate). Defaults OFF, so the engine behaves EXACTLY as today (the
    /// Dispatcher path) until the owner flips this on. Every plan-step injection
    /// still rides the existing marked + ledgered injection path, and an
    /// escalation pauses + notifies (never auto-continues). The other gate is the
    /// plan state itself: with the toggle on but no approved plan, the idle path
    /// stays on the Dispatcher.
    nonisolated public static var plannerEnabled: Bool { isOn(plannerMarker) }
    public static func setPlannerEnabled(_ on: Bool) { setOn(plannerMarker, on) }
    private static let plannerMarker = "planner-enabled.marker"

    /// Test seam: read/write the planner toggle against an explicit dir so a
    /// round-trip never creates the real marker the running app would pick up.
    /// (The public getter/setter intentionally target the real Application
    /// Support dir; tests use these to exercise the gate hermetically.)
    nonisolated static func plannerEnabled(dir: URL) -> Bool { isOn(plannerMarker, dir: dir) }
    static func setPlannerEnabled(_ on: Bool, dir: URL) { setOn(plannerMarker, on, dir: dir) }

    // MARK: - Code-review dimension (v0.3.x) - opt-in, default OFF

    /// When ON, the REVIEW dimension is active: ReviewEngine reviews the code a
    /// supervised worker writes (Edit/Write/MultiEdit) on the fly and surfaces
    /// substantive quality issues in the hover panel's Activity tab. Defaults OFF,
    /// so a fresh build behaves EXACTLY as today — the ReviewEngine subscribes but
    /// short-circuits on every event and spends nothing until the owner flips this
    /// on. Strictly additive to (never a modifier of) the safety triage: the
    /// destructive-action path is unchanged whether this is on or off. The global
    /// `supervisorPaused` marker still suppresses it (a paused supervisor reviews
    /// nothing).
    nonisolated public static var reviewEnabled: Bool { isOn(reviewMarker) }
    public static func setReviewEnabled(_ on: Bool) { setOn(reviewMarker, on) }
    private static let reviewMarker = "review-enabled.marker"

    /// Test seam: read/write the review toggle against an explicit dir.
    nonisolated static func reviewEnabled(dir: URL) -> Bool { isOn(reviewMarker, dir: dir) }
    static func setReviewEnabled(_ on: Bool, dir: URL) { setOn(reviewMarker, on, dir: dir) }

    // MARK: - Approve-plan affordance (v0.2.0 M4-prep) - one-shot, gated by planner opt-in

    /// A ONE-SHOT request to approve the watched session's latest
    /// awaiting-approval plan, expressed as a marker file. It exists so the
    /// planner/evaluator loop is exercisable live BEFORE the M3 approval UI
    /// (which is gated on a Stitch design): the owner touches
    /// `approve-plan.marker`, and on the next periodic tick the engine approves
    /// the plan + starts driving it, then DELETES the marker (so a single touch
    /// approves exactly one plan, never re-approving on later ticks).
    ///
    /// This is strictly subordinate to `plannerEnabled`: the engine only
    /// consults it when the planner opt-in is ON. With the planner toggle OFF
    /// the marker is ignored entirely (no read, no consume), so it adds NO new
    /// behavior to the default build. `consumeApprovePlanRequested` reads-then-
    /// deletes atomically enough for this single-writer use (the engine tick).
    nonisolated public static var approvePlanRequested: Bool { isOn(approvePlanMarker) }
    public static func setApprovePlanRequested(_ on: Bool) { setOn(approvePlanMarker, on) }
    private static let approvePlanMarker = "approve-plan.marker"

    /// Read the approve-plan marker and, if present, DELETE it (one-shot
    /// consume). Returns whether it was present. The engine calls this once per
    /// tick AFTER confirming `plannerEnabled`, so an approval fires exactly once
    /// per touch. `dir` is the test seam (a temp dir) so a round-trip never
    /// touches the real marker the running app would pick up.
    @discardableResult
    nonisolated public static func consumeApprovePlanRequested(dir: URL? = nil) -> Bool {
        let present = isOn(approvePlanMarker, dir: dir)
        if present { setOn(approvePlanMarker, false, dir: dir) }
        return present
    }

    /// Test seam: read/write the approve-plan marker against an explicit dir.
    nonisolated static func approvePlanRequested(dir: URL) -> Bool { isOn(approvePlanMarker, dir: dir) }
    static func setApprovePlanRequested(_ on: Bool, dir: URL) { setOn(approvePlanMarker, on, dir: dir) }
}
