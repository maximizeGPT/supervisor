// SystemEscalation.swift. The events where SUPERVISOR ITSELF is the thing
// that stopped working, and the owner is the only fix.
//
// The intervention channel escalates what a WORKER did (pause, kill, a
// pending question), and everything about it hangs off a `TriageDecision`.
// These two events have no decision to hang off: the daily cost cap tripping
// and the model provider refusing calls both mean triage has silently gone
// dark — every session on the machine is now unwatched, which is strictly
// worse than any single flagged command, and the local banner is on a screen
// nobody is looking at (that being the premise of the remote channel).
//
// So they travel as a parallel system-event path rather than as new
// `InterventionOutcome` cases. Deliberately: InterventionOutcome's kind is
// the persisted `flags.intervention_outcome` vocabulary (adding a case is a
// DB migration concern), `Notifier.plainTitle` / `composeBody` /
// `RemoteNotifyPolicy.verdict` all switch exhaustively over per-session
// outcomes, and a cap-hit has no session, no PID and no flag row to write.
// The wrong shape, forced, would cost more than this small enum.
//
// Copy rule: nothing session-derived, ever. These strings describe
// Supervisor's own state and render in a banner, on the hover, and on the
// owner's phone. No paths, no commands, no em dashes.

import Foundation

public enum SystemEscalationEvent: Sendable, Equatable {

    /// The owner's `cost.daily_cap_usd` was reached: every further model
    /// call is refused before the network, so triage is dark until midnight
    /// or a raised cap. Carries the numbers the refusal was made from.
    case costCapHit(spentUSD: Double, capUSD: Double)

    /// The provider rejected Supervisor's calls with an auth- or
    /// billing-class status (401 bad key, 402 out of credit, 403 no
    /// permission). Retrying does not help; only the owner can fix the key
    /// or the account.
    case providerUnavailable(status: Int)

    /// Triage is still running but no longer fully guarded. Distinct from
    /// `costCapHit` on purpose: a cap hit is the owner's own budget doing its
    /// job and everything stops, whereas this is Supervisor's plumbing being
    /// broken while the work continues. Same channel, different sentence, and
    /// a different dedupe key so one never swallows the other.
    case triageDegraded(reason: DegradedReason)

    /// Why triage is degraded. An enum rather than a string so the copy is
    /// pinned in one place and a new reason cannot be invented at a call site.
    public enum DegradedReason: String, Sendable, Equatable {
        /// The cost store would not read (locked SQLite, full disk, corrupt
        /// row), so the daily-cap gate cannot tell what has been spent. The
        /// spend-heavy paths are blocked fail-closed; the destructive-command
        /// path is allowed through unmetered rather than leaving real commands
        /// unreviewed because of a broken ledger.
        case costStoreUnreadable = "cost_store_unreadable"

        /// A spend WRITE threw (read-only database, full disk, locked file),
        /// so today's total has stopped moving. The mirror image of the case
        /// above and the more dangerous direction: reads still succeed, so
        /// the cap compares against a frozen number and can never trip. The
        /// gate that exists to bound spend has failed OPEN.
        case costStoreUnwritable = "cost_store_unwritable"
    }

    /// If an incident is STILL standing this long after its first page,
    /// one repeat goes out — and only one. A capped or credit-dead
    /// provider stays that way for hours; an hourly page all day carried
    /// no new information and taught the owner to mute the channel, but a
    /// single "still down" after most of a workday is worth a buzz.
    public static let repeatAfterSeconds: TimeInterval = 6 * 3600

    /// The remote channel's own dedupe window for these events, passed
    /// with each postSystemEvent as defense in depth. Minutes, not the
    /// engine ledger's horizon: the ledger (below) is the policy now, and
    /// a NEW incident it clears and re-pages must not be swallowed at the
    /// second gate the first gate just opened. This only absorbs a
    /// pathological emit storm.
    public static let remoteStormGuardSeconds: TimeInterval = 600

    // MARK: - Incident-based emission policy

    /// Per-kind ledger entry: when the CURRENT incident first paged, and
    /// whether its one 6-hour repeat already went. The engine holds one of
    /// these per kind while an incident is open and drops them all the
    /// moment a provider call succeeds — a success means the cap is no
    /// longer refusing and the key works, so the next failure is a NEW
    /// incident and pages promptly instead of hiding inside an old window.
    public struct IncidentState: Equatable, Sendable {
        public var firstPagedAt: Date
        public var repeatedAt: Date?

        public init(firstPagedAt: Date, repeatedAt: Date? = nil) {
            self.firstPagedAt = firstPagedAt
            self.repeatedAt = repeatedAt
        }
    }

