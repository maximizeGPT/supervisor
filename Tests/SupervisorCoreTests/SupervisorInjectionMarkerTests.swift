// SupervisorInjectionMarkerTests.swift
//
// Fix A (2026-06-15): every Supervisor injection must be unmistakably marked as
// NOT from the operator, and the marking must not break the InjectionLedger
// correlation the triage-side fix + engagement guard rely on.

import XCTest
@testable import SupervisorCore

final class SupervisorInjectionMarkerTests: XCTestCase {

    func testWrapIsNoOp() {
        // 2026-06-16 — owner's call: no visible banner on injects (provenance is
        // tracked internally via the InjectionLedger). wrap returns body unchanged.
        let body = "Pick up Issue #7 and implement the parser."
        XCTAssertEqual(SupervisorInjectionMarker.wrap(body), body,
                       "wrap must be a no-op — no visible marker stamped on injects")
    }

    func testWrapIsIdempotent() {
        // A re-queued / re-fired dispatch can pass through wrap() twice; it must
        // never stack markers.
        let body = "reset it to empty now"
        let once = SupervisorInjectionMarker.wrap(body)
        let twice = SupervisorInjectionMarker.wrap(once)
        XCTAssertEqual(once, twice, "re-wrapping must not stack markers")
    }

    func testMarkedInjectionStillCorrelatesInLedger() {
        // The router now records the MARKED text, and the turn that lands in the
        // JSONL is the marked text — so the ledger must correlate on the marked
        // form, or the triage labeling + engagement guard would stop recognizing
        // Supervisor's own turns.
        let ledger = InjectionLedger()
        let session = "s-1"
        let proposal = "The session objective is to ship. Direction: do X. 75 min cap."
        let marked = SupervisorInjectionMarker.wrap(proposal)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        ledger.record(sessionId: session, text: marked, at: t)
        XCTAssertTrue(
            ledger.isSupervisorInjected(sessionId: session, text: marked, asOf: t.addingTimeInterval(2)),
            "the marked injected turn must correlate back to its ledger record"
        )
        // A genuine operator turn (unmarked) must NOT correlate.
        XCTAssertFalse(
            ledger.isSupervisorInjected(sessionId: session, text: "do X now please", asOf: t.addingTimeInterval(2)),
            "an operator turn must never be mistaken for a Supervisor injection"
        )
    }
}
