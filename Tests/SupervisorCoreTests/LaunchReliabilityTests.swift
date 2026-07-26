// LaunchReliabilityTests.swift
//
// Regression tests for the v0.3.0 launch-failure classes behind the field
// report "sometimes opens, sometimes doesn't; I've had to restart my laptop":
//
//   1. SIGABRT at launch: UNUserNotificationCenter.current() abort()s in a
//      process with no bundle identifier (three identical crash reports,
//      2026-07-05, frame `+[UNUserNotificationCenter currentNotificationCenter]`
//      inside enterRunningState). Notifications must degrade, never decide
//      whether the app launches.
//   2. Silent duplicate exit while a hung incumbent holds the flock: the
//      duplicate policy must take over from a non-supervising incumbent
//      (stale/missing heartbeat) and only bow out to a healthy one.
//
// The xctest harness itself is the historical crash environment for (1) —
// these tests passing at all is part of the regression proof.

import XCTest
@testable import SupervisorCore

final class LaunchReliabilityTests: XCTestCase {

    private func tempTrace() -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-reliability-\(UUID().uuidString).log"))
    }

    // MARK: - 1. Notification-center gate (the SIGABRT class)

    /// The launch path may only construct a Notifier via `ifAvailable`.
    /// Whatever environment this runs in, the call must not crash, and its
    /// nil-ness must agree exactly with the gate.
    func testNotifierIfAvailableNeverCrashesAndMatchesGate() {
        let notifier = Notifier.ifAvailable(trace: tempTrace())
        XCTAssertEqual(notifier == nil, !NotificationCenterGate.available,
                       "ifAvailable must return nil exactly when the gate reports the center unavailable")
    }

    /// The gate must be CLOSED in this harness: the xctest runner has a
    /// bundle identifier yet current() still aborts here
    /// ("bundleProxyForCurrentProcess is nil" — reproduced by this very
    /// suite before the gate checked for a real .app bundle). If this test
    /// fails because the harness became a real app bundle, the gate
    /// predicate needs a fresh look, not a deleted test.
    func testGateIsClosedInTestHarness() {
        XCTAssertFalse(NotificationCenterGate.available)
        XCTAssertNil(Notifier.ifAvailable(trace: tempTrace()),
                     "constructing a real Notifier here would abort the harness")
    }

    /// The degraded stand-in keeps the router functional and reports an
    /// honest failed outcome instead of posting.
    func testTraceOnlyNotifierReportsFailedOutcome() async {
        let notifier = TraceOnlyNotifier(trace: tempTrace())
        let outcome = await notifier.post(decision: Self.makeDecision())
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("no bundle identifier"))
    }

    /// Both LivePermissionChecker center touches are gated: calling them in
    /// a gate-unavailable process must degrade, not abort. (Before the gate,
    /// this call was the documented way to crash this very harness.)
    func testPermissionCheckerNotificationCallsDoNotCrash() async {
        let checker = LivePermissionChecker()
        let status = await checker.notificationStatus()
        if !NotificationCenterGate.available {
            XCTAssertEqual(status, .denied, "gate-unavailable must report denied, not crash")
            let granted = try? await checker.requestNotifications()
            XCTAssertEqual(granted, false)
        }
    }

    // MARK: - 2. Duplicate-launch policy (the reboot-to-fix class)

    /// No app-alive marker: the incumbent never got a beat out (hung before
    /// its first touch, or a pre-marker app version). Takeover.
    func testMissingAppAliveMarkerMeansTakeover() {
        let action = DuplicateLaunchPolicy.decide(appAliveAge: nil)
        guard case .takeOver(let reason) = action else {
            return XCTFail("an incumbent with no app-alive marker is not responsive; expected takeover, got \(action)")
        }
        XCTAssertTrue(reason.contains("no app-alive"))
    }

    /// The beat is written by the incumbent's MAIN run loop, so a stale
    /// marker means a wedged main thread — the keychain-prompt hang class.
    func testStaleAppAliveMarkerMeansTakeover() {
        let action = DuplicateLaunchPolicy.decide(appAliveAge: 31)
        guard case .takeOver = action else {
            return XCTFail("expected takeover for a 31s marker, got \(action)")
        }
    }

    /// A fresh marker means the incumbent's run loop is turning — running OR
    /// sitting in onboarding. Both are healthy; both must be activated, never
    /// killed (the onboarding-incumbent kill was a round-1 review finding).
    func testFreshAppAliveMarkerMeansActivateAndQuit() {
        XCTAssertEqual(DuplicateLaunchPolicy.decide(appAliveAge: 5), .activateIncumbentAndQuit)
    }

    /// Exactly-at-window is NOT stale: the beat ticks every ~5s, so the
    /// boundary must not be jittery about a single late tick.
    func testWindowBoundaryIsNotStale() {
        XCTAssertEqual(
            DuplicateLaunchPolicy.decide(appAliveAge: DuplicateLaunchPolicy.stalenessWindow),
            .activateIncumbentAndQuit
        )
    }

    func testCustomWindowRespected() {
        XCTAssertEqual(DuplicateLaunchPolicy.decide(appAliveAge: 8, stalenessWindow: 5),
                       DuplicateLaunchPolicy.Action.takeOver(reason: "incumbent app-alive marker is 8s old (staleness window 5s)"))
        XCTAssertEqual(DuplicateLaunchPolicy.decide(appAliveAge: 3, stalenessWindow: 5),
                       .activateIncumbentAndQuit)
    }

    /// The policy threshold and the menu-bar honest-health threshold are the
    /// same product concept; if one moves, both must (this test is the tripwire).
    func testStalenessWindowMatchesHonestHealthThreshold() {
        XCTAssertEqual(DuplicateLaunchPolicy.stalenessWindow, 30)
    }

    // MARK: - Fixture

    private static func makeDecision() -> TriageDecision {
        TriageDecision(
            sessionId: "launch-test-s1",
            cwd: "/tmp/launch-test",
            candidate: TriageCandidate(
                category: "destructive_action_pending",
                severity: .high,
                matchedCommand: "rm -rf /tmp/x",
                action: .notify,
                reasoningPlain: "fixture",
                reasoningTechnical: "fixture",
                suggestedInjectText: nil,
                dedupDelivery: false
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: "launch-test-s1",
                command: "rm -rf /tmp/x",
                description: nil,
                toolUseId: "t1",
                turnUUID: "u1",
                ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                  cache_creation_input_tokens: nil,
                                  cache_read_input_tokens: nil),
            model: "haiku",
            prePost: .preExecution
        )
    }
}
