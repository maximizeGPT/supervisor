// ContextWikiModels.swift — the value-type vocabulary for the Context Wiki
// auditor (v0.3.x feature).
//
// WHAT THIS FEATURE IS. Supervisor supervises Claude Code sessions. Those
// sessions are steered by a project's "context surfaces" — CLAUDE.md files,
// `.claude/skills/*/SKILL.md`, `.claude/commands/*.md`, AGENTS.md — which
// accumulate the same way a human wiki does: facts get restated in three
// places, a skill grows a dozen near-duplicate reference docs, binary assets
// get checked in and never regenerated. Bloated, contradictory context makes
// every session it feeds worse. This feature perpetually AUDITS that context
// and RECOMMENDS cleanups.
//
// THE PATTERN (Karpathy's "LLM Wiki", April 2026). Three artifacts, one arrow:
//   raw sources  ->  wiki  ->  schema
//   (read-only)      (a consolidated, cross-referenced structure Supervisor
//                     maintains)   (a conventions doc that prevents re-bloat)
// His insight: an LLM doesn't get bored maintaining cross-references, so the
// upkeep that kills human wikis (re-linking, de-duping) is cheap here. We lean
// on that: the wiki is a live cross-reference graph, and the schema is the set
// of "one fact, one home" conventions that keep it from re-bloating.
//
// DESIGN STANCE (matches the rest of SupervisorCore).
//   - These are PLAIN VALUE TYPES: Codable + Sendable + Equatable, no I/O, no
//     clock, no actor. The scanner/metrics/consolidator are pure functions over
//     them, so every branch is unit-testable with a literal (see ContextSteward
//     for the same stance).
//   - NON-DESTRUCTIVE BY DEFAULT. An `AuditReport` never mutates a raw source;
//     it only DESCRIBES and RECOMMENDS. Anything that would delete or merge a
//     real file is a `Recommendation` with `requiresSignoff == true`. Applying
//     it is a separate, human-gated step — the same "surface, never auto-destroy"
//     philosophy the ContextSteward already encodes ("a real reset is a human
//     call").
//   - GENERAL, not hardcoded. Every type is keyed on `path` strings and a
//     `RawSourceKind`; nothing here knows about any one user's setup.

import Foundation

/// What kind of context surface a raw source is. String-coded for forward
/// compatibility: an unknown value read back from a persisted report degrades
/// to `.other` rather than crashing (same choice FlagSeverity/AuditEntryKind
/// make elsewhere).
public enum RawSourceKind: String, Codable, Sendable, CaseIterable {
    /// `CLAUDE.md` / `CLAUDE.local.md` — memory/instruction files.
    case claudeMd
    /// `AGENTS.md` — the cross-tool agent-instructions convention.
    case agentsMd
    /// A skill's entry point: `.../<skill>/SKILL.md`.
    case skillManifest
    /// Any other TEXT doc inside a skill directory (reference/*.md, a script,
    /// a template). Counts toward the skill's weight and is a merge candidate.
    case skillReference
    /// A NON-text file inside a skill directory (a checked-in PNG/GIF/MP4). These
    /// are the "regenerable weight" a lean-disk owner would rather rebuild on
    /// demand than store; flagged, never counted as instruction content.
    case skillAsset
    /// `.claude/commands/*.md` — slash-command definitions.
    case command
    /// `settings.json` / `settings.local.json` — noted for inventory, never
    /// content-audited (it is configuration, not instruction prose).
    case settings
    /// A top-level markdown doc that isn't a skill/command file (e.g. a linked
    /// MISSION.md / PROJECTS.md context doc). Generic instruction prose.
    case contextDoc
    /// Anything else we enumerated but don't classify.
    case other

    /// True for kinds whose *prose* is instruction content we should read,
    /// survey, and de-duplicate. Assets/settings are excluded.
    public var isInstructionText: Bool {
        switch self {
        case .claudeMd, .agentsMd, .skillManifest, .skillReference, .command, .contextDoc:
            return true
        case .skillAsset, .settings, .other:
            return false
        }
    }
}

/// One raw source: an existing context file, treated READ-ONLY as input. The
/// `id` is the path so a report round-trips through a Set/dictionary cleanly.
public struct RawSource: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }

    /// Absolute filesystem path. The stable identity of the source.
    public var path: String
    /// How this source is classified.
    public var kind: RawSourceKind
    /// The owning skill's name, when the source lives under `skills/<name>/`.
    /// `nil` for CLAUDE.md/commands/top-level docs.
    public var skill: String?
    /// First markdown `#` heading, else the file's basename — a human label.
    public var title: String?
    /// File size in bytes (from the filesystem; works for text and assets).
    public var byteCount: Int
    /// Line count for text sources; 0 for assets (not meaningfully "lines").
    public var lineCount: Int
    /// Whether the file is text (sniffed: extension + a NUL-byte check). Read for
    /// a title/line-count; a superset of `isProse`.
    public var isText: Bool
    /// Whether this is PROSE a Claude session actually loads as context/instruction
    /// (`.md`/`.txt` families). A skill's `.js`/`.py` scripts are text but are
    /// EXECUTED, never read into the model's context, so they are `isText` but not
    /// `isProse`. Duplication + size analysis targets prose only — that is the
    /// memory/context surface this feature audits; scripts are inventoried as
    /// weight, not context.
    public var isProse: Bool

    public init(
        path: String,
        kind: RawSourceKind,
        skill: String? = nil,
        title: String? = nil,
        byteCount: Int,
        lineCount: Int,
        isText: Bool,
        isProse: Bool = false
    ) {
        self.path = path
        self.kind = kind
        self.skill = skill
        self.title = title
        self.byteCount = byteCount
        self.lineCount = lineCount
        self.isText = isText
        self.isProse = isProse
    }
}

