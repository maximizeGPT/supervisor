// DailyCapGateTests.swift
//
// Audit B4: the two capCheck closures read today's spend as
// `(try? store.todayTotalUSD()) ?? 0`, so a thrown read reported "$0 spent"
// and the cap could never trip. The gate that bounds spend failed OPEN,
// precisely when the machine was already unhealthy.

import XCTest
@testable import SupervisorCore

final class DailyCapGateTests: XCTestCase {

    private func tempTrace() -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("cap-gate-\(UUID().uuidString).log"))
    }

    private struct StoreUnavailable: Error {}

    func testReturnsCapAndSpentOnAHealthyRead() {
        let limit = DailyCapGate.evaluate(cap: 2.00, spentUSD: { 0.37 }, trace: tempTrace())
        XCTAssertEqual(limit?.cap, 2.00)
        XCTAssertEqual(limit?.spent, 0.37)
        XCTAssertEqual(limit?.storeReadFailed, false,
                       "a read that worked is never flagged as failed")
    }

    /// The flag the blast-radius carve-out reads. Both verdicts present as
    /// spent >= cap, and only this bit tells them apart, so a call site that
    /// needs to distinguish "budget spent" from "ledger broken" has something
    /// to distinguish them BY.
    func testOnlyAThrownReadIsFlaggedAsAStoreFailure() {
        let realCapHit = DailyCapGate.evaluate(cap: 2.00, spentUSD: { 2.50 }, trace: tempTrace())
        XCTAssertEqual(realCapHit?.storeReadFailed, false)
        XCTAssertTrue((realCapHit?.spent ?? 0) >= (realCapHit?.cap ?? .infinity))

        let brokenStore = DailyCapGate.evaluate(
            cap: 2.00, spentUSD: { throw StoreUnavailable() }, trace: tempTrace()
        )
        XCTAssertEqual(brokenStore?.storeReadFailed, true)
        XCTAssertTrue((brokenStore?.spent ?? 0) >= (brokenStore?.cap ?? .infinity),
                      "still fails closed by default: the flag is an opt-in carve-out, not a bypass")
    }

    func testNoCapMeansNoGate() {
        XCTAssertNil(DailyCapGate.evaluate(cap: nil, spentUSD: { 99 }, trace: tempTrace()),
                     "an owner who opted out of capping is not gated")
    }

    /// (e) The fix: a store read that throws reports spend AT the cap, so the
    /// client refuses the call instead of waving it through as "$0 spent."
    func testThrownSpendReadFailsClosed() {
        let limit = DailyCapGate.evaluate(
            cap: 2.00, spentUSD: { throw StoreUnavailable() }, trace: tempTrace()
        )
        let unwrapped = try? XCTUnwrap(limit)
        XCTAssertNotNil(unwrapped)
        XCTAssertEqual(limit?.cap, 2.00)
        XCTAssertEqual(limit?.spent, 2.00)
        XCTAssertTrue((limit?.spent ?? 0) >= (limit?.cap ?? .infinity),
                      "spent >= cap is what LLMClient refuses on; a broken read must land there")
    }

    func testFailClosedIsTraced() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cap-gate-trace-\(UUID().uuidString).log")
        let trace = TraceLog(path: path)
        _ = DailyCapGate.evaluate(cap: 5.00, spentUSD: { throw StoreUnavailable() }, trace: trace)
        trace.sync()
        let contents = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        XCTAssertTrue(contents.contains("cap.fail_closed"),
                      "a silently refused call is an unexplained outage; the reason has to be in the trace")
        XCTAssertTrue(contents.contains("spend_read_failed"))
    }

    /// The two halves compose: an untouched config plus a broken store means
    /// refused calls, not unbounded ones.
    func testDefaultCapAndBrokenStoreTogetherRefuse() {
        let cap = UserConfig.parse(nil).effectiveDailyCostCapUSD
        XCTAssertEqual(cap, UserConfig.defaultDailyCostCapUSD)
        let limit = DailyCapGate.evaluate(
            cap: cap, spentUSD: { throw StoreUnavailable() }, trace: tempTrace()
        )
        XCTAssertEqual(limit?.spent, UserConfig.defaultDailyCostCapUSD,
                       "a broken read presents AT whatever the effective cap is")
        XCTAssertEqual(limit?.storeReadFailed, true,
                       "and says so, or the refusal pages as a cap hit with a number nobody measured")
    }
}
