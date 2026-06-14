// HumanActivityProbe.swift — "is the human at the keyboard right now?"
//
// Owner policy (2026-06-13): Supervisor must never type into — or queue a
// dispatch behind — a composer the human is actively using. Verbatim:
//   "if the human is typing, it shouldn't queue or type while the human is
//    typing."
// So every delivery path that synthesizes keystrokes (the answer/continue
// inject paths AND the urgent wrong_trajectory redirect) consults this probe
// first and DEFERS if a real keystroke landed in the last couple of seconds.
// Deferral is not a drop: the triage engine re-evaluates the session on its
// next idle tick, so the dispatch fires once the human pauses — never on top
// of their input.
//
// This is the cheap, system-wide first gate. The precise "is the human's own
// draft sitting in THIS composer?" check is a separate, OCR-based guard on the
// inject path; the two compose (HID idle catches active typing anywhere; the
// composer read catches a parked draft).

import CoreGraphics
import Foundation

/// Reports how long it's been since the human last pressed a physical key.
/// Abstracted so the router can be tested with a deterministic stub instead of
/// the live CoreGraphics event clock.
public protocol HumanActivityProbe: Sendable {
    /// Seconds since the most recent keystroke, system-wide. A small value
    /// (below the router's guard threshold) means the human is typing right
    /// now, so an inject would steal focus from — or clobber — their input.
    func secondsSinceLastKeystroke() -> TimeInterval
}

/// Production probe: CoreGraphics HID idle time for `.keyDown`. This is the
/// hardware-level event clock (the same lineage the OS uses for idle/
/// screensaver timing), so it reflects real key presses.
///
/// Caveat: Supervisor's OWN synthesized keystrokes post into the HID stream
/// and also reset this clock. That's harmless here because the guard is read
/// BEFORE a dispatch types — so it sees the human's activity, not its own. The
/// only way our own events pollute the reading is a prior inject < threshold
/// ago, in which case deferring is the safe outcome anyway (back-to-back
/// dispatches into a just-touched composer are exactly what we want to space).
public struct CGHumanActivityProbe: HumanActivityProbe {
    public init() {}

    public func secondsSinceLastKeystroke() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }
}

/// Test probe: returns a fixed idle reading.
public struct StubHumanActivityProbe: HumanActivityProbe {
    public let idleSeconds: TimeInterval
    public init(idleSeconds: TimeInterval) { self.idleSeconds = idleSeconds }
    public func secondsSinceLastKeystroke() -> TimeInterval { idleSeconds }
}
