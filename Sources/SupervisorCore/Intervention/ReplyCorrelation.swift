// ReplyCorrelation.swift. Which page a reply is answering, and the only
// thing that makes a posted string a reply at all.
//
// The outbound page ends with a line the owner reads off their phone:
//
//     reply: a7k2mq <your answer>
//
// This table is what turns `a7k2mq` back into a session, a working
// directory, and a pending outcome. Two jobs, and the second one is the
// security job:
//
//   1. ROUTING. A reply lands in the session it is answering. "Inject into
//      whichever session paged most recently" is exactly the guess a path
//      that types into live agents must not make.
//
//   2. ADMISSION. The topic is shared with the outbound page (see
//      RemoteReplyEndpoint), so anyone who learns it can post. A code that
//      Supervisor minted, that is bound to one session, that works once,
//      and that dies in an hour is what separates "the owner answering the
//      page they were sent" from "a string somebody put on a topic". Text
//      that does not open with a live code is not a reply and is never
//      typed anywhere.
//
// The code is NOT the whole defence and must not be treated as one. It is
// six characters read off a lock screen and retyped one-handed, so it is
// sized to be typed, not to resist an offline attack. What bounds guessing
// is RemoteReplyGate's failure budget: a handful of wrong codes switches
// the inbound half off and pages the owner. Six characters over a
// 31-character alphabet is 887,503,681 values, so the five guesses that
// budget allows are worth about 6 in a billion. Four characters (923,521)
// would have made that 5 in a million, still small, but the two extra
// keystrokes cost the owner nothing and buy three orders of magnitude, so
// the trade is not close.
//
// SINGLE USE, ALWAYS. Every reply that reaches a keyboard retires its
// code, and so does every reply the safety screen refused. A code that
// still works after it has been answered is a code that can be replayed
// off a screenshot, and a code that survives a refusal is an oracle for
// probing the screen one phrasing at a time.
//
// `reinstate` is the narrow exception, and it covers only the two cases
// where nothing was typed and nothing was judged: a live code sent with no
// text after it, and an injection that could not be routed. Both are the
// owner holding a valid code and getting no answer, so both give it back.
// A reinstated entry keeps its original `mintedAt`, so the exception
// cannot be used to extend a code's life.
//
// Bounded and pruned: at most `capacity` live entries, expired ones dropped
// on every access, oldest evicted when full. A long-running app pages a
// lot, and nothing here may grow with uptime.

import Foundation
import Security

/// One live page the owner can answer.
public struct ReplyCorrelationEntry: Sendable, Equatable {

    /// The code printed in the page.
    public let code: String

    /// Which session the reply drives. A code resolves to exactly one, and
    /// a reply can never reach any other.
    public let sessionId: String

    /// The session's working directory, needed to resolve the inject
    /// target. Held in memory only and never sent anywhere: the page
    /// carries the BASENAME, never this.
    public let cwd: String?

    /// The session's branch, used by the injector for tab targeting.
    public let branch: String?

    /// `RemoteNotifyPolicy.outcomeKind` vocabulary: WHICH pending outcome
    /// this code answers. A code minted for a blocked question does not
    /// become a general-purpose write handle on the session just because
    /// the session is still alive an hour later, and the trace line says
    /// what was being answered.
    public let outcomeKind: String

    /// The `flags` row this page came from, when there is one. It is the
    /// handle the LOCAL resolution path already has: when the owner answers
    /// at the Mac or dismisses the flag, the question this code was minted
    /// to answer is closed, and a code that is still live after that is a
    /// key to a door nobody is standing at. nil for a page with no
    /// persisted row (tests, older callers), which simply cannot be retired
    /// early and falls back to the TTL.
    public let flagId: String?

    /// When the code was minted. The TTL runs from here.
    public let mintedAt: Date

    public init(
        code: String,
        sessionId: String,
        cwd: String?,
        branch: String?,
        outcomeKind: String,
        flagId: String?,
        mintedAt: Date
    ) {
        self.code = code
        self.sessionId = sessionId
        self.cwd = cwd
        self.branch = branch
        self.outcomeKind = outcomeKind
        self.flagId = flagId
        self.mintedAt = mintedAt
    }
}

/// Thread-safe (lock-guarded) because the notifier mints from the router's
/// dispatch task and the inbound gate resolves from its own reader task.
public final class ReplyCorrelationTable: @unchecked Sendable {

