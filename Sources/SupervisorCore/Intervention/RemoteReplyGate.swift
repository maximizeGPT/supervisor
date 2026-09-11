// RemoteReplyGate.swift. Everything a posted string has to survive before
// it becomes keystrokes in a live coding session.
//
// The transport (RemoteInboxSubscriber) is deliberately dumb: it yields
// whatever appeared on the topic. This is the part that decides, and it is
// written as one ordered list of gates with one exit each, because a
// security path with two ways to reach the same action has two paths to
// audit and only one of them ever gets read.
//
// THE THREAT, AND WHAT THE CODE IS AND IS NOT. The ntfy topic is shared
// with the outbound page. On ntfy.sh a topic is public in both directions,
// so there are two very different adversaries and the correlation code
// only stops one of them.
//
//   SOMEBODY WHO CAN POST BUT IS NOT SUBSCRIBED. A topic glimpsed in a URL
//   bar, read off a config screenshot, or guessed. The code stops them
//   dead: they have to name a value Supervisor minted for a page they
//   never saw, and the failure budget below gives them five tries.
//
//   SOMEBODY WHO IS SUBSCRIBED. They read the page, and the page prints
//   the code. For them the code is NOT admission control and nothing here
//   pretends otherwise. It bounds replay and it fixes routing, and that is
//   all. Read access to the topic is, by construction, write access to the
//   sessions Supervisor pages about.
//
// That second sentence is the feature's real security boundary and it
// belongs in the owner's face, not in a comment: an owner who needs it to
// be false has to run a protected ntfy instance where subscribing requires
// a token. config.yaml says so, and so does the README.
//
// What survives for the subscribed adversary is the ordinary injection
// defence: InjectionSafetyScreen, the same deny-list every Supervisor
// injection crosses. It is a shell-harm screen, not a natural-language
// one, so "delete the tests and push" passes it. Supervisor's usual answer
// to that is that an injected turn is never owner authorization (the
// ledger's remoteOwner label keeps that true here too), but the agent on
// the other end will still read the sentence and act on it.
//
// THE ORDER, and why each gate sits where it does:
//
//   1. disabled        the feature is off. Off means nothing is read,
//                      nothing is counted, nothing is logged per message.
//   2. already seen    a repeat of a message id we have processed. FIRST,
//                      before any counter, because the poll fallback
//                      re-delivers by design: charging a redelivered
//                      SUCCESS to the failure budget would let the owner's
//                      own correct reply lock them out.
//   3. locked out      the failure budget blew. Sticky until the owner
//                      re-arms; an inbound channel that unlocks itself on
//                      a timer is a rate limit wearing a lockout's name.
//   4. oversize        a body past the cap is dropped unparsed. Bounds the
//                      work one post can cause. Not remembered, because
//                      nothing was really processed.
//   5. no code         the text does not open with a code-shaped token, so
//                      it is not an answer to anything. Discarded, cheaply,
//                      and BEFORE the rate cap. That ordering is the fix
//                      for a real denial of service: a stream delivers each
//                      message exactly once, so a genuine reply the rate
//                      cap dropped is gone for good, and if plain chatter
//                      counted toward the cap then `while true; do curl -d
//                      hi; done` would silently kill the owner's replies
//                      forever without ever tripping the lockout. Parsing
//                      is a prefix check, so nothing is spent finding out.
//                      Also NOT charged to the failure budget: chatter and
//                      a mis-subscribed neighbour are noise, not guesses.
//   6. rate limited    more CODE-CARRYING messages in the window than a
//                      human answering pages could produce. Everything
//                      past this gate touches the code table, the screen,
//                      or a keyboard, so this is where a cap is worth
//                      having. A flood cannot hide here: a code-shaped
//                      token either resolves (it was live) or charges the
//                      failure budget, so twenty of them is a lockout and
//                      a page, not silence.
//   7. unknown code    code-shaped and not live. This IS a guess (or an
//                      expired page), and it is the only thing that
//                      charges the budget.
//   8. empty body      a live code with nothing after it. The code is NOT
//                      spent, because the owner fat-fingered a send and
//                      should be able to finish their sentence.
//   9. screen block    InjectionSafetyScreen refused the text. The code IS
//                      spent: a code that survives a refusal is an oracle
//                      for probing the screen one phrasing at a time.
//  10. inject          claim the code (atomically, so a double delivery
//                      cannot double-inject), reset the failure budget
//                      (a correct code proves the owner is present), and
//                      hand the text to the injecting delegate, which
//                      screens it AGAIN on the way to the keyboard. An
//                      injection that fails to ROUTE puts the code back so
//                      the owner can retry; one the injector REFUSES keeps
//                      it spent, for the same oracle reason as gate 9.
//
// WHAT GOES BACK. Three of those outcomes are acknowledged on the topic
// (delivered, refused, rate limited) because a reply channel that answers
// with silence whether it worked or not is one the owner cannot trust from
// the place they need it. The acknowledgement is content-free and the
// wording is fixed in `RemoteReplyAcknowledgement`, because the topic is
// publicly readable: it may say that something happened and name a project
// basename, which is what every page already carries, and nothing else.
// The guessing outcomes (unknown code, locked out) are deliberately NOT
// acknowledged: an answer there would tell a stranger which guesses landed.
//
// Nothing here logs the topic, the webhook URL, or a full code. Codes are
// traced by their first two characters, which is enough to line a trace up
// against a page and not enough to replay one.

