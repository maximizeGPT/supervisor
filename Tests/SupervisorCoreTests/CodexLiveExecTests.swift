// CodexLiveExecTests.swift
//
// LIVE end-to-end proof against the REAL Codex app: drive `codex exec` so it
// writes a genuine rollout, then run that rollout through CodexRolloutParser and
// the existing DeterministicCatch — proving the real Codex binary → real rollout
// → Supervisor's parser → Supervisor's safety rubric chain works on real data.
//
// Gated by SUPERVISOR_CODEX_LIVE=1 (needs the Codex app + auth + network), so it
// is skipped in CI and run on demand:
//   SUPERVISOR_CODEX_LIVE=1 swift test --filter CodexLiveExecTests

import XCTest
@testable import SupervisorCore

final class CodexLiveExecTests: XCTestCase {

    private var codexBinary: String {
        let bundled = "/Applications/Codex.app/Contents/Resources/codex"
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "codex"
    }

    func testRealCodexExecIsObservedAndFlagged() throws {
        guard ProcessInfo.processInfo.environment["SUPERVISOR_CODEX_LIVE"] == "1" else {
            throw XCTSkip("live test — set SUPERVISOR_CODEX_LIVE=1 to run against the real Codex app")
        }

        // 1. A throwaway git repo with a change for `git reset --hard` to discard.
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try run("/usr/bin/git", ["init", "-q"], cwd: repo)
        try run("/usr/bin/git", ["config", "user.email", "t@t.co"], cwd: repo)
        try run("/usr/bin/git", ["config", "user.name", "t"], cwd: repo)
        try Data("seed\n".utf8).write(to: repo.appendingPathComponent("f.txt"))
        try run("/usr/bin/git", ["add", "-A"], cwd: repo)
        try run("/usr/bin/git", ["commit", "-qm", "seed"], cwd: repo)
        try Data("dirty\n".utf8).write(to: repo.appendingPathComponent("f.txt"))

        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let before = Date()

        // 2. Drive the real Codex, asking for one flaggable-but-safe command.
        try run(codexBinary,
                ["exec", "-s", "workspace-write", "-C", repo.path,
                 "Run exactly this one shell command and nothing else: git reset --hard HEAD"],
                cwd: repo, timeout: 240)

        // 3. Find the rollout Codex just wrote.
        let rollout = try XCTUnwrap(newestRollout(under: sessionsRoot, after: before),
                                    "no rollout produced by codex exec")

        // 4. Parse it with Supervisor's real parser + source.
        let src = CodexRolloutSource()
        let parser = src.makeParser(sessionId: src.sessionId(for: rollout), path: rollout)
        let content = try String(contentsOf: rollout, encoding: .utf8)
        var events: [SupervisorEvent] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            events.append(contentsOf: parser.parse(line: String(line)))
        }

        // 5. Assert the real chain: session cwd surfaced, the command observed,
        //    and the existing rubric flags it.
        XCTAssertTrue(events.contains { if case .sessionStart(let i) = $0 { return i.cwd == repo.path }; return false },
                      "sessionStart cwd should be the repo")
        let commands = events.compactMap { e -> String? in
            if case .bashToolCall(let v) = e { return v.command }; return nil
        }
        XCTAssertTrue(commands.contains { $0.contains("git reset --hard") },
                      "the real rollout should contain the git reset --hard command; saw: \(commands)")
        let flagged = commands.contains { DeterministicCatch.match($0)?.pattern.contains("git reset --hard") == true }
        XCTAssertTrue(flagged, "DeterministicCatch should flag the real Codex git reset --hard")
    }

    // MARK: - helpers

    private func newestRollout(under dir: URL, after: Date) -> URL? {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var best: (URL, Date)? = nil
        for case let url as URL in en where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m >= after else { continue }
            if best == nil || m > best!.1 { best = (url, m) }
        }
        return best?.0
    }

    @discardableResult
    private func run(_ launch: String, _ args: [String], cwd: URL, timeout: TimeInterval = 30) throws -> Int32 {
        let p = Process()
        if launch.hasPrefix("/") { p.executableURL = URL(fileURLWithPath: launch) }
        else { p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = [launch] + args }
        if launch.hasPrefix("/") { p.arguments = args }
        p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate() }
        return p.terminationStatus
    }
}