/// A block of content that appears — near-identically — in two or more distinct
/// sources. The deterministic heart of the audit: cross-file duplication is the
/// single strongest, model-free signal of re-bloat, and it maps directly to an
/// `.extractShared` / `.link` recommendation.
public struct DuplicateBlock: Codable, Sendable, Equatable {
    /// A representative excerpt (the block's first normalized line) so a human
    /// can recognize what's duplicated without opening every file.
    public var excerpt: String
    /// How many consecutive normalized lines the block spans.
    public var lineSpan: Int
    /// The sorted set of source paths the block appears in (always count >= 2).
    public var occurrences: [String]

    public init(excerpt: String, lineSpan: Int, occurrences: [String]) {
        self.excerpt = excerpt
        self.lineSpan = lineSpan
        self.occurrences = occurrences
    }

    /// Lines that would be reclaimed by keeping ONE canonical copy and linking
    /// from the rest: the block's span times the number of redundant copies.
    public var reclaimableLines: Int { lineSpan * max(0, occurrences.count - 1) }
}

/// Deterministic, model-free metrics over the raw sources. Computed with zero
/// LLM calls, so the auditor always produces a useful report even with no API
/// key / no budget. The optional semantic survey (SourceSurvey) enriches this;
/// it never replaces it.
public struct SourceMetrics: Codable, Sendable, Equatable {
    public var totalSources: Int
    /// Count of PROSE sources — the actual context/instruction surface (md/txt),
    /// not the skill's executable scripts.
    public var proseSources: Int
    public var totalBytes: Int
    /// Total lines across PROSE sources — the "how much is the model asked to
    /// hold as context" proxy. Excludes scripts (executed, never read as context).
    public var totalProseLines: Int
    /// Bytes NOT loaded as context: checked-in binary assets plus executable
    /// scripts. Regenerable / machinery weight worth flagging, distinct from the
    /// prose the model actually reads.
    public var nonContextBytes: Int
    /// The heaviest PROSE sources (by line count) — a small top-N for the summary
    /// and split recommendations.
    public var largestProseSources: [RawSource]
    /// Cross-file duplication found across the PROSE sources.
    public var duplicateBlocks: [DuplicateBlock]

    public init(
        totalSources: Int,
        proseSources: Int,
        totalBytes: Int,
        totalProseLines: Int,
        nonContextBytes: Int,
        largestProseSources: [RawSource],
        duplicateBlocks: [DuplicateBlock]
    ) {
        self.totalSources = totalSources
        self.proseSources = proseSources
        self.totalBytes = totalBytes
        self.totalProseLines = totalProseLines
        self.nonContextBytes = nonContextBytes
        self.largestProseSources = largestProseSources
        self.duplicateBlocks = duplicateBlocks
    }
}

/// The result of surveying ONE source with the cheap model (the fan-out pass).
/// Optional enrichment: absent when no LLM ran. Deliberately small and
/// structured so the fan-out can force it as a tool-call and parse it safely.
public struct SourceSurvey: Codable, Sendable, Equatable {
    public var path: String
    /// One line: what this source is for / when it applies.
    public var purpose: String
    /// The distinct topics/claims it covers — the raw material of the wiki's
    /// cross-reference graph.
    public var topics: [String]
    /// The irreducible content that MUST survive any consolidation.
    public var loadBearing: [String]
    /// Content that reads as filler / stale / restated elsewhere.
    public var deadWeight: [String]
    /// Free-text notes on what this overlaps with (other files/skills).
    public var overlapsNotes: [String]
    /// 1 (lean) .. 5 (severely bloated). Clamped on ingest.
    public var bloatScore: Int

    public init(
        path: String,
        purpose: String,
        topics: [String],
        loadBearing: [String],
        deadWeight: [String],
        overlapsNotes: [String],
        bloatScore: Int
    ) {
        self.path = path
        self.purpose = purpose
        self.topics = topics
        self.loadBearing = loadBearing
        self.deadWeight = deadWeight
        self.overlapsNotes = overlapsNotes
        self.bloatScore = max(1, min(5, bloatScore))
    }
}