import Foundation

/// What happened to one inbound message. Every case is terminal, and only
/// `.injected` ever put text in a session.
public enum RemoteReplyDisposition: Sendable, Equatable {
    /// The feature is off, or no endpoint could carry replies.
    case inert
    /// This ntfy message id has already been processed.
    case duplicate
    /// The failure budget blew; inbound is off until the owner re-arms.
    case lockedOut
    /// Body longer than the cap.
    case oversize(bytes: Int)
    /// More inbound messages in the window than the cap allows.
    case rateLimited
    /// Not addressed to any page. Unsolicited text, discarded.
    case noCode
    /// Code-shaped, but not a live code. Charged to the failure budget.
    case unknownCode
    /// A live code with no reply text after it.
    case emptyBody
    /// The reply text did not pass `InjectionSafetyScreen`.
    case screenBlocked(reason: String)
    /// Accepted, screened and typed into the session.
    case injected(sessionId: String)
    /// Accepted and screened, but the injector could not deliver it.
    case injectFailed(reason: String)
}

/// One accepted reply, on its way to the keyboard.
public struct RemoteReplyInjection: Sendable, Equatable {
    public let sessionId: String
    public let cwd: String?
    public let branch: String?
    /// The owner's text, with the correlation code already stripped.
    public let text: String
    /// Which pending outcome this answers. Trace only.
    public let outcomeKind: String

    public init(sessionId: String, cwd: String?, branch: String?, text: String, outcomeKind: String) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.branch = branch
        self.text = text
        self.outcomeKind = outcomeKind
    }
}

/// What the injecting side did with an accepted reply.
public enum RemoteReplyInjectionResult: Sendable, Equatable {
    case injected
    /// The injecting side's own safety screen refused it. Distinct from the
    /// gate's screen so a divergence between the two is visible rather than
    /// silently absorbed.
    case screenBlocked(reason: String)
    case failed(reason: String)
}

/// The seam between deciding and typing. `InterventionRouter` conforms; the
/// tests substitute a recorder, which is what lets every gate above be
/// tested without a process, a window or a keystroke.
public protocol RemoteReplyInjecting: Sendable {
    func injectRemoteReply(_ request: RemoteReplyInjection) async -> RemoteReplyInjectionResult
}

/// Counters the panel and the tests read. A snapshot, so nothing holds a
/// lock to render it.
public struct RemoteReplyStats: Sendable, Equatable {
    public var accepted = 0
    public var duplicates = 0
    public var unsolicited = 0
    public var badCodes = 0
    public var oversize = 0
    public var rateLimited = 0
    public var screenRefusals = 0
    public var injectFailures = 0
    public var lockedOut = false
    public var lockedOutAt: Date?

    public init() {}
}

public final class RemoteReplyGate: @unchecked Sendable {

    public struct Configuration: Sendable, Equatable {

