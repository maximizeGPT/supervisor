// SupervisorInjectionMarkerTests.swift
//
// No-stamp decision (fix-queue #7): injections must read CLEAN — no in-text
// banner / notice. Provenance for Supervisor's own triage comes from the
// InjectionLedger, not from a marker in the text. These tests pin that wrap()
// is a clean passthrough (also stripping any legacy banner) and that the ledger
// still correlates an injection on its clean text.

import XCTest
@testable import SupervisorCore

final class SupervisorInjectionMarkerTests: XCTestCase {

    func testWrapReturnsBodyClean() {
        let body = "Pick up Issue #7 and implement the parser."
        let wrapped = SupervisorInjectionMarker.wrap(body)
        XCTAssertEqual(wrapped, body, "wrap must return the body unchanged — no banner, no notice")
        XCTAssertFalse(wrapped.contains("SUPERVISOR"),
                       "injected text must not carry the legacy banner word")
        XCTAssertFalse(wrapped.contains("does NOT authorize"),
                       "injected text must not carry the legacy authorization notice")
    }

    func testWrapStripsLegacyBanner() {
        // A dispatch queued before the no-stamp decision may still carry the old
        // banner + notice + separator. wrap() must strip it so even old in-flight
        // text drives clean.
        let body = "reset it to empty now"
        let legacy = "\(SupervisorInjectionMarker.legacyBanner)\nThe Supervisor harness generated the text below automatically.\n———\n\(body)"
        XCTAssertEqual(SupervisorInjectionMarker.wrap(legacy), body,
                       "wrap must strip the legacy banner/notice/separator and return the original body")
    }

    func testWrapIsIdempotent() {
        let body = "reset it to empty now"
        let once = SupervisorInjectionMarker.wrap(body)
        let twice = SupervisorInjectionMarker.wrap(once)
        XCTAssertEqual(once, twice, "re-wrapping a clean body must be a no-op")
        XCTAssertEqual(once, body)
    }

    func testCleanInjectionCorrelatesInLedger() {
        // The router records exactly what it injects (the clean text), and the
        // turn that lands in the JSONL is that same clean text — so the ledger
        // correlates on the clean form. This is what keeps the triage labeling +
        // engagement guard recognizing Supervisor's own turns after the banner
        // is gone.
        let ledger = InjectionLedger()
        let session = "s-1"
        let proposal = "The session objective is to ship. Direction: do X. 75 min cap."
        let injected = SupervisorInjectionMarker.wrap(proposal)
        XCTAssertEqual(injected, proposal, "the injected text is clean")
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        ledger.record(sessionId: session, text: injected, at: t)
        XCTAssertTrue(
            ledger.isSupervisorInjected(sessionId: session, text: injected, asOf: t.addingTimeInterval(2)),
            "the clean injected turn must correlate back to its ledger record"
        )
        // A genuine operator turn must NOT correlate.
        XCTAssertFalse(
            ledger.isSupervisorInjected(sessionId: session, text: "do X now please", asOf: t.addingTimeInterval(2)),
            "an operator turn must never be mistaken for a Supervisor injection"
        )
    }
}
