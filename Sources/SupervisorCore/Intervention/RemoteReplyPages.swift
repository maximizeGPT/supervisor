// RemoteReplyPages.swift. What the inbound reply channel says back to the
// phone, and the ceiling on what any of it may contain.
//
// Every message here is Supervisor talking about ITSELF rather than about
// a session, and every one is posted to the SAME ntfy topic the pages go
// out on. That topic is publicly readable (see the RemoteReplyGate
// header), so the ceiling is exactly what the `minimal` detail level
// already discloses: Supervisor's own verdict and a project BASENAME.
// Never the reply text, never the command, never session prose, and never
// a correlation code.
//
// WHY THE COPY LIVES HERE AND NOT AT THE CALL SITE. Every one of these is
// posted from main.swift, which is an executable target XCTest cannot
// import, so a message composed inline there is a message no test can
// read. Everything in this file is data, and the tests assert on the bytes
// that reach the wire.
//
// DEDUPE WINDOWS ARE PART OF THE COPY, and they are the reason this file
// has more comment than string. `RemoteNotifier` keys its system dedupe on
// `system|<kind>`, which is the KIND and nothing else: no session, no
// episode, no sequence number. So a window here does not collapse a repeat
// of one event, it collapses the SECOND EVENT. For anything the owner has
// to act on, the right window is zero and the repeat suppression belongs
// upstream where it can tell two episodes apart.

import Foundation

/// The Supervisor-health messages the reply channel can send, alongside the
/// per-reply acknowledgement below.
public enum RemoteReplyPage {

    // MARK: - Lockout (the failure budget blew)

    public static let lockoutKind = "remote_reply_locked_out"

    public static let lockoutTitle = "Supervisor turned off remote replies"

    public static func lockoutBody(failures: Int, window: TimeInterval) -> String {
        "\(failures) replies in \(Int(window / 60)) minutes carried a code Supervisor did not issue. "
            + "Somebody may know this topic. Replies from your phone are off. "
            + "Nothing was typed into any session, and pages still arrive. "
            + "To turn replies back on, flip the toggle in the panel off and on "
            + "(or set remote_notify.reply_enabled to false then true in config.yaml). "
            + "Consider moving to a new ntfy topic first."
    }

    /// Zero, where the obvious value is an hour.
    ///
    /// One page per lockout episode is already guaranteed upstream:
    /// `recordFailure` reports `trip` only on the charge that flips
    /// `lockedOut`, and the flag is sticky until the owner re-arms. An hour
    /// on top of that buys nothing and costs the owner the warning that
    /// matters most. The page they are reading tells them to re-arm by
    /// toggling `reply_enabled`, the attacker who caused the first lockout
    /// is still on the topic when they do, and the second lockout inside
    /// that hour is the one that says so.
    public static let lockoutDedupeWindow: TimeInterval = 0

    // MARK: - Inbound endpoint refused us (401 / 403 / 404)

    public static let inboxDeniedKind = "remote_reply_inbox_denied"

    public static let inboxDeniedTitle = "Supervisor cannot read your reply topic"

    /// The status is the whole diagnosis and it is safe to say: it is the
    /// server's answer to Supervisor, not anything about a session. The
    /// topic itself never appears, here or in the trace.
    public static func inboxDeniedBody(status: Int) -> String {
        "Your ntfy endpoint answered \(status) when Supervisor tried to read replies, "
            + "so replies from your phone are not arriving. Pages still go out. "
            + "Check that the topic in your webhook URL still exists and that any token it needs is still valid. "
            + "Supervisor keeps retrying, slowly, and will pick up again on its own if the endpoint recovers."
    }

    /// Zero, for the same reason as the lockout. The subscriber latches its
    /// own "already paged this episode" flag and clears it on the first
    /// successful read, so one page per outage is guaranteed there; a
    /// window here would only swallow the NEXT outage.
    public static let inboxDeniedDedupeWindow: TimeInterval = 0
}

/// What the owner is told about one reply that reached the code table.
///
/// The design asks for a confirmation, and a confirmation on a public topic
/// is a hard constraint on wording: it may say that something happened and
/// where, and nothing about what was said. Each case below is the whole
/// message, deliberately, so there is no template a future caller can
/// interpolate session text into.
public enum RemoteReplyAcknowledgement: Sendable, Equatable {

    /// Typed into the session, which is named by its project BASENAME only.
    /// nil when the entry carried no cwd, which the wording then omits
    /// rather than guessing at.
    case delivered(project: String?)

