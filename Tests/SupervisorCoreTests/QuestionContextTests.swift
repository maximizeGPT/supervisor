// QuestionContextTests.swift — DEFECT 1.
//
// Non-API coverage for answering Claude Code's mid-session questions from
// repo context (not just PRINCIPLES.md), and for routing routine dev
// questions (commit/push/A-or-B) to the answerable "engineering" path
// instead of escalating them to the human.

import XCTest
import Foundation
@testable import SupervisorCore

final class QuestionContextTests: XCTestCase {

    // MARK: - The engineering message now carries repo context

    func testEngineeringMessageIncludesRepoContext() {
        let msg = QuestionAnswerer.engineeringUserMessage(
            question: "Should I commit this?",
            principles: "PRINCIPLES BODY",
            repoContext: "Current branch: autonomous-x (working branch)\nRecent commits:\nabc fix"
        )
        XCTAssertTrue(msg.contains("Should I commit this?"))
        XCTAssertTrue(msg.contains("autonomous-x"),
            "the answerer must receive the live branch so it can decide commit/push")
        XCTAssertTrue(msg.contains("Recent commits"))
        XCTAssertTrue(msg.contains("PRINCIPLES BODY"))
    }

    func testEngineeringMessageHandlesEmptyContext() {
        let msg = QuestionAnswerer.engineeringUserMessage(
            question: "Tab width 2 or 4?",
            principles: "P",
            repoContext: ""
        )
        XCTAssertTrue(msg.contains("(no repo context available)"))
    }

    // MARK: - Repo context gatherer (real git, no API)

    private func makeGitRepo(branch: String) throws -> String {
        let tmp = NSTemporaryDirectory() + "qctx-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        func git(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git"] + args
            p.currentDirectoryURL = URL(fileURLWithPath: tmp)
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
        }
        git(["init", "-q", "-b", branch])
        git(["config", "user.email", "t@t.t"])
        git(["config", "user.name", "t"])
        try "hello".write(toFile: tmp + "/f.txt", atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-q", "-m", "initial commit"])
        return tmp
    }

    func testGatherRepoContextWorkingBranch() async throws {
        let repo = try makeGitRepo(branch: "autonomous-20260101")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let ctx = await gatherRepoContextForAnswer(cwd: repo, branch: nil, timeout: 5)
        XCTAssertTrue(ctx.contains("autonomous-20260101"), "branch must be in context; got: \(ctx)")
        XCTAssertTrue(ctx.contains("working branch"),
            "a non-main branch must be flagged as a routine/working branch")
        XCTAssertTrue(ctx.contains("initial commit"), "recent commits must be in context")
    }

    func testGatherRepoContextProtectedBranch() async throws {
        let repo = try makeGitRepo(branch: "main")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let ctx = await gatherRepoContextForAnswer(cwd: repo, branch: "main", timeout: 5)
        XCTAssertTrue(ctx.contains("PROTECTED"),
            "main must be flagged PROTECTED so the answerer never auto-pushes/merges there")
    }

    func testGatherRepoContextDetectsUncommitted() async throws {
        let repo = try makeGitRepo(branch: "feature-x")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try "changed".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        let ctx = await gatherRepoContextForAnswer(cwd: repo, branch: "feature-x", timeout: 5)
        XCTAssertTrue(ctx.contains("Uncommitted changes"),
            "a 'should I commit this' question needs the uncommitted changes in context; got: \(ctx)")
    }

    // MARK: - Rubric routes routine dev questions to engineering

    func testRubricRoutesRoutineDevToEngineering() {
        let body = HardcodedRubric.userQuestionPending.body
        // Engineering now explicitly covers commit/push/proceed.
        XCTAssertTrue(body.contains("Should I commit this?"),
            "commit must be an engineering (answerable) example")
        XCTAssertTrue(body.contains("Should I push?"),
            "push (to a working branch) must be an engineering example")
        // Default rule flips routine dev to engineering.
        XCTAssertTrue(body.lowercased().contains("default routine") ||
                      body.contains("default to \"engineering\""),
            "routine dev-workflow questions must default to engineering, not safety")
    }

    func testRubricKeepsDestructiveAsSafety() {
        let body = HardcodedRubric.userQuestionPending.body
        XCTAssertTrue(body.contains("force-push to main") || body.contains("protected branch"),
            "genuinely destructive actions (protected branch) must remain safety")
        XCTAssertTrue(body.contains("rm -rf") || body.contains("delete this directory"),
            "data-loss actions must remain safety")
    }
}
