// ContextWikiViewModelTests.swift — the Context Health window's state logic.
//
// The SwiftUI view is thin; the decisions that matter (the verdict headline, the
// "one lit path" top-unresolved selection, the non-destructive accept/undo, and
// the copy-as-tasks destination) live on the view model and are pure given an
// injected report. These tests pin that logic without a screen — the behavioral
// QA loop covers the auditor; this covers the UI's brain.

import XCTest
@testable import SupervisorCore
@testable import SupervisorUI

@MainActor
final class ContextWikiViewModelTests: XCTestCase {

    private func rec(_ title: String, kind: RecommendationKind = .prune, severity: SeverityBand = .minor,
                     lines: Int = 0, bytes: Int = 0, paths: [String] = [], signoff: Bool = true) -> Recommendation {
        Recommendation(kind: kind, title: title, rationale: "because \(title)", affectedPaths: paths,
                       estLinesSaved: lines, estBytesSaved: bytes, risk: .low, severity: severity,
                       requiresSignoff: signoff, origin: "test")
    }

    private func report(_ recs: [Recommendation], sources: [RawSource] = [], metrics: SourceMetrics? = nil) -> AuditReport {
        AuditReport(
            root: "/proj", generatedAt: Date(timeIntervalSince1970: 1),
            sources: sources,
            metrics: metrics ?? SourceMetrics(totalSources: sources.count, proseSources: sources.count, totalBytes: 0,
                                              totalProseLines: 0, nonContextBytes: 0, largestProseSources: [], duplicateBlocks: []),
            surveys: [], wiki: [], schema: "s", recommendations: recs, usedLLM: false)
    }

    private func vm(_ r: AuditReport) -> ContextWikiViewModel {
        ContextWikiViewModel(root: URL(fileURLWithPath: "/proj"), initialReport: r)
    }

    // MARK: - Verdict

    func testVerdictAllClearWhenNoActionable() {
        let m = vm(report([rec("a convention", kind: .schemaRule, signoff: false)]))
        XCTAssertTrue(m.isClean)
        XCTAssertEqual(m.verdict.headline, "All clear.")
        XCTAssertEqual(m.verdict.severity, .info)
    }

    func testVerdictNotableHeadlineAndAccentWord() {
        let m = vm(report([rec("big", severity: .notable, bytes: 900_000)]))
        XCTAssertFalse(m.isClean)
        XCTAssertEqual(m.verdict.headline, "A few cleanups.")
        XCTAssertEqual(m.verdict.accentWord, "cleanups")
        XCTAssertTrue(m.verdict.subline.contains("Nothing has been changed"))
    }

    func testVerdictMajorReadsWorthACleanup() {
        let m = vm(report([rec("huge", severity: .major, lines: 50)]))
        XCTAssertEqual(m.verdict.headline, "Worth a cleanup.")
        XCTAssertTrue(m.verdict.subline.contains("reclaimable lines"))
    }

    // MARK: - One lit path

    func testTopUnresolvedFollowsSeverityThenMovesOnAccept() {
        let a = rec("first", severity: .notable)
        let b = rec("second", severity: .minor)
        let c = rec("third", severity: .info)
        let m = vm(report([a, b, c]))
        XCTAssertTrue(m.isTopUnresolved(a))
        XCTAssertFalse(m.isTopUnresolved(b))

        m.accept(a)
        XCTAssertFalse(m.isTopUnresolved(a))   // accepted, no longer the lit one
        XCTAssertTrue(m.isTopUnresolved(b))    // the next unresolved lights up
        m.accept(b)
        XCTAssertTrue(m.isTopUnresolved(c))
    }

    // MARK: - Accept / undo (non-destructive, stable across a re-audit)

    func testAcceptAndUndo() {
        let a = rec("x", severity: .minor)
        let m = vm(report([a]))
        XCTAssertFalse(m.isAccepted(a))
        m.accept(a)
        XCTAssertTrue(m.isAccepted(a))
        XCTAssertEqual(m.acceptedCount, 1)
        m.undo(a)
        XCTAssertFalse(m.isAccepted(a))
        XCTAssertEqual(m.acceptedCount, 0)
    }

    func testAcceptSurvivesReaudit() {
        // Same content -> same key -> the sign-off persists even though a fresh
        // audit produces a new Recommendation UUID.
        let title = "carousel: prune assets"
        let first = rec(title, severity: .notable, bytes: 900_000)
        let m = vm(report([first]))
        m.accept(first)
        let secondSameContent = rec(title, severity: .notable, bytes: 900_000)
        XCTAssertTrue(m.isAccepted(secondSameContent))
    }

    // MARK: - Copy-as-tasks destination

    func testApprovedTasksTextListsOnlyApprovedWithPaths() {
        let a = rec("prune carousel", severity: .notable, paths: ["/a/x.png", "/a/y.png"])
        let b = rec("split doc", severity: .minor, paths: ["/b/big.md"])
        let m = vm(report([a, b]))
        m.accept(a)
        let text = m.approvedTasksText()
        XCTAssertTrue(text.contains("prune carousel"))
        XCTAssertTrue(text.contains("/a/x.png"))
        XCTAssertFalse(text.contains("split doc"))   // b not accepted
        XCTAssertTrue(text.contains("(1)"))          // one approved
    }

    func testApprovedTasksEmptyWhenNothingAccepted() {
        let m = vm(report([rec("x")]))
        XCTAssertTrue(m.approvedTasksText().isEmpty)
    }

    // MARK: - Derived collections

    func testActionableExcludesSchemaRulesAndDuplicatedTopicsSurface() {
        let recs = [rec("action", severity: .minor), rec("rule", kind: .schemaRule, signoff: false)]
        var r = report(recs)
        r.wiki = [WikiTopic(name: "shared", canonicalHome: "/a", appearsIn: ["/a", "/b"]),
                  WikiTopic(name: "solo", canonicalHome: "/c", appearsIn: ["/c"])]
        let m = vm(r)
        XCTAssertEqual(m.actionable.count, 1)
        XCTAssertEqual(m.schemaRules.count, 1)
        XCTAssertEqual(m.duplicatedTopics.count, 1)   // only the 2-file topic
    }
}
