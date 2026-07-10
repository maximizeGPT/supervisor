// ContextWikiTests.swift — deterministic, no-network coverage for the Context
// Wiki auditor.
//
// Everything here is pure or filesystem-only (temp fixtures): the scanner's
// classification, the metric layer's cross-file duplicate detection and its
// significance thresholds, the consolidator's wiki/recommendations/schema, the
// re-audit steward's precedence, the survey JSON parser, and the Codable
// round-trip the persistence layer relies on. No LLM is ever called.

import XCTest
@testable import SupervisorCore

final class ContextWikiTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Create a throwaway directory tree; caller writes files into it.
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxwiki-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Scanner

    func testScannerClassifiesEveryContextKind() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Memory\nsome instruction line that is clearly long enough\n", to: root.appendingPathComponent("CLAUDE.md"))
        try write("# Agents\ncross-tool instructions here for the agent to follow\n", to: root.appendingPathComponent("AGENTS.md"))
        try write("# Notes\njust a top-level context doc with enough content here\n", to: root.appendingPathComponent("notes.md"))
        try write("# Foo skill\nthe entry point manifest for the foo skill here\n", to: root.appendingPathComponent(".claude/skills/foo/SKILL.md"))
        try write("# Foo reference\na deeper reference doc for the foo skill here\n", to: root.appendingPathComponent(".claude/skills/foo/reference/deep.md"))
        try write("# Cmd\na slash command definition body goes right here now\n", to: root.appendingPathComponent(".claude/commands/do-thing.md"))
        try write("{\"k\":1}", to: root.appendingPathComponent(".claude/settings.json"))
        // A binary-ish asset inside the skill (NUL byte -> treated as asset).
        try write("PNG\u{0}\u{0}binary", to: root.appendingPathComponent(".claude/skills/foo/logo.png.md")) // .md ext but NUL content
        // Skipped tree.
        try write("ignored", to: root.appendingPathComponent(".git/config"))

        let sources = ContextSourceScanner().scan(root: root)
        func kind(_ suffix: String) -> RawSourceKind? {
            sources.first { $0.path.hasSuffix(suffix) }?.kind
        }
        XCTAssertEqual(kind("/CLAUDE.md"), .claudeMd)
        XCTAssertEqual(kind("/AGENTS.md"), .agentsMd)
        XCTAssertEqual(kind("/notes.md"), .contextDoc)
        XCTAssertEqual(kind("/foo/SKILL.md"), .skillManifest)
        XCTAssertEqual(kind("/reference/deep.md"), .skillReference)
        XCTAssertEqual(kind("/commands/do-thing.md"), .command)
        XCTAssertEqual(kind("/settings.json"), .settings)
        // NUL-content .md inside a skill downgrades to an asset.
        XCTAssertEqual(kind("/logo.png.md"), .skillAsset)
        // .git is never descended.
        XCTAssertFalse(sources.contains { $0.path.contains("/.git/") })

        // Skill attribution + title extraction.
        let manifest = sources.first { $0.path.hasSuffix("/foo/SKILL.md") }
        XCTAssertEqual(manifest?.skill, "foo")
        XCTAssertEqual(manifest?.title, "Foo skill")
        XCTAssertEqual(sources.first { $0.path.hasSuffix("/reference/deep.md") }?.skill, "foo")
    }

    func testScannerMissingRootIsEmptyNotCrash() {
        let ghost = URL(fileURLWithPath: "/nope/does/not/exist-\(UUID().uuidString)")
        XCTAssertTrue(ContextSourceScanner().scan(root: ghost).isEmpty)
    }

    func testScannerLineCountIgnoresTrailingNewline() throws {
        // Regression (QA finding): a trailing newline must not add a phantom line.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("line one is long enough here\nline two is long enough here\n",   // 2 lines, trailing \n
                  to: root.appendingPathComponent(".claude/skills/a/SKILL.md"))
        try write("only line no trailing newline here",                              // 1 line, no \n
                  to: root.appendingPathComponent(".claude/skills/b/SKILL.md"))
        let sources = ContextSourceScanner().scan(root: root)
        XCTAssertEqual(sources.first { $0.path.hasSuffix("/a/SKILL.md") }?.lineCount, 2)
        XCTAssertEqual(sources.first { $0.path.hasSuffix("/b/SKILL.md") }?.lineCount, 1)
    }

    func testScannerFollowsSymlinkedSkillDirectories() throws {
        // Regression (QA finding): real ~/.claude/skills symlinks skill dirs; those
        // must be audited, not silently skipped. Paths stay under the audited tree.
        let root = try makeTempRoot()
        let target = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: target) }
        try write("# Linked\nthe linked skill manifest body long enough to count here\n",
                  to: target.appendingPathComponent("realskill/SKILL.md"))
        try write("# Normal\nthe normal skill manifest body long enough to count here\n",
                  to: root.appendingPathComponent(".claude/skills/normalskill/SKILL.md"))
        let skillsDir = root.appendingPathComponent(".claude/skills")
        try FileManager.default.createSymbolicLink(
            at: skillsDir.appendingPathComponent("linkedskill"),
            withDestinationURL: target.appendingPathComponent("realskill"))

        let skills = Set(ContextSourceScanner().scan(root: root).compactMap(\.skill))
        XCTAssertTrue(skills.contains("linkedskill"), "a symlinked skill directory must be followed")
        XCTAssertTrue(skills.contains("normalskill"))
    }

    func testScannerSurvivesSymlinkCycle() throws {
        // The cycle guard must stop a symlink loop (a child linking to an ancestor)
        // from hanging, while still finding the real files. If it hangs, this test
        // times out — which is the assertion.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let skills = root.appendingPathComponent(".claude/skills")
        try write("# A\nthe A skill manifest body that is long enough to count here\n",
                  to: skills.appendingPathComponent("a/SKILL.md"))
        try FileManager.default.createSymbolicLink(
            at: skills.appendingPathComponent("a/loop"), withDestinationURL: skills)

        let sources = ContextSourceScanner().scan(root: root)
        XCTAssertTrue(sources.contains { $0.path.hasSuffix("/a/SKILL.md") })
    }

    // MARK: - Metrics / duplicate detection

    func testDuplicateBlockAcrossTwoFiles() {
        let a = RawSource(path: "/a.md", kind: .skillManifest, byteCount: 200, lineCount: 4, isText: true, isProse: true)
        let b = RawSource(path: "/b.md", kind: .skillManifest, byteCount: 200, lineCount: 4, isText: true, isProse: true)
        let shared = """
        This is a genuinely shared rule about never using em dashes anywhere.
        And a second shared line that is also clearly long enough to count here.
        """
        let contentA = "# A heading unique to file a\n" + shared + "\nunique tail line for a that is long enough to be significant here\n"
        let contentB = "# B heading unique to file b\n" + shared + "\nunique tail line for b that is long enough to be significant here\n"
        let store = [a.path: contentA, b.path: contentB]

        let metrics = ContextMetrics().compute(sources: [a, b]) { store[$0.path] }
        XCTAssertEqual(metrics.proseSources, 2)
        // Exactly one 2-line block shared across both files.
        let block = metrics.duplicateBlocks.first { $0.occurrences == ["/a.md", "/b.md"] }
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.lineSpan, 2)
        XCTAssertEqual(block?.reclaimableLines, 2)  // span(2) * (2 files - 1)
    }

    func testShortAndStructuralLinesAreNotCountedAsDuplication() {
        let a = RawSource(path: "/a.md", kind: .contextDoc, byteCount: 40, lineCount: 3, isText: true, isProse: true)
        let b = RawSource(path: "/b.md", kind: .contextDoc, byteCount: 40, lineCount: 3, isText: true, isProse: true)
        // Both share only trivia: a short line, a heading, a ruler.
        let trivia = "## Usage\n---\n- ok\n"
        let store = [a.path: trivia, b.path: trivia]
        let metrics = ContextMetrics().compute(sources: [a, b]) { store[$0.path] }
        XCTAssertTrue(metrics.duplicateBlocks.isEmpty, "short/structural lines must not register as duplication")
    }

    func testMetricTotalsAndAssetBytes() {
        let text = RawSource(path: "/t.md", kind: .contextDoc, byteCount: 100, lineCount: 10, isText: true, isProse: true)
        let asset = RawSource(path: "/img.png", kind: .skillAsset, skill: "s", byteCount: 5000, lineCount: 0, isText: false)
        let metrics = ContextMetrics().compute(sources: [text, asset]) { _ in "line one is long enough\nline two is long enough\n" }
        XCTAssertEqual(metrics.totalSources, 2)
        XCTAssertEqual(metrics.proseSources, 1)
        XCTAssertEqual(metrics.nonContextBytes, 5000)
        XCTAssertEqual(metrics.totalProseLines, 10)
    }

    // MARK: - Consolidator

    func testConsolidatorBuildsWikiWithCanonicalHome() {
        let manifest = RawSource(path: "/skills/x/SKILL.md", kind: .skillManifest, skill: "x", byteCount: 10, lineCount: 2, isText: true, isProse: true)
        let reference = RawSource(path: "/skills/x/reference/long-detail.md", kind: .skillReference, skill: "x", byteCount: 10, lineCount: 2, isText: true, isProse: true)
        let metrics = SourceMetrics(
            totalSources: 2, proseSources: 2, totalBytes: 20, totalProseLines: 4, nonContextBytes: 0,
            largestProseSources: [],
            duplicateBlocks: [DuplicateBlock(excerpt: "a shared duplicated rule sentence here", lineSpan: 1, occurrences: [manifest.path, reference.path])]
        )
        let wiki = WikiConsolidator().buildWiki(sources: [manifest, reference], metrics: metrics, surveys: [])
        let topic = wiki.first { $0.isDuplicated }
        XCTAssertNotNil(topic)
        // SKILL.md (manifest, rank 2) beats a reference doc (rank 5) as the home.
        XCTAssertEqual(topic?.canonicalHome, manifest.path)
        XCTAssertEqual(topic?.appearsIn.count, 2)
    }

    func testConsolidatorEmitsExtractSharedNeedingSignoff() {
        let a = RawSource(path: "/a/SKILL.md", kind: .skillManifest, skill: "a", byteCount: 10, lineCount: 60, isText: true, isProse: true)
        let b = RawSource(path: "/b/SKILL.md", kind: .skillManifest, skill: "b", byteCount: 10, lineCount: 60, isText: true, isProse: true)
        let metrics = SourceMetrics(
            totalSources: 2, proseSources: 2, totalBytes: 20, totalProseLines: 120, nonContextBytes: 0,
            largestProseSources: [],
            duplicateBlocks: [DuplicateBlock(excerpt: "shared brand rule block", lineSpan: 45, occurrences: [a.path, b.path])]
        )
        let recs = WikiConsolidator().recommendations(sources: [a, b], metrics: metrics, surveys: [])
        let extract = recs.first { $0.kind == .extractShared }
        XCTAssertNotNil(extract)
        XCTAssertTrue(extract!.requiresSignoff)
        XCTAssertEqual(extract!.severity, .major)         // 45 reclaimable >= 40
        XCTAssertEqual(extract!.estLinesSaved, 45)
        // Schema rules are advisory and never require sign-off.
        let schema = recs.first { $0.kind == .schemaRule }
        XCTAssertNotNil(schema)
        XCTAssertFalse(schema!.requiresSignoff)
    }

    func testConsolidatorFlagsOversizeAndAssets() {
        let big = RawSource(path: "/skills/z/SKILL.md", kind: .skillManifest, skill: "z", byteCount: 9000, lineCount: 400, isText: true, isProse: true)
        let asset = RawSource(path: "/skills/z/big.png", kind: .skillAsset, skill: "z", byteCount: 900 * 1024, lineCount: 0, isText: false)
        let metrics = SourceMetrics(totalSources: 2, proseSources: 1, totalBytes: 900 * 1024 + 9000, totalProseLines: 400, nonContextBytes: 900 * 1024, largestProseSources: [big], duplicateBlocks: [])
        let recs = WikiConsolidator(skillManifestLineBudget: 150).recommendations(sources: [big, asset], metrics: metrics, surveys: [])
        XCTAssertTrue(recs.contains { $0.kind == .split && $0.affectedPaths == [big.path] })
        let prune = recs.first { $0.kind == .prune }
        XCTAssertNotNil(prune)
        XCTAssertEqual(prune?.estBytesSaved, 900 * 1024)
        XCTAssertTrue(prune!.requiresSignoff)
    }

    func testSchemaMentionsOneFactOneHome() {
        let schema = WikiConsolidator().generateSchema(root: "/proj", sources: [], metrics: SourceMetrics(totalSources: 0, proseSources: 0, totalBytes: 0, totalProseLines: 0, nonContextBytes: 0, largestProseSources: [], duplicateBlocks: []))
        XCTAssertTrue(schema.contains("One fact, one home"))
        XCTAssertTrue(schema.contains("Size budgets"))
    }

    // MARK: - Steward

    func testStewardPrecedence() {
        let steward = ContextWikiSteward(maxAuditAge: 100, minAuditInterval: 10)
        let now = Date(timeIntervalSince1970: 1_000_000)

        // Never audited -> reaudit.
        XCTAssertEqual(steward.assess(.init(lastAuditAt: nil, latestSourceModifiedAt: nil, lastSourceCount: 0, currentSourceCount: 0, now: now)),
                       .reaudit(reason: "no prior audit for this project — establishing a baseline."))

        // Within min interval -> upToDate even if a source changed.
        let recent = now.addingTimeInterval(-5)
        XCTAssertEqual(steward.assess(.init(lastAuditAt: recent, latestSourceModifiedAt: now, lastSourceCount: 3, currentSourceCount: 4, now: now)),
                       .upToDate)

        // Source count changed (past min interval) -> reaudit.
        let old = now.addingTimeInterval(-50)
        if case .reaudit = steward.assess(.init(lastAuditAt: old, latestSourceModifiedAt: nil, lastSourceCount: 3, currentSourceCount: 5, now: now)) {} else {
            XCTFail("count change should trigger reaudit")
        }

        // Source modified after last audit -> reaudit.
        if case .reaudit = steward.assess(.init(lastAuditAt: old, latestSourceModifiedAt: now.addingTimeInterval(-40), lastSourceCount: 3, currentSourceCount: 3, now: now)) {} else {
            XCTFail("content change should trigger reaudit")
        }

        // Nothing changed, within max age -> upToDate.
        XCTAssertEqual(steward.assess(.init(lastAuditAt: old, latestSourceModifiedAt: now.addingTimeInterval(-60), lastSourceCount: 3, currentSourceCount: 3, now: now)),
                       .upToDate)

        // Nothing changed but older than max age -> reaudit (periodic refresh).
        let ancient = now.addingTimeInterval(-200)
        if case .reaudit = steward.assess(.init(lastAuditAt: ancient, latestSourceModifiedAt: ancient, lastSourceCount: 3, currentSourceCount: 3, now: now)) {} else {
            XCTFail("stale audit should trigger periodic refresh")
        }
    }

    // MARK: - Survey parser

    func testSurveyorParsesJSONAmidProse() {
        let raw = """
        Sure, here is the survey:
        ```json
        {"purpose": "does a thing", "topics": ["a", "b"], "loadBearing": ["keep this"], "deadWeight": ["cut that"], "overlapsNotes": ["overlaps foo"], "bloatScore": 4}
        ```
        Hope that helps!
        """
        let survey = SourceSurveyor.parse(raw, path: "/x.md")
        XCTAssertNotNil(survey)
        XCTAssertEqual(survey?.purpose, "does a thing")
        XCTAssertEqual(survey?.topics, ["a", "b"])
        XCTAssertEqual(survey?.bloatScore, 4)
    }

    func testSurveyorParseRejectsGarbage() {
        XCTAssertNil(SourceSurveyor.parse("no json here at all", path: "/x.md"))
    }

    func testSurveyBloatScoreClamped() {
        let s = SourceSurvey(path: "/x", purpose: "", topics: [], loadBearing: [], deadWeight: [], overlapsNotes: [], bloatScore: 99)
        XCTAssertEqual(s.bloatScore, 5)
        let s2 = SourceSurvey(path: "/x", purpose: "", topics: [], loadBearing: [], deadWeight: [], overlapsNotes: [], bloatScore: -3)
        XCTAssertEqual(s2.bloatScore, 1)
    }

    // MARK: - End-to-end (deterministic) + persistence round-trip

    func testAuditEndToEndOverTempTree() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = """
        A shared cardinal rule that is definitely long enough to be counted here.
        A second shared cardinal line also long enough to be counted here now.
        A third shared cardinal line likewise long enough to be counted as well.

        """
        try write("# One\n" + shared, to: root.appendingPathComponent(".claude/skills/one/SKILL.md"))
        try write("# Two\n" + shared, to: root.appendingPathComponent(".claude/skills/two/SKILL.md"))

        let report = await ContextAuditor().audit(root: root, surveyor: nil, now: Date(timeIntervalSince1970: 42))
        XCTAssertFalse(report.usedLLM)
        XCTAssertEqual(report.metrics.proseSources, 2)
        XCTAssertFalse(report.metrics.duplicateBlocks.isEmpty)
        XCTAssertTrue(report.recommendations.contains { $0.kind == .extractShared })
        XCTAssertTrue(report.schema.contains("One fact, one home"))
        XCTAssertEqual(report.generatedAt, Date(timeIntervalSince1970: 42))

        // Persistence round-trip: report -> row -> report.
        let stored = try StoredContextAudit.from(report)
        XCTAssertEqual(stored.sourceCount, report.metrics.totalSources)
        let restored = stored.report()
        XCTAssertEqual(restored?.root, report.root)
        XCTAssertEqual(restored?.recommendations.count, report.recommendations.count)
    }

    func testContextAuditStorePersistsAndReads() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = ContextAuditStore(database: db)
        let report = AuditReport(
            root: "/proj", generatedAt: Date(timeIntervalSince1970: 100),
            sources: [], metrics: SourceMetrics(totalSources: 1, proseSources: 1, totalBytes: 10, totalProseLines: 5, nonContextBytes: 0, largestProseSources: [], duplicateBlocks: []),
            surveys: [], wiki: [], schema: "s",
            recommendations: [Recommendation(kind: .schemaRule, title: "t", rationale: "r", affectedPaths: [], risk: .low, severity: .info, requiresSignoff: false, origin: "consolidation")],
            usedLLM: false
        )
        try store.record(report)
        let latest = try store.latest(root: "/proj")
        XCTAssertEqual(latest?.root, "/proj")
        XCTAssertEqual(latest?.recommendationCount, 1)
        XCTAssertEqual(try store.history(root: "/proj").count, 1)
    }
}
