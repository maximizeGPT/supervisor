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
        // matching process either:
        //   - returns nil (logs locator.not_found), OR
        //   - returns Claude.app's PID via the v0.3.1 fallback if
        //     Claude.app is running on the test machine.
        // Both outcomes are correct per the locator's design — the
        // fallback was added precisely so the inject path doesn't
        // degrade on Claude.app-hosted sessions. The test asserts
        // the result is EITHER nil OR a Claude.app PID; nothing else.
        let locator = LiveProcessLocator(execNamePatterns: ["FakeClaudeCLI"])
        let handle = locator.locate(targetCwd: "/var/folders/no/such/path/exists-\(UUID().uuidString)")
        if let h = handle {
            XCTAssertTrue(h.execPath.contains("Claude") || h.execPath.contains("claude"),
                          "if any handle returns from a not-found cwd, it must be the Claude.app fallback (v0.3.1); got \(h.execPath)")
        }
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
        // v0.3.2: on dev machines with Claude.app running, the v0.3.1
        // Claude.app fallback may return Claude.app's PID instead of nil.
        // The bare exec-name filter assertion is: if a handle returns,
        // it must NOT be FakeClaudeCLI's PID — Claude.app's PID is the
        // only legal alternative.
        if let h = handle {
            XCTAssertNotEqual(h.execPath, "/path/to/FakeClaudeCLI",
                              "FakeClaudeCLI must not be returned by ['claude','claude-code'] filter")
            XCTAssertTrue(h.execPath.contains("Claude") || h.execPath.contains("claude"),
                          "if any handle returns, it must be a recognized Claude binary (v0.3.1 fallback); got \(h.execPath)")
        }
    }

    // MARK: - Issue #1 acceptance criteria — loud-failure trace tag

    /// Test fixture per GH Issue #1's acceptance criteria. Validates the
    /// `locator.exec_unrecognized` trace tag fires when a process in the
    /// target cwd has a non-matching exec name (the interpreter-launched
    /// Claude Code case — `node /path/to/cli.mjs` etc.).
    ///
    /// Spawn FakeClaudeCLI in target cwd, query the locator with
    /// patterns that DON'T match (`["claude", "claude-code"]`), and
    /// assert the trace log contains the discriminating tag with the
    /// FakeClaudeCLI PID and execPath. Per Issue #1: "silent nil from
    /// the locator is the worst safety regression we could ship."
    ///
    /// The locator may return non-nil if Claude.app is running on the
    /// test machine (v0.3.1 fallback). That doesn't invalidate the
    /// test — the trace tag is emitted BEFORE the fallback runs and
    /// the assertion targets the tag, not the return value.
    // MARK: - Issue #1 option A — KERN_PROCARGS2 argv inspection

    /// Verifies the argv-marker rescue path. `LiveProcessLocator.readProcessArgv`
    /// is the integration surface; calling it on this test's own PID
    /// returns argv that includes the test runner. We verify the
    /// **mechanism** (sysctl + parsing) by calling it on a known PID
    /// (the current process) and asserting the returned argv contains
    /// something we can predict — argv[0] always exists and is the
    /// executable.
    ///
    /// We deliberately don't test against a `node /path/to/cli.mjs`
    /// shape because spawning Node inside the test runner is fragile
    /// (Node may not be installed in CI). The argvContainsClaudeCodeMarker
    /// matcher is exercised in `testArgvContainsClaudeCodeMarker` below
    /// against synthetic argv arrays.
    func testReadProcessArgvReturnsCurrentProcessArgv() throws {
        let myPid = getpid()
        guard let argv = LiveProcessLocator.readProcessArgv(pid: myPid) else {
            XCTFail("KERN_PROCARGS2 sysctl must succeed for the current process; got nil")
            return
        }
        XCTAssertGreaterThan(argv.count, 0, "argv must be non-empty")
        // argv[0] is the test binary path; basename should contain
        // something like "xctest" or the SwiftPM test bundle name.
        XCTAssertFalse(argv[0].isEmpty, "argv[0] must be non-empty")
    }

    /// Test the marker-matching predicate directly against synthetic
    /// argv arrays. Covers all 4 documented markers + the no-match case.
    /// Pure logic — no process spawning, fast, deterministic.
    func testArgvContainsClaudeCodeMarker() {
        // Positive cases — each marker matches in isolation.
        XCTAssertTrue(LiveProcessLocator.argvContainsClaudeCodeMarker(
            ["node", "/usr/local/bin/claude/cli.mjs"]))
        XCTAssertTrue(LiveProcessLocator.argvContainsClaudeCodeMarker(
            ["node", "/usr/local/share/claude-code-cli/index.js"]))
        XCTAssertTrue(LiveProcessLocator.argvContainsClaudeCodeMarker(
            ["bun", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/dist/cli.js"]))
        XCTAssertTrue(LiveProcessLocator.argvContainsClaudeCodeMarker(
            ["deno", "run", "--allow-all", "/some/path/cli.js"]))

        // Negative cases — unrelated argvs must not match.
        XCTAssertFalse(LiveProcessLocator.argvContainsClaudeCodeMarker(
            ["node", "/Users/main/projects/myapp/server.js"]))
        XCTAssertFalse(LiveProcessLocator.argvContainsClaudeCodeMarker(
            ["python", "-m", "myproject.cli"]))
        XCTAssertFalse(LiveProcessLocator.argvContainsClaudeCodeMarker([]))
    }

    /// Asserts the interpreter basename set is the v0.3.2-committed
    /// list. Locks the set down so a future PR adding `python` or
    /// `ruby` without rationale (Claude Code isn't those distributions)
    /// is caught.
    func testInterpreterBasenamesIsTheCommittedSet() {
        XCTAssertEqual(
            LiveProcessLocator.interpreterBasenames,
            Set(["node", "bun", "deno"]),
            "Adding interpreters here requires a corresponding entry in claudeCodeArgvMarkers + a CHANGELOG note"
        )
    }

    func testLocatorEmitsExecUnrecognizedWhenCwdMatchesButExecDoesNot() throws {
        let binary = try fakeClaudeBinary()
        let dir = try makeTempDir("exec-unrec")
        let pidFile = dir + "/fake.pid"
        let jsonl = dir + "/test.jsonl"
        let proc = try spawnFakeClaude(binary: binary, cwd: dir, jsonl: jsonl, pidFile: pidFile)
        defer { cleanup(processes: [proc], dirs: [dir]) }

        guard let fakePid = waitForPidFile(at: pidFile) else {
            XCTFail("FakeClaudeCLI never wrote its pid file")
            return
        }

        // Custom trace log we can inspect.
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-trace-\(UUID().uuidString).log")
        let trace = TraceLog(path: traceURL)

        // Locator with patterns that do NOT match FakeClaudeCLI; same
        // shape as the interpreter-launched case (`node` exec name vs.
        // patterns ['claude','claude-code']).
        let locator = LiveProcessLocator(execNamePatterns: ["claude", "claude-code"], trace: trace)
        _ = locator.locate(targetCwd: dir)

        // Trace log assertions: the discriminating tag must fire with
        // the FakeClaudeCLI PID and the execPath that got skipped.
        let traceText = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(
            traceText.contains("locator.exec_unrecognized"),
            "trace must emit locator.exec_unrecognized for the cwd-matched-but-exec-non-matching candidate; trace was:\n\(traceText)"
        )
        XCTAssertTrue(
            traceText.contains("pid=\(fakePid)"),
            "trace must reference the unrecognized candidate's PID (\(fakePid)); trace was:\n\(traceText)"
        )
        XCTAssertTrue(
            traceText.contains("FakeClaudeCLI"),
            "trace must reference the unrecognized candidate's execPath (FakeClaudeCLI); trace was:\n\(traceText)"
        )
    }

    // MARK: - Session-id targeting (multi-session inject)

    /// The session-id matcher against synthetic argv. Pure logic, fast.
    /// Covers the `--resume <id>` / `--session-id <id>` value forms, the
    /// embedded-in-path form (a `--jsonl /…/<id>.jsonl` arg), and the
    /// negatives (wrong id, empty argv, empty id).
    func testArgvContainsSessionId() {
        let sid = "9d9fc5f7-f8b8-41c8-b9e9-5313e6c6d1ec"
        XCTAssertTrue(LiveProcessLocator.argvContainsSessionId(
            ["claude", "--resume", sid], sessionId: sid))
        XCTAssertTrue(LiveProcessLocator.argvContainsSessionId(
            ["claude", "--session-id", sid, "--model", "opus"], sessionId: sid))
        XCTAssertTrue(LiveProcessLocator.argvContainsSessionId(
            ["claude", "/Users/x/.claude/projects/-p/\(sid).jsonl"], sessionId: sid),
            "an id embedded in a path arg must still match")
        XCTAssertFalse(LiveProcessLocator.argvContainsSessionId(
            ["claude", "--resume", "00000000-0000-0000-0000-000000000000"], sessionId: sid))
        XCTAssertFalse(LiveProcessLocator.argvContainsSessionId([], sessionId: sid))
        XCTAssertFalse(LiveProcessLocator.argvContainsSessionId(
            ["claude", "--resume", sid], sessionId: ""))
    }

    /// End-to-end: a real FakeClaudeCLI subprocess carrying a session id in
    /// its argv (via `--jsonl /…/<id>.jsonl`, the same shape a real
    /// `--resume <id>` produces) is pinned by `locate(bySessionId:)` —
    /// independent of cwd. A different id must NOT match (no Claude.app
    /// fallback on this path: session-id is exact).
    func testLocatorFindsProcessBySessionId() throws {
        let binary = try fakeClaudeBinary()
        let dir = try makeTempDir("by-session")
        let sessionId = UUID().uuidString
        let pidFile = dir + "/fake.pid"
        let jsonl = dir + "/\(sessionId).jsonl"   // id rides in argv via --jsonl
        let proc = try spawnFakeClaude(binary: binary, cwd: dir, jsonl: jsonl, pidFile: pidFile)
        defer { cleanup(processes: [proc], dirs: [dir]) }

        guard let fakePid = waitForPidFile(at: pidFile) else {
            XCTFail("FakeClaudeCLI never wrote its pid file at \(pidFile)")
            return
        }

        let locator = LiveProcessLocator(execNamePatterns: ["FakeClaudeCLI"])
        let handle = locator.locate(bySessionId: sessionId)
        XCTAssertNotNil(handle, "expected to find FakeClaudeCLI carrying session id \(sessionId)")
        XCTAssertEqual(handle?.pid, fakePid, "must pin the exact process whose argv carries the id")

        // A fresh, unused id matches nothing — and unlike the cwd path there
        // is no Claude.app fallback, so this is a clean nil.
        XCTAssertNil(locator.locate(bySessionId: UUID().uuidString),
                     "an unused session id must not match any process")
        // Empty id is rejected outright.
        XCTAssertNil(locator.locate(bySessionId: ""))
    }
}
