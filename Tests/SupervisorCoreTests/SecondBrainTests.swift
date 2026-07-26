// SecondBrainTests.swift — deterministic, no-network coverage for the Second
// Brain (iterative memory optimization).
//
// Everything here is pure or filesystem-only (synthetic JSONL transcript
// fixtures in temp dirs): the distiller's deterministic extraction and its
// redaction guarantee, the optimizer's merge/confirm/retire rules and its
// idempotence, the renderer's sections/provenance/iteration log, the surveyor's
// lenient JSON parser, and the store round-trip. No LLM is ever called.

import XCTest
@testable import SupervisorCore

final class SecondBrainTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Create a throwaway directory; caller writes files into it.
    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a synthetic transcript for `root` into the projects-dir layout the
    /// distiller reads (`<projectsDir>/<munged-root>/<sessionId>.jsonl`).
    private func writeTranscript(
        projectsDir: URL,
        root: URL,
        sessionId: String,
        lines: [String]
    ) throws {
        let dir = projectsDir.appendingPathComponent(
            MemoryDistiller.mungedDirectoryName(forRoot: root.path), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: dir.appendingPathComponent("\(sessionId).jsonl"), atomically: true, encoding: .utf8)
    }

    private func jsonLine(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private func userLine(_ text: String, ts: String, meta: Bool = false, sidechain: Bool = false, cwd: String? = nil) -> String {
        var obj: [String: Any] = [
            "type": "user",
            "timestamp": ts,
            "message": ["role": "user", "content": text],
        ]
        if meta { obj["isMeta"] = true }
        if sidechain { obj["isSidechain"] = true }
        if let cwd { obj["cwd"] = cwd }
        return jsonLine(obj)
    }

    private func assistantLine(ts: String, sidechain: Bool = false) -> String {
        var obj: [String: Any] = [
            "type": "assistant",
            "timestamp": ts,
            "message": ["role": "assistant", "content": [["type": "text", "text": "done — I made the change"]]],
        ]
        if sidechain { obj["isSidechain"] = true }
        return jsonLine(obj)
    }

    private func candidate(
        _ kind: MemoryEntryKind,
        _ text: String,
        session: String = "sess-1",
        ts: TimeInterval = 100
    ) -> MemoryCandidate {
        MemoryCandidate(
            kind: kind, text: text, sessionId: session,
            timestamp: Date(timeIntervalSince1970: ts),
            excerptHash: "h"
        )
    }

    // MARK: - Distiller

    func testDistillerExtractsCorrectionDecisionAndPreference() async throws {
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-a", lines: [
            userLine("Build the storage layer for me please", ts: "2026-07-16T10:00:00.000Z"),
            assistantLine(ts: "2026-07-16T10:00:05.000Z"),
            userLine("No, don't use tabs in this repo — use spaces for indentation.", ts: "2026-07-16T10:01:00.000Z"),
            assistantLine(ts: "2026-07-16T10:01:05.000Z"),
            userLine("Let's use GRDB for all persistence in this project.", ts: "2026-07-16T10:02:00.000Z"),
            assistantLine(ts: "2026-07-16T10:02:05.000Z"),
            userLine("I prefer small focused functions over long ones here.", ts: "2026-07-16T10:03:00.000Z"),
        ])

        let distiller = MemoryDistiller(projectsDir: projects)
        let candidates = await distiller.distill(root: root)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates.map(\.kind), [.correction, .decision, .preference])
        XCTAssertTrue(candidates[0].text.contains("don't use tabs"))
        XCTAssertTrue(candidates[1].text.contains("GRDB"))
        XCTAssertEqual(candidates.map(\.sessionId), ["sess-a", "sess-a", "sess-a"])
        // liveSessionIds sees the same transcript.
        XCTAssertEqual(distiller.liveSessionIds(root: root), ["sess-a"])
    }

    func testDistillerCorrectionRequiresPrecedingAssistantAction() async throws {
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        // A "no, ..." OPENING message corrects nothing — no assistant acted yet.
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-b", lines: [
            userLine("No, don't touch the release branch for this work.", ts: "2026-07-16T10:00:00.000Z"),
        ])
        let candidates = await MemoryDistiller(projectsDir: projects).distill(root: root)
        XCTAssertFalse(candidates.contains { $0.kind == .correction })
    }

    func testDistillerSkipsMachineryMetaAndSidechainText() async throws {
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-c", lines: [
            assistantLine(ts: "2026-07-16T10:00:00.000Z"),
            userLine("<command-name>/compact</command-name>", ts: "2026-07-16T10:01:00.000Z"),
            userLine("Actually we should always run the linter first.", ts: "2026-07-16T10:02:00.000Z", meta: true),
            userLine("No, don't do that in the subagent.", ts: "2026-07-16T10:03:00.000Z", sidechain: true),
            // A tool_result-only user turn is machinery, not owner text.
            jsonLine([
                "type": "user",
                "timestamp": "2026-07-16T10:04:00.000Z",
                "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "we should always do X"]]],
            ]),
        ])
        let candidates = await MemoryDistiller(projectsDir: projects).distill(root: root)
        XCTAssertTrue(candidates.isEmpty, "machinery/meta/sidechain text must never become a memory")
    }

    func testDistillerRedactsSecretsBeforeAnyCandidateExists() async throws {
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-d", lines: [
            assistantLine(ts: "2026-07-16T10:00:00.000Z"),
            userLine(
                "No, don't hardcode sk-ant-api03-FAKEFAKE1234567890 in the config — read the token from the environment.",
                ts: "2026-07-16T10:01:00.000Z"
            ),
        ])
        let candidates = await MemoryDistiller(projectsDir: projects).distill(root: root)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertFalse(candidates[0].text.contains("sk-ant-"), "a planted key must never reach an entry")
        XCTAssertTrue(candidates[0].text.contains("<redacted:anthropic-key>"))
    }

    func testDistillerMissingProjectDirIsEmptyNotCrash() async {
        let ghost = URL(fileURLWithPath: "/nope/does/not/exist-\(UUID().uuidString)")
        let distiller = MemoryDistiller(projectsDir: ghost)
        let candidates = await distiller.distill(root: ghost)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertNil(distiller.liveSessionIds(root: ghost))
    }

    func testLiveSessionIdsDistinguishesUnknownFromEmpty() async throws {
        // A missing/unreadable projects dir is ABSENCE of evidence — nil, so
        // the optimizer never staleness-retires off a read failure (an empty
        // set here would read as "every source session is gone" and wipe the
        // brain after enough runs).
        let ghost = URL(fileURLWithPath: "/nope/does/not/exist-\(UUID().uuidString)")
        XCTAssertNil(MemoryDistiller(projectsDir: ghost).liveSessionIds(root: ghost))

        // An existing but EMPTY munged dir IS positive evidence: empty set.
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        let munged = projects.appendingPathComponent(
            MemoryDistiller.mungedDirectoryName(forRoot: root.path), isDirectory: true)
        try FileManager.default.createDirectory(at: munged, withIntermediateDirectories: true)
        XCTAssertEqual(MemoryDistiller(projectsDir: projects).liveSessionIds(root: root), [])
    }

    func testSnapshotMatchesSeparateCallsInOneWalk() async throws {
        // snapshot(root:) must be semantically identical to distill(root:) +
        // liveSessionIds(root:) — it exists so the DevTools flow walks the
        // projects dir once instead of twice (issue #54), not to change
        // behavior. Includes the nil-vs-empty evidence distinction.
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-a", lines: [
            userLine("Build the storage layer for me please", ts: "2026-07-16T10:00:00.000Z"),
            assistantLine(ts: "2026-07-16T10:00:05.000Z"),
            userLine("No, don't use tabs in this repo — use spaces.", ts: "2026-07-16T10:01:00.000Z"),
        ])

        let distiller = MemoryDistiller(projectsDir: projects)
        let snapshot = await distiller.snapshot(root: root)
        let separate = await distiller.distill(root: root)
        XCTAssertEqual(snapshot.candidates, separate)
        XCTAssertEqual(snapshot.liveSessionIds, distiller.liveSessionIds(root: root))
        XCTAssertEqual(snapshot.liveSessionIds, ["sess-a"])

        // Missing projects dir: no candidates, live-session evidence UNKNOWN.
        let ghost = URL(fileURLWithPath: "/nope/does/not/exist-\(UUID().uuidString)")
        let ghostSnapshot = await MemoryDistiller(projectsDir: ghost).snapshot(root: root)
        XCTAssertTrue(ghostSnapshot.candidates.isEmpty)
        XCTAssertNil(ghostSnapshot.liveSessionIds)
    }

    func testMungedDirectoryName() {
        XCTAssertEqual(MemoryDistiller.mungedDirectoryName(forRoot: "/Users/main/my_proj.x"),
                       "-Users-main-my-proj-x")
        XCTAssertEqual(MemoryDistiller.mungedDirectoryName(forRoot: "/Users/main"), "-Users-main")
        // Claude Code's munge is ASCII-only: non-ASCII letters ('é', CJK)
        // become '-' too, so the Swift side must not preserve them.
        XCTAssertEqual(MemoryDistiller.mungedDirectoryName(forRoot: "/Users/mainé/proj-日本"),
                       "-Users-main--proj---")
    }

    func testDistillerSkipsForeignCwdTranscriptInSameMungedDir() async throws {
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        // A sibling project whose path munges to the SAME directory name (the
        // munge is lossy: '-' and '_' both become '-').
        let sibling = root.path.replacingOccurrences(of: "sb-root", with: "sb_root")
        XCTAssertEqual(MemoryDistiller.mungedDirectoryName(forRoot: sibling),
                       MemoryDistiller.mungedDirectoryName(forRoot: root.path))

        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-ours", lines: [
            assistantLine(ts: "2026-07-16T10:00:00.000Z"),
            userLine("No, don't use tabs in this repo — use spaces.", ts: "2026-07-16T10:01:00.000Z", cwd: root.path),
        ])
        // The foreign transcript lands in the same munged dir but records the
        // sibling's cwd — its corrections must not contaminate this root.
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-foreign", lines: [
            assistantLine(ts: "2026-07-16T10:02:00.000Z"),
            userLine("No, don't gate merges on CI in this project.", ts: "2026-07-16T10:03:00.000Z", cwd: sibling),
        ])
        // No cwd record at all: kept — benefit of the doubt (matches the
        // Python twin's fallback).
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-nocwd", lines: [
            assistantLine(ts: "2026-07-16T10:04:00.000Z"),
            userLine("We should always run swiftformat before committing.", ts: "2026-07-16T10:05:00.000Z"),
        ])

        let distiller = MemoryDistiller(projectsDir: projects)
        let candidates = await distiller.distill(root: root)
        XCTAssertEqual(Set(candidates.map(\.sessionId)), ["sess-ours", "sess-nocwd"])
        XCTAssertEqual(distiller.liveSessionIds(root: root), ["sess-ours", "sess-nocwd"])
    }

    func testSidechainAssistantTurnDoesNotEnableCorrectionGating() async throws {
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        // The only assistant activity between the two user messages is a
        // SIDECHAIN (subagent) turn — it must not count as "assistant acted",
        // so the "no, ..." that follows corrects nothing.
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-sc", lines: [
            userLine("Please plan the storage work first", ts: "2026-07-16T10:00:00.000Z"),
            assistantLine(ts: "2026-07-16T10:00:05.000Z", sidechain: true),
            userLine("No, don't touch the storage layer yet.", ts: "2026-07-16T10:01:00.000Z"),
        ])
        let candidates = await MemoryDistiller(projectsDir: projects).distill(root: root)
        XCTAssertFalse(candidates.contains { $0.kind == .correction },
                       "a sidechain assistant turn must not enable correction classification")
    }

    func testCorrectionCuesRequireWordBoundary() async throws {
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-wb", lines: [
            assistantLine(ts: "2026-07-16T10:00:00.000Z"),
            // Opens with "stop..." but the cue is not on a word boundary — a
            // sign-off, not a durable correction.
            userLine("Stopping here for today, we can pick this up tomorrow.", ts: "2026-07-16T10:01:00.000Z"),
            assistantLine(ts: "2026-07-16T10:01:05.000Z"),
            userLine("Stop deleting that file, it is generated on purpose.", ts: "2026-07-16T10:02:00.000Z"),
        ])
        let candidates = await MemoryDistiller(projectsDir: projects).distill(root: root)
        XCTAssertEqual(candidates.count, 1, "'stopping here for today...' must not become a correction")
        XCTAssertEqual(candidates.first?.kind, .correction)
        XCTAssertTrue(candidates.first?.text.contains("Stop deleting that file") == true)
    }

    // MARK: - Models

    func testEntryIdStableAcrossWhitespaceAndCase() {
        XCTAssertEqual(
            MemoryEntry.makeID(kind: .decision, text: "Use  GRDB\nfor storage"),
            MemoryEntry.makeID(kind: .decision, text: "use grdb for storage")
        )
        XCTAssertNotEqual(
            MemoryEntry.makeID(kind: .decision, text: "use grdb for storage"),
            MemoryEntry.makeID(kind: .preference, text: "use grdb for storage"),
            "the same text under a different kind is a different fact"
        )
    }

    func testCandidateTextCapped() {
        let long = String(repeating: "a", count: 1_000)
        XCTAssertEqual(candidate(.decision, long).text.count, MemoryEntry.textCap)
    }

    func testMemoryEntryKindRawValuesPinTheCrossTwinContract() {
        // The raw values ARE the contract shared with the Python skill twin
        // and its curation rubric (snake_case) — a renamed case must not be
        // able to drift the serialized vocabulary.
        XCTAssertEqual(
            Set(MemoryEntryKind.allCases.map(\.rawValue)),
            ["decision", "correction", "environment_fact", "gotcha", "preference"]
        )
    }

    // MARK: - Optimizer

    func testOptimizerAddsThenConfirmsIdempotently() {
        let optimizer = SecondBrainOptimizer()
        let candidates = [
            candidate(.correction, "don't use tabs in this repo, use spaces", ts: 100),
            candidate(.decision, "let's use GRDB for all persistence here", ts: 200),
        ]
        let now = Date(timeIntervalSince1970: 1_000)

        let (first, delta1) = optimizer.optimize(
            ledger: .empty(root: "/proj"), candidates: candidates, now: now)
        XCTAssertEqual(delta1.iteration, 1)
        XCTAssertEqual(delta1.added, 2)
        XCTAssertEqual(delta1.confirmed, 0)
        XCTAssertEqual(delta1.activeTotal, 2)
        XCTAssertTrue(first.activeEntries.allSatisfy { $0.confidence == .low })
        XCTAssertEqual(first.updatedAt, now)

        // Idempotence: the same inputs again add/merge NOTHING — they confirm.
        let (second, delta2) = optimizer.optimize(
            ledger: first, candidates: candidates, now: now)
        XCTAssertEqual(delta2.iteration, 2)
        XCTAssertEqual(delta2.added, 0)
        XCTAssertEqual(delta2.merged, 0)
        XCTAssertEqual(delta2.confirmed, 2)
        XCTAssertEqual(delta2.activeTotal, 2)
        XCTAssertEqual(second.entries.count, 2)
        XCTAssertTrue(second.activeEntries.allSatisfy { $0.confidence == .medium })
        XCTAssertTrue(second.activeEntries.allSatisfy { $0.lastConfirmedIteration == 2 })
        XCTAssertTrue(second.activeEntries.allSatisfy { $0.firstSeenIteration == 1 })
    }

    func testOptimizerMergesRicherNearDuplicateThenConfirmsOnRerun() {
        let optimizer = SecondBrainOptimizer()
        let short = candidate(.decision, "always use spaces for indentation")
        let rich = candidate(.decision, "always use spaces for indentation in swift files too")

        let (l1, _) = optimizer.optimize(ledger: .empty(root: "/proj"), candidates: [short])
        let (l2, d2) = optimizer.optimize(ledger: l1, candidates: [rich])
        XCTAssertEqual(d2.merged, 1)
        XCTAssertEqual(d2.added, 0)
        XCTAssertEqual(d2.activeTotal, 1)
        // The richer text won; the absorbed entry is kept as history.
        let active = l2.activeEntries
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0].text, rich.text)
        XCTAssertEqual(active[0].firstSeenIteration, 1, "origin iteration survives the merge")
        XCTAssertTrue(active[0].mergedIDs.contains(short.id))
        XCTAssertTrue(l2.entries.contains { $0.status == .merged && $0.text == short.text })

        // Re-run with the same rich candidate: confirm, not re-merge.
        let (_, d3) = optimizer.optimize(ledger: l2, candidates: [rich])
        XCTAssertEqual(d3.merged, 0)
        XCTAssertEqual(d3.added, 0)
        XCTAssertEqual(d3.confirmed, 1)
    }

    func testOptimizerAbsorbsShorterNearDuplicateThenConfirmsOnRerun() {
        let optimizer = SecondBrainOptimizer()
        let rich = candidate(.decision, "always use spaces for indentation in swift files")
        let short = candidate(.decision, "always use spaces for indentation")

        let (l1, _) = optimizer.optimize(ledger: .empty(root: "/proj"), candidates: [rich])
        let (l2, d2) = optimizer.optimize(ledger: l1, candidates: [short])
        XCTAssertEqual(d2.merged, 1)
        XCTAssertEqual(d2.added, 0)
        let entry = l2.activeEntries[0]
        XCTAssertEqual(entry.text, rich.text, "the richer existing text stays canonical")
        XCTAssertTrue(entry.mergedIDs.contains(short.id))
        XCTAssertEqual(entry.lastConfirmedIteration, 2)

        // The absorbed alias id now CONFIRMS on a re-run.
        let (_, d3) = optimizer.optimize(ledger: l2, candidates: [short])
        XCTAssertEqual(d3.merged, 0)
        XCTAssertEqual(d3.confirmed, 1)
    }

    func testOptimizerBumpsConfidenceAtMostOncePerIteration() {
        let optimizer = SecondBrainOptimizer()
        let exact = candidate(.decision, "always use spaces for indentation", ts: 100)
        let richer = candidate(.decision, "always use spaces for indentation in swift files too", ts: 200)

        // One batch re-observing the SAME fact twice (exact id match + a
        // contained richer variant): confidence rises exactly ONE step.
        let (l1, _) = optimizer.optimize(ledger: .empty(root: "/proj"), candidates: [exact])
        XCTAssertEqual(l1.activeEntries[0].confidence, .low)
        let (l2, d2) = optimizer.optimize(ledger: l1, candidates: [exact, richer])
        XCTAssertEqual(d2.confirmed, 1)
        XCTAssertEqual(d2.merged, 1)
        XCTAssertEqual(l2.activeEntries.count, 1)
        XCTAssertEqual(l2.activeEntries[0].confidence, .medium,
                       "confirm + merge of one entry in one batch is a single confidence step")

        // Same shape in the absorb direction (the existing entry is richer).
        let (m1, _) = optimizer.optimize(ledger: .empty(root: "/proj"), candidates: [richer])
        let (m2, dm2) = optimizer.optimize(ledger: m1, candidates: [exact, richer])
        XCTAssertEqual(dm2.confirmed, 1)
        XCTAssertEqual(dm2.merged, 1)
        XCTAssertEqual(m2.activeEntries.count, 1)
        XCTAssertEqual(m2.activeEntries[0].confidence, .medium,
                       "absorb + confirm of one entry in one batch is a single confidence step")
    }

    func testOptimizerCorrectionContradictsAndRetiresOldBelief() {
        let optimizer = SecondBrainOptimizer()
        let belief = candidate(.decision, "use tabs for indentation everywhere in this repo")
        let (l1, _) = optimizer.optimize(ledger: .empty(root: "/proj"), candidates: [belief])

        let correction = candidate(
            .correction,
            "no, don't use tabs for indentation everywhere in this repo — use spaces instead"
        )
        let (l2, d2) = optimizer.optimize(ledger: l1, candidates: [correction])
        XCTAssertEqual(d2.retired, 1)
        XCTAssertEqual(d2.added, 1)
        XCTAssertEqual(d2.activeTotal, 1)
        XCTAssertTrue(l2.entries.contains { $0.status == .retired && $0.kind == .decision })
        XCTAssertEqual(l2.activeEntries[0].kind, .correction)

        // The retired belief must NOT resurrect when the old transcript line is
        // re-distilled alongside the correction on the next run.
        let (l3, d3) = optimizer.optimize(ledger: l2, candidates: [belief, correction])
        XCTAssertEqual(d3.added, 0)
        XCTAssertEqual(d3.retired, 0)
        XCTAssertEqual(d3.confirmed, 1)
        XCTAssertEqual(l3.activeEntries.count, 1)
        XCTAssertEqual(l3.activeEntries[0].kind, .correction)
    }

    func testOptimizerRetiresStaleEntryOnlyWhenSessionGone() {
        // N=2 so the test doesn't need six iterations.
        let optimizer = SecondBrainOptimizer(retireAfterUnconfirmedIterations: 2)
        let (l1, _) = optimizer.optimize(
            ledger: .empty(root: "/proj"),
            candidates: [candidate(.decision, "we should gate merges on green CI", session: "gone-sess")]
        )

        // Iteration 2: only one iteration unconfirmed — kept even though gone.
        let (l2, d2) = optimizer.optimize(ledger: l1, candidates: [], liveSessionIds: [])
        XCTAssertEqual(d2.retired, 0)
        // Iteration 3: two iterations unconfirmed AND the source session is
        // gone — retired.
        let (l3, d3) = optimizer.optimize(ledger: l2, candidates: [], liveSessionIds: [])
        XCTAssertEqual(d3.retired, 1)
        XCTAssertEqual(d3.activeTotal, 0)
        XCTAssertTrue(l3.entries.allSatisfy { $0.status == .retired })

        // Same staleness but the session still exists -> merely dormant, kept.
        let (l2b, _) = optimizer.optimize(ledger: l1, candidates: [], liveSessionIds: ["gone-sess"])
        let (_, d3b) = optimizer.optimize(ledger: l2b, candidates: [], liveSessionIds: ["gone-sess"])
        XCTAssertEqual(d3b.retired, 0)

        // Unknown live set (nil) never retires on staleness alone.
        let (l2c, _) = optimizer.optimize(ledger: l1, candidates: [])
        let (_, d3c) = optimizer.optimize(ledger: l2c, candidates: [])
        XCTAssertEqual(d3c.retired, 0)
    }

    func testOptimizerCarriesDriftNoteFromPriorReport() {
        let report = AuditReport(
            root: "/proj", generatedAt: Date(timeIntervalSince1970: 50),
            sources: [],
            metrics: SourceMetrics(totalSources: 1, proseSources: 1, totalBytes: 10, totalProseLines: 5, nonContextBytes: 0, largestProseSources: [], duplicateBlocks: []),
            surveys: [], wiki: [], schema: "s", recommendations: [], usedLLM: false
        )
        let (ledger, delta) = SecondBrainOptimizer().optimize(
            ledger: .empty(root: "/proj"), candidates: [], priorReport: report)
        XCTAssertNotNil(delta.contextDriftNote)
        XCTAssertEqual(ledger.recentDeltas.last?.contextDriftNote, delta.contextDriftNote)
    }

    func testLedgerDeltaHistoryIsCapped() {
        let optimizer = SecondBrainOptimizer()
        var ledger = MemoryLedger.empty(root: "/proj")
        for _ in 0..<(MemoryLedger.deltaHistoryCap + 5) {
            (ledger, _) = optimizer.optimize(ledger: ledger, candidates: [])
        }
        XCTAssertEqual(ledger.recentDeltas.count, MemoryLedger.deltaHistoryCap)
        XCTAssertEqual(ledger.recentDeltas.last?.iteration, ledger.iteration)
    }

    // MARK: - Surveyor parser

    func testSurveyorParsesJSONAmidProse() {
        let original = [
            candidate(.decision, "let's use GRDB for storage"),
            candidate(.decision, "some transient chatter about nothing"),
        ]
        let raw = """
        Here are the durable facts:
        ```json
        [{"index": 0, "kind": "decision", "text": "Use GRDB for all persistence."}]
        ```
        """
        let refined = MemorySurveyor.parse(raw, original: original)
        XCTAssertEqual(refined?.count, 1)
        XCTAssertEqual(refined?[0].text, "Use GRDB for all persistence.")
        // Provenance always comes from the original candidate.
        XCTAssertEqual(refined?[0].sessionId, original[0].sessionId)
        XCTAssertEqual(refined?[0].excerptHash, original[0].excerptHash)
    }

    func testSurveyorParseToleratesBadKindAndIndex() {
        let original = [candidate(.correction, "don't shell out to git directly")]
        let raw = """
        [{"index": 0, "kind": "banana", "text": "Do not shell out to git directly."},
         {"index": 7, "kind": "decision", "text": "phantom"}]
        """
        let refined = MemorySurveyor.parse(raw, original: original)
        XCTAssertEqual(refined?.count, 1)
        XCTAssertEqual(refined?[0].kind, .correction, "an unknown kind keeps the original's")
    }

    func testSurveyorParseRejectsGarbage() {
        XCTAssertNil(MemorySurveyor.parse("no json here at all", original: []))
    }

    // MARK: - Renderer

    private func sampleLedger() -> MemoryLedger {
        let ts = Date(timeIntervalSince1970: 1_752_600_000)
        var ledger = MemoryLedger.empty(root: "/proj")
        ledger.iteration = 2
        ledger.updatedAt = ts
        ledger.entries = [
            MemoryEntry(
                id: MemoryEntry.makeID(kind: .decision, text: "let's use GRDB for all persistence"),
                kind: .decision, text: "let's use GRDB for all persistence",
                provenance: MemoryProvenance(sessionId: "sess-abcdef123", timestamp: ts, excerptHash: "abc123"),
                confidence: .high, firstSeenIteration: 1, lastConfirmedIteration: 2
            ),
            MemoryEntry(
                id: MemoryEntry.makeID(kind: .correction, text: "don't use tabs, use spaces"),
                kind: .correction, text: "don't use tabs, use spaces",
                provenance: MemoryProvenance(sessionId: "sess-abcdef123", timestamp: ts, excerptHash: "def456"),
                confidence: .medium, firstSeenIteration: 2, lastConfirmedIteration: 2
            ),
            MemoryEntry(
                id: MemoryEntry.makeID(kind: .decision, text: "use tabs everywhere"),
                kind: .decision, text: "use tabs everywhere",
                provenance: MemoryProvenance(sessionId: "sess-abcdef123", timestamp: ts, excerptHash: "old789"),
                status: .retired, confidence: .low, firstSeenIteration: 1, lastConfirmedIteration: 1
            ),
        ]
        ledger.recentDeltas = [
            IterationDelta(iteration: 1, added: 2, confirmed: 0, merged: 0, retired: 0, activeTotal: 2),
            IterationDelta(iteration: 2, added: 1, confirmed: 1, merged: 0, retired: 1, activeTotal: 2),
        ]
        return ledger
    }

    func testRenderBrainContainsSectionsProvenanceAndIterationLog() {
        let ledger = sampleLedger()
        let md = SecondBrainRenderer().renderBrain(ledger)
        XCTAssertTrue(md.contains("# Second Brain"))
        XCTAssertTrue(md.contains("## Decisions"))
        XCTAssertTrue(md.contains("## Corrections"))
        XCTAssertTrue(md.contains("let's use GRDB for all persistence"))
        XCTAssertTrue(md.contains("confidence: high"))
        XCTAssertTrue(md.contains("session `sess-abc"))
        XCTAssertTrue(md.contains("excerpt abc123"))
        // Retired history is present but collapsed.
        XCTAssertTrue(md.contains("## Retired"))
        XCTAssertTrue(md.contains("<details>"))
        XCTAssertTrue(md.contains("use tabs everywhere"))
        // Iteration log table with both deltas.
        XCTAssertTrue(md.contains("## Iteration log"))
        XCTAssertTrue(md.contains("| Iteration | Added | Confirmed | Merged | Retired | Active |"))
        XCTAssertTrue(md.contains("| 2 | 1 | 1 | 0 | 1 | 2 |"))
        // The local-ownership promise is stated in the header.
        XCTAssertTrue(md.contains("only on this machine"))
    }

    func testRenderBrainEmptyLedger() {
        let md = SecondBrainRenderer().renderBrain(.empty(root: "/proj"))
        XCTAssertTrue(md.contains("No entries yet"))
        XCTAssertFalse(md.contains("## Retired"))
    }

    func testWriteArtifactsWritesBrainAndLedgerJSON() throws {
        let out = try makeTempDir("sb-out")
        defer { try? FileManager.default.removeItem(at: out) }
        let ledger = sampleLedger()
        let written = try SecondBrainRenderer().writeArtifacts(ledger, to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.brainPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.ledgerJSONPath.path))
        // The JSON twin round-trips.
        let data = try Data(contentsOf: written.ledgerJSONPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(MemoryLedger.self, from: data)
        XCTAssertEqual(restored.root, ledger.root)
        XCTAssertEqual(restored.entries.count, ledger.entries.count)
    }

    // MARK: - Coordinator

    func testCoordinatorDryRunResumesButWritesNothing() async throws {
        // The honest-iteration rule: a dry preview READS the prior persisted
        // ledger (so its iteration number is real) but writes no artifacts
        // and records no row.
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        let db = try SupervisorDatabase.inMemory()
        let store = MemoryLedgerStore(database: db)
        let (l1, d1) = SecondBrainOptimizer().optimize(
            ledger: .empty(root: root.path),
            candidates: [candidate(.decision, "let's use GRDB for all persistence here")],
            now: Date(timeIntervalSince1970: 100)
        )
        try store.record(l1, delta: d1)

        let coordinator = SecondBrainCoordinator(distiller: MemoryDistiller(projectsDir: projects))
        let result = try await coordinator.runIteration(
            root: root, database: db, persistToDatabase: false, artifactsDir: nil,
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(result.resumedFromIteration, l1.iteration)
        XCTAssertEqual(result.resumedActiveEntryCount, l1.activeEntries.count)
        XCTAssertEqual(result.ledger.iteration, l1.iteration + 1)
        XCTAssertNil(result.artifactPaths)
        XCTAssertNil(result.persistedRowID)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(try store.history(root: root.path).count, 1, "dry run must not record a row")
    }

    func testCoordinatorPersistWritesArtifactsAndRow() async throws {
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        let out = try makeTempDir("sb-out")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: out)
        }
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-a", lines: [
            assistantLine(ts: "2026-07-16T10:00:00.000Z"),
            userLine("Let's use GRDB for all persistence in this project.", ts: "2026-07-16T10:01:00.000Z"),
        ])
        let db = try SupervisorDatabase.inMemory()

        let coordinator = SecondBrainCoordinator(distiller: MemoryDistiller(projectsDir: projects))
        let result = try await coordinator.runIteration(
            root: root, database: db, persistToDatabase: true, artifactsDir: out,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(result.resumedFromIteration)
        XCTAssertEqual(result.ledger.iteration, 1)
        XCTAssertEqual(result.delta.added, 1)
        let paths = try XCTUnwrap(result.artifactPaths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.brain.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.ledgerJSON.path))
        XCTAssertNotNil(result.persistedRowID)
        let stored = try XCTUnwrap(MemoryLedgerStore(database: db).latest(root: root.path))
        XCTAssertEqual(stored.ledger()?.iteration, 1)
        XCTAssertFalse(result.consoleSummary.isEmpty)
    }

    func testCoordinatorPersistWithoutDatabaseWarnsInsteadOfFailing() async throws {
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = SecondBrainCoordinator(distiller: MemoryDistiller(projectsDir: projects))
        let result = try await coordinator.runIteration(
            root: root, database: nil, persistToDatabase: true, artifactsDir: nil,
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertNil(result.persistedRowID)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("DB is unavailable"))
    }

    // MARK: - Store

    func testMemoryLedgerStorePersistsLatestAndHistory() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = MemoryLedgerStore(database: db)
        let optimizer = SecondBrainOptimizer()

        let (l1, d1) = optimizer.optimize(
            ledger: .empty(root: "/proj"),
            candidates: [candidate(.decision, "let's use GRDB for all persistence here")],
            now: Date(timeIntervalSince1970: 100)
        )
        try store.record(l1, delta: d1)

        let (l2, d2) = optimizer.optimize(
            ledger: l1,
            candidates: [candidate(.decision, "let's use GRDB for all persistence here")],
            now: Date(timeIntervalSince1970: 200)
        )
        try store.record(l2, delta: d2)

        let latest = try store.latest(root: "/proj")
        XCTAssertEqual(latest?.iteration, 2)
        XCTAssertEqual(latest?.confirmedCount, 1)
        XCTAssertEqual(latest?.activeEntries, 1)
        XCTAssertEqual(try store.history(root: "/proj").count, 2)
        XCTAssertNil(try store.latest(root: "/other"))

        // The blob round-trips into the loop's resume point.
        let restored = latest?.ledger()
        XCTAssertEqual(restored?.iteration, 2)
        XCTAssertEqual(restored?.activeEntries.count, 1)
        XCTAssertEqual(restored?.activeEntries.first?.confidence, .medium)
        XCTAssertEqual(restored?.recentDeltas.count, 2)
    }

    // MARK: - End-to-end (deterministic)

    func testDistillOptimizeRenderEndToEnd() async throws {
        let projects = try makeTempDir("sb-projects")
        let root = try makeTempDir("sb-root")
        let out = try makeTempDir("sb-out")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: out)
        }
        try writeTranscript(projectsDir: projects, root: root, sessionId: "sess-e2e", lines: [
            assistantLine(ts: "2026-07-16T10:00:00.000Z"),
            userLine("No, don't commit generated files — add them to gitignore.", ts: "2026-07-16T10:01:00.000Z"),
            assistantLine(ts: "2026-07-16T10:01:05.000Z"),
            userLine("We should always run swiftformat before committing.", ts: "2026-07-16T10:02:00.000Z"),
        ])

        let distiller = MemoryDistiller(projectsDir: projects)
        let candidates = await distiller.distill(root: root)
        let (ledger, delta) = SecondBrainOptimizer().optimize(
            ledger: .empty(root: root.path),
            candidates: candidates,
            liveSessionIds: distiller.liveSessionIds(root: root),
            now: Date(timeIntervalSince1970: 42)
        )
        XCTAssertEqual(delta.added, 2)
        XCTAssertEqual(delta.activeTotal, 2)

        let renderer = SecondBrainRenderer()
        let summary = renderer.consoleSummary(ledger, delta: delta)
        XCTAssertTrue(summary.contains("Second Brain — \(root.path)"))
        XCTAssertTrue(summary.contains("+2 added"))

        let written = try renderer.writeArtifacts(ledger, to: out)
        let md = try String(contentsOf: written.brainPath, encoding: .utf8)
        XCTAssertTrue(md.contains("gitignore"))
        XCTAssertTrue(md.contains("swiftformat"))
    }
}
