// LLMCallMeterTests.swift
//
// The hourly spend line. The owner's question was "why did this fill $10
// overnight," and the answer has to be one scannable number per hour, not 300
// per-call lines.

import XCTest
@testable import SupervisorCore

final class LLMCallMeterTests: XCTestCase {

    private func usage(input: Int, output: Int, cacheHit: Int? = nil) -> AnthropicUsage {
        AnthropicUsage(
            input_tokens: input,
            output_tokens: output,
            cache_creation_input_tokens: nil,
            cache_read_input_tokens: cacheHit
        )
    }

    func testRecordAccumulatesAcrossCalls() {
        let meter = LLMCallMeter()
        meter.record(usage: usage(input: 5500, output: 20, cacheHit: 5120), costUSD: 0.0012)
        meter.record(usage: usage(input: 300, output: 5), costUSD: 0.0003)

        let w = meter.peek()
        XCTAssertEqual(w.calls, 2)
        XCTAssertEqual(w.inputTokens, 5800)
        XCTAssertEqual(w.outputTokens, 25)
        XCTAssertEqual(w.cacheHitTokens, 5120, "a provider that reports no cache adds zero, not nil")
        XCTAssertEqual(w.estimatedUSD, 0.0015, accuracy: 1e-9)
    }

    func testDrainResetsTheWindow() {
        let meter = LLMCallMeter()
        meter.record(usage: usage(input: 100, output: 1), costUSD: 0.01)
        XCTAssertEqual(meter.drain().calls, 1)
        let second = meter.drain()
        XCTAssertEqual(second, LLMCallMeter.Window(),
                       "the second hour starts empty; hours must not double-count")
    }

    func testHourlyLineShape() {
        var w = LLMCallMeter.Window()
        w.calls = 12
        w.inputTokens = 66_000
        w.cacheHitTokens = 61_440
        w.estimatedUSD = 0.0187
        let line = LLMCallMeter.hourlyLine(w, dayTotalUSD: 0.42, capUSD: 2.00)
        XCTAssertEqual(line, "cost.hourly calls=12 input_tokens=66000 cache_hit=61440 est_usd=0.0187 day_total_usd=0.42 cap_usd=2.00")
    }

    /// A silent hour is the line that proves the fix: zero calls, zero tokens.
    func testSilentHourReadsAsZero() {
        let line = LLMCallMeter.hourlyLine(LLMCallMeter.Window(), dayTotalUSD: 0.42, capUSD: 2.00)
        XCTAssertTrue(line.contains("calls=0"))
        XCTAssertTrue(line.contains("est_usd=0.0000"))
    }

    func testHourlyLineWithoutACapSaysOff() {
        let line = LLMCallMeter.hourlyLine(LLMCallMeter.Window(), dayTotalUSD: nil, capUSD: nil)
        XCTAssertTrue(line.hasSuffix("cap_usd=off"))
        XCTAssertFalse(line.contains("day_total_usd="),
                       "an unreadable cost store omits the total rather than reporting a fake $0.00")
    }

    /// Concurrency: the meter is written from every API call on whatever thread
    /// URLSession returns on, and drained from the main run loop.
    func testConcurrentRecordsAreNotLost() {
        let meter = LLMCallMeter()
        let group = DispatchGroup()
        for _ in 0..<200 {
            DispatchQueue.global().async(group: group) {
                meter.record(usage: self.usage(input: 10, output: 1, cacheHit: 5), costUSD: 0.001)
            }
        }
        group.wait()
        let w = meter.peek()
        XCTAssertEqual(w.calls, 200)
        XCTAssertEqual(w.inputTokens, 2000)
        XCTAssertEqual(w.cacheHitTokens, 1000)
    }
}