    /// How long a code stays answerable.
    ///
    /// One hour, chosen against the re-page cadence rather than against
    /// human patience. `BlockedSessionRepager` re-pages a still-blocked
    /// session every 45 minutes with a fresh code, so an hour leaves no
    /// window in which the owner holds a page whose code is already dead
    /// and no new page has arrived. Longer would mean a page screenshotted
    /// into a group chat stays a working key into a session for the rest of
    /// the day, which is the case this bound exists to close.
    public static let defaultLifetime: TimeInterval = 60 * 60

    /// Live entries retained. A page every couple of minutes for an hour is
    /// well under this; the cap is the bound, not the working size.
    public static let defaultCapacity = 64

    /// Code alphabet: lowercase letters and digits minus the pairs a human
    /// retypes wrong (i/l/1, o/0). The code is read off a phone
    /// notification and typed back by hand, so an unambiguous alphabet is
    /// worth more than the fraction of a bit it costs.
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    /// Code length. Six over this alphabet is 887,503,681 values. See the
    /// file header for why six and not four.
    static let codeLength = 6

    private let lock = NSLock()
    private var entries: [String: ReplyCorrelationEntry] = [:]
    private let lifetime: TimeInterval
    private let capacity: Int
    /// Seam so tests can mint deterministic codes. Production draws from the
    /// system CSPRNG: an observer who sees one code must learn nothing about
    /// the next, because pages travel over a channel strangers may be
    /// reading.
    private let randomByte: @Sendable () -> UInt8

    public init(
        lifetime: TimeInterval = ReplyCorrelationTable.defaultLifetime,
        capacity: Int = ReplyCorrelationTable.defaultCapacity,
        randomByte: @escaping @Sendable () -> UInt8 = {
            var byte: UInt8 = 0
            if SecRandomCopyBytes(kSecRandomDefault, 1, &byte) != errSecSuccess {
                byte = UInt8.random(in: 0...255)
            }
            return byte
        }
    ) {
        self.lifetime = lifetime
        self.capacity = capacity
        self.randomByte = randomByte
    }

    /// Register a page and return the code to print in it. Returns nil only
    /// when a free code could not be found, which cannot happen in practice
    /// (at most 64 live entries out of 887 million) but is reported rather
    /// than looped on forever while holding a lock.
    @discardableResult
    public func mint(
        sessionId: String,
        cwd: String?,
        branch: String?,
        outcomeKind: String,
        flagId: String? = nil,
        at now: Date = Date()
    ) -> String? {
        guard !sessionId.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        prune(now: now)
        guard let code = freshCode() else { return nil }
        entries[code] = ReplyCorrelationEntry(
            code: code,
            sessionId: sessionId,
            cwd: cwd,
            branch: branch,
            outcomeKind: outcomeKind,
            flagId: flagId,
            mintedAt: now
        )
        // Evict oldest AFTER inserting, so the entry just minted is never
        // the one thrown away by its own insertion.
        evictOldestIfOverCapacity()
        return code
    }

    /// Take the live entry for `code` and retire it in the same locked
    /// step, or return nil when the code is unknown, expired or already
    /// spent.
    ///
    /// Resolve-and-retire is one operation on purpose. A separate
    /// `resolve` then `retire` leaves a window in which two deliveries of
    /// the same code both resolve, and the transport WILL deliver the same
    /// message twice (a poll after a reconnect does exactly that).
    ///
    /// The caller cannot tell unknown from expired from spent, and does not
    /// need to: all three mean "this answers nothing", and telling them
    /// apart in any outbound message would tell a stranger posting guesses
    /// which of their guesses landed.
    public func claim(code: String, at now: Date = Date()) -> ReplyCorrelationEntry? {
        lock.lock(); defer { lock.unlock() }
        prune(now: now)
        return entries.removeValue(forKey: Self.normalize(code))
    }

    /// Put a claimed entry back, for the two gates that claim a code and
    /// then find that nothing was typed and nothing was judged: a live code
    /// sent with no reply text after it (an owner pressing send early), and
    /// an accepted reply the injector could not route to a session. Both
    /// leave the owner holding a valid code with no answer delivered, and
    /// nothing mints them another one until the next re-page.
    ///
    /// The entry carries its ORIGINAL `mintedAt`, so a code cannot have its
    /// life extended by being claimed and reinstated in a loop, and an entry
    /// already past its TTL is dropped by the next prune rather than
    /// resurrected.
    func reinstate(_ entry: ReplyCorrelationEntry) {
        lock.lock(); defer { lock.unlock() }
        entries[entry.code] = entry
    }