/// A node in the maintained wiki: one topic and every source it appears in,
/// with a suggested canonical home. This is the cross-reference structure
/// Karpathy's pattern centers on — cheap for an LLM to keep current, expensive
/// for a human, so exactly the upkeep to automate.
public struct WikiTopic: Codable, Sendable, Equatable {
    /// The topic label (a duplicated rule, a shared convention, a concept).
    public var name: String
    /// Where this topic SHOULD live (the single canonical home). Heuristic:
    /// the most-authoritative / shortest-path source among its appearances.
    public var canonicalHome: String?
    /// Every source that currently states this topic (>= 1). When count > 1 and
    /// a `canonicalHome` is set, the others are link candidates.
    public var appearsIn: [String]

    public init(name: String, canonicalHome: String?, appearsIn: [String]) {
        self.name = name
        self.canonicalHome = canonicalHome
        self.appearsIn = appearsIn
    }

    /// A topic stated in more than one place — a de-dup opportunity.
    public var isDuplicated: Bool { appearsIn.count > 1 }
}

/// What kind of cleanup a recommendation proposes.
public enum RecommendationKind: String, Codable, Sendable {
    /// Pull content duplicated across N files into one shared home + link to it.
    case extractShared
    /// Combine near-duplicate files into one.
    case merge
    /// Delete dead / stale / regenerable weight.
    case prune
    /// Replace a restated passage with a link to its canonical home.
    case link
    /// An oversized single file should be decomposed.
    case split
    /// A convention to adopt so this class of bloat can't recur (feeds the schema).
    case schemaRule
}

public enum RiskLevel: String, Codable, Sendable, Comparable {
    case low, medium, high
    private var order: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
    public static func < (l: RiskLevel, r: RiskLevel) -> Bool { l.order < r.order }
}

/// How much a finding matters. Drives ranking + the summary headline.
public enum SeverityBand: String, Codable, Sendable, Comparable {
    case info, minor, notable, major
    private var order: Int { switch self { case .info: 0; case .minor: 1; case .notable: 2; case .major: 3 } }
    public static func < (l: SeverityBand, r: SeverityBand) -> Bool { l.order < r.order }
}

/// One recommended cleanup. Descriptive only — applying it is a separate,
/// human-gated action. `requiresSignoff` is true for anything that would edit
/// or delete a real file; the renderer surfaces those with an explicit
/// checkbox so nothing is ever changed silently.
public struct Recommendation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: RecommendationKind
    public var title: String
    public var rationale: String
    public var affectedPaths: [String]
    public var estLinesSaved: Int
    public var estBytesSaved: Int
    public var risk: RiskLevel
    public var severity: SeverityBand
    /// True when acting on this would mutate/delete a source file (merge, prune,
    /// link-edit). A `.schemaRule` is advisory and does not require signoff.
    public var requiresSignoff: Bool
    /// Provenance: "deterministic" (metrics), "survey" (cheap-model), or
    /// "consolidation" (main-session synthesis).
    public var origin: String

    public init(
        id: String = UUID().uuidString,
        kind: RecommendationKind,
        title: String,
        rationale: String,
        affectedPaths: [String],
        estLinesSaved: Int = 0,
        estBytesSaved: Int = 0,
        risk: RiskLevel,
        severity: SeverityBand,
        requiresSignoff: Bool,
        origin: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.rationale = rationale
        self.affectedPaths = affectedPaths
        self.estLinesSaved = estLinesSaved
        self.estBytesSaved = estBytesSaved
        self.risk = risk
        self.severity = severity
        self.requiresSignoff = requiresSignoff
        self.origin = origin
    }
}

/// The complete, non-destructive output of one audit run: the raw inventory,
/// the deterministic metrics, any semantic surveys, the consolidated wiki, the
/// generated schema conventions, and the ranked recommendations. Codable so it
/// can be persisted (ContextAuditStore) and re-rendered without re-running.
public struct AuditReport: Codable, Sendable, Equatable {
    public var root: String
    public var generatedAt: Date
    public var sources: [RawSource]
    public var metrics: SourceMetrics
    public var surveys: [SourceSurvey]
    public var wiki: [WikiTopic]
    public var schema: String
    public var recommendations: [Recommendation]
    /// Whether the semantic survey pass ran (an API key + budget were available).
    public var usedLLM: Bool

    public init(
        root: String,
        generatedAt: Date,
        sources: [RawSource],
        metrics: SourceMetrics,
        surveys: [SourceSurvey],
        wiki: [WikiTopic],
        schema: String,
        recommendations: [Recommendation],
        usedLLM: Bool
    ) {
        self.root = root
        self.generatedAt = generatedAt
        self.sources = sources
        self.metrics = metrics
        self.surveys = surveys
        self.wiki = wiki
        self.schema = schema
        self.recommendations = recommendations
        self.usedLLM = usedLLM
    }

    /// The highest-severity band present, for the one-line headline. `.info`
    /// when there are no recommendations (a clean setup).
    public var topSeverity: SeverityBand {
        recommendations.map(\.severity).max() ?? .info
    }

    /// Total estimated lines reclaimable if every non-signoff-free recommendation
    /// were applied — a single "how bloated" number for the summary.
    public var totalReclaimableLines: Int {
        recommendations.reduce(0) { $0 + $1.estLinesSaved }
    }
}
