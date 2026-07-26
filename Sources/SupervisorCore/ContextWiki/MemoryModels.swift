// MemoryModels.swift — the value-type vocabulary for the Second Brain
// (iterative memory optimization, built on the Context Wiki subsystem).
//
// WHAT THIS FEATURE IS. Nadella's "Reverse Information Paradox" (July 2026):
// users pay for AI twice — once in money, and once in the proprietary knowledge
// they reveal in prompts and corrections, knowledge that evaporates when the
// session ends (or quietly improves someone else's model). Supervisor already
// watches every Claude Code session, so it is uniquely placed to CAPTURE that
// knowledge for its owner: each correction, decision, and stated preference is
// distilled into a locally-owned second brain that improves every iteration.
// The memory stays in the user's tenant — plain Markdown + JSON on local disk
// and rows in the local sqlite DB — and the optional LLM pass has a
// deterministic fallback, so switching models or providers never loses the
// accumulated brain.
//
// THE LOOP (one iteration, run on demand — see SecondBrainOptimizer):
//   capture -> redact -> merge -> retire -> measure -> render
// Candidates are distilled from recent transcripts (MemoryDistiller), pass
// through the Redactor BEFORE anything persists, merge/dedupe against the
// active ledger, stale contradicted/orphaned entries retire, the iteration is
// measured as an `IterationDelta`, and the ledger renders to SECOND-BRAIN.md
// next to the other wiki artifacts.
//
// DESIGN STANCE (matches ContextWikiModels).
//   - PLAIN VALUE TYPES: Codable + Sendable + Equatable, no I/O, no clock, no
//     actor. The distiller/optimizer/renderer are functions over them, so every
//     branch is unit-testable with a literal.
//   - "ONE FACT, ONE HOME." An entry's identity is a stable content hash of its
//     normalized text + kind, so the same fact re-observed across sessions and
//     iterations lands on the same entry (confirming it) instead of duplicating.
//   - NON-DESTRUCTIVE HISTORY. Entries are never deleted by the loop; they move
//     to `merged`/`retired` status and stay visible (collapsed) in the render,
//     so the owner can always see what the brain used to believe and why.

import Foundation

/// What kind of durable knowledge a memory entry captures. String-coded for
/// forward compatibility (same choice RawSourceKind makes). The raw values ARE
/// the cross-twin contract — the Python skill twin and its curation rubric use
/// these exact snake_case strings — so every case pins its value explicitly.
public enum MemoryEntryKind: String, Codable, Sendable, CaseIterable {
    /// An explicit project decision ("let's use GRDB", "we should ship X first").
    case decision = "decision"
    /// A user correction of an assistant action — the strongest proprietary-
    /// knowledge signal ("no, don't use tabs", "actually, run it from root").
    case correction = "correction"
    /// A stable fact about the environment/toolchain (CI quirks, path layout).
    case environmentFact = "environment_fact"
    /// A hard-won trap ("the sandbox blocks kqueue on that dir").
    case gotcha = "gotcha"
    /// A standing owner preference ("prefer small focused functions").
    case preference = "preference"

    /// Human-facing section heading for the renderer.
    public var sectionTitle: String {
        switch self {
        case .decision: return "Decisions"
        case .correction: return "Corrections"
        case .environmentFact: return "Environment facts"
        case .gotcha: return "Gotchas"
        case .preference: return "Preferences"
        }
    }
}

/// Where an entry sits in its lifecycle. Never deleted — history stays legible.
public enum MemoryEntryStatus: String, Codable, Sendable {
    /// Live knowledge; rendered in its kind's section, matched against new
    /// candidates each iteration.
    case active
    /// Absorbed into a richer active entry (which carries this one's id in its
    /// `mergedIDs`). Kept for provenance, no longer matched or rendered as live.
    case merged
    /// Contradicted by a later correction, or unconfirmed for N iterations with
    /// its source session gone. Rendered collapsed at the bottom.
    case retired
}

