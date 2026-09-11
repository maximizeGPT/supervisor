// InjectionLedger.swift
//
// The record of what Supervisor itself typed into a watched session, so the
// triage can tell its own injected text apart from the human owner's real
// messages.
//
// THE GAP THIS CLOSES (the self-authorization / impersonation gap): Supervisor
// injects answers and continue-dispatches into a session as plain user-role
// turns. Claude Code records them in the JSONL transcript identically to a
// human-typed turn. When the triage later reads that transcript to decide
// whether a destructive action was authorized, it has no way to tell its own
// injected words from the owner's — so it can attribute "you said 'delete
// them', so you authorized this" to text Supervisor authored. That is a
// self-authorization loop: the harness green-lighting a destructive action on
// its own injected words.
//
// THE MECHANISM: the InterventionRouter records every injection here at the
// moment it types it (session + verbatim text + timestamp). When the engine
// assembles a triage prompt it asks this ledger whether the "most recent user
// prompt" correlates to a recorded injection; if so it labels the turn
// [supervisor-injected] and the rubric refuses to treat it as authorization.
//
// Recording happens at inject TIME, not after delivery is confirmed, on
// purpose: the resulting user turn can appear in the JSONL (and be triaged)
// before a post-hoc delivery poll would finish. A recorded injection that
// never lands simply never correlates to anything — harmless. The reverse
// (a landed injection not yet recorded) is the gap, so we record first.
//
// Correlation is (sessionId + normalized text) within a time window. The
// asymmetry is safe (see UserPromptOrigin): a false correlation withholds a
// real authorization (a recoverable false positive), a missed correlation
// re-opens the gap — so the match is deliberately tolerant.

import Foundation

/// WHO caused an injection. Both values are Supervisor typing, and neither
/// is ever owner authorization, so `isSupervisorInjected` is true for both
/// and the triage prompt tags both `[supervisor-injected]`. The distinction
/// is for the record, not for the rubric.
///
/// `remoteOwner` is text that arrived over the inbound reply channel
/// (`RemoteReplyGate`). It is the weaker of the two, not the stronger: the
/// owner wrote it, but it reached this machine over a topic that is a
/// bearer credential, so the honest statement is "this came off the wire",
/// never "the owner said this at the keyboard". Conflating the two is
/// exactly the laundering the impersonation gap is about, which is why this
/// gets its own label instead of borrowing `owner`.
public enum InjectionOrigin: String, Sendable, Equatable, CaseIterable {
    /// Supervisor's own model-generated text: an answer, a redirect, a
    /// dispatch proposal.
    case supervisor
    /// An owner's reply that arrived over the remote inbound channel.
    case remoteOwner
}

/// Thread-safe (lock-guarded) so the router (which records) and the
/// `@MainActor` TriageEngine (which reads) can share one instance without
/// actor-hopping. Bounded per session; old entries are pruned on write.
public final class InjectionLedger: @unchecked Sendable {

    private struct Entry {
        let normalized: String
        let raw: String
        let ts: Date
        let origin: InjectionOrigin
    }

    private let lock = NSLock()
    private var bySession: [String: [Entry]] = [:]

    /// Max injections retained per session. A session rarely has more than a
    /// handful of in-flight injections inside the correlation window; 32 is
    /// generous headroom while bounding memory.
    private let retentionPerSession: Int

    /// How long after an injection a user turn may still correlate to it. The
    /// resulting turn normally lands within seconds; the window is generous so
    /// a turn read late from the rolling event buffer still matches, while an
    /// ancient identical injection can't shadow a genuine later re-type.
    private let correlationWindow: TimeInterval

    /// Clock skew slack: a JSONL turn timestamp can read slightly BEFORE the
    /// injection's `Date()` (different clocks / sub-second rounding), so allow
    /// a small negative delta before rejecting on time.
    private let skewSlack: TimeInterval

    /// Below this length an injected string must match a user turn EXACTLY
    /// (after normalization); at or above it, containment is allowed (Claude
    /// Code may wrap or append to what was pasted). Keeps short injections
    /// ("yes", "proceed") from over-matching unrelated turns.
    private let containmentMinLength: Int

    public init(
        retentionPerSession: Int = 32,
        correlationWindow: TimeInterval = 3600,
        skewSlack: TimeInterval = 300,
        containmentMinLength: Int = 24
    ) {
        self.retentionPerSession = retentionPerSession
        self.correlationWindow = correlationWindow
        self.skewSlack = skewSlack
        self.containmentMinLength = containmentMinLength
    }

