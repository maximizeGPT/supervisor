// HoverScreenGateTests.swift
//
// The owner sent a screenshot of THREE stacked "Watching. All clear" hover
// pills and said it keeps spitting multiple instances. The extra pills were
// harness instances: every E2E scenario and deploy harness launches a real
// Supervisor with an isolated `SUPERVISOR_HOME`, and the single-instance flock
// is namespaced by that same seam (ConfigPaths.homeIdentityHash), so an
// isolated instance coexists with the owner's real app BY DESIGN. Filesystem
// isolation was complete; screen isolation did not exist, so each instance
// drew its own band on his screen.
//
// These tests pin both halves of the gate:
//   - the predicate: a `SUPERVISOR_HOME` that is not the real home means "do
//     not draw", and no override at all means production, unchanged;
//   - the controller: a suppressed instance never reaches a state where the
//     band is on screen, through ANY of its entry points.
//
// Nothing here orders a window front. A test that proved the production path
// by actually showing the band would put a pill on the owner's screen every
// time he runs `swift test`, which is the bug.
//
// Every controller below is handed its frontmost app instead of reading the
// live one. The gate's other inputs were already injected; that read was the
// last one still on the machine, and it made these tests depend on which app
// the owner happened to have in front. Concretely:
// `ConfigTests.testKeychainStoreRoundTrip` writes to the real login keychain,
// macOS raises a SecurityAgent prompt over whatever was frontmost, and once it
// resolves the frontmost app is the terminal that launched the run, which is
// in `defaultHostApps`. `C` sorts before `H`, so on a full-suite run these
// tests ran on the far side of that prompt and
// `testRealHomeInstanceArmsTheVisibilityGate` failed its last assertion. Run
// alone, or on CI where nothing is frontmost, it passed.

import XCTest

@testable import SupervisorCore
@testable import SupervisorUI

@MainActor
final class HoverScreenGateTests: XCTestCase {

    /// A bundle ID in `defaultHostApps`. Passing this is how a test says "a
    /// terminal is in front", which is the only condition under which the band
    /// is allowed on screen at all.
    private static let hostApp = "com.apple.Terminal"

    /// A bundle ID that is in no host-app set, so the band stays hidden for a
    /// stated reason rather than an inherited one.
    private static let nonHostApp = "com.apple.Safari"

    private func makeVM() -> HoverViewModel {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-gate-test-\(UUID()).log"))
        return HoverViewModel(bus: EventBus(trace: trace), trace: trace)
    }

    // MARK: - The predicate

    /// Production parity, stated as bluntly as it can be: with no
    /// `SUPERVISOR_HOME` in the environment, nothing about the hover changes.
    func testNoOverrideIsTheRealUserHome() {
        XCTAssertTrue(
            ConfigPaths.isRealUserHome(environment: [:]),
            "an environment with no SUPERVISOR_HOME must resolve the real home, or every production launch loses its hover band"
        )
    }

    /// `resolvedHome` treats an empty override as absent; the screen gate has
    /// to agree, or an exported-but-empty variable would silently blank the
    /// band for a real user.
    func testEmptyOverrideIsTheRealUserHome() {
        XCTAssertTrue(
            ConfigPaths.isRealUserHome(environment: ["SUPERVISOR_HOME": ""])
        )
    }

    /// The gate compares resolved paths rather than testing for the variable's
    /// presence, so pointing the override back at the real home is a no-op —
    /// which is what a wrapper script that exports `SUPERVISOR_HOME="$HOME"`
    /// deserves.
    func testOverridePointingAtTheRealHomeIsStillTheRealUserHome() {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(
            ConfigPaths.isRealUserHome(environment: ["SUPERVISOR_HOME": realHome])
        )
    }

    /// The harness shape: an isolated home under /tmp is not the real home, so
    /// the instance must not draw.
    func testIsolatedHomeIsNotTheRealUserHome() {
        XCTAssertFalse(
            ConfigPaths.isRealUserHome(environment: ["SUPERVISOR_HOME": "/tmp/supervisor-e2e/run/home"]),
            "an E2E instance must not be classified as the real user's home"
        )
    }

