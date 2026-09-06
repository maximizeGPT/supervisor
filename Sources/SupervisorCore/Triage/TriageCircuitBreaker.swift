// TriageCircuitBreaker.swift. Stop hammering a provider that says 402.
//
// A 402 means the account is out of credit. Unlike a 429 or a 5xx, it does
// not heal in seconds, and before this breaker existed a dead-credit
// provider produced one failed call (plus its trace line) roughly every 30
// seconds, around the clock, for nothing — the exact storm the 2026-09-03
// audit flagged live against DeepSeek. After a 402, triage attempts pause
// for 5 minutes; if the next probe still meets a 402 the pause doubles, up
// to an hour, and any success snaps the breaker shut again.
//
// Scoped to 402 on purpose. 401/403 are configuration errors the owner gets
// paged about separately (SystemEscalationEvent) but might fix any minute;
// 429 already carries the provider's own retry-after; 5xx and network blips
// are transient. Only "out of money" earns an hour-class backoff.
//
// A pure value type: the engine owns one as state and feeds it timestamps,
// so every transition is a table in the tests. While the breaker is open the
// engine SKIPS the call silently — the trace gets one line per state change
// (opened / reopened / closed), never one per suppressed tick.

import Foundation

public struct TriageCircuitBreaker: Sendable, Equatable {

    /// First pause after a 402.
    public static let initialBackoffSeconds: TimeInterval = 300
    /// Ceiling for the doubling: 300 -> 600 -> 1200 -> 2400 -> 3600, hold.
    public static let maxBackoffSeconds: TimeInterval = 3600

    /// How many 402s in a row the breaker has absorbed. Drives the backoff
    /// exponent; reset by any success.
    public private(set) var consecutiveTrips = 0

    /// Calls are suppressed until this moment. nil = closed.
    public private(set) var openUntil: Date?

    public init() {}

    /// Whether a triage call should be skipped right now. The boundary is
    /// half-open at `openUntil` itself: once the deadline passes, exactly
    /// one probe call goes through and its result decides the next state.
    public func isOpen(at now: Date) -> Bool {
        guard let openUntil else { return false }
        return now < openUntil
    }

    /// The pause a trip at `consecutiveTrips` produces (the value used for
    /// the NEXT recordPaymentRequired). Exposed for trace lines and tests.
    public var currentBackoffSeconds: TimeInterval? {
        guard consecutiveTrips > 0 else { return nil }
        let doubled = Self.initialBackoffSeconds * pow(2, Double(consecutiveTrips - 1))
        return min(doubled, Self.maxBackoffSeconds)
    }

    /// What a record call did to the state, for the one-line-per-change
    /// trace rule.
    public enum Change: Equatable, Sendable {
        /// closed -> open. This is the once-per-incident moment: the hover
        /// notice and the trace's "opened" line hang off it.
        case opened(until: Date)
        /// open -> open with a doubled window (the probe met another 402).
        case reopened(until: Date)
        /// open (or tripped) -> closed on a success.
        case closed
        /// Nothing moved (a success on an already-closed breaker).
        case none
    }

    /// A 402 landed: (re)open with exponential backoff.
    @discardableResult
    public mutating func recordPaymentRequired(at now: Date) -> Change {
        let wasTripped = consecutiveTrips > 0
        consecutiveTrips += 1
        // currentBackoffSeconds is non-nil from here (trips >= 1).
        let until = now.addingTimeInterval(currentBackoffSeconds ?? Self.initialBackoffSeconds)
        openUntil = until
        return wasTripped ? .reopened(until: until) : .opened(until: until)
    }

    /// Any successful call closes the breaker and resets the ladder: the
    /// account was topped up, the next 402 (if ever) is a new incident.
    @discardableResult
    public mutating func recordSuccess() -> Change {
        guard consecutiveTrips > 0 || openUntil != nil else { return .none }
        consecutiveTrips = 0
        openUntil = nil
        return .closed
    }
}
