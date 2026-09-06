// BlockedSessionRepager.swift. The 45-minute "still waiting on you".
//
// The first page about a blocked session (pause landed, kill landed, a
// question or approval is pending) rides the intervention channel at the
// moment it happens. But the premise of the remote channel is an owner who
// is away, and away includes "saw the buzz, was driving, forgot". A pause
// that nobody answers is a worker frozen for the rest of the day, so a
// still-blocked session re-pages every 45 minutes until the block clears.
//
// This is a SEPARATE mechanism from the anti-spam dedupe window: the window
// collapses repeats of the same event; this deliberately re-raises one. The
// app runs it as a periodic scanner over the flags table (the durable record
// of what the interventions did and whether the owner responded) rather than
// as a per-flag timer, so a crash or relaunch cannot orphan a timer and the
// whole policy is a pure function over (flags, sessions, reminder ledger,
// now) — testable as a table.
//
// What counts as blocked, and what clears it:
//
//   blocked   an unresponded flag whose recorded intervention outcome is
//             waiting on a human: pause, kill, proposed-task approval,
//             low-confidence direction, an answer to paste, a permission
//             to grant.
//   cleared   the owner responded to the flag (panel or banner dismiss);
//             OR the session produced events after the flag (a resumed or
//             answered session moves again, and a paused/killed one
//             cannot); OR, for a kill, a new session started in the same
//             cwd (the restart the reminder was asking for); OR a newer
//             blocked flag superseded this one (only the newest per
//             session reminds); OR the flag aged past 24 hours (an owner
//             who ignored a full day of reminders has decided).
//
// "Session end" has no durable marker in the store (a quiet JSONL looks
// identical for an ended session and a paused one, and the paused one is
// exactly the case that must keep reminding), so the age horizon plus the
// respond-to-clear rule stand in for it.

import Foundation

public enum BlockedSessionRepager {

    /// Cadence of the re-page.
    public static let reminderInterval: TimeInterval = 45 * 60

    /// A flag older than this stops reminding even if still unresponded.
    public static let staleFlagHorizon: TimeInterval = 24 * 60 * 60

    /// Events after the flag mean the session moved (resume, answer typed,
    /// dispatch delivered). A little slack because the intervention's own
    /// surrounding events can land in the store moments after the flag row.
    public static let activitySlack: TimeInterval = 30

    /// The outcomes that mean a human is the only way forward. Mirrors
    /// RemoteNotifyPolicy's deliver set minus notifyOnly (a high-severity
    /// notify informs; it does not block anything).
    public static let blockedOutcomes: Set<InterventionOutcomeKind> = [
        .pauseSucceeded,
        .killSucceeded,
        .continueProposedMedium,
        .continueLowConfidence,
        .injectDegraded,
        .screenRecordingDenied,
    ]

    /// One reminder the caller should deliver.
    public struct Reminder: Equatable, Sendable {
        public let flagId: String
        public let sessionId: String
        public let outcome: InterventionOutcomeKind
        public let blockedSince: Date
    }

    /// The one-flag decision the spec names: given when the block started
    /// and when it was last reminded about, is another reminder due now?
    /// The first reminder is due one interval after the block (the block
    /// itself was already paged by the intervention channel).
    public static func shouldRemind(
        blockedSince: Date,
        lastRemindedAt: Date?,
        now: Date,
        interval: TimeInterval = reminderInterval
    ) -> Bool {
        let anchor = max(blockedSince, lastRemindedAt ?? .distantPast)
        return now.timeIntervalSince(anchor) >= interval
    }