/// How confident the brain is in an entry. Starts low; each re-observation
/// bumps it one step (low -> medium -> high).
public enum MemoryConfidence: String, Codable, Sendable, Comparable {
    case low, medium, high
    private var order: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
    public static func < (l: MemoryConfidence, r: MemoryConfidence) -> Bool { l.order < r.order }

    /// One step more confident (saturating at `.high`).
    var bumped: MemoryConfidence {
        switch self {
        case .low: return .medium
        case .medium: return .high
        case .high: return .high
        }
    }
}

/// Where an entry came from: which session taught it, when, and a stable hash
/// of the (already-redacted) source excerpt so the origin is verifiable without
/// persisting the raw transcript text.
public struct MemoryProvenance: Codable, Sendable, Equatable {
    /// The Claude Code session id whose transcript the fact was distilled from.
    public var sessionId: String
    /// The transcript timestamp of the source turn.
    public var timestamp: Date
    /// Stable hash of the REDACTED source excerpt (never the raw text — nothing
    /// secret-derived is persisted, hashed or otherwise).
    public var excerptHash: String

    public init(sessionId: String, timestamp: Date, excerptHash: String) {
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.excerptHash = excerptHash
    }
}

/// A candidate fact freshly distilled from a transcript, BEFORE it is merged
/// into the ledger. Text is already redacted and capped by the distiller; the
/// optimizer turns candidates into (or matches them against) `MemoryEntry`s.
public struct MemoryCandidate: Sendable, Equatable {
    public var kind: MemoryEntryKind
    /// Redacted, whitespace-collapsed, capped at `MemoryEntry.textCap`.
    public var text: String
    public var sessionId: String
    public var timestamp: Date
    public var excerptHash: String

    public init(kind: MemoryEntryKind, text: String, sessionId: String, timestamp: Date, excerptHash: String) {
        self.kind = kind
        self.text = MemoryEntry.cap(text)
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.excerptHash = excerptHash
    }

    /// The stable identity this candidate would have as an entry.
    public var id: String { MemoryEntry.makeID(kind: kind, text: text) }
    /// The normalized text used for id + near-duplicate containment matching.
    public var normalizedText: String { MemoryEntry.normalize(text) }
}

/// One remembered fact — "one fact, one home". Identity is a content hash of
/// the normalized text + kind, so the same fact re-observed anywhere maps to
/// the same entry.
public struct MemoryEntry: Codable, Sendable, Equatable, Identifiable {
    /// Stable content hash (see `makeID`). NOT a UUID: identity must survive
    /// re-distillation across sessions and processes.
    public var id: String
    public var kind: MemoryEntryKind
    /// The fact, one home: redacted, whitespace-collapsed, capped at `textCap`.
    public var text: String
    /// The FIRST observation that taught this fact (kept through confirms —
    /// the origin is the provenance, later sightings only bump the counters).
    public var provenance: MemoryProvenance
    public var status: MemoryEntryStatus
    public var confidence: MemoryConfidence
    /// The ledger iteration this entry first appeared in.
    public var firstSeenIteration: Int
    /// The most recent iteration in which the fact was re-observed (or first
    /// added). Drives the staleness retire rule.
    public var lastConfirmedIteration: Int
    /// Ids of near-duplicate candidates absorbed into this entry. A re-run of
    /// the same inputs matches here and CONFIRMS instead of re-merging — the
    /// property that makes the optimizer idempotent.
    public var mergedIDs: [String]

    public init(
        id: String,
        kind: MemoryEntryKind,
        text: String,
        provenance: MemoryProvenance,
        status: MemoryEntryStatus = .active,
        confidence: MemoryConfidence = .low,
        firstSeenIteration: Int,
        lastConfirmedIteration: Int,
        mergedIDs: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = MemoryEntry.cap(text)
        self.provenance = provenance
        self.status = status
        self.confidence = confidence
        self.firstSeenIteration = firstSeenIteration
        self.lastConfirmedIteration = lastConfirmedIteration
        self.mergedIDs = mergedIDs
    }

