// ProcessLocatorTests.swift — A2 verification.
//
// These tests spawn real FakeClaudeCLI subprocesses (built from the
// Sources/FakeClaudeCLI target) and exercise LiveProcessLocator against
// them. The test harness is independent of the code under test by design —
// FakeClaudeCLI imports no SupervisorCore types — so a passing test
// confirms the locator's libproc walk works end-to-end against a real
// process, not a stubbed one.
//
// Tests covered:
//   - happy path: one FakeClaudeCLI in the target cwd → locator returns
//     that PID.
//   - filter-by-cwd: a second FakeClaudeCLI in a DIFFERENT cwd
//     (via --multi-instance) doesn't confuse the lookup — the locator
//     still returns just the target-cwd match.
//   - ambiguous: two FakeClaudeCLI in the SAME cwd → locator returns
//     nil (logs locator.ambiguous).
//   - not found: no FakeClaudeCLI running at all → locator returns nil
//     (logs locator.not_found).
//   - exec-name filter: when execNamePatterns doesn't match, locator
//     returns nil even though the process is running in the right cwd.

import XCTest
import Darwin
@testable import SupervisorCore

final class ProcessLocatorTests: XCTestCase {

    // MARK: - Discovery + helpers

    /// Locate the FakeClaudeCLI binary `swift test` built into .build/.
    /// Searches every apple-macosx triple under .build so the test works
    /// on both arm64 and x86_64 dev machines.
    private func fakeClaudeBinary() throws -> URL {
        let fm = FileManager.default
        let buildDir = ".build"
        guard let triples = try? fm.contentsOfDirectory(atPath: buildDir) else {
            throw XCTSkip("no .build dir at \(buildDir) — run `swift build` first")
        }
        for triple in triples where triple.contains("apple-macosx") {
            let candidate = URL(fileURLWithPath: "\(buildDir)/\(triple)/debug/FakeClaudeCLI")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw XCTSkip("FakeClaudeCLI not found under .build/*/debug/ — run `swift build --target FakeClaudeCLI` first")
    }

    /// Spawn a FakeClaudeCLI subprocess. Caller is responsible for
    /// terminating the returned Process.
    private func spawnFakeClaude(
        binary: URL,
        cwd: String,
        jsonl: String,
        pidFile: String,
        intervalMs: Int = 100,
        maxEvents: Int = 600,         // long enough for any single test
        holdFd: Bool = true,
        multiInstance: Bool = false
    ) throws -> Process {
        let p = Process()
        p.executableURL = binary
        var args = [
            "--jsonl", jsonl,
            "--cwd", cwd,
            "--pid-file", pidFile,
            "--interval-ms", "\(intervalMs)",
            "--max-events", "\(maxEvents)",
        ]
        if !holdFd { args.append("--no-fd-hold") }
        if multiInstance { args.append("--multi-instance") }
        p.arguments = args
        // Suppress fake-claude's stderr — its FakeClaudeCLI:-style errors
        // would otherwise interleave with XCTest output.
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// Poll for the sidecar PID file to appear. Returns the parsed pid_t,
    /// or nil if the deadline expires.
    private func waitForPidFile(at path: String, timeout: TimeInterval = 4) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            usleep(50_000)
        }
        return nil
    }