    /// Retire every code minted for one flag. This is the LOCAL resolution
    /// path: the owner answered at the Mac or dismissed the flag, so the
    /// question the page asked is closed and the code that answered it must
    /// die with it. Without this a page from an hour ago stays a working
    /// write handle into a session whose question was settled minutes later.
    public func retireAll(flagId: String) {
        guard !flagId.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.flagId != flagId }
    }

    /// Live entry count. Test and trace hook; never exposes the entries.
    public func liveCount(at now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        prune(now: now)
        return entries.count
    }

    /// Case-folded, whitespace-trimmed. The owner retypes this from a phone
    /// keyboard that likes to capitalize the first word of a message, so
    /// `A7K2MQ` has to mean the same thing as `a7k2mq`.
    public static func normalize(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Shape check used by the parser before any table lookup: exactly
    /// `codeLength` characters from the alphabet. Cheap, and it means a
    /// message that could not possibly be a code is classified as noise
    /// rather than as a failed guess, which keeps ntfy's own chatter and a
    /// mis-subscribed neighbour from eating the owner's failure budget.
    public static func looksLikeCode(_ token: String) -> Bool {
        let normalized = normalize(token)
        guard normalized.count == codeLength else { return false }
        let allowed = Set(alphabet)
        return normalized.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Internals (all called under the lock)

    private func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.mintedAt) < lifetime }
    }

    private func evictOldestIfOverCapacity() {
        guard entries.count > capacity else { return }
        let ordered = entries.values.sorted { $0.mintedAt < $1.mintedAt }
        for entry in ordered.prefix(entries.count - capacity) {
            entries.removeValue(forKey: entry.code)
        }
    }

    /// A code not currently in use. Bounded attempts: with at most 64 live
    /// entries out of 887 million values a collision is a rounding error,
    /// and an unbounded loop under a lock is worse than a missed code.
    private func freshCode() -> String? {
        for _ in 0..<32 {
            let candidate = String((0..<Self.codeLength).map { _ in
                Self.alphabet[Int(unbiasedIndex())]
            })
            if entries[candidate] == nil { return candidate }
        }
        return nil
    }

    /// Rejection sampling into the alphabet. `byte % 31` would make the
    /// first eight letters about 4% more likely than the rest, which is a
    /// small loss on its own and a pointless one: the discard rate here is
    /// under 3%, so the loop is bounded in practice. It is still capped, so
    /// a broken `randomByte` seam in a test cannot hang the process; the
    /// fallback biases one character rather than spinning.
    private func unbiasedIndex() -> UInt8 {
        let count = UInt8(Self.alphabet.count)
        let limit = UInt8(256 - (256 % Int(count)))
        for _ in 0..<64 {
            let byte = randomByte()
            if byte < limit { return byte % count }
        }
        return randomByte() % count
    }
}

/// The table is what the notifier asks for a code. Conformance lives here
/// rather than the protocol's file so the notifier's dependency stays the
/// protocol and the inbound half stays optional.
extension ReplyCorrelationTable: ReplyCodeMinting {
    public func mintReplyCode(
        sessionId: String,
        cwd: String?,
        branch: String?,
        outcomeKind: String,
        flagId: String?
    ) -> String? {
        mint(sessionId: sessionId, cwd: cwd, branch: branch, outcomeKind: outcomeKind, flagId: flagId)
    }
}

/// Mints codes only while the inbound channel is genuinely armed.
///
/// The notifier holds its minter for the life of the process, but whether
/// replies can be answered changes underneath it: the owner edits
/// config.yaml, a webhook is stored late, the failure budget blows. Without
/// this the page would print "reply with this code" to an owner whose reply
/// nothing is listening for, which is a worse failure than no reply channel
/// at all, because it reads as working.
///
/// So the rule is one line: no code on the page unless something is
/// actually reading the topic.
public final class ArmedReplyCodeMinter: ReplyCodeMinting, @unchecked Sendable {

    private let table: ReplyCorrelationTable
    private let lock = NSLock()
    private var armed: Bool

    public init(table: ReplyCorrelationTable, armed: Bool = false) {
        self.table = table
        self.armed = armed
    }

    public var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return armed
    }

    public func setArmed(_ value: Bool) {
        lock.lock()
        let changed = armed != value
        armed = value
        lock.unlock()
        // Disarming retires nothing by itself; the codes already printed on
        // pages simply stop resolving because the gate stops reading. They
        // still expire on their own TTL, so nothing accumulates.
        _ = changed
    }

    public func mintReplyCode(
        sessionId: String,
        cwd: String?,
        branch: String?,
        outcomeKind: String,
        flagId: String?
    ) -> String? {
        guard isArmed else { return nil }
        return table.mint(
            sessionId: sessionId,
            cwd: cwd,
            branch: branch,
            outcomeKind: outcomeKind,
            flagId: flagId
        )
    }
}
