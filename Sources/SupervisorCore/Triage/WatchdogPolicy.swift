// WatchdogPolicy.swift - v0.2.0 M7. The model-aware interval policy for the
// stall watchdog.
//
// The watchdog's silence threshold ("how long with outstanding async work + no
// visible progress before we check in") is model-aware: a slower / more
// deliberate model may legitimately go quiet longer while a sub-agent or a
// background task runs, so its interval is longer; a fast model's silence is
// suspicious sooner. This type keeps the model -> interval mapping in ONE small,
// tunable place so the policy can be tuned without touching the engine or the
// pure StallWatchdog decision.
//
// DEFAULT 30 minutes (the locked decision). The per-model overrides are keyed by
// a normalized substring of the model id (lowercased), so "claude-opus-4-8" and
// "claude-opus-4-1-20250805" both match the "opus" family without pinning a
// build. An unknown / nil model gets the default interval - and that is the
// clear extension point: when the engine learns the watched session's model
// (today it is read opportunistically from the transcript and may be nil), it
// passes it here; until then everything runs at the safe 30m default.
//
// Pure value type: no clock, no I/O. `interval(forModel:)` is a total function.

import Foundation

public struct WatchdogPolicy: Sendable {

    /// The default silence interval when the model is unknown or has no override.
    /// 30 minutes per the locked M7 decision.
    public static let defaultInterval: TimeInterval = 30 * 60

    /// The model -> interval overrides, keyed by a lowercased family substring.
    /// Kept deliberately small and conservative; tune HERE (one place). The
    /// values bracket the 30m default: faster models check in sooner, slower /
    /// more deliberate ones get more runway before a stall is suspected.
    ///
    /// Matching is by substring so a family key covers every build of that
    /// family (e.g. "opus" matches "claude-opus-4-8" and any dated opus id).
    public static let defaultOverrides: [(family: String, interval: TimeInterval)] = [
        // Fast / cheap models: silence is suspicious sooner.
        ("haiku", 20 * 60),
        // Mid models: the default cadence.
        ("sonnet", 30 * 60),
        // Deliberate / long-thinking models: more runway before we probe.
        ("opus", 45 * 60),
    ]

    public let defaultInterval: TimeInterval
    /// Stored lowercased for case-insensitive substring matching.
    private let overrides: [(family: String, interval: TimeInterval)]

    /// - `defaultInterval`: used when the model is nil or matches no override.
    /// - `overrides`: model-family-substring -> interval. Defaults to the table
    ///   above; tests pass a custom table to exercise model-awareness.
    public init(
        defaultInterval: TimeInterval = WatchdogPolicy.defaultInterval,
        overrides: [(family: String, interval: TimeInterval)] = WatchdogPolicy.defaultOverrides
    ) {
        self.defaultInterval = defaultInterval
        self.overrides = overrides.map { ($0.family.lowercased(), $0.interval) }
    }

    /// The silence interval to use for a session running `model`. nil / empty /
    /// unrecognized -> `defaultInterval` (the safe 30m floor). The first override
    /// whose family substring appears in the lowercased model id wins (table
    /// order), so order the table from most-specific to least if families ever
    /// overlap.
    public func interval(forModel model: String?) -> TimeInterval {
        guard let model, !model.isEmpty else { return defaultInterval }
        let lowered = model.lowercased()
        for override in overrides where lowered.contains(override.family) {
            return override.interval
        }
        return defaultInterval
    }
}
