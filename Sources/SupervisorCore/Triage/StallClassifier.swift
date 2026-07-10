// StallClassifier.swift - v0.2.0 observability (Reddit feedback B).
//
// The stall watchdog (StallWatchdog) decides WHETHER to nudge; this classifies
// WHY the session stalled, so the nudge audit record (PART A) says more than
// "continued." It is a PURE function over signals the AsyncWorkScanner already
// reads off the transcript in its single pass (no new read, no model call, no
// I/O) plus the watchdog's own escalated-stop flag. Every branch is unit-
// testable with literals, mirroring StallWatchdog / WatchdogPolicy.
//
// The classification is best-effort and SOFT: it only labels the nudge for the
// audit trail and the human-readable "why". It NEVER changes the watchdog's
// action (the watchdog still just nudges, then notifies, and never auto-kills).
// A signal it cannot read degrades to `.unknown`, never a wrong escalation.

import Foundation

/// Why a watched session appears to have stalled. String-coded for a stable
/// on-disk representation in the audit log (matches FlagAction / AuditEntryKind).
///   - bgTaskSilent:   a background Bash task is outstanding and the session has
///                     gone quiet (the default / most common case).
///   - subAgentFanout: the outstanding work is a sub-agent (Task/Agent) fan-out
///                     that has gone quiet - a parent waiting on children.
///   - awaitingInput:  the transcript ends on an assistant question with no user
///                     reply; the session is waiting on the HUMAN, not a dead
///                     task. (The watchdog still nudges, but the receipt is
///                     honest that this is an input wait.)
///   - rateLimited:    a recent turn / result carried a rate-limit / overloaded
///                     marker (429, "rate limit", "overloaded").
///   - crashed:        a recent result carried a hard-crash marker (segfault,
///                     panic, killed, core dumped) - the async work likely died.
///   - unknown:        outstanding work + silence, but none of the above signals
///                     are present (or the transcript could not be read).
public enum StallClassification: String, Codable, Sendable, CaseIterable {
    case bgTaskSilent
    case subAgentFanout
    case awaitingInput
    case rateLimited
    case crashed
    case unknown

    /// A short human-readable phrase for the audit summary / "why" line.
    public var humanReason: String {
        switch self {
        case .bgTaskSilent:   return "a background task is outstanding and the session went quiet"
        case .subAgentFanout: return "sub-agents were launched and the session went quiet waiting on them"
        case .awaitingInput:  return "the session is waiting on a human reply to its last question"
        case .rateLimited:    return "a recent turn hit a rate limit or overloaded error"
        case .crashed:        return "a recent task result looks like it crashed or was killed"
        case .unknown:        return "outstanding async work with no clear failure signal"
        }
    }
}

/// The pure stall failure-mode classifier. `classify(scan:escalated:)` maps the
/// scanner's PART B signals to a `StallClassification`. Pure: same inputs ->
/// same output, no clock, no I/O.
public struct StallClassifier: Sendable {

    public init() {}

    /// Classify why a session stalled from the AsyncWorkScanner's scan signals.
    ///
    /// PRECEDENCE (most-specific / most-actionable first):
    ///   1. crashed       - a hard-crash marker is the strongest "the work died" signal.
    ///   2. rateLimited   - a throttle marker explains the silence concretely.
    ///   3. awaitingInput - the tail is an assistant question with no user reply.
    ///   4. subAgentFanout- the most-recent outstanding launch is a sub-agent.
    ///   5. bgTaskSilent  - there is outstanding work (the default labelled case).
    ///   6. unknown       - none of the above (or nothing outstanding to explain).
    ///
    /// `escalated` is accepted for symmetry with the watchdog's escalate path
    /// (the caller may pass whether this classification is for an escalation vs a
    /// check-in); it does not change the label today but keeps the signature
    /// stable for a future escalate-specific refinement.
    public func classify(scan: AsyncWorkScanner.Scan, escalated: Bool = false) -> StallClassification {
        if scan.crashSignal { return .crashed }
        if scan.rateLimitSignal { return .rateLimited }
        if scan.awaitingInputSignal { return .awaitingInput }
        if scan.lastOutstandingIsSubAgent { return .subAgentFanout }
        if scan.outstanding || scan.launchCount > 0 { return .bgTaskSilent }
        return .unknown
    }
}
