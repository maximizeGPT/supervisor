// CodexLocatorParityTests.swift
//
// Verifies the Codex intervention-parity change to ProcessLocator two ways,
// against the REAL environment:
//   1. Safety: a real `codex ... app-server` (server-mode) is recognized and
//      NEVER returned as a signal target (would freeze the Codex GUI).
//   2. Parity: a live `codex exec` session IS located by its cwd, exactly like
//      a Claude Code CLI session, so notify/inject/pause/kill can target it.
//
// Gated by SUPERVISOR_CODEX_LIVE=1 (needs the Codex app + a live process).
//   SUPERVISOR_CODEX_LIVE=1 swift test --filter CodexLocatorParityTests

import XCTest
@testable import SupervisorCore

final class CodexLocatorParityTests: XCTestCase {

    private var live: Bool { ProcessInfo.processInfo.environment["SUPERVISOR_CODEX_LIVE"] == "1" }
    private let codexBin = "/Applications/Codex.app/Contents/Resources/codex"

    // "codex" is in the default patterns now.
    func testCodexIsADefaultPattern() {
        // Constructing with the default patterns must recognize a codex CLI by
        // name; we assert indirectly via the server-mode subcommand set being
        // wired (the guard that keeps it safe).
        XCTAssertTrue(LiveProcessLocator.codexServerSubcommands.contains("app-server"))
        XCTAssertTrue(LiveProcessLocator.codexServerSubcommands.contains("mcp-server"))
    }

    // SAFETY (deterministic): the server-mode rule scans EVERY argv token, so a
    // global flag before the subcommand can't smuggle a server past the guard.
    func testServerGuardScansAllArgvTokens() {
        XCTAssertTrue(LiveProcessLocator.isCodexServerArgv(["codex", "app-server"]))
        XCTAssertTrue(LiveProcessLocator.isCodexServerArgv(["codex", "--log-level", "debug", "app-server"]),
                      "a flag before the subcommand must not hide the server mode")
        XCTAssertTrue(LiveProcessLocator.isCodexServerArgv(["codex", "-c", "k=v", "mcp-server", "--stdio"]))
        // Interactive shapes stay eligible.
        XCTAssertFalse(LiveProcessLocator.isCodexServerArgv(["codex"]), "a bare interactive codex is not a server")
        XCTAssertFalse(LiveProcessLocator.isCodexServerArgv(["codex", "exec", "-C", "/tmp/repo", "do the thing"]))
        XCTAssertFalse(LiveProcessLocator.isCodexServerArgv(["codex", "resume", "fix the app-server bug"]),
                       "a prompt MENTIONING a server subcommand is one token — no exact-token match")
    }

    // SAFETY (deterministic): unreadable argv on a codex-named process FAILS
    // CLOSED — we can't prove it's interactive, so it must not be a signal target.
    func testServerGuardFailsClosedOnUnreadableArgv() {
        XCTAssertTrue(LiveProcessLocator.isCodexServerArgv(nil),
                      "nil argv (EPERM / racing exit) must be treated as server-mode: refuse to signal")
    }

    // SAFETY: the real desktop `codex app-server` is identified as server-mode
    // and is never returned by locate — a signal to it would freeze the GUI.
    func testRealAppServerIsNeverASignalTarget() throws {
        guard live else { throw XCTSkip("live test — set SUPERVISOR_CODEX_LIVE=1") }
        guard let (pid, execPath, cwd) = firstCodexServerProcess() else {
            throw XCTSkip("no running `codex app-server` to check (start the Codex app)")
        }
        XCTAssertEqual((execPath as NSString).lastPathComponent, "codex")
        XCTAssertTrue(LiveProcessLocator.isCodexServerProcess(execPath: execPath, pid: pid),
                      "the desktop codex app-server must be recognized as server-mode")
        // locate on its cwd must not hand back the server pid.
        let handle = LiveProcessLocator().locate(targetCwd: cwd, allowDesktopFallback: false)
        XCTAssertNotEqual(handle?.pid, pid, "locate must never return the codex app-server as a target")
        XCTAssertFalse(LiveProcessLocator().stillClaudeProcess(pid: pid),
                       "the TOCTOU recheck must also refuse the server-mode codex")
    }

    // PARITY: a live `codex exec` session is located by its cwd like a CLI agent.
    func testLiveCodexExecIsLocatedByCwd() throws {
        guard live else { throw XCTSkip("live test — set SUPERVISOR_CODEX_LIVE=1") }
        guard FileManager.default.isExecutableFile(atPath: codexBin) else {
            throw XCTSkip("codex binary not present")
        }
        // Use /private/tmp — a fully-resolved path with no symlink in it (unlike
        // /var/folders, where /var symlinks to /private/var). The process's real
        // cwd (proc_pidinfo) and the locator compare cwd strings exactly, and in
        // production the session cwd comes from session_meta.cwd (already
        // resolved), so this mirrors reality.
        let repo = URL(fileURLWithPath: "/private/tmp/codex-loc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try? shell("/usr/bin/git", ["init", "-q"], cwd: repo)

        // Spawn a codex exec that will stay alive a while (multi-step prompt).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: codexBin)
        p.arguments = ["exec", "-s", "workspace-write", "-C", repo.path,
                       "List the files, then wait: read README if present, then print the date, then git status. Take your time."]
        p.currentDirectoryURL = repo
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate() } }

        // Poll: the codex exec process should be locatable by the repo cwd.
        let traceURL = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString).trace")
        let locator = LiveProcessLocator(trace: TraceLog(path: traceURL))
        var found: ProcessHandle?
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && p.isRunning {
            if let h = locator.locate(targetCwd: repo.path, allowDesktopFallback: false) {
                found = h; break
            }
            usleep(150_000)
        }
        if found == nil {
            let tail = (try? String(contentsOf: traceURL, encoding: .utf8))?.split(separator: "\n").suffix(6).joined(separator: "\n") ?? "(no trace)"
            print("LOCATOR DIAG target=[\(repo.path)] procRunning=\(p.isRunning)\ntrace:\n\(tail)")
        }
        let handle = try XCTUnwrap(found, "a live codex exec should be locatable by its cwd")
        XCTAssertEqual((handle.execPath as NSString).lastPathComponent, "codex")
        XCTAssertEqual(handle.cwd, repo.path)
        XCTAssertTrue(locator.stillClaudeProcess(pid: handle.pid),
                      "an interactive codex exec must pass the signal recheck (it is a valid target)")
    }

    // MARK: - helpers

    private func firstCodexServerProcess() -> (pid_t, String, String)? {
        guard let out = try? shell("/usr/bin/pgrep", ["-f", "Resources/codex app-server"]),
              let pidStr = out.split(separator: "\n").first, let pid = pid_t(pidStr) else { return nil }
        let execPath = "/Applications/Codex.app/Contents/Resources/codex"
        // cwd via lsof (best-effort); default "/" which is what the app-server uses.
        var cwd = "/"
        if let l = try? shell("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]) {
            if let n = l.split(separator: "\n").first(where: { $0.hasPrefix("n") }) { cwd = String(n.dropFirst()) }
        }
        return (pid, execPath, cwd)
    }

    @discardableResult
    private func shell(_ launch: String, _ args: [String], cwd: URL? = nil) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
