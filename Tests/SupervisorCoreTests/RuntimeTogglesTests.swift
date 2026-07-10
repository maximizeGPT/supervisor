import XCTest
@testable import SupervisorCore

/// RuntimeToggles are marker files the running app reads live. These verify the
/// primitive round-trips — using a TEMP dir so a test never creates a real
/// marker the deployed Supervisor would pick up.
final class RuntimeTogglesTests: XCTestCase {

    func testMarkerRoundTripInTempDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("toggles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(RuntimeToggles.isOn("x.marker", dir: dir), "absent marker reads off")
        RuntimeToggles.setOn("x.marker", true, dir: dir)
        XCTAssertTrue(RuntimeToggles.isOn("x.marker", dir: dir), "set reads on (and creates the dir)")
        RuntimeToggles.setOn("x.marker", false, dir: dir)
        XCTAssertFalse(RuntimeToggles.isOn("x.marker", dir: dir), "cleared reads off")
    }

    func testTwoMarkersAreIndependent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("toggles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        RuntimeToggles.setOn("a.marker", true, dir: dir)
        XCTAssertTrue(RuntimeToggles.isOn("a.marker", dir: dir))
        XCTAssertFalse(RuntimeToggles.isOn("b.marker", dir: dir),
                       "one toggle must not flip the other")
    }

    /// v0.2.0 M7: the stall watchdog is DEFAULT ON via a DISABLE marker (like
    /// loopCapDisabled). Absent marker -> disabled == false -> the feature is
    /// active; present -> disabled == true. Verified in a temp dir so the real
    /// marker is never created.
    func testWatchdogDefaultOnDisableMarker() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("toggles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(RuntimeToggles.watchdogDisabled(dir: dir),
                       "no marker -> watchdog NOT disabled (default ON)")
        RuntimeToggles.setWatchdogDisabled(true, dir: dir)
        XCTAssertTrue(RuntimeToggles.watchdogDisabled(dir: dir),
                      "marker present -> watchdog disabled")
        RuntimeToggles.setWatchdogDisabled(false, dir: dir)
        XCTAssertFalse(RuntimeToggles.watchdogDisabled(dir: dir),
                       "marker removed -> watchdog active again")
    }
}
