// OnboardingScreenGateTests.swift
//
// The hover band was the visible half of the isolation bug; these pin the two
// windows that were still ungated after it was fixed.
//
// An E2E scenario launches a REAL Supervisor with its own SUPERVISOR_HOME, and
// the single-instance flock is namespaced by that same seam, so an isolated
// instance runs ALONGSIDE the owner's app by design. s03 launches against a
// virgin fake home precisely so the app lands in onboarding — which meant a
// 480x420 window on the owner's desktop plus an `NSApp.activate` that took his
// keyboard out of whatever he was typing in. The permission popover is the
// same shape: a floating panel that activates the app, raised by a monitor
// that runs in every instance.
//
// The onboarding window is gated differently from the hover band, and that
// difference is the point: s03 DRIVES onboarding through the Accessibility
// API, and AX only reports windows the app actually has. So the isolated
// instance keeps a real, ordered-in window and loses its position on any
// screen. Suppressing the window outright would have made the scenario
// undrivable.
//
// Nothing here presents the real-user path. A test that proved it by showing
// the window would put an onboarding window on the owner's screen every time
// he runs `swift test`, which is the bug.

import AppKit
import XCTest

@testable import SupervisorCore
@testable import SupervisorUI

@MainActor
final class OnboardingScreenGateTests: XCTestCase {

    // MARK: - Fixtures

    private final class StubChecker: PermissionChecker, @unchecked Sendable {
        func isAXGranted() -> Bool { false }
        func notificationStatus() async -> NotificationAuthStatus { .notDetermined }
        func isScreenRecordingGranted() -> Bool { false }
        func requestScreenRecording() -> Bool { false }
        func requestAX(prompt: Bool) -> Bool { false }
        func requestNotifications() async throws -> Bool { false }
        func snapshot() async -> PermissionSnapshot {
            .init(ax: false, notifications: .notDetermined, screenRecording: false)
        }
    }

    private func makeVM() -> OnboardingViewModel {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-gate-test-\(UUID()).log"))
        return OnboardingViewModel(
            permissions: StubChecker(),
            keyStore: InMemoryProviderKeyStore(),
            activeProviderStore: InMemoryActiveProviderStore(),
            clientFactory: { provider, key in
                LLMClient(provider: provider, apiKey: key, redactor: DefaultRedactor(), traceLog: trace)
            },
            trace: trace
        )
    }

    // MARK: - The onboarding window

    /// The bug, stated as an assertion: an isolated instance's onboarding
    /// window exists (s03 needs it) and is on no screen (the owner needs that).
    func testSuppressedOnboardingWindowIsRealButOffEveryScreen() throws {
        let controller = OnboardingWindowController(
            vm: makeVM(),
            presentsOnScreen: false,
            onCompletion: { _ in }
        )
        controller.present()

        let window = try XCTUnwrap(controller.window, "the AX driver enumerates windows; an instance with none cannot be driven at all")
        XCTAssertTrue(window.isVisible, "the window has to be ORDERED IN to appear in the AX tree")
        XCTAssertEqual(
            window.frame.origin, OnboardingWindowController.offScreenOrigin,
            "AppKit constrains a titled window back onto a screen unless the placement override is armed"
        )
        for screen in NSScreen.screens {
            XCTAssertFalse(
                screen.frame.intersects(window.frame),
                "an isolated instance must not put a single pixel of onboarding on \(screen.frame)"
            )
        }
        controller.dismiss()
    }

    /// The gate is armed at construction, because the constraint override has
    /// to be in place before the first order-in. This is the line that fails if
    /// someone later gates only `present()` and leaves the window free to be
    /// nudged back on screen.
    func testSuppressedControllerArmsOffScreenPlacementAtConstruction() {
        let controller = OnboardingWindowController(
            vm: makeVM(),
            presentsOnScreen: false,
            onCompletion: { _ in }
        )
        XCTAssertEqual((controller.window as? OnboardingWindow)?.allowsOffScreenPlacement, true)

        let real = OnboardingWindowController(
            vm: makeVM(),
            presentsOnScreen: true,
            onCompletion: { _ in }
        )
        XCTAssertEqual(
            (real.window as? OnboardingWindow)?.allowsOffScreenPlacement, false,
            "the owner's own window keeps AppKit's keep-it-reachable behavior, unchanged"
        )
    }

    /// The default the app actually uses. `swift test` runs with no
    /// SUPERVISOR_HOME, so a controller built the way main.swift builds it must
    /// come out presenting — this catches a future edit that defaults the gate
    /// to closed and ships a Supervisor whose onboarding never appears.
    func testDefaultInitPresentsOnScreenForARealUser() throws {
        guard ConfigPaths.isRealUserHome else {
            throw XCTSkip("this test process runs with a SUPERVISOR_HOME override")
        }
        let controller = OnboardingWindowController(vm: makeVM(), onCompletion: { _ in })
        XCTAssertTrue(
            controller.presentsOnScreen,
            "production behavior with no SUPERVISOR_HOME is unchanged: onboarding presents and activates"
        )
    }

    // MARK: - The permission-lost popover

    /// This panel calls `NSApp.activate(ignoringOtherApps:)`, so an isolated
    /// instance whose AX grant flickered would have stolen the owner's keyboard
    /// mid-sentence. A suppressed instance never even builds the panel: an
    /// NSPanel that exists is one `makeKeyAndOrderFront` away from his screen.
    func testSuppressedPermissionPopoverBuildsNoPanel() {
        let popover = PermissionLostPopover(presentsOnScreen: false)
        popover.present(reason: .accessibilityRevoked)
        XCTAssertNil(popover.window, "no panel may exist on an instance that is not allowed to draw")
        popover.present(reason: .notificationsRevoked)
        XCTAssertNil(popover.window, "both revocation reasons route through the same gate")
        // Dismissing something that was never built must not be a crash path:
        // the monitor calls it on every re-grant.
        popover.dismiss()
    }

    func testPermissionPopoverDefaultsToPresentingForARealUser() throws {
        guard ConfigPaths.isRealUserHome else {
            throw XCTSkip("this test process runs with a SUPERVISOR_HOME override")
        }
        XCTAssertTrue(
            PermissionLostPopover().presentsOnScreen,
            "a real user must still be told when macOS revokes his AX grant"
        )
        // Deliberately not presented here: showing it would put a floating
        // panel on the owner's screen and activate the test runner.
    }
}