    /// The full pass: every blocked-and-due flag, newest-per-session.
    /// `lastReminded` is the caller's in-memory ledger of flagId to the
    /// last reminder SENT (stamped on delivery success only, so a failed
    /// send retries on the next pass rather than silently burning 45
    /// minutes).
    public static func scan(
        flags: [StoredFlag],
        sessions: [StoredSession],
        lastReminded: [String: Date],
        now: Date
    ) -> [Reminder] {
        let sessionById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let blocked = flags.filter { flag in
            guard let outcome = flag.interventionOutcome, blockedOutcomes.contains(outcome) else { return false }
            guard flag.userResponse == nil else { return false }
            let age = now.timeIntervalSince(flag.ts)
            guard age >= 0, age < staleFlagHorizon else { return false }
            // Session moved after the flag: the block cleared without a
            // recorded response (the panel's Resume, a typed answer). An
            // unknown session row is treated as cleared too — with no way
            // to verify the block still stands, a wrong silence beats a
            // wrong 3am page.
            guard let session = sessionById[flag.sessionId] else { return false }
            if session.lastSeenAt.timeIntervalSince(flag.ts) > activitySlack { return false }
            // A kill clears when the owner did the thing the reminder asks
            // for: started a fresh session in the same working directory.
            // Accepted tradeoff: cwd is the only restart signal the store
            // has, so an UNRELATED new session in the same directory (a
            // teammate's shell, a second worker on the same repo) also
            // silences the reminder, and a restart made from a different
            // directory keeps reminding. A wrong silence after a kill the
            // owner already knows about beats re-paging someone who acted;
            // the 24h horizon caps the other direction.
            if outcome == .killSucceeded {
                let restarted = sessions.contains {
                    $0.id != flag.sessionId && $0.cwd == session.cwd && $0.startedAt > flag.ts
                }
                if restarted { return false }
            }
            return true
        }

        // Newest blocked flag per session: a pause that later got killed (or
        // re-flagged) reminds about the CURRENT state, not the history.
        var newestPerSession: [String: StoredFlag] = [:]
        for flag in blocked {
            if let existing = newestPerSession[flag.sessionId], existing.ts >= flag.ts { continue }
            newestPerSession[flag.sessionId] = flag
        }

        return newestPerSession.values
            .filter { shouldRemind(blockedSince: $0.ts, lastRemindedAt: lastReminded[$0.id], now: now) }
            .sorted { $0.ts < $1.ts }
            .compactMap { flag in
                guard let outcome = flag.interventionOutcome else { return nil }
                return Reminder(
                    flagId: flag.id,
                    sessionId: flag.sessionId,
                    outcome: outcome,
                    blockedSince: flag.ts
                )
            }
    }

    // MARK: - Reminder copy

    /// Minimal by construction, matching the channel's default posture: the
    /// state, how long, and an 8-char session prefix. Nothing quoted from
    /// the session (the original page already carried the detail the owner
    /// opted into).
    public static func message(for reminder: Reminder, now: Date) -> (title: String, body: String) {
        let waited = describeDuration(now.timeIntervalSince(reminder.blockedSince))
        let state: String
        switch reminder.outcome {
        case .pauseSucceeded:
            state = "A session is still paused and waiting for your decision."
        case .killSucceeded:
            state = "A stopped session is still waiting for you to start a new one."
        case .continueProposedMedium:
            state = "A proposed next task is still waiting for your approval."
        case .continueLowConfidence:
            state = "A session finished its work and is still waiting for your direction."
        case .injectDegraded:
            state = "An answer is still waiting for you to paste it into the session."
        case .screenRecordingDenied:
            state = "Supervisor is still waiting on the Screen Recording permission."
        case .notifyOnly, .injectSucceeded, .continueFired, .queued:
            // Not blocked outcomes; scan never produces them. Honest
            // fallback copy anyway rather than a crash or a lie.
            state = "A session is still waiting on you."
        }
        return (
            "Supervisor is still waiting on you",
            "\(state) Blocked for \(waited). Session \(reminder.sessionId.prefix(8))."
        )
    }

    /// "47m" / "3h 12m" style, floor-rounded. Owner-facing, so words stay
    /// short and there is never a bare seconds count.
    static func describeDuration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(interval / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