    /// Cap on entry text ("one fact, one home" — a fact longer than this is a
    /// document, not a fact).
    public static let textCap = 400

    static func cap(_ text: String) -> String {
        text.count > textCap ? String(text.prefix(textCap)) : text
    }

    /// Normalize text for identity + containment: lowercased, whitespace
    /// collapsed. Mirrors ReviewFindingStore.fingerprint's normalization so
    /// trivial rewordings (case, spacing) collapse to one entry.
    public static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The stable identity of a fact: FNV-1a over kind + normalized text. Uses
    /// the shared stable hash (NOT Swift's per-run-randomized `Hasher`) so
    /// identity survives across launches — same reasoning as
    /// ReviewFindingStore's fingerprint, which shares the StableHash home.
    public static func makeID(kind: MemoryEntryKind, text: String) -> String {
        StableHash.fnv1a64Hex("\(kind.rawValue)\u{1F}\(normalize(text))")
    }
}

/// The complete second brain for one project root: every entry (all statuses),
/// the iteration counter, and a short delta history for the render's iteration
/// log. Codable so it round-trips through the `second_brain_ledgers` blob and
/// the plain-JSON artifact — the provider-agnostic, user-owned record.
public struct MemoryLedger: Codable, Sendable, Equatable {
    /// The project root this brain belongs to (per-root identity).
    public var root: String
    /// Monotonic iteration counter; bumped once per optimizer run.
    public var iteration: Int
    /// Every entry ever learned, all statuses (history is never deleted).
    public var entries: [MemoryEntry]
    /// The last few iteration deltas (capped at `deltaHistoryCap`), newest last
    /// — feeds the render's iteration log without a DB read.
    public var recentDeltas: [IterationDelta]
    /// When the ledger last changed (the optimizer's injected `now`).
    public var updatedAt: Date

    public init(
        root: String,
        iteration: Int,
        entries: [MemoryEntry],
        recentDeltas: [IterationDelta] = [],
        updatedAt: Date
    ) {
        self.root = root
        self.iteration = iteration
        self.entries = entries
        self.recentDeltas = recentDeltas
        self.updatedAt = updatedAt
    }

    /// How many deltas `recentDeltas` retains (the iteration-log window).
    public static let deltaHistoryCap = 10

    /// A fresh, never-iterated ledger for a root.
    public static func empty(root: String) -> MemoryLedger {
        MemoryLedger(root: root, iteration: 0, entries: [], recentDeltas: [], updatedAt: .distantPast)
    }

    /// The live knowledge — what the render shows as the brain's current state.
    public var activeEntries: [MemoryEntry] {
        entries.filter { $0.status == .active }
    }
}

/// What one optimizer iteration did — the "is the brain improving" measure.
public struct IterationDelta: Codable, Sendable, Equatable {
    /// Which iteration this delta describes.
    public var iteration: Int
    /// Brand-new entries added this iteration.
    public var added: Int
    /// Existing entries re-observed (id/alias match) — confidence bumped.
    public var confirmed: Int
    /// Near-duplicate candidates absorbed into existing entries (containment).
    public var merged: Int
    /// Entries retired this iteration (contradicted, or stale + session gone).
    public var retired: Int
    /// Active entries after the iteration.
    public var activeTotal: Int
    /// Optional context-drift note derived from the most recent AuditReport for
    /// the same root, when one was available — ties the brain's trend to the
    /// Context Wiki's bloat trend. `nil` when no prior audit existed.
    public var contextDriftNote: String?

    public init(
        iteration: Int,
        added: Int,
        confirmed: Int,
        merged: Int,
        retired: Int,
        activeTotal: Int,
        contextDriftNote: String? = nil
    ) {
        self.iteration = iteration
        self.added = added
        self.confirmed = confirmed
        self.merged = merged
        self.retired = retired
        self.activeTotal = activeTotal
        self.contextDriftNote = contextDriftNote
    }
}
