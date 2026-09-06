import XCTest
@testable import SupervisorCore

/// `Scripts/deploy.sh` is not Swift, but one line's POSITION in it is
/// load-bearing product behavior, so it gets a test.
///
/// The self-rebuild marker has two readers. The relaunched app reads it to
/// announce "Supervisor updated itself", which can happen any time before the
/// relaunch. The status-bar companion reads it in the moment it notices its
/// parent died, to decide whether that death was deliberate, and that check
/// happens within ONE 2s tick of the pkill. The marker was written seconds
/// AFTER the pkill, so the deploy exemption never actually applied: it
/// survived only because the unanchored pkill pattern also matched and killed
/// the companion itself. Anchor the pattern, or reorder the steps, and every
/// deploy would have paged the owner "Supervisor stopped".
final class DeployScriptOrderingTests: XCTestCase {

    private var deployScript: String {
        get throws {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // SupervisorCoreTests/
                .deletingLastPathComponent()   // Tests/
                .deletingLastPathComponent()   // <repo>/
            return try String(
                contentsOf: repoRoot.appendingPathComponent("Scripts/deploy.sh"),
                encoding: .utf8
            )
        }
    }

    /// Executable lines only. The comments discuss both the marker and the
    /// pkill, and matching those would make the assertion meaningless.
    private func firstExecutableLine(containing needle: String, in script: String) -> Int? {
        for (i, raw) in script.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.contains(needle) { return i }
        }
        return nil
    }

    func testSelfRebuildMarkerIsWrittenBeforeTheProcessIsKilled() throws {
        let script = try deployScript
        guard let markerWrite = firstExecutableLine(containing: "> \"$MARKER\"", in: script) else {
            return XCTFail("deploy.sh no longer writes the self-rebuild marker the way this test recognizes")
        }
        guard let kill = firstExecutableLine(containing: "pkill", in: script) else {
            return XCTFail("deploy.sh no longer stops the running app the way this test recognizes")
        }
        XCTAssertLessThan(
            markerWrite, kill,
            "the companion reads the marker within one 2s tick of the kill, so writing it afterwards means the deploy exemption never applies and every deploy pages the owner a false outage"
        )
    }

    /// The marker the companion consults is the one deploy.sh writes. A rename
    /// on either side silently re-breaks the exemption.
    func testDeployWritesTheMarkerPathTheCompanionReads() throws {
        let script = try deployScript
        let expected = ConfigPaths(home: URL(fileURLWithPath: "/stub"))
            .selfRebuildMarkerPath.lastPathComponent
        XCTAssertTrue(script.contains(expected),
                      "deploy.sh must write \(expected), the file reparentAction checks")
    }
}