    /// The safety screen refused the text. The owner is told that, and
    /// nothing about which phrasing tripped it: the reason is a probing
    /// oracle, so it stays on the Mac.
    ///
    /// This case has a real cost and it is worth naming rather than
    /// leaving for the next reader to find. A subscribed adversary who
    /// spends a code on a probe now learns from the topic whether the
    /// screen refused it, which is one bit they previously had to get by
    /// watching the session. What it does NOT change is the rate: a
    /// refusal still burns the code, so each probe costs one outbound page
    /// to mint the next one, which is the bound the whole design already
    /// leans on. Silence here would cost the owner the case this
    /// acknowledgement exists for, which is learning that their answer did
    /// not land while they are away from the Mac.
    case refused

    /// The rate cap dropped it before any of that.
    case rateLimited

    public var kind: String {
        switch self {
        case .delivered:   return "remote_reply_delivered"
        case .refused:     return "remote_reply_refused"
        case .rateLimited: return "remote_reply_rate_limited"
        }
    }

    public var title: String {
        switch self {
        case .delivered:   return "Supervisor delivered your reply"
        case .refused:     return "Supervisor refused your reply"
        case .rateLimited: return "Supervisor dropped a reply"
        }
    }

    /// Every body opens with a word, not a token. The ack is posted to the
    /// topic the gate reads, so ntfy echoes it straight back; a body whose
    /// first token were code-shaped would be Supervisor answering its own
    /// page. `RemoteReplyGate.parse` needs six characters from its alphabet
    /// in the leading position, and none of these has one.
    public var body: String {
        switch self {
        case .delivered(let project):
            guard let project, !project.isEmpty else {
                return "Reply delivered."
            }
            return "Reply delivered to \(project)."
        case .refused:
            return "Reply refused, see Supervisor. Nothing was typed into the session."
        case .rateLimited:
            return "Replies are arriving faster than the cap allows, so one was dropped. "
                + "Nothing was typed into the session. Send it again in a minute."
        }
    }

    /// Zero for the two outcomes an owner acts on, and a storm guard for the
    /// one that a stranger can produce at will.
    ///
    /// `delivered` and `refused` both require a LIVE code, which is minted
    /// only by an outbound page and spent on use, so their rate is bounded
    /// by Supervisor's own paging. Two of them inside a window are two
    /// different replies, and swallowing the second would leave an answer
    /// the owner sent looking like it vanished.
    ///
    /// `rateLimited` is the opposite. It fires on any code-SHAPED token,
    /// with no table lookup, so a flood produces one per message up to the
    /// cap. Without a guard the inbound flood becomes an outbound flood on
    /// the owner's phone. One minute matches the gate's own rate window, so
    /// the owner is told once per window that the cap is biting, which is
    /// all the information there is.
    public var dedupeWindow: TimeInterval {
        switch self {
        case .delivered, .refused: return 0
        case .rateLimited:         return 60
        }
    }
}

// MARK: - Posting

/// The reply channel's messages, as methods on the real notifier.
///
/// A thin extension rather than a helper type, so the wiring in main.swift
/// is one call per site and the tests can drive the SAME method against a
/// real `RemoteNotifier` and a stub transport. That matters for the lockout
/// in particular: the bug this file exists to fix (a second lockout inside
/// an hour silently dropped) lives in the notifier's dedupe, so a test with
/// a mocked pager structurally cannot see it.
extension RemoteNotifier {

    @discardableResult
    public func postRemoteReplyLockout(failures: Int, window: TimeInterval) async -> Notifier.Outcome {
        await postSystemMessage(
            title: RemoteReplyPage.lockoutTitle,
            body: RemoteReplyPage.lockoutBody(failures: failures, window: window),
            kind: RemoteReplyPage.lockoutKind,
            dedupeWindow: RemoteReplyPage.lockoutDedupeWindow
        )
    }

    @discardableResult
    public func postRemoteReplyInboxDenied(status: Int) async -> Notifier.Outcome {
        await postSystemMessage(
            title: RemoteReplyPage.inboxDeniedTitle,
            body: RemoteReplyPage.inboxDeniedBody(status: status),
            kind: RemoteReplyPage.inboxDeniedKind,
            dedupeWindow: RemoteReplyPage.inboxDeniedDedupeWindow
        )
    }

    @discardableResult
    public func postRemoteReplyAcknowledgement(_ ack: RemoteReplyAcknowledgement) async -> Notifier.Outcome {
        await postSystemMessage(
            title: ack.title,
            body: ack.body,
            kind: ack.kind,
            dedupeWindow: ack.dedupeWindow
        )
    }
}
