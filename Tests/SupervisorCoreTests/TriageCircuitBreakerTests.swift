// TriageCircuitBreakerTests.swift
//
// The 402 backoff ladder as a table: 5 minutes, doubling per persistent
// 402, capped at an hour, snapped shut by any success. Pure value type, so
// no clocks, no sleeps, no network.

import XCTest
@testable import SupervisorCore

final class TriageCircuitBreakerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testClosedByDefault() {
        let breaker = TriageCircuitBreaker()
        XCTAssertFalse(breaker.isOpen(at: t0))
        XCTAssertNil(breaker.openUntil)
        XCTAssertNil(breaker.currentBackoffSeconds)
    }

    func testFirstPaymentRequiredOpensForFiveMinutes() {
        var breaker = TriageCircuitBreaker()
        let change = breaker.recordPaymentRequired(at: t0)
        XCTAssertEqual(change, .opened(until: t0.addingTimeInterval(300)))
        XCTAssertTrue(breaker.isOpen(at: t0))
        XCTAssertTrue(breaker.isOpen(at: t0.addingTimeInterval(299)))
        XCTAssertFalse(breaker.isOpen(at: t0.addingTimeInterval(300)),
                       "the boundary is half-open: at the deadline one probe goes through")
    }

    func testBackoffDoublesAndCapsAtOneHour() {
        var breaker = TriageCircuitBreaker()
        let expected: [TimeInterval] = [300, 600, 1200, 2400, 3600, 3600, 3600]
        var clock = t0
        for (index, want) in expected.enumerated() {
            let change = breaker.recordPaymentRequired(at: clock)
            XCTAssertEqual(breaker.currentBackoffSeconds, want, "trip \(index + 1)")
            let wantChange: TriageCircuitBreaker.Change = index == 0
                ? .opened(until: clock.addingTimeInterval(want))
                : .reopened(until: clock.addingTimeInterval(want))
            XCTAssertEqual(change, wantChange, "trip \(index + 1)")
            // The next probe happens when the window closes.
            clock = clock.addingTimeInterval(want)
        }
    }

    func testSuccessClosesAndResetsTheLadder() {
        var breaker = TriageCircuitBreaker()
        breaker.recordPaymentRequired(at: t0)
        breaker.recordPaymentRequired(at: t0.addingTimeInterval(300))
        XCTAssertEqual(breaker.currentBackoffSeconds, 600)

        XCTAssertEqual(breaker.recordSuccess(), .closed)
        XCTAssertFalse(breaker.isOpen(at: t0.addingTimeInterval(301)))
        XCTAssertNil(breaker.currentBackoffSeconds)

        // The next 402 is a NEW incident: back to the 5-minute rung, and it
        // reports .opened (the once-per-incident moment) again.
        let change = breaker.recordPaymentRequired(at: t0.addingTimeInterval(1000))
        XCTAssertEqual(change, .opened(until: t0.addingTimeInterval(1300)))
        XCTAssertEqual(breaker.currentBackoffSeconds, 300)
    }

    func testSuccessOnAClosedBreakerIsANoOp() {
        var breaker = TriageCircuitBreaker()
        XCTAssertEqual(breaker.recordSuccess(), .none,
                       "the common every-30s success path must not read as a state change")
    }
}