    /// Record that Supervisor injected `text` into `sessionId`. Call at inject
    /// time. Empty / whitespace-only text is ignored (nothing to correlate).
    ///
    /// `origin` defaults to `.supervisor` so every existing call site keeps
    /// its exact behaviour; the remote reply path passes `.remoteOwner` so
    /// the record can never be read back as the owner typing here.
    public func record(
        sessionId: String,
        text: String,
        at ts: Date = Date(),
        origin: InjectionOrigin = .supervisor
    ) {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var entries = bySession[sessionId] ?? []
        entries.append(Entry(normalized: normalized, raw: text, ts: ts, origin: origin))
        // Prune by age (outside the window can never correlate) then by count.
        let cutoff = ts.addingTimeInterval(-correlationWindow)
        entries.removeAll { $0.ts < cutoff }
        if entries.count > retentionPerSession {
            entries.removeFirst(entries.count - retentionPerSession)
        }
        bySession[sessionId] = entries
    }

    /// Did Supervisor inject this user turn? `asOf` is the turn's timestamp.
    /// True when a recorded injection for this session matches `text` and sits
    /// within `[asOf - window, asOf + skewSlack]` (the injection precedes the
    /// turn, modulo clock skew).
    public func isSupervisorInjected(sessionId: String, text: String, asOf: Date) -> Bool {
        let candidate = Self.normalize(text)
        guard !candidate.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let entries = bySession[sessionId] else { return false }
        let lowerBound = asOf.addingTimeInterval(-correlationWindow)
        let upperBound = asOf.addingTimeInterval(skewSlack)
        for entry in entries {
            guard entry.ts >= lowerBound, entry.ts <= upperBound else { continue }
            if Self.matches(injected: entry.normalized, turn: candidate, minLength: containmentMinLength) {
                return true
            }
        }
        return false
    }

    /// The origin recorded for a matching injection, or nil when nothing
    /// correlates. Same matching rule as `isSupervisorInjected`, so the two
    /// can never disagree about whether a turn was injected; this one also
    /// says WHICH channel typed it.
    ///
    /// Deliberately NOT consulted by the rubric. `isSupervisorInjected`
    /// stays the single authorization question and answers true for every
    /// origin, so adding a channel here can never widen what counts as
    /// owner authorization. This is the audit answer, not the gate.
    public func origin(sessionId: String, text: String, asOf: Date) -> InjectionOrigin? {
        let candidate = Self.normalize(text)
        guard !candidate.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entries = bySession[sessionId] else { return nil }
        let lowerBound = asOf.addingTimeInterval(-correlationWindow)
        let upperBound = asOf.addingTimeInterval(skewSlack)
        // Latest match wins: the same text injected twice by two channels is
        // most honestly attributed to the one that typed it most recently.
        for entry in entries.reversed() {
            guard entry.ts >= lowerBound, entry.ts <= upperBound else { continue }
            if Self.matches(injected: entry.normalized, turn: candidate, minLength: containmentMinLength) {
                return entry.origin
            }
        }
        return nil
    }

    /// Test/inspection hook: number of retained entries for a session.
    public func entryCount(sessionId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return bySession[sessionId]?.count ?? 0
    }

    /// The timestamp of the MOST RECENT injection recorded for this session, or
    /// nil if none. v0.2.0 M2d-2 uses this as the anchor for a plan step's
    /// observation window: the events at/after the last injection (the step we
    /// just typed) are the activity to grade. Best-effort - a pruned-away ancient
    /// injection simply isn't counted, which is correct (it is not the live step).
    public func lastInjectionTime(sessionId: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return bySession[sessionId]?.last?.ts
    }

    // MARK: - Matching

    /// Collapse runs of whitespace and trim. The injected text and the JSONL
    /// turn should be byte-identical, but a paste round-trip can reflow
    /// whitespace; normalizing on it keeps the match robust without loosening
    /// it on content.
    static func normalize(_ s: String) -> String {
        let collapsed = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    static func matches(injected: String, turn: String, minLength: Int) -> Bool {
        if injected == turn { return true }
        // Containment (either direction) only for substantial strings, so a
        // long injected answer still matches if Claude Code wrapped or
        // appended to it, without short tokens over-matching.
        guard injected.count >= minLength else { return false }
        return turn.contains(injected) || injected.contains(turn)
    }
}
