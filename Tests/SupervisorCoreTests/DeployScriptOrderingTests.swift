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

    // MARK: - The signing-identity guard aborts before anything is touched

    /// The guard is only worth having if it runs before the two steps that
    /// change the machine: the self-rebuild marker (a file in Application
    /// Support) and the rsync into /Applications. Run it after either one and
    /// the "ABORTED before touching" message is a lie, and the deploy that
    /// drops the Accessibility grant has already happened.
    func testSigningIdentityCheckRunsBeforeTheMarkerWriteAndTheSwap() throws {
        let script = try deployScript
        guard let check = firstExecutableLine(containing: "check-signing-identity.sh", in: script) else {
            return XCTFail("deploy.sh no longer runs the signing-identity check")
        }
        guard let markerWrite = firstExecutableLine(containing: "> \"$MARKER\"", in: script) else {
            return XCTFail("deploy.sh no longer writes the self-rebuild marker the way this test recognizes")
        }
        // The function DEFINITION (`swap_bundle() {`) sits near the top of the
        // script; the call site is what has to come after the check.
        guard let swap = firstExecutableLine(containing: "swap_bundle \"$SRC\"", in: script) else {
            return XCTFail("deploy.sh no longer calls swap_bundle the way this test recognizes")
        }
        XCTAssertLessThan(check, markerWrite,
                          "a check that runs after the marker write has already changed the machine it claims not to have touched")
        XCTAssertLessThan(check, swap,
                          "a check that runs after the swap cannot abort the swap")
    }

    /// The failing branch has to stop the script. An earlier shape ran the
    /// check for its output and carried on regardless, which reads identically
    /// in the log right up until the grant is gone.
    func testIdentityMismatchAbortsTheDeploy() throws {
        let script = try deployScript
        XCTAssertTrue(script.contains("if ! Scripts/check-signing-identity.sh"),
                      "deploy.sh must branch on the check's exit status, not just print it")
        XCTAssertTrue(script.contains("ABORTED before touching"),
                      "the abort has to say so; a silent exit looks like a successful deploy")
        XCTAssertTrue(script.contains("SUPERVISOR_ALLOW_IDENTITY_CHANGE"),
                      "a deliberate identity change needs a documented override")
    }

    /// The guard's own behavior, exercised for real: scratch bundles, actual
    /// `codesign` signatures, actual exit codes from
    /// `Scripts/check-signing-identity.sh`. Ad-hoc cases only here, because
    /// signing with a real identity reads a private key and can raise a
    /// keychain prompt that would hang an unattended run. Run the harness
    /// directly for the full set, including the same-identity and
    /// identity-change cases.
    func testCheckSigningIdentityHarnessPasses() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let harness = repoRoot.appendingPathComponent("Scripts/test-check-signing-identity.sh")
        guard FileManager.default.fileExists(atPath: harness.path),
              FileManager.default.fileExists(atPath: "/usr/bin/codesign") else {
            throw XCTSkip("harness or codesign unavailable")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [harness.path]
        var env = ProcessInfo.processInfo.environment
        env["CHECK_SIGNING_HARNESS_ADHOC_ONLY"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0,
                       "Scripts/test-check-signing-identity.sh failed:\n\(output)")
        XCTAssertTrue(
            output.contains("ad-hoc build with nothing installed is allowed"),
            "the first-install case is the one that regressed; it must still be exercised:\n\(output)"
        )
    }
}