    /// The one emission decision: page when the incident OPENS (no ledger
    /// entry yet), page at most once more if it still stands past
    /// `repeatAfterSeconds`, and otherwise stay quiet. Pure, so the policy
    /// is a table in the tests.
    public static func incidentEmission(
        state: IncidentState?,
        now: Date
    ) -> (state: IncidentState, emit: Bool) {
        guard var state else {
            return (IncidentState(firstPagedAt: now), true)
        }
        if state.repeatedAt == nil, now.timeIntervalSince(state.firstPagedAt) >= repeatAfterSeconds {
            state.repeatedAt = now
            return (state, true)
        }
        return (state, false)
    }

    /// Stable log/wire tag; also the dedupe key half.
    public var kind: String {
        switch self {
        case .costCapHit:          return "cost_cap_hit"
        case .providerUnavailable: return "provider_unavailable"
        // Reason-qualified, so a future second reason pages on its own merits
        // instead of being deduped away by the first one still standing.
        case .triageDegraded(let reason): return "triage_degraded.\(reason.rawValue)"
        }
    }

    /// Banner and page title. Same sentence on every surface.
    public var title: String {
        switch self {
        case .costCapHit:
            return "Supervisor hit its daily cost cap"
        case .providerUnavailable:
            return "Supervisor cannot reach its model provider"
        case .triageDegraded:
            // Says "still watching" first on purpose. A cap hit means nothing
            // is watched; this one means the important part still is, and the
            // owner should not read the two as the same outage.
            return "Supervisor is watching commands but cannot track spend"
        }
    }

    /// Banner and page body: what stopped, why, and the one thing the owner
    /// can do about it.
    public var body: String {
        switch self {
        case .costCapHit(let spent, let cap):
            // Names the file's real location rather than a bare "config.yaml"
            // the owner has to go hunting for. Home-relative on purpose: this
            // sentence is delivered to Discord, Slack and phones, and the
            // absolute path would publish the account name. Since 0.4.0 a
            // first launch seeds that file, so the remedy names something that
            // exists.
            return String(
                format: "Today's model spend reached $%.2f of the $%.2f cap, so triage is paused and sessions are not being watched. Raise cost.daily_cap_usd in %@ to resume today, or wait for the daily reset.",
                spent, cap, StarterConfig.ownerFacingLocation
            )
        case .providerUnavailable(let status):
            let why: String
            switch status {
            case 401: why = "the API key was rejected (HTTP 401). Update the key in Supervisor's panel settings."
            case 402: why = "the account is out of credit (HTTP 402). Top up the provider account; Supervisor backs off and retries on its own."
            case 403: why = "the key lacks permission for the triage model (HTTP 403)."
            default:  why = "it answered HTTP \(status)."
            }
            return "Triage calls are failing because \(why) Sessions are not being watched until this is fixed."
        case .triageDegraded(let reason):
            switch reason {
            case .costStoreUnreadable:
                return "Supervisor cannot read its own spend record, so the daily cost cap is not being enforced. Risky commands are still being reviewed, but idle checks and dispatch are paused and today's spend is not counted. Quit and reopen Supervisor; if it persists, check that the disk is not full."
            case .costStoreUnwritable:
                // Says "keeps spending" out loud. The unreadable case pauses
                // the spend-heavy paths; this one does not pause anything,
                // because reads still succeed and nothing looks wrong. That
                // is the more expensive failure, and the copy has to say so.
                return "Supervisor cannot write to its own spend record, so today's total has stopped moving and the daily cost cap can no longer stop anything. Supervision continues and keeps spending, uncounted. Quit and reopen Supervisor; if it persists, check that the disk is not full."
            }
        }
    }

    /// Classify an LLM-call failure into a system escalation, or nil for
    /// the failures that are not owner-blocking (rate limits, transient
    /// network, 5xx — those heal on their own and must not page a phone).
    /// Pure, so the mapping is a table in the tests.
    public static func classify(_ error: Error) -> SystemEscalationEvent? {
        if let cap = error as? DailyCapExceededError {
            // A refusal from an unreadable ledger is NOT a cap hit. Its
            // `spentUSD` was synthesized equal to the cap by the fail-closed
            // gate, so paging it as a cap hit quotes an invented total and
            // offers a remedy ("raise cost.daily_cap_usd") that cannot ever
            // clear it — the synthesized spend follows the new cap up. It is
            // also the one that used to page on a loop: cost_cap_hit is wiped
            // by the clear-on-success sweep, so the next tick opened a fresh
            // incident and paged again, where triage_degraded is exempt.
            if cap.storeReadFailed {
                return .triageDegraded(reason: .costStoreUnreadable)
            }
            return .costCapHit(spentUSD: cap.spentUSD, capUSD: cap.capUSD)
        }
        guard let api = error as? AnthropicClientError else { return nil }
        switch api {
        case .invalidKey:
            return .providerUnavailable(status: 401)
        case .permissionDenied:
            return .providerUnavailable(status: 403)
        case .requestError(let status, _) where status == 402:
            return .providerUnavailable(status: 402)
        case .rateLimit, .requestError, .serverError, .network, .decodingFailed, .redactorMissing:
            return nil
        }
    }
}
