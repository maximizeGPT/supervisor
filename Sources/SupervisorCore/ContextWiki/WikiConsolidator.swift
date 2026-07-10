// WikiConsolidator.swift — the "-> wiki -> schema" half of the pattern.
//
// The consolidation stays in the MAIN session (per the feature's design): the
// cheap model does the wide, boring per-file SURVEY; the synthesis — deciding
// what the canonical home of each fact is, what to recommend, and what
// conventions prevent recurrence — is done here, deterministically, over the
// metrics + surveys. Deterministic on purpose: the same inputs yield the same
// wiki/schema/recommendations, so the judgement is pinned by unit tests rather
// than re-rolled by a model each run.
//
// THREE OUTPUTS, matching Karpathy's arrow:
//   buildWiki(...)        -> [WikiTopic]        the cross-reference graph
//   recommendations(...)  -> [Recommendation]   ranked cleanups (non-destructive)
//   generateSchema(...)   -> String             the conventions that prevent re-bloat
//
// NON-DESTRUCTIVE. Nothing here edits a file. Recommendations that WOULD change a
// file carry `requiresSignoff = true`; the renderer surfaces them behind an
// explicit checkbox.

import Foundation

public struct WikiConsolidator: Sendable {

    // MARK: - Tunable conventions (also emitted into the schema doc)

    /// Target ceiling for a SKILL.md. Past this, route depth into reference docs.
    public let skillManifestLineBudget: Int
    /// Target ceiling for a reference doc / CLAUDE.md / command before it should
    /// be split.
    public let docLineBudget: Int
    /// Aggregate checked-in asset bytes past which "regenerate on demand" is worth
    /// recommending (the owner values lean disk).
    public let assetByteBudget: Int

    public init(
        skillManifestLineBudget: Int = 150,
        docLineBudget: Int = 400,
        assetByteBudget: Int = 200 * 1024
    ) {
        self.skillManifestLineBudget = skillManifestLineBudget
        self.docLineBudget = docLineBudget
        self.assetByteBudget = assetByteBudget
    }

    // MARK: - Wiki

    /// Assemble the cross-reference graph. Two inputs feed it:
    ///   - deterministic duplicate blocks (the same passage in N files) — a
    ///     topic whose home should be one place with links from the rest;
    ///   - survey topics (semantic) — a concept named by more than one file's
    ///     survey, which is a softer overlap worth cross-referencing.
    /// Topics are keyed by a normalized name so the two sources merge cleanly.
    public func buildWiki(sources: [RawSource], metrics: SourceMetrics, surveys: [SourceSurvey]) -> [WikiTopic] {
        let byPath = Dictionary(uniqueKeysWithValues: sources.map { ($0.path, $0) })
        var appearances: [String: (display: String, paths: Set<String>)] = [:]

        func add(_ name: String, path: String) {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            if var existing = appearances[key] {
                existing.paths.insert(path)
                appearances[key] = existing
            } else {
                appearances[key] = (display: name, paths: [path])
            }
        }

        // Duplicate blocks: the excerpt is the topic; every occurrence is an
        // appearance.
        for block in metrics.duplicateBlocks {
            for p in block.occurrences { add(block.excerpt, path: p) }
        }
        // Survey topics: each topic named in a survey is an appearance at that
        // survey's path.
        for survey in surveys {
            for topic in survey.topics { add(topic, path: survey.path) }
        }

        var topics: [WikiTopic] = appearances.values.map { entry in
            let paths = entry.paths.sorted()
            return WikiTopic(
                name: entry.display,
                canonicalHome: chooseCanonicalHome(among: paths, byPath: byPath),
                appearsIn: paths
            )
        }
        // Duplicated topics first (the actionable ones), then by spread, then name.
        topics.sort {
            if $0.isDuplicated != $1.isDuplicated { return $0.isDuplicated && !$1.isDuplicated }
            if $0.appearsIn.count != $1.appearsIn.count { return $0.appearsIn.count > $1.appearsIn.count }
            return $0.name < $1.name
        }
        return topics
    }

    /// Pick the single most-authoritative existing home for a topic. Preference:
    /// a memory/instruction root (CLAUDE.md), then a top-level context doc, then
    /// a skill's manifest, then anything shorter-pathed. This is the "one fact,
    /// one home" heuristic — the others become link candidates.
    func chooseCanonicalHome(among paths: [String], byPath: [String: RawSource]) -> String? {
        guard !paths.isEmpty else { return nil }
        func rank(_ path: String) -> Int {
            switch byPath[path]?.kind {
            case .claudeMd: return 0
            case .contextDoc: return 1
            case .skillManifest: return 2
            case .agentsMd: return 3
            case .command: return 4
            case .skillReference: return 5
            default: return 6
            }
        }
        return paths.min { a, b in
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }
    }

    // MARK: - Recommendations

