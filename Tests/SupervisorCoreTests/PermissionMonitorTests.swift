// PermissionMonitorTests.swift
//
// Verifies that the monitor (a) establishes a baseline silently on the
// first poll, and (b) emits exactly one event per transition (revoke,
// regrant). The polling timer itself isn't exercised — we drive
// `probeNow()` directly to make the tests deterministic.

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class PermissionMonitorTests: XCTestCase {

    final class StubChecker: PermissionChecker, @unchecked Sendable {
        var ax: Bool = false
        var notif: NotificationAuthStatus = .notDetermined
        var screen: Bool = false
        func isAXGranted() -> Bool { ax }
        func notificationStatus() async -> NotificationAuthStatus { notif }
        func isScreenRecordingGranted() -> Bool { screen }
        func requestAX(prompt: Bool) -> Bool { ax }
        func requestNotifications() async throws -> Bool { true }
        func snapshot() async -> PermissionSnapshot {
            .init(ax: ax, notifications: notif, screenRecording: screen)
        }
    }

    func testBaselinePollEmitsNothing() async {
        let checker = StubChecker()
        checker.ax = true
        checker.notif = .authorized
        let monitor = PermissionMonitor(checker: checker)
        var events: [PermissionEvent] = []
        let sub = monitor.events.sink { events.append($0) }

        await monitor.probeNow()
        XCTAssertEqual(events, [], "baseline should not emit")
        XCTAssertNotNil(monitor.lastSnapshot)
        _ = sub
    }

    func testAXRevokeEmitsOnce() async {
        let checker = StubChecker()
        checker.ax = true
        let monitor = PermissionMonitor(checker: checker)
        var events: [PermissionEvent] = []
        let sub = monitor.events.sink { events.append($0) }

        await monitor.probeNow()                    // baseline (granted)
        checker.ax = false
        await monitor.probeNow()                    // transition (revoked)
        await monitor.probeNow()                    // stable; no re-emit

        XCTAssertEqual(events, [.axRevoked])
        _ = sub
    }

    func testAXRegrantEmits() async {
        let checker = StubChecker()
        checker.ax = false
        let monitor = PermissionMonitor(checker: checker)
        var events: [PermissionEvent] = []
        let sub = monitor.events.sink { events.append($0) }

        await monitor.probeNow()                    // baseline (revoked)
        checker.ax = true
        await monitor.probeNow()                    // regrant

        XCTAssertEqual(events, [.axRegranted])
        _ = sub
    }

    func testNotificationsRevokeAndRegrant() async {
        let checker = StubChecker()
        checker.notif = .authorized
        let monitor = PermissionMonitor(checker: checker)
        var events: [PermissionEvent] = []
        let sub = monitor.events.sink { events.append($0) }

        await monitor.probeNow()                    // baseline
        checker.notif = .denied
        await monitor.probeNow()                    // revoke
        checker.notif = .authorized
        await monitor.probeNow()                    // regrant
        XCTAssertEqual(events, [.notificationsRevoked, .notificationsRegranted])
        _ = sub
    }

    func testNotificationsNotDeterminedNotTreatedAsGrant() async {
        // .notDetermined is the pre-prompt state — counts as "not enough"
        // alongside .denied. Transitioning .denied -> .notDetermined isn't
        // a regrant; transitioning .notDetermined -> .authorized IS.
        let checker = StubChecker()
        checker.notif = .denied
        let monitor = PermissionMonitor(checker: checker)
        var events: [PermissionEvent] = []
        let sub = monitor.events.sink { events.append($0) }

        await monitor.probeNow()                    // baseline (denied)
        checker.notif = .notDetermined
        await monitor.probeNow()                    // pre-prompt — no event
        checker.notif = .authorized
        await monitor.probeNow()                    // real grant
        XCTAssertEqual(events, [.notificationsRegranted])
        _ = sub
    }
}