    /// A trailing slash is the same directory. Path comparison has to be
    /// standardized or the gate would be decided by how a script happened to
    /// spell the export.
    func testTrailingSlashOnTheRealHomeStillCounts() {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(
            ConfigPaths.isRealUserHome(environment: ["SUPERVISOR_HOME": realHome + "/"])
        )
    }

    // MARK: - The controller

    /// The suppressed instance, through every door it has: `present()`, the
    /// user-attention surface, and an action flash raised by the engine. None
    /// of them may put the band on screen.
    func testSuppressedInstanceNeverPutsTheBandOnScreen() {
        let vm = makeVM()
        let controller = HoverWindowController(
            vm: vm,
            isAnySessionActive: { true },
            // A terminal IS in front. Every other condition for showing the
            // band is met, so suppression is the only thing keeping it off the
            // screen and this test proves that and nothing weaker.
            frontmostBundleID: { Self.hostApp },
            presentsOnScreen: false
        )

        controller.present()
        XCTAssertFalse(controller.currentlyVisible, "present() must not show the band on a suppressed instance")
        XCTAssertFalse(
            controller.isVisibilityGateArmed,
            "a suppressed instance must not even arm the observer and poll timer — an armed timer is a second route to orderFrontRegardless"
        )

        controller.surfaceBriefly(for: 0.1)
        XCTAssertFalse(controller.currentlyVisible, "surfaceBriefly() must not show the band on a suppressed instance")

        // The self-rebuild announcement raises an action flash, which is the
        // one path that force-shows the band regardless of what is frontmost.
        // A deploy harness running against an isolated home hits this on every
        // relaunch, so it is the most likely way a suppressed instance would
        // have reached the screen anyway.
        vm.announceSelfRebuild(version: "0.0.0-test")
        XCTAssertTrue(vm.actionFlash, "precondition: announceSelfRebuild must raise the flash")
        XCTAssertFalse(controller.currentlyVisible, "an action flash must not show the band on a suppressed instance")

        controller.dismiss()
    }

    /// Production side of the same gate. It cannot assert the band is VISIBLE
    /// without drawing one, so it asserts the observable thing `present()` does
    /// on the way there: arming the workspace observer and the poll timer. That
    /// is the machinery the suppressed path deliberately skips, so if the gate
    /// were ever inverted this fails.
    func testRealHomeInstanceArmsTheVisibilityGate() {
        let controller = HoverWindowController(
            vm: makeVM(),
            isAnySessionActive: { true },
            frontmostBundleID: { Self.nonHostApp },
            presentsOnScreen: true
        )
        controller.present()
        XCTAssertTrue(
            controller.isVisibilityGateArmed,
            "a real-home instance must observe app switches and poll, exactly as it did before the gate existed"
        )
        // The band stays hidden for the pre-existing visibility rule, stated
        // rather than inherited: nothing that hosts a session is in front. The
        // arming above is the whole production-side claim this test can make
        // without drawing a pill on the owner's screen.
        XCTAssertFalse(
            controller.currentlyVisible,
            "no host app is frontmost, so the gate must keep the band off screen"
        )
        controller.dismiss()
    }

    /// The default the app actually uses. `swift test` runs with no
    /// `SUPERVISOR_HOME`, so a controller built the way `main.swift` builds it
    /// must come out presenting — this is the line that would catch a future
    /// edit that defaults the gate to closed and silently ships a Supervisor
    /// with no visible band.
    func testDefaultInitPresentsOnScreenForARealUser() throws {
        guard ConfigPaths.isRealUserHome else {
            throw XCTSkip("this test process runs with a SUPERVISOR_HOME override")
        }
        // Built the way main.swift builds it, except for the frontmost app.
        // `init` runs `applyVisibility` through the actionFlash sink, so on the
        // live read this line orders a real pill onto the owner's screen
        // whenever a terminal happens to be in front, which is the bug this
        // file exists to prevent.
        let controller = HoverWindowController(
            vm: makeVM(),
            frontmostBundleID: { Self.nonHostApp }
        )
        XCTAssertTrue(
            controller.presentsOnScreen,
            "the default must be to present; production behavior with no SUPERVISOR_HOME is unchanged"
        )
    }
}
