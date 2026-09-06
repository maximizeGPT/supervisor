// RemoteNotifyPolicy.swift. Which interventions are worth reaching the
// owner when the owner is not looking at the Mac.
//
// Every intervention already posts a local banner. This policy is consulted
// only for the ADDITIONAL remote channel, and it can never suppress the
// banner.
//
// The rule is one sentence: deliver remotely when the session is blocked on
// a human, or when a high-severity flag fired anyway. Everything Supervisor
// handled by itself stays local, because a phone that buzzes for work that
// already got done is a phone the owner mutes, and a muted channel is worse
// than no channel (the owner now believes they are covered).
//
// Concretely:
//
//   pauseSucceeded          → deliver. The worker is frozen until a human acts.
//   killSucceeded           → deliver. The worker is gone until a human acts.
//   continueProposedMedium  → deliver. Propose-and-wait is a wait ON THE OWNER.
//   continueLowConfidence   → deliver. Supervisor went quiet and said why.
//   injectDegraded          → deliver. Supervisor has an answer it couldn't type.
//   screenRecordingDenied   → deliver. Blocked on a permission only the owner grants.
//   notifyOnly              → deliver iff severity == .high.
//   injectSucceeded         → skip. Supervisor answered; nothing is waiting.
//   continueFired           → skip. Supervisor dispatched; nothing is waiting.
//   queued                  → skip. The deferral means a human IS at the keyboard.
//
// Pure functions, no I/O, no state. The reason strings are stable
// identifiers, not prose. They land verbatim in the trace log and in the
// remote payload so "why did this page me" is answerable after the fact.

import Foundation

/// Outcome of the policy check. Carries a stable reason either way so the
/// trace line is discriminating in both directions. "Why did this send"
/// and "why did this not send" are equally common questions.
public enum RemoteNotifyVerdict: Sendable, Equatable {
    case deliver(reason: String)
    case skip(reason: String)

    /// Convenience for call sites that only branch on the boolean.
    public var isDeliver: Bool {
        if case .deliver = self { return true }
        return false
    }

    /// The reason string, whichever case this is.
    public var reason: String {
        switch self {
        case .deliver(let r), .skip(let r): return r
        }
    }
}

public enum RemoteNotifyPolicy {

    /// Should this (decision, outcome) pair reach the owner off-machine?
    public static func verdict(
        decision: TriageDecision,
        outcome: InterventionOutcome
    ) -> RemoteNotifyVerdict {
        switch outcome {
        case .pauseSucceeded:
            return .deliver(reason: "worker_paused")
        case .killSucceeded:
            return .deliver(reason: "worker_killed")
        case .continueProposedMedium:
            return .deliver(reason: "awaiting_owner_approval")
        case .continueLowConfidence:
            return .deliver(reason: "awaiting_owner_direction")
        case .injectDegraded:
            return .deliver(reason: "answer_needs_manual_paste")
        case .screenRecordingDenied:
            // The plan did not die, it is waiting on one System Settings
            // toggle. Nobody but the owner can flip it, so this is the
            // definition of blocked-on-a-human.
            return .deliver(reason: "screen_recording_permission_off")
        case .notifyOnly:
            // A high-severity notify means the rubric saw something bad and
            // chose not to stop the worker. The owner still wants to know
            // before the next command runs.
            switch decision.candidate.severity {
            case .high:   return .deliver(reason: "high_severity_flag")
            case .medium: return .skip(reason: "medium_severity_notify")
            case .low:    return .skip(reason: "low_severity_notify")
            }
        case .injectSucceeded:
            return .skip(reason: "handled_supervisor_answered")
        case .continueFired:
            return .skip(reason: "handled_supervisor_dispatched")
        case .queued:
            // HumanActivityProbe deferred this because a real keystroke just
            // landed. The owner is AT the Mac, and the loop re-attempts on
            // the next idle tick. Paging a phone in the owner's pocket while
            // they type is the exact noise that gets the channel muted.
            return .skip(reason: "handled_queued_human_present")
        }
    }

    /// Key used to collapse repeats inside the dedupe window. Session plus
    /// outcome kind plus category: a loop that pauses the same session for
    /// the same reason forty times pages once, but a DIFFERENT category on
    /// the same session still gets through. Deliberately does not include
    /// free text, because reasoning prose varies between otherwise identical
    /// events and would defeat the collapse. The category goes in NORMALIZED
    /// (the same substitution the wire uses): a model inventing a fresh
    /// category string per event would otherwise mint a fresh key per event
    /// and defeat the collapse the same way free text would.
    public static func dedupeKey(
        decision: TriageDecision,
        outcome: InterventionOutcome
    ) -> String {
        "\(decision.sessionId)|\(outcomeKind(outcome))|\(RemoteNotifyPayload.normalizedCategory(decision.candidate.category))"
    }

    /// Short stable tag for the outcome case, without its payload. Used in
    /// the dedupe key and in trace lines (the synthesized `\(outcome)`
    /// description would drag PIDs and prose into both).
    ///
    /// Deliberately NOT `InterventionOutcome.kind.rawValue`: that enum is the
    /// persisted `flags.intervention_outcome` vocabulary and changing it
    /// migrates a database column. These tags are wire and log identifiers
    /// and must be free to stay stable independently.
    public static func outcomeKind(_ outcome: InterventionOutcome) -> String {
        switch outcome {
        case .notifyOnly:             return "notify"
        case .pauseSucceeded:         return "pause"
        case .killSucceeded:          return "kill"
        case .injectSucceeded:        return "inject"
        case .injectDegraded:         return "inject_degraded"
        case .screenRecordingDenied:  return "screen_recording_denied"
        case .continueFired:          return "continue"
        case .continueProposedMedium: return "continue_proposed"
        case .continueLowConfidence:  return "continue_low_confidence"
        case .queued:                 return "queued"
        }
    }
}