        /// Off unless config.yaml says on. Mirrors the outbound channel: the
        /// switch is visible and diffable, and an install that never edits
        /// config.yaml never reads a byte off a topic.
        public var enabled: Bool

        /// Wrong codes tolerated inside `failureWindow` before inbound shuts.
        ///
        /// Five. The number has to sit above what a real owner produces by
        /// accident (a code typed from a lock screen, a reply to a page that
        /// expired while they were driving, an autocorrect) and far below
        /// what a guesser needs. Against a six-character code five guesses
        /// are worth 5 / 887,503,681, about 6 in a billion; a guesser who
        /// paces themselves to stay under the threshold gets roughly 26,000
        /// guesses a year, about 3 in 100,000 against one live code. Both
        /// are dominated by the fact that blowing the budget PAGES THE
        /// OWNER, so a serious attempt announces itself on the first burst.
        public var failureBudget: Int

        /// The window the budget is measured over. Ten minutes: long enough
        /// that a fast guesser cannot reset it by pausing between attempts,
        /// short enough that three typos spread across a working day never
        /// accumulate into a lockout.
        ///
        /// Two honest limits on what this buys, both of which want a fix
        /// and neither of which is in this change. A guesser who paces
        /// themselves under the threshold never trips it (about 210,000
        /// tries a year against 887 million values, with each code alive
        /// for an hour). And the lockout is in memory, so a relaunch hands
        /// a guesser a fresh budget. A second, wider budget measured in
        /// days and persisted alongside the flags would close both.
        public var failureWindow: TimeInterval

        /// Largest reply body accepted, in UTF-8 bytes. A reply is a
        /// sentence typed on a phone. Anything past this is either a
        /// mistake or an attempt to make Supervisor do work, and it is
        /// dropped before it is parsed.
        public var maxBodyBytes: Int

        /// Messages processed per `rateWindow` before the rest are dropped.
        /// Twenty in a minute is far above a human answering pages and far
        /// below what a script can post, so it costs the owner nothing and
        /// bounds the cost of a flood.
        public var maxMessagesPerWindow: Int
        public var rateWindow: TimeInterval

        /// Processed message ids retained for replay detection. Bounds
        /// memory; ids older than `seenIdLifetime` are pruned first, so the
        /// cap is only reached under a flood the rate limit already refused.
        public var seenIdCapacity: Int
        public var seenIdLifetime: TimeInterval

        public init(
            enabled: Bool = false,
            failureBudget: Int = 5,
            failureWindow: TimeInterval = 600,
            maxBodyBytes: Int = 2048,
            maxMessagesPerWindow: Int = 20,
            rateWindow: TimeInterval = 60,
            seenIdCapacity: Int = 512,
            seenIdLifetime: TimeInterval = 3600
        ) {
            self.enabled = enabled
            self.failureBudget = max(1, failureBudget)
            self.failureWindow = failureWindow
            self.maxBodyBytes = max(1, maxBodyBytes)
            self.maxMessagesPerWindow = max(1, maxMessagesPerWindow)
            self.rateWindow = rateWindow
            self.seenIdCapacity = max(1, seenIdCapacity)
            self.seenIdLifetime = seenIdLifetime
        }
    }

    private let correlations: ReplyCorrelationTable
    private let injecting: any RemoteReplyInjecting
    private let trace: TraceLog
    private let now: @Sendable () -> Date
    /// Called once when the failure budget blows, so the owner learns from
    /// their phone that their phone has stopped working. Async because the
    /// production wiring is a webhook POST.
    private let onLockout: @Sendable (Int, TimeInterval) async -> Void
    /// Called for every outcome the owner is entitled to hear about: the
    /// reply landed, the screen refused it, the cap dropped it. The design
    /// requires a confirmation, and a channel that answers with silence
    /// whether it worked or not is one the owner cannot trust in the case
    /// that matters (they are away from the Mac and cannot check).
    ///
    /// Not called for the dispositions that would be a gift to a stranger.
    /// `unknownCode` and `lockedOut` would turn the topic into a guessing
    /// oracle that says which guesses landed; `duplicate`, `noCode`,
    /// `oversize` and `inert` mean nothing reached the code table, so an
    /// answer there is Supervisor replying to noise on a public topic.
    /// `injectFailed` is deliberately silent too: the code has been
    /// reinstated, so the owner's own retry is the signal, and a page
    /// saying "could not route" invites a retry that will fail the same
    /// way.
    private let onAcknowledge: @Sendable (RemoteReplyAcknowledgement) async -> Void

