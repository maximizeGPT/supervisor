// ContextWikiSteward.swift — the "perpetually audits" half, as a pure classifier.
//
// The feature is meant to run continuously, not once. But CONTINUOUSLY does not
// mean CONSTANTLY: re-scanning + re-surveying on every file event would burn
// budget for no new signal. This type decides WHEN a re-audit is worthwhile,
// from cheap, always-available signals. It mirrors ContextSteward exactly: a
// pure, side-effect-free `(signals, thresholds) -> Decision` function, so every
// branch is unit-testable with a literal and the live wiring stays trivial.
//
// WHAT IT IS NOT. It does not scan, audit, read files, or spend anything. It
// only answers "should we run an audit now?". The caller (a timer, or a config
// watcher) turns a `.reaudit` into an actual ContextAuditor run.
//
// Deliberately conservative and additive: the feature does NOT auto-run inside
// the v0.3.0-rc loop. It is invoked explicitly (the DevTools command today; a
// menu action / opt-in toggle later), so a hardened release's runtime behavior
// is unchanged unless someone asks for an audit.

import Foundation

/// The signals the steward classifies. All cheap to gather without an audit:
/// when we last audited, when the context surfaces last changed, and how many
/// there are now vs. then.
public struct WikiStewardSignals: Sendable, Equatable {
    /// When the last audit for this root completed. `nil` = never audited.
    public var lastAuditAt: Date?
    /// The most recent modification time across the root's context surfaces.
    /// `nil` = unknown (reads as "no change since last audit").
    public var latestSourceModifiedAt: Date?
    /// Source count at the last audit (0 if never audited).
    public var lastSourceCount: Int
    /// Source count right now.
    public var currentSourceCount: Int
    /// Now — injected so the decision is deterministic in tests.
    public var now: Date

    public init(
        lastAuditAt: Date?,
        latestSourceModifiedAt: Date?,
        lastSourceCount: Int,
        currentSourceCount: Int,
        now: Date
    ) {
        self.lastAuditAt = lastAuditAt
        self.latestSourceModifiedAt = latestSourceModifiedAt
        self.lastSourceCount = lastSourceCount
        self.currentSourceCount = currentSourceCount
        self.now = now
    }
}

/// The verdict. `.upToDate` = nothing to do; `.reaudit` carries a human-readable
/// reason for the trace / UI.
public enum WikiStewardDecision: Sendable, Equatable {
    case upToDate
    case reaudit(reason: String)
}

public struct ContextWikiSteward: Sendable {

    /// Re-audit at least this often even if nothing visibly changed — a
    /// belt-and-suspenders refresh (thresholds drift, new heuristics ship).
    /// Default 7 days.
    public let maxAuditAge: TimeInterval

    /// Minimum gap between audits, so a burst of edits can't trigger a re-audit
    /// storm. Default 1 hour. Even when sources changed, we wait this long since
    /// the last audit.
    public let minAuditInterval: TimeInterval

    public static let defaultMaxAuditAge: TimeInterval = 7 * 24 * 60 * 60
    public static let defaultMinAuditInterval: TimeInterval = 60 * 60

    public init(
        maxAuditAge: TimeInterval = ContextWikiSteward.defaultMaxAuditAge,
        minAuditInterval: TimeInterval = ContextWikiSteward.defaultMinAuditInterval
    ) {
        self.maxAuditAge = maxAuditAge
        self.minAuditInterval = minAuditInterval
    }

    /// Decide whether `signals` warrant a re-audit.
    ///
    /// PRECEDENCE:
    ///   1. never audited            -> reaudit (there's no baseline yet)
    ///   2. within minAuditInterval  -> upToDate (rate-limit; overrides the rest)
    ///   3. source count changed     -> reaudit (a file was added/removed)
    ///   4. a source changed since the last audit -> reaudit (content edited)
    ///   5. older than maxAuditAge   -> reaudit (periodic refresh)
    ///   6. otherwise                -> upToDate
    public func assess(_ signals: WikiStewardSignals) -> WikiStewardDecision {
        guard let lastAuditAt = signals.lastAuditAt else {
            return .reaudit(reason: "no prior audit for this project — establishing a baseline.")
        }

        let sinceLast = signals.now.timeIntervalSince(lastAuditAt)

        // Rate-limit: never re-audit more often than minAuditInterval, no matter
        // how much churned. A tight edit loop shouldn't spawn back-to-back audits.
        if sinceLast < minAuditInterval {
            return .upToDate
        }

        if signals.currentSourceCount != signals.lastSourceCount {
            let delta = signals.currentSourceCount - signals.lastSourceCount
            let word = delta > 0 ? "added" : "removed"
            return .reaudit(reason: "\(abs(delta)) context source(s) \(word) since the last audit.")
        }

        if let modified = signals.latestSourceModifiedAt, modified > lastAuditAt {
            return .reaudit(reason: "a context source changed since the last audit.")
        }

        if sinceLast >= maxAuditAge {
            let days = Int((sinceLast / (24 * 60 * 60)).rounded())
            return .reaudit(reason: "last audit was about \(days) day(s) ago — periodic refresh.")
        }

        return .upToDate
    }
}
