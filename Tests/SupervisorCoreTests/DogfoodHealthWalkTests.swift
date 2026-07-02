// DogfoodHealthWalkTests.swift
//
// Wave 4 headless dogfood — Scenario 5 (crash / health walk).
//
// The status-bar icon must never lie about whether Supervisor is alive and
// watching. The documented transitions are:
//   fresh heartbeat        → green
//   stale (10–30s)         → amber
//   very stale / gone      → red
//   network-down marker    → amber (even over a FRESH heartbeat: a green dot
//                            with a dead key is worse than no product)
//   pause marker           → paused (a live-but-paused process is NOT "running")
//
// SEAM NOTE: the COMPOSED green/amber/red/paused decision — folding heartbeat
// age together with the network-down and pause markers — lives in
// `SupervisorStatusBar/main.swift` (StatusBarController.displayHealth /
// isPausedDisplay / displayTitle). That is an executable target, not
// importable into this unit test. So this file exercises every Core-level
// PRIMITIVE that decision is built from (the age classifier, the heartbeat
// file's staleness, the two markers, the paused hover surface), and each is
// asserted independently.
//   TODO(v0.3.0 follow-up): extract the composed status decision into a pure
//   `SupervisorCore` function — e.g.
//   `StatusDecision.evaluate(age:networkDownReason:paused:)` — so the full
//   marker+age composition can be unit-tested here instead of only its inputs.

import XCTest
@testable import SupervisorCore

final class DogfoodHealthWalkTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-dogfood-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Age classifier transitions (fresh → green, stale → amber, gone → red)

    func testHeartbeatHealthClassifiesAgeIntoGreenAmberRed() {
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 0),   .green, "just-written heartbeat is green")
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 9.5), .green, "under 10s is still green")
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 10),  .amber, "10s crosses into amber")
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 29),  .amber, "under 30s is amber")

        // 30s+ and a missing file are both red — the process is not writing.
        guard case .red = HeartbeatHealth.evaluate(age: 30) else {
            return XCTFail("30s must be red")
        }
        guard case let .red(reason) = HeartbeatHealth.evaluate(age: .infinity) else {
            return XCTFail("a missing heartbeat (age .infinity) must be red")
        }
        XCTAssertTrue(reason.contains("missing"), "the red reason must name the missing file; got \(reason)")
    }

    // MARK: - The heartbeat FILE drives the same classification end to end

    func testHeartbeatFileRoundTripDrivesStalenessClassification() throws {
        let path = tempDir.appendingPathComponent("heartbeat")
        let file = HeartbeatFile(path: path)

        // Missing file → infinite age → red.
        XCTAssertEqual(try file.ageSeconds(asOf: Date()), .infinity)
        guard case .red = HeartbeatHealth.evaluate(age: try file.ageSeconds(asOf: Date())) else {
            return XCTFail("no heartbeat file must classify red")
        }

        // A written heartbeat at a fixed base time. Reading age `asOf` a fixed
        // offset makes the walk deterministic (no wall-clock race).
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try file.write(Heartbeat(timestamp: base))

        XCTAssertEqual(HeartbeatHealth.evaluate(age: try file.ageSeconds(asOf: base.addingTimeInterval(2))),  .green)
        XCTAssertEqual(HeartbeatHealth.evaluate(age: try file.ageSeconds(asOf: base.addingTimeInterval(20))), .amber)
        guard case .red = HeartbeatHealth.evaluate(age: try file.ageSeconds(asOf: base.addingTimeInterval(60))) else {
            return XCTFail("a 60s-old heartbeat must classify red")
        }
    }

    // MARK: - The heartbeat wire format round-trips its flags

    func testHeartbeatFilePreservesFlagsAcrossWriteRead() throws {
        let file = HeartbeatFile(path: tempDir.appendingPathComponent("heartbeat-flags"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try file.write(Heartbeat(timestamp: base, flags: [.networkDown, .axLost]))
        let read = try file.read()
        XCTAssertEqual(read?.flags, [.networkDown, .axLost])
        // No-flags heartbeat reads back as an empty set (the `-` sentinel).
        try file.write(Heartbeat(timestamp: base, flags: []))
        XCTAssertEqual(try file.read()?.flags, [])
    }

    // MARK: - Network-down marker (the amber-over-fresh input)

    func testNetworkDownMarkerPresenceIsTheAmberSignal() {
        let heartbeatPath = tempDir.appendingPathComponent("heartbeat")
        let marker = NetworkDownMarker.alongside(heartbeatPath: heartbeatPath)

        XCTAssertNil(marker.read(), "no marker → not degraded (green stays green)")

        marker.set(reason: "Can't reach Anthropic — check your API key")
        XCTAssertEqual(marker.read(), "Can't reach Anthropic — check your API key",
                       "a present marker is the degraded reason the status bar shows as amber")
        // The composition the executable applies: a FRESH heartbeat is green by
        // age, but the present marker forces amber. Both inputs are asserted
        // here; the fold itself lives in SupervisorStatusBar (see SEAM NOTE).
        XCTAssertEqual(HeartbeatHealth.evaluate(age: 1), .green,
                       "the heartbeat alone is green; the marker is what turns the icon amber")

        marker.clear()
        XCTAssertNil(marker.read(), "clearing the marker (recovery) drops the amber signal")
    }

    // MARK: - Pause marker mechanism (the paused input)

    func testPauseMarkerMechanismRoundTripsInIsolatedDir() {
        // Use an ISOLATED temp dir so the round-trip never writes the REAL
        // supervisor-paused.marker that a running app would act on.
        let dir = tempDir
        let name = "supervisor-paused.marker"

        XCTAssertFalse(RuntimeToggles.isOn(name, dir: dir), "no marker → not paused")
        RuntimeToggles.setOn(name, true, dir: dir)
        XCTAssertTrue(RuntimeToggles.isOn(name, dir: dir), "marker present → paused")
        RuntimeToggles.setOn(name, false, dir: dir)
        XCTAssertFalse(RuntimeToggles.isOn(name, dir: dir), "marker removed → un-paused")
    }

    // MARK: - Paused honesty on the hover surface (pause-marker → paused)

    @MainActor
    func testHoverReflectsPausedAndYieldsToMoreUrgentTruths() {
        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("trace.log")))
        let hover = HoverViewModel(bus: bus, trace: TraceLog(path: tempDir.appendingPathComponent("trace.log")))

        // From idle, pausing paints the paused state (amber + "Supervisor
        // paused") — never a green "All clear" over a dormant engine.
        hover.reflectSupervisorPaused(true)
        XCTAssertEqual(hover.plainLabel, HoverViewModel.pausedLabel)
        guard case .degraded(let reason) = hover.activity, reason == HoverViewModel.pausedLabel else {
            return XCTFail("paused must render the paused state, got \(hover.activity)")
        }

        // Un-pausing restores idle.
        hover.reflectSupervisorPaused(false)
        guard case .idle = hover.activity else {
            return XCTFail("un-pausing must return to idle, got \(hover.activity)")
        }

        // A live safety flag is a more urgent truth than "paused": pausing must
        // NOT overwrite it (the icon must keep showing the flag).
        hover.flagRaised(severity: .high, action: .pause, reasoningPlain: "Paused Claude Code on rm -rf.")
        hover.reflectSupervisorPaused(true)
        guard case .flagged(.high, .pause, _) = hover.activity else {
            return XCTFail("a live flag must outrank paused, got \(hover.activity)")
        }
    }
}
