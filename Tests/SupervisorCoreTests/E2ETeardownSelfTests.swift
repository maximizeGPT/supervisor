import XCTest

@testable import SupervisorCore

/// `Scripts/e2e/common.sh` is not Swift, but it is the thing that launches real
/// Supervisor instances onto the owner's screen, so its teardown contract
/// belongs in the suite that has to stay green.
///
/// The bug: the owner sent a screenshot of three stacked "Watching. All clear"
/// hover pills. Each harness scenario launches a real app with an isolated
/// `SUPERVISOR_HOME`, and the single-instance flock is namespaced by that same
/// seam, so an isolated instance coexists with the owner's real one BY DESIGN.
/// Two gaps then made that visible on his screen: a scenario interrupted with
/// Ctrl-C died without running its EXIT trap at all, and `s13` overwrote
/// `APP_PID_FILE` with the relaunched pid, which is how a deliberately
/// SIGSTOPped instance stopped being anything teardown knew about. A frozen
/// process keeps its window painted and can never run cleanup of its own.
///
/// The self-test drives the real `common.sh` against stand-in binaries, so
/// every exit path is exercised WITHOUT launching a Supervisor or putting a
/// window on anyone's screen. See `Scripts/e2e/selftest-teardown.sh` for the
/// case list.
final class E2ETeardownSelfTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SupervisorCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <repo>/
    }

    func testHarnessReclaimsEveryLaunchedProcessOnEveryExitPath() throws {
        let script = repoRoot.appendingPathComponent("Scripts/e2e/selftest-teardown.sh")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: script.path),
            "Scripts/e2e/selftest-teardown.sh is missing or not executable"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = repoRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Read before waiting: the self-test's output is small, but a pipe that
        // fills while the writer is still running deadlocks both sides.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(
            process.terminationStatus, 0,
            "e2e teardown self-test failed — the harness can leak a launched Supervisor onto the owner's screen:\n\(output)"
        )
    }
}