    /// The ranked, non-destructive cleanup list. Combines deterministic findings
    /// (duplication, oversize, asset weight) with survey-derived ones (high bloat,
    /// named dead weight, cross-skill overlap), then sorts by impact.
    public func recommendations(
        sources: [RawSource],
        metrics: SourceMetrics,
        surveys: [SourceSurvey]
    ) -> [Recommendation] {
        var recs: [Recommendation] = []
        let byPath = Dictionary(uniqueKeysWithValues: sources.map { ($0.path, $0) })

        // --- 1. Duplication, grouped by the set of files that share it. All the
        //        blocks shared by the same file-set become ONE "extract shared +
        //        link" recommendation, so a big shared preamble reads as a single
        //        action, not fifty. ---
        var byOwnerSet: [String: [DuplicateBlock]] = [:]
        for block in metrics.duplicateBlocks {
            byOwnerSet[block.occurrences.joined(separator: "\u{1}"), default: []].append(block)
        }
        for (_, blocks) in byOwnerSet.sorted(by: { lhsRhsReclaim($0.value) > lhsRhsReclaim($1.value) }) {
            let owners = blocks[0].occurrences
            let reclaim = blocks.reduce(0) { $0 + $1.reclaimableLines }
            guard reclaim >= 3 else { continue }        // ignore trivial coincidence
            let names = owners.map { shortName($0, byPath: byPath) }.joined(separator: ", ")
            let canonical = chooseCanonicalHome(among: owners, byPath: byPath).map { shortName($0, byPath: byPath) } ?? "one file"
            let sev: SeverityBand = reclaim >= 40 ? .major : (reclaim >= 12 ? .notable : (reclaim >= 5 ? .minor : .info))
            recs.append(Recommendation(
                kind: .extractShared,
                title: "Deduplicate \(reclaim) line\(reclaim == 1 ? "" : "s") shared across \(owners.count) files",
                rationale: "\(blocks.count) block(s) of near-identical content appear in: \(names). Keep one canonical copy (suggested home: \(canonical)) and replace the rest with a link. LLMs maintain links cheaply; duplicated prose drifts out of sync.",
                affectedPaths: owners,
                estLinesSaved: reclaim,
                risk: owners.count > 2 ? .medium : .low,
                severity: sev,
                requiresSignoff: true,
                origin: "deterministic"
            ))
        }

        // --- 2. Oversized single PROSE files -> split / route to references. A
        //        long script is not a context-budget problem, so only prose counts. ---
        for src in sources where src.isProse {
            let budget = src.kind == .skillManifest ? skillManifestLineBudget : docLineBudget
            guard src.lineCount > budget else { continue }
            let over = src.lineCount - budget
            let sev: SeverityBand = src.lineCount > budget * 2 ? .notable : .minor
            recs.append(Recommendation(
                kind: .split,
                title: "\(shortName(src.path, byPath: byPath)) is \(src.lineCount) lines (budget \(budget))",
                rationale: "\(over) lines over the \(budget)-line budget for a \(src.kind.rawValue). Decompose into focused sections/reference docs so a session loads only what it needs.",
                affectedPaths: [src.path],
                estLinesSaved: 0,
                risk: .low,
                severity: sev,
                requiresSignoff: true,
                origin: "deterministic"
            ))
        }

        // --- 3. Checked-in asset weight -> regenerate on demand. Per-skill so the
        //        rec names a concrete directory. ---
        let assetsBySkill = Dictionary(grouping: sources.filter { $0.kind == .skillAsset }, by: { $0.skill ?? "(root)" })
        for (skill, assets) in assetsBySkill.sorted(by: { $0.key < $1.key }) {
            let bytes = assets.reduce(0) { $0 + $1.byteCount }
            guard bytes >= assetByteBudget else { continue }
            recs.append(Recommendation(
                kind: .prune,
                title: "\(skill): \(humanBytes(bytes)) of checked-in assets across \(assets.count) file\(assets.count == 1 ? "" : "s")",
                rationale: "Binary assets in a skill are regenerable build output. If a script can rebuild them, keep the script and drop the artifacts to keep the tree (and any clone) lean.",
                affectedPaths: assets.map(\.path).sorted(),
                estBytesSaved: bytes,
                risk: .low,
                severity: bytes >= assetByteBudget * 3 ? .notable : .minor,
                requiresSignoff: true,
                origin: "deterministic"
            ))
        }

        // --- 4. Survey-derived (semantic), when the cheap-model pass ran. ---
        for survey in surveys {
            if survey.bloatScore >= 4, !survey.deadWeight.isEmpty {
                recs.append(Recommendation(
                    kind: .prune,
                    title: "High bloat in \(shortName(survey.path, byPath: byPath)) (score \(survey.bloatScore)/5)",
                    rationale: "Survey flagged low-value content: " + survey.deadWeight.prefix(4).joined(separator: "; ") + ".",
                    affectedPaths: [survey.path],
                    estLinesSaved: 0,
                    risk: .medium,
                    severity: survey.bloatScore >= 5 ? .notable : .minor,
                    requiresSignoff: true,
                    origin: "survey"
                ))
            }
        }

        // --- 5. Advisory schema rules (never require signoff). A small standard
        //        set, plus a duplication-specific one if duplication was found. ---
        recs.append(contentsOf: schemaRuleRecommendations(metrics: metrics))

        // Rank: severity desc, then reclaimable desc, then lower risk first, then
        // title for stability.
        recs.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.estLinesSaved != $1.estLinesSaved { return $0.estLinesSaved > $1.estLinesSaved }
            if $0.risk != $1.risk { return $0.risk < $1.risk }
            return $0.title < $1.title
        }
        return recs
    }

    private func schemaRuleRecommendations(metrics: SourceMetrics) -> [Recommendation] {
        var rules: [Recommendation] = []
        if !metrics.duplicateBlocks.isEmpty {
            rules.append(Recommendation(
                kind: .schemaRule,
                title: "Adopt \"one fact, one home\"",
                rationale: "Duplication was found across \(metrics.duplicateBlocks.count) block(s). Establish that every rule/convention lives in exactly one canonical file and other files link to it, so the same content can't drift into three versions.",
                affectedPaths: [],
                risk: .low,
                severity: .info,
                requiresSignoff: false,
                origin: "consolidation"
            ))
        }
        rules.append(Recommendation(
            kind: .schemaRule,
            title: "Set size budgets (SKILL.md \(skillManifestLineBudget), docs \(docLineBudget))",
            rationale: "A per-kind line budget makes re-bloat visible: when a manifest crosses the budget, that's the signal to route depth into a reference doc rather than growing the entry point.",
            affectedPaths: [],
            risk: .low,
            severity: .info,
            requiresSignoff: false,
            origin: "consolidation"
        ))
        return rules
    }

    // MARK: - Schema

    /// Generate the conventions doc — the artifact whose whole job is to prevent
    /// the wiki from re-bloating. General (parameterized only by the budgets and a
    /// couple of headline numbers), so it reads sensibly for any project.
    public func generateSchema(root: String, sources: [RawSource], metrics: SourceMetrics) -> String {
        let dupCount = metrics.duplicateBlocks.count
        let reclaimable = metrics.duplicateBlocks.reduce(0) { $0 + $1.reclaimableLines }
        return """
        # Context Schema — conventions for this project

        > Generated by Supervisor's Context Wiki. This file is the *schema* half of
        > the raw-sources -> wiki -> schema pattern: a small set of conventions that
        > keep the context surfaces (CLAUDE.md, SKILL.md, commands) from re-bloating.
        > Point Supervisor at this project again any time to re-check adherence.

        Root: `\(root)`
        Baseline at generation: \(metrics.proseSources) context (prose) sources, \(metrics.totalProseLines) lines, \
        \(dupCount) duplicated block(s) (~\(reclaimable) reclaimable lines).

        ## 1. One fact, one home
        Every rule, convention, or fact lives in exactly ONE canonical file. Other
        files that need it LINK to it (`see <path>`), never restate it. An LLM keeps
        links current for free; copy-pasted prose silently drifts into conflicting
        versions.

        ## 2. Size budgets
        - `SKILL.md`: aim for <= \(skillManifestLineBudget) lines. It is a router, not a
          manual — push depth into `reference/` docs and link to them.
        - Reference doc / `CLAUDE.md` / command: <= \(docLineBudget) lines. Split when larger.
        - A file over its budget is a prompt to restructure, not to keep appending.

        ## 3. One skill, one job
        If two skills share more than ~40% of their rules (brand voice, shared
        constants, common conventions), extract the shared part into one file both
        link to. Don't fork the same guidance into each skill.

        ## 4. Assets are build output
        Binary assets (PNG/GIF/MP4) inside a skill are regenerable. Keep the script
        that builds them; don't commit the artifacts. A clone should be lean.

        ## 5. Cross-references over copies
        Prefer `see <path>#section` to duplicating a passage. When you catch yourself
        pasting the same paragraph into a second file, that's the signal to promote it
        to a canonical home and link instead.

        ---
        _Re-run the audit to measure drift against these conventions over time._
        """
    }

    // MARK: - Helpers

    private func lhsRhsReclaim(_ blocks: [DuplicateBlock]) -> Int {
        blocks.reduce(0) { $0 + $1.reclaimableLines }
    }

    /// A compact label for a path: `<skill>/<file>` when it's in a skill, else the
    /// basename. Keeps recommendations readable without absolute paths everywhere.
    func shortName(_ path: String, byPath: [String: RawSource]) -> String {
        let base = (path as NSString).lastPathComponent
        if let skill = byPath[path]?.skill { return "\(skill)/\(base)" }
        return base
    }

    private func humanBytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
}
