// PermissionCheckerTests.swift
//
// Unit-testable surface: deep-link URLs, the UNAuthorizationStatus mapper,
// the PermissionSnapshot semantics. Live probes are not covered here —
// they require an AppKit runtime + a real user; they get smoke-tested at
// Checkpoint B.

import XCTest
import UserNotifications
@testable import SupervisorCore

final class PermissionCheckerTests: XCTestCase {

    // MARK: - Deep links

    func testAccessibilityDeepLinkStable() {
        XCTAssertEqual(
            PermissionSettingsURL.accessibility.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testNotificationsDeepLinkStable() {
        XCTAssertEqual(
            PermissionSettingsURL.notifications.absoluteString,
            "x-apple.systempreferences:com.apple.preference.notifications"
        )
    }

    func testScreenRecordingDeepLinkStable() {
        XCTAssertEqual(
            PermissionSettingsURL.screenRecording.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    // MARK: - UNAuthorizationStatus → NotificationAuthStatus mapper

    func testAuthStatusMapping() {
        XCTAssertEqual(NotificationAuthStatus(.notDetermined), .notDetermined)
        XCTAssertEqual(NotificationAuthStatus(.denied), .denied)
        XCTAssertEqual(NotificationAuthStatus(.authorized), .authorized)
        XCTAssertEqual(NotificationAuthStatus(.provisional), .provisional)
        // .ephemeral is iOS-only (App Clips). The macOS SDK marks it
        // @available(macOS, unavailable), so we can't construct one to
        // pass through the mapper. Listed in NotificationAuthStatus for
        // schema completeness; not reachable on this platform.
    }

    // MARK: - PermissionSnapshot semantics

    func testSnapshotClearedForExitRequiresAX() {
        XCTAssertFalse(PermissionSnapshot(ax: false, notifications: .authorized, screenRecording: true).clearedForOnboardingExit)
        XCTAssertTrue(PermissionSnapshot(ax: true, notifications: .denied, screenRecording: false).clearedForOnboardingExit)
        XCTAssertTrue(PermissionSnapshot(ax: true, notifications: .notDetermined, screenRecording: false).clearedForOnboardingExit)
        XCTAssertTrue(PermissionSnapshot(ax: true, notifications: .authorized, screenRecording: true).clearedForOnboardingExit)
    }

    // MARK: - Why no live probe test
    //
    // Spike 2 finding bites here too: `UNUserNotificationCenter.current()`
    // calls `+currentNotificationCenter` which asserts the host has a
    // CFBundleIdentifier. The xctest harness binary doesn't (it's
    // SupervisorPackageTests.xctest, not a .app bundle), so attempting to
    // hit the live notification API from a unit test aborts with
    // NSInternalInconsistencyException. Real probing happens at
    // Checkpoint B, where Supervisor.app has a proper bundle. Documented
    // here so the next person who wants to add a "smoke test" for the
    // live checker doesn't re-discover this the painful way.
}