    private let lock = NSLock()
    private var configuration: Configuration
    private var stats = RemoteReplyStats()
    private var seenIds: [String: Date] = [:]
    private var seenOrder: [String] = []
    private var failureTimes: [Date] = []
    private var processedTimes: [Date] = []
    private var lockedOut = false

    public init(
        correlations: ReplyCorrelationTable,
        injecting: any RemoteReplyInjecting,
        configuration: Configuration = Configuration(),
        trace: TraceLog = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        onLockout: @escaping @Sendable (Int, TimeInterval) async -> Void = { _, _ in },
        onAcknowledge: @escaping @Sendable (RemoteReplyAcknowledgement) async -> Void = { _ in }
    ) {
        self.correlations = correlations
        self.injecting = injecting
        self.configuration = configuration
        self.trace = trace
        self.now = now
        self.onLockout = onLockout
        self.onAcknowledge = onAcknowledge
    }

    public var currentConfiguration: Configuration {
        lock.lock(); defer { lock.unlock() }
        return configuration
    }

    public var snapshot: RemoteReplyStats {
        lock.lock(); defer { lock.unlock() }
        var copy = stats
        copy.lockedOut = lockedOut
        return copy
    }

    public var isLockedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return lockedOut
    }

    public func apply(_ new: Configuration) {
        lock.lock()
        let old = configuration
        configuration = new
        // Turning the feature off and on again is an owner action, and it
        // is the documented way to clear a lockout without a relaunch.
        if !old.enabled && new.enabled { clearLockoutLocked() }
        lock.unlock()
        guard old != new else { return }
        trace.emit("remote", "remote.reply_config_changed enabled=\(old.enabled)->\(new.enabled) budget=\(new.failureBudget)")
    }

    /// Clear a lockout programmatically. Nothing here is on a timer: a
    /// lockout that expires by itself is a rate limit wearing a lockout's
    /// name.
    ///
    /// The owner-facing path is not this method, it is the off-and-on of
    /// `remote_notify.reply_enabled`, which `apply` treats as the same
    /// instruction whether the write comes from the panel toggle or from
    /// hand-editing config.yaml. This exists for the tests; the lockout
    /// page points the owner at the panel toggle first, since that is the
    /// easier of the two wired paths.
    public func rearm() {
        lock.lock()
        let was = lockedOut
        clearLockoutLocked()
        lock.unlock()
        if was { trace.emit("remote", "remote.reply_rearmed") }
    }

    // MARK: - The gates

    /// The result of the synchronous gates. Every locked step in this file
    /// is a small synchronous function, because `accept` is async and an
    /// `NSLock` held across a suspension point is a deadlock waiting for a
    /// slow injector. `RemoteNotifier` is built the same way.
    enum Admission: Equatable {
        case proceed(Configuration)
        case stop(RemoteReplyDisposition)
    }

    /// Gates 1 to 4. Stops before the parse, because the parse decides
    /// whether this message is worth spending the rate budget on.
    func admit(_ message: RemoteInboxMessage, at stamp: Date) -> Admission {
        lock.lock(); defer { lock.unlock() }
        let config = configuration

        // 1. Off means off. Nothing read, nothing counted, nothing logged.
        guard config.enabled else { return .stop(.inert) }

        // 2. Replay, before anything that counts. The poll fallback
        // re-delivers by design, so a redelivered SUCCESS must not read as
        // a fresh failure and eat the owner's budget.
        pruneSeenLocked(now: stamp, config: config)
        if seenIds[message.id] != nil {
            stats.duplicates += 1
            return .stop(.duplicate)
        }

        // 3. Locked out. Sticky: only `rearm()` or an off/on of the switch
        // clears it. Not marked seen, so a re-arm can still accept a
        // genuine reply the poll re-delivers afterwards.
        if lockedOut { return .stop(.lockedOut) }

        // 4. Size cap, before parsing.
        let bytes = message.message.utf8.count
        if bytes > config.maxBodyBytes {
            stats.oversize += 1
            return .stop(.oversize(bytes: bytes))
        }

        return .proceed(config)
    }

    /// Gate 6, run only for a message that actually carries a code, plus
    /// the seen-id write that makes everything after it happen at most
    /// once. One locked step, because "check the cap then remember the id"
    /// in two steps lets two concurrent deliveries of one post both pass.
    ///
    /// Returns false when the cap refused it. A refused message is NOT
    /// remembered: nothing was really processed, so a re-delivery deserves
    /// another look.
    func admitCodeCarrying(_ message: RemoteInboxMessage, at stamp: Date, config: Configuration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        processedTimes.removeAll { stamp.timeIntervalSince($0) >= config.rateWindow }
        if processedTimes.count >= config.maxMessagesPerWindow {
            stats.rateLimited += 1
            return false
        }
        processedTimes.append(stamp)
        rememberSeenLocked(message.id, now: stamp, config: config)
        return true
    }

    /// Run one inbound message through every gate. The only entry point,
    /// and the only thing that can reach `injecting`.
    @discardableResult
    public func accept(_ message: RemoteInboxMessage) async -> RemoteReplyDisposition {
        let stamp = now()
        let config0 = currentConfiguration

        let config: Configuration
        switch admit(message, at: stamp) {
        case .stop(let disposition):
            switch disposition {
            case .inert:
                break
            case .duplicate:
                trace.emit("remote", "remote.reply_dropped reason=duplicate")
            case .lockedOut:
                trace.emit("remote", "remote.reply_dropped reason=locked_out")
            case .oversize(let bytes):
                trace.emit("remote", "remote.reply_dropped reason=oversize bytes=\(bytes) cap=\(config0.maxBodyBytes)")
            default:
                break
            }
            return disposition
        case .proceed(let admitted):
            config = admitted
        }

        // 5. Is this addressed to a page at all? Cheap, and BEFORE the rate
        // cap so that plain chatter cannot consume the budget a real reply
        // needs. NOT charged to the failure budget either: charging noise
        // would hand a stranger a way to lock the owner out with text that
        // never mentions a code.
        guard let parsed = Self.parse(message.message) else {
            bump { $0.unsolicited += 1 }
            trace.emit("remote", "remote.reply_dropped reason=no_code")
            return .noCode
        }

        // 6. Rate cap, on the code-carrying path only, together with the
        // seen-id write.
        guard admitCodeCarrying(message, at: stamp, config: config) else {
            trace.emit("remote", "remote.reply_dropped reason=rate_limited window=\(Int(config.rateWindow))s")
            // Told, but with a storm guard on the notifier side: this is the
            // one acknowledged outcome a stranger can produce at will, so it
            // is capped at one page per window rather than one per message.
            await onAcknowledge(.rateLimited)
            return .rateLimited
        }

        // 7. A code-shaped token that is not live. This is a guess (or a
        // page that expired), and the only thing that charges the budget.
        guard let entry = correlations.claim(code: parsed.code, at: stamp) else {
            return await chargeFailure(codeHead: Self.codeHead(parsed.code), now: stamp, config: config)
        }

        // 8. A live code with nothing after it. The code has already been
        // claimed, so put it back: the owner pressed send early and should
        // be able to finish their sentence rather than wait for a re-page.
        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            correlations.reinstate(entry)
            trace.emit("remote", "remote.reply_dropped reason=empty_body code=\(Self.codeHead(entry.code))")
            return .emptyBody
        }

        // 9. The harm screen. Inbound text is hostile input by default: it
        // arrived over a channel a stranger may hold, and it is about to be
        // typed into a live agent as a turn that agent will act on. The code
        // is NOT reinstated on a block, because a code that survives a
        // refusal lets somebody probe the screen one phrasing at a time.
        if case .block(let reason) = InjectionSafetyScreen.screen(body) {
            bump { $0.screenRefusals += 1 }
            trace.emit(
                "remote",
                "remote.reply_refused reason=injection_screen_blocked_\(reason) code=\(Self.codeHead(entry.code)) session=\(entry.sessionId)"
            )
            // The refusal is said out loud; WHICH phrasing tripped the
            // screen is not. That reason is a probing oracle and it stays
            // on the Mac.
            await onAcknowledge(.refused)
            return .screenBlocked(reason: reason)
        }

        // 10. Accepted. A correct code proves the owner is on the other end,
        // so the failure run resets here.
        resetFailures()

        let request = RemoteReplyInjection(
            sessionId: entry.sessionId,
            cwd: entry.cwd,
            branch: entry.branch,
            text: body,
            outcomeKind: entry.outcomeKind
        )
        trace.emit(
            "remote",
            "remote.reply_accepted code=\(Self.codeHead(entry.code)) session=\(entry.sessionId) answering=\(entry.outcomeKind) chars=\(body.count)"
        )

        switch await injecting.injectRemoteReply(request) {
        case .injected:
            bump { $0.accepted += 1 }
            // The project BASENAME and nothing else. It is what the
            // `minimal` detail level already puts on this topic in every
            // page, so the confirmation discloses nothing the page that
            // prompted it did not.
            await onAcknowledge(.delivered(project: entry.cwd.map(RemoteNotifyPayload.basename(of:))))
            return .injected(sessionId: entry.sessionId)
        case .screenBlocked(let reason):
            // The injecting side refused what this gate allowed. Both
            // screens are the same function, so this should be unreachable;
            // it is kept as a distinct outcome rather than folded into a
            // generic failure so that if the two ever diverge the trace says
            // so instead of hiding it.
            bump { $0.screenRefusals += 1 }
            trace.emit("remote", "remote.reply_refused reason=injector_screen_\(reason) session=\(entry.sessionId)")
            await onAcknowledge(.refused)
            return .screenBlocked(reason: reason)
        case .failed(let reason):
            // Put the code back. The text was not refused, it was never
            // delivered: the injector could not resolve a target, the entry
            // carried no cwd, the owner was typing at the Mac. Burning the
            // code there costs the owner the answer AND the only way to
            // send it again, because nothing mints a fresh code until the
            // next re-page 45 minutes later.
            //
            // Deliberately NOT what `.screenBlocked` above does. A code that
            // survives a REFUSAL is an oracle for probing the screen one
            // phrasing at a time; a code that survives a ROUTING failure is
            // a retry. The entry carries its original `mintedAt`, so a
            // reinstated code expires on its original schedule and a loop of
            // claim-and-reinstate cannot extend its life; the table's prune
            // runs on the next claim and drops it if the hour is up.
            //
            // One honest wrinkle: `paste_no_turn_landed` means keystrokes
            // were posted and no turn appeared. Nearly always nothing landed
            // and the retry is exactly what the owner wants, but if the
            // paste did land and only the confirmation read failed, a retry
            // types the same sentence twice. A sentence sent twice is the
            // cheaper failure than a dead code and a lost answer.
            correlations.reinstate(entry)
            bump { $0.injectFailures += 1 }
            trace.emit(
                "remote",
                "remote.reply_inject_failed reason=\(reason) session=\(entry.sessionId) code_reinstated=true"
            )
            return .injectFailed(reason: reason)
        }
    }

    // MARK: - Failure budget

    /// Charge one failure and say whether THIS charge tripped the lockout.
    /// Takes the lock itself, so it is deliberately not named `...Locked`:
    /// that suffix means "the caller already holds it" everywhere else in
    /// this file, and NSLock is not recursive. Returns the run length and
    /// whether THIS charge is the one that tripped the lockout, so the
    /// caller pages exactly once no matter how many bad codes follow.
    private func recordFailure(now stamp: Date, config: Configuration) -> (count: Int, trip: Bool) {
        lock.lock(); defer { lock.unlock() }
        stats.badCodes += 1
        failureTimes.removeAll { stamp.timeIntervalSince($0) >= config.failureWindow }
        failureTimes.append(stamp)
        let count = failureTimes.count
        let trip = count >= config.failureBudget && !lockedOut
        if trip {
            lockedOut = true
            stats.lockedOutAt = stamp
        }
        return (count, trip)
    }

    private func chargeFailure(
        codeHead: String,
        now stamp: Date,
        config: Configuration
    ) async -> RemoteReplyDisposition {
        let (count, trip) = recordFailure(now: stamp, config: config)
        trace.emit("remote", "remote.reply_bad_code count=\(count)/\(config.failureBudget) code=\(codeHead)")
        guard trip else { return .unknownCode }
        trace.emit(
            "remote",
            "remote.reply_locked_out failures=\(count) window=\(Int(config.failureWindow))s - inbound replies are off until the owner re-arms"
        )
        // Page the owner on the way out. The channel that just shut is the
        // channel they were relying on, so the outbound half has to say so;
        // silence here reads exactly like a quiet night.
        await onLockout(count, config.failureWindow)
        return .lockedOut
    }

    private func bump(_ mutate: (inout RemoteReplyStats) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&stats)
    }

    private func resetFailures() {
        lock.lock(); defer { lock.unlock() }
        failureTimes.removeAll()
    }

    // MARK: - Parsing

    struct ParsedReply: Equatable {
        let code: String
        let body: String
    }

    /// A reply is a code-shaped first token and everything after it.
    ///
    /// Deliberately the whole grammar. There are no verbs, no `approve`, no
    /// `deny`, nothing that means one thing as a keyword and another as the
    /// first word of a sentence, so there is no phrasing an owner can type
    /// that does something other than what it reads like.
    ///
    /// A leading `reply:` is tolerated because the page prints that word and
    /// people retype what they see.
    static func parse(_ raw: String) -> ParsedReply? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the exact `reply:` form, and matched with a case-insensitive
        // RANGE rather than by counting characters off a lowercased copy
        // (case folding can change the count). A bare `reply` with no colon
        // is deliberately NOT stripped: the outbound page begins with the
        // word Reply on its last line, and a parser that skipped it would
        // be one wording change away from reading Supervisor's own echoed
        // page as a reply to itself.
        if let range = text.range(of: "reply:", options: [.caseInsensitive, .anchored]) {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let split = text.firstIndex(where: { $0.isWhitespace }) else {
            // A bare code with no body: still a parse, so the empty-body
            // gate can answer it rather than the no-code gate calling a
            // real owner's fumble "unsolicited".
            return ReplyCorrelationTable.looksLikeCode(text)
                ? ParsedReply(code: ReplyCorrelationTable.normalize(text), body: "")
                : nil
        }
        let token = String(text[text.startIndex..<split])
        guard ReplyCorrelationTable.looksLikeCode(token) else { return nil }
        return ParsedReply(
            code: ReplyCorrelationTable.normalize(token),
            body: String(text[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The first two characters of a code. Enough to line a trace line up
    /// against a page that was sent, and not enough to replay one: the four
    /// unknown characters are still 923,521 values against a budget of five
    /// guesses. The only line that names a code which is still LIVE is the
    /// empty-body one; accepted and refused replies have already spent
    /// theirs.
    static func codeHead(_ code: String) -> String {
        String(code.prefix(2)) + "…"
    }

    // MARK: - Seen ids (all called under the lock)

    private func pruneSeenLocked(now stamp: Date, config: Configuration) {
        guard !seenOrder.isEmpty else { return }
        let cutoff = stamp.addingTimeInterval(-config.seenIdLifetime)
        while let oldest = seenOrder.first, let seenAt = seenIds[oldest], seenAt < cutoff {
            seenOrder.removeFirst()
            seenIds.removeValue(forKey: oldest)
        }
    }

    private func rememberSeenLocked(_ id: String, now stamp: Date, config: Configuration) {
        seenIds[id] = stamp
        seenOrder.append(id)
        while seenOrder.count > config.seenIdCapacity, let oldest = seenOrder.first {
            seenOrder.removeFirst()
            seenIds.removeValue(forKey: oldest)
        }
    }

    private func clearLockoutLocked() {
        lockedOut = false
        stats.lockedOutAt = nil
        failureTimes.removeAll()
    }
}
