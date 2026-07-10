// HeartbeatHealthTests.swift
//
// Pins the pure freshness → health mapping the out-of-process SupervisorStatusBar
// companion uses to drive the menu-bar icon. This is the honest-health spine:
// a fresh heartbeat is green, a stale one is amber, a very stale or missing one
// is red. The evaluator lives in Core precisely so it can be tested without an
// AppKit runtime.

import XCTest
@testable import SupervisorCore

final class HeartbeatHealthTests: XCTestCase {

    func testFreshIsGreen() {
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 0), .green)
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 9.99), .green)
    }

    func testStaleIsAmber() {
        // The 10s boundary flips green → amber.
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 10), .amber)
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 29.99), .amber)
    }

    func testVeryStaleIsRed() {
        // The 30s boundary flips amber → red, carrying a human-readable reason.
        if case .red = HeartbeatHealth.evaluate(age: 30) {} else {
            XCTFail("age 30 should be red")
        }
        if case .red = HeartbeatHealth.evaluate(age: 120) {} else {
            XCTFail("age 120 should be red")
        }
    }

    func testMissingHeartbeatIsRed() {
        // .infinity is what HeartbeatFile.ageSeconds returns when the file is
        // absent — the "supervisor never started / already gone" case.
        guard case .red(let reason) = HeartbeatHealth.evaluate(age: .infinity) else {
            return XCTFail("missing heartbeat should be red")
        }
        XCTAssertTrue(reason.contains("missing"), "reason should name the missing file, got: \(reason)")
    }

    // MARK: - FIX 3: negative / future-dated heartbeat age

    func testFutureBeatBeyondToleranceIsRedNotGreen() {
        // A heartbeat whose timestamp is far in the FUTURE (a backward clock step
        // from NTP correction, sleep/resume, VM restore, or a manual change) is
        // NOT evidence of liveness. Before the fix, age = -3600 fell into the
        // `age < 10` branch and read GREEN — so a supervisor that then died would
        // coast green for ~|age|+10s. It must be red.
        guard case .red(let reason) = HeartbeatHealth.evaluate(age: -3600) else {
            return XCTFail("a beat one hour in the future must be red, not green")
        }
        XCTAssertTrue(reason.contains("future"), "reason should name the future timestamp, got: \(reason)")
        XCTAssertNotEqual(HeartbeatHealth.evaluate(age: -3600), .green)
    }

    func testTinyBackwardJitterStaysGreen() {
        // A sub-second / couple-second backward skew between the writer's and
        // reader's clocks is benign jitter, not a stepped clock — still green.
        XCTAssertEqual(HeartbeatHealth.evaluate(age: -0.5), .green)
        XCTAssertEqual(HeartbeatHealth.evaluate(age: -HeartbeatHealth.clockJitterToleranceSeconds), .green)
    }

    func testFutureBeatJustBeyondToleranceIsRed() {
        // Just past the tolerance boundary flips to red.
        guard case .red = HeartbeatHealth.evaluate(age: -(HeartbeatHealth.clockJitterToleranceSeconds + 0.5)) else {
            return XCTFail("age just beyond the jitter tolerance must be red")
        }
    }

    // MARK: - FIX 4: engine-progress token gates green (hang detection)

    func testFreshBeatButStaleEngineIsNotGreen() {
        // The exact hang case: the process heartbeat is fresh (the dumb-timer child
        // is alive) but the engine token has not advanced in 60s — the engine has
        // hung. Green would be a lie; it must be red.
        let health = HeartbeatHealth.evaluate(age: 2, engineAge: 60)
        XCTAssertNotEqual(health, .green, "a fresh beat over a hung engine must not be green")
        guard case .red(let reason) = health else {
            return XCTFail("stale engine token should drive red, got: \(health)")
        }
        XCTAssertTrue(reason.contains("engine"), "reason should name the engine, got: \(reason)")
    }

    func testFreshBeatAndFreshEngineIsGreen() {
        // Both signals fresh → the only honest green.
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 2, engineAge: 1), .green)
    }

    func testFreshBeatButMissingEngineIsRed() {
        // Engine token absent (engine never ticked) — cannot confirm engine
        // liveness, so not green even though the process beat is fresh.
        guard case .red = HeartbeatHealth.evaluate(age: 2, engineAge: .infinity) else {
            return XCTFail("a fresh beat with no engine token must be red")
        }
    }

    func testFreshBeatButFutureEngineIsNotGreen() {
        // A future-dated engine token is no more trustworthy than a future beat.
        XCTAssertNotEqual(HeartbeatHealth.evaluate(age: 2, engineAge: -3600), .green)
    }

    func testNilEngineAgeIsBackwardCompatible() {
        // Legacy call sites / tests that pass no engine signal are unchanged:
        // engine gating only applies when an engineAge is supplied.
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 2, engineAge: nil),
                       HeartbeatHealth.evaluate(age: 2))
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 2, engineAge: nil), .green)
    }

    func testEvaluateReturnsTheWorseOfTheTwoSignals() {
        // Process amber + engine green → amber (process dominates).
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 20, engineAge: 1), .amber)
        // Process green + engine amber → amber (engine dominates).
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 2, engineAge: 20), .amber)
        // Either side red → red.
        guard case .red = HeartbeatHealth.evaluate(age: 2, engineAge: 45) else {
            return XCTFail("a red engine signal must win")
        }
    }

    // MARK: - EngineProgress writer round-trip

    func testEngineProgressRecordTickWritesFreshToken() throws {
        let tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-engine-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpHome) }
        let paths = ConfigPaths(home: tmpHome)

        XCTAssertTrue(EngineProgress.recordTick(paths: paths), "recordTick should succeed")

        // The token the status bar reads back is fresh, so evaluate() with a fresh
        // process beat is green.
        let engineAge = try HeartbeatFile(path: paths.engineProgressPath).ageSeconds()
        XCTAssertLessThan(engineAge, 5, "just-written engine token should be fresh")
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 2, engineAge: engineAge), .green)
    }
}
