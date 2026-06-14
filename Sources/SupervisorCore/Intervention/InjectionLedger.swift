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

/// Thread-safe (lock-guarded) so the router (which records) and the
/// `@MainActor` TriageEngine (which reads) can share one instance without
/// actor-hopping. Bounded per session; old entries are pruned on write.
public final class InjectionLedger: @unchecked Sendable {

    private struct Entry {
        let normalized: String
        let raw: String
        let ts: Date
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
    public func record(sessionId: String, text: String, at ts: Date = Date()) {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var entries = bySession[sessionId] ?? []
        entries.append(Entry(normalized: normalized, raw: text, ts: ts))
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

    /// Test/inspection hook: number of retained entries for a session.
    public func entryCount(sessionId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return bySession[sessionId]?.count ?? 0
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
