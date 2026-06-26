// InjectionLedgerTests.swift
//
// The self-authorization / impersonation gap, correlation layer. The ledger
// is what lets the triage tell Supervisor's own injected turns apart from the
// owner's real messages. These tests pin the correlation contract: a recorded
// injection matches its later user turn (same session, within the window),
// and NOTHING ELSE does — because a false match only withholds a real
// authorization (recoverable), while a missed match re-opens the gap.

import XCTest
@testable import SupervisorCore

final class InjectionLedgerTests: XCTestCase {

    func testRecordedInjectionCorrelatesToItsTurn() {
        let ledger = InjectionLedger()
        let t = Date()
        ledger.record(sessionId: "s1", text: "delete the build directory and rebuild", at: t)
        XCTAssertTrue(
            ledger.isSupervisorInjected(sessionId: "s1", text: "delete the build directory and rebuild", asOf: t.addingTimeInterval(2)),
            "an injected turn must correlate to its own recorded injection")
    }

    func testGenuineOwnerTurnDoesNotCorrelate() {
        let ledger = InjectionLedger()
        ledger.record(sessionId: "s1", text: "run the tests", at: Date())
        XCTAssertFalse(
            ledger.isSupervisorInjected(sessionId: "s1", text: "now delete the production database", asOf: Date()),
            "a turn Supervisor never injected must read as owner-authored (no false [supervisor-injected])")
    }

    func testCrossSessionDoesNotCorrelate() {
        let ledger = InjectionLedger()
        let t = Date()
        ledger.record(sessionId: "s1", text: "proceed with the migration", at: t)
        XCTAssertFalse(
            ledger.isSupervisorInjected(sessionId: "s2", text: "proceed with the migration", asOf: t.addingTimeInterval(1)),
            "an injection into one session must not mark a same-text turn in another session")
    }

    func testOutsideWindowDoesNotCorrelate() {
        let ledger = InjectionLedger(correlationWindow: 60)
        let injectedAt = Date()
        ledger.record(sessionId: "s1", text: "wipe and reset everything now", at: injectedAt)
        // A turn two hours later with identical text is a genuine re-type, not
        // this injection — the window protects against an ancient injection
        // shadowing a real later authorization.
        XCTAssertFalse(
            ledger.isSupervisorInjected(sessionId: "s1", text: "wipe and reset everything now", asOf: injectedAt.addingTimeInterval(7200)),
            "a match outside the correlation window must not count")
    }

    func testWhitespaceReflowStillMatches() {
        let ledger = InjectionLedger()
        let t = Date()
        ledger.record(sessionId: "s1", text: "Use YAML matching rubric.yaml.  §5 delegates engineering decisions.", at: t)
        // A paste round-trip can reflow whitespace; normalization keeps the
        // match robust without loosening it on content.
        XCTAssertTrue(
            ledger.isSupervisorInjected(sessionId: "s1", text: "Use YAML matching rubric.yaml. §5 delegates engineering decisions.", asOf: t.addingTimeInterval(1)),
            "whitespace-only differences must still correlate")
    }

    func testLongInjectionContainedInLargerTurnMatches() {
        let ledger = InjectionLedger()
        let t = Date()
        let injected = "yes, drop the test_runs table — it is a disposable fixture"
        ledger.record(sessionId: "s1", text: injected, at: t)
        // Claude Code may wrap or append to what was pasted; a substantial
        // injected string contained in the turn still correlates.
        XCTAssertTrue(
            ledger.isSupervisorInjected(sessionId: "s1", text: injected + "\n\n(submitted)", asOf: t.addingTimeInterval(1)),
            "a long injected string contained in the turn must correlate")
    }

    func testShortInjectionRequiresExactMatch() {
        let ledger = InjectionLedger()
        let t = Date()
        ledger.record(sessionId: "s1", text: "yes", at: t)
        // Short tokens must NOT over-match: a turn merely containing "yes"
        // (e.g. the owner typing "yes, but only the cache") is not this
        // injection — otherwise we'd suppress a genuine owner authorization.
        XCTAssertFalse(
            ledger.isSupervisorInjected(sessionId: "s1", text: "yesterday's data can stay, delete the rest", asOf: t.addingTimeInterval(1)),
            "a short injection must require an exact normalized match, not containment")
        XCTAssertTrue(
            ledger.isSupervisorInjected(sessionId: "s1", text: "yes", asOf: t.addingTimeInterval(1)),
            "a short injection still matches itself exactly")
    }

    func testClockSkewSlackAllowsTurnSlightlyBeforeInjection() {
        let ledger = InjectionLedger(skewSlack: 300)
        let injectedAt = Date()
        ledger.record(sessionId: "s1", text: "force push the rebase to my-feature-branch", at: injectedAt)
        // The JSONL turn timestamp can read slightly before the injection's
        // Date() (different clocks / rounding); the slack absorbs it.
        XCTAssertTrue(
            ledger.isSupervisorInjected(sessionId: "s1", text: "force push the rebase to my-feature-branch", asOf: injectedAt.addingTimeInterval(-30)),
            "a turn timestamp within the skew slack before the injection must still correlate")
    }

    func testEmptyTextIsIgnored() {
        let ledger = InjectionLedger()
        ledger.record(sessionId: "s1", text: "   \n  ", at: Date())
        XCTAssertEqual(ledger.entryCount(sessionId: "s1"), 0, "whitespace-only injections are not recorded")
        XCTAssertFalse(ledger.isSupervisorInjected(sessionId: "s1", text: "", asOf: Date()))
    }

    func testRetentionPrunesOldestBeyondCap() {
        let ledger = InjectionLedger(retentionPerSession: 3, correlationWindow: 3600)
        let base = Date()
        for i in 0..<6 {
            ledger.record(sessionId: "s1", text: "injection number \(i) with enough length to be substantial", at: base.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(ledger.entryCount(sessionId: "s1"), 3, "per-session retention bounds the ledger")
        // The earliest injections are pruned; the most recent are retained.
        XCTAssertFalse(ledger.isSupervisorInjected(sessionId: "s1", text: "injection number 0 with enough length to be substantial", asOf: base.addingTimeInterval(6)))
        XCTAssertTrue(ledger.isSupervisorInjected(sessionId: "s1", text: "injection number 5 with enough length to be substantial", asOf: base.addingTimeInterval(6)))
    }

    func testNoLedgerSharingMeansEachSessionIsolated() {
        let ledger = InjectionLedger()
        let t = Date()
        ledger.record(sessionId: "a", text: "shared phrasing here that is long enough", at: t)
        XCTAssertEqual(ledger.entryCount(sessionId: "a"), 1)
        XCTAssertEqual(ledger.entryCount(sessionId: "b"), 0)
    }
}