    /// Canonical absolute path — the locator reads the kernel's cwd which
    /// is always canonical, so test cwds resolved against /tmp (which is
    /// symlinked to /private/tmp on macOS) must be realpath-ed before
    /// comparison.
    private func canonicalPath(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buf) != nil {
            return String(cString: buf)
        }
        return path
    }

    /// Create a unique temp directory for a single test. Returned path is
    /// already canonical.
    private func makeTempDir(_ name: String) throws -> String {
        let raw = NSTemporaryDirectory() + "locator-\(name)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return canonicalPath(raw)
    }

    private func cleanup(processes: [Process], dirs: [String]) {
        for p in processes where p.isRunning {
            p.terminate()
        }
        // Give signals a beat to land before deleting the JSONLs they hold.
        usleep(150_000)
        for d in dirs {
            try? FileManager.default.removeItem(atPath: d)
        }
    }

    // MARK: - Happy path

    func testLocatorFindsSingleFakeClaude() throws {
        let binary = try fakeClaudeBinary()
        let dir = try makeTempDir("single")
        let pidFile = dir + "/fake.pid"
        let jsonl = dir + "/test.jsonl"
        let proc = try spawnFakeClaude(binary: binary, cwd: dir, jsonl: jsonl, pidFile: pidFile)
        defer { cleanup(processes: [proc], dirs: [dir]) }

        guard let fakePid = waitForPidFile(at: pidFile) else {
            XCTFail("FakeClaudeCLI never wrote its pid file at \(pidFile)")
            return
        }

        let locator = LiveProcessLocator(execNamePatterns: ["FakeClaudeCLI"])
        let handle = locator.locate(targetCwd: dir)

        XCTAssertNotNil(handle, "expected to find FakeClaudeCLI in \(dir)")
        XCTAssertEqual(handle?.pid, fakePid)
        XCTAssertEqual(handle?.cwd, dir)
        XCTAssertTrue(handle?.execPath.contains("FakeClaudeCLI") ?? false,
                      "execPath should contain FakeClaudeCLI; got \(handle?.execPath ?? "(nil)")")
    }

    // MARK: - Filter by cwd (--multi-instance: parent in dir A, child in /tmp)

    func testLocatorReturnsOnlyTheCwdMatchAmongMultiplePids() throws {
        let binary = try fakeClaudeBinary()
        let dir = try makeTempDir("multi-cwd")
        let pidFile = dir + "/fake.pid"
        let jsonl = dir + "/test.jsonl"
        let proc = try spawnFakeClaude(
            binary: binary, cwd: dir, jsonl: jsonl, pidFile: pidFile,
            multiInstance: true
        )
        defer { cleanup(processes: [proc], dirs: [dir]) }

        guard let parentPid = waitForPidFile(at: pidFile) else {
            XCTFail("parent never wrote pid file")
            return
        }
        // Give child time to also start (it chdir's to /tmp before writing
        // its sidecar at pidFile + ".child").
        _ = waitForPidFile(at: pidFile + ".child", timeout: 2)

        let locator = LiveProcessLocator(execNamePatterns: ["FakeClaudeCLI"])

        // Locator for the parent's cwd returns ONLY the parent.
        let parentHandle = locator.locate(targetCwd: dir)
        XCTAssertEqual(parentHandle?.pid, parentPid,
                       "child in /tmp should not have polluted the lookup for cwd=\(dir)")

        // (We don't assert child lookup against /tmp here — /tmp can hold
        // other unrelated FakeClaudeCLI invocations across concurrent
        // tests. The single-test invariant is what matters: the lookup
        // for `dir` returns the parent only.)
    }

    // MARK: - Ambiguous (two in same cwd)

    func testLocatorReturnsNilWhenTwoProcessesShareCwd() throws {
        let binary = try fakeClaudeBinary()
        let dir = try makeTempDir("ambiguous")
        let pidFile1 = dir + "/fake1.pid"
        let pidFile2 = dir + "/fake2.pid"
        let proc1 = try spawnFakeClaude(binary: binary, cwd: dir,
                                        jsonl: dir + "/a.jsonl", pidFile: pidFile1)
        let proc2 = try spawnFakeClaude(binary: binary, cwd: dir,
                                        jsonl: dir + "/b.jsonl", pidFile: pidFile2)
        defer { cleanup(processes: [proc1, proc2], dirs: [dir]) }

        guard waitForPidFile(at: pidFile1) != nil,
              waitForPidFile(at: pidFile2) != nil else {
            XCTFail("one of the fake claudes never wrote its pid file")
            return
        }

        let locator = LiveProcessLocator(execNamePatterns: ["FakeClaudeCLI"])
        let handle = locator.locate(targetCwd: dir)
        XCTAssertNil(handle, "two FakeClaudeCLI processes in the same cwd should produce locator.ambiguous → nil")
    }

    // MARK: - Not found

    func testLocatorReturnsNilWhenNoMatchingProcess() throws {
        // No fake claude launched. Locator queried for a cwd with no
        // matching process should return nil and log locator.not_found.
        let locator = LiveProcessLocator(execNamePatterns: ["FakeClaudeCLI"])
        let handle = locator.locate(targetCwd: "/var/folders/no/such/path/exists-\(UUID().uuidString)")
        XCTAssertNil(handle)
    }

    // MARK: - Exec-name filter

    func testLocatorExcludesProcessesNotMatchingExecName() throws {
        let binary = try fakeClaudeBinary()
        let dir = try makeTempDir("execname")
        let pidFile = dir + "/fake.pid"
        let jsonl = dir + "/test.jsonl"
        let proc = try spawnFakeClaude(binary: binary, cwd: dir, jsonl: jsonl, pidFile: pidFile)
        defer { cleanup(processes: [proc], dirs: [dir]) }

        guard waitForPidFile(at: pidFile) != nil else {
            XCTFail("FakeClaudeCLI never wrote its pid file")
            return
        }

        // Same cwd, but the locator is looking for "claude" / "claude-code",
        // not "FakeClaudeCLI" — the filter must exclude.
        let locator = LiveProcessLocator(execNamePatterns: ["claude", "claude-code"])
        let handle = locator.locate(targetCwd: dir)
        XCTAssertNil(handle,
                     "execName filter ['claude','claude-code'] should exclude FakeClaudeCLI")
    }
}
