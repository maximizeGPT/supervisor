// ContextHealthMonitorTests.swift — the ambient verdict derivation + the
// once-only nudge guarantee. Deterministic, no network: an audit over a temp
// tree drives the monitor and we assert the published state + the single-fire
// nudge. @MainActor because the monitor is main-actor-isolated.

import XCTest
@testable import SupervisorCore

@MainActor
final class ContextHealthMonitorTests: XCTestCase {

    private func makeTree(_ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Spin the run loop until `predicate()` or a timeout — the audit runs on a
    /// detached Task and hops back to the main actor.
    private func wait(until predicate: @escaping () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testLeanTreeYieldsLeanState() throws {
        let root = try makeTree { r in
            try write("# One\njust one skill manifest with a single unremarkable line here\n",
                      to: r.appendingPathComponent(".claude/skills/one/SKILL.md"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let m = ContextHealthMonitor(root: root)
        m.refresh()
        wait { if case .lean = m.state { return true }; return false }
        XCTAssertEqual(m.state, .lean)
        XCTAssertNotNil(m.lastAuditAt)
    }

    /// Build a tree with notable drift: two skills sharing content plus a
    /// checked-in asset big enough to cross the notable prune band.
    private func makeNotableTree() throws -> URL {
        try makeTree { r in
            let shared = "a shared cardinal rule long enough to count as real content here\na second shared cardinal rule likewise long enough to be counted\na third shared cardinal rule also long enough to be counted now\n"
            try write("# A\n" + shared, to: r.appendingPathComponent(".claude/skills/a/SKILL.md"))
            try write("# B\n" + shared, to: r.appendingPathComponent(".claude/skills/b/SKILL.md"))
            // A 700KB checked-in asset -> a NOTABLE prune recommendation (the
            // prune band goes notable at >= 3x the 200KB asset budget = 600KB).
            let data = Data(count: 700 * 1024)
            try FileManager.default.createDirectory(at: r.appendingPathComponent(".claude/skills/a/assets"), withIntermediateDirectories: true)
            try data.write(to: r.appendingPathComponent(".claude/skills/a/assets/art.png"))
        }
    }

    /// Mutable fire counter the async nudge callback can safely update.
    private final class FireBox: @unchecked Sendable { var fires = 0 }

    /// Spin the run loop briefly so the monitor's post-callback Task (the
    /// persist step) runs to completion before the test proceeds.
    private func settle() {
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testDuplicationTreeYieldsCleanupsAndFiresNudgeExactlyOnce() throws {
        let root = try makeNotableTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let box = FireBox()
        // Isolated defaults so the persisted once-ever flag doesn't leak across runs.
        let m = ContextHealthMonitor(root: root, defaults: UserDefaults(suiteName: "ch-test-\(UUID().uuidString)")!)
        m.onFirstNotable = { _, _ in box.fires += 1; return true }
        m.refresh()
        wait { if case .cleanups = m.state { return true }; return false }
        guard case .cleanups(let count, _, let notable) = m.state else { return XCTFail("expected cleanups, got \(m.state)") }
        XCTAssertGreaterThan(count, 0)
        XCTAssertTrue(notable, "a 300KB checked-in asset should read as notable")
        wait { box.fires == 1 }
        XCTAssertEqual(box.fires, 1, "the nudge fires on the first notable crossing")
        settle()   // let the post-callback persist Task land before re-auditing

        // A second refresh over the same notable tree must NOT fire the nudge again.
        m.refresh()
        wait { if case .cleanups = m.state { return true }; return false }
        settle()
        XCTAssertEqual(box.fires, 1, "the earned nudge fires at most once per process")
    }

    func testNudgePersistedOnlyAfterSuccessfulPost() throws {
        let root = try makeNotableTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "ch-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let nudgeKey = "contextHealth.nudged." + root.path
        let box = FireBox()
        let m = ContextHealthMonitor(root: root, defaults: defaults)

        // 1. The post FAILS: the once-ever flag must NOT be persisted, so a
        //    later notable crossing retries instead of the nudge being burned.
        m.onFirstNotable = { _, _ in box.fires += 1; return false }
        m.refresh()
        wait { if case .cleanups = m.state { return true }; return false }
        wait { box.fires == 1 }
        settle()
        XCTAssertFalse(defaults.bool(forKey: nudgeKey),
                       "a FAILED post must not persist the once-ever flag")
        m.refresh()
        wait { box.fires == 2 }
        XCTAssertEqual(box.fires, 2, "after a failed post the next notable crossing retries the nudge")
        settle()

        // 2. The post SUCCEEDS: now the flag persists and the nudge never refires.
        m.onFirstNotable = { _, _ in box.fires += 1; return true }
        m.refresh()
        wait { box.fires == 3 }
        settle()
        XCTAssertTrue(defaults.bool(forKey: nudgeKey),
                      "a successful post persists the once-ever flag")
        m.refresh()
        wait { if case .cleanups = m.state { return true }; return false }
        settle()
        XCTAssertEqual(box.fires, 3, "once posted successfully, the nudge never fires again")
    }
}
