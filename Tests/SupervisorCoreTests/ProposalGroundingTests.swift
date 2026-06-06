import XCTest
@testable import SupervisorCore

/// TASK 2: a dispatch proposal for a session must ground against THAT session's
/// repo. A proposal naming another project's code is a cross-project leak.
final class ProposalGroundingTests: XCTestCase {

    func testExtractCodeSymbolsPicksCodeNotProse() {
        let syms = Set(RepoProposalGrounder.extractCodeSymbols(
            "Refactor detect_stale_build and LoopController in dispatch_loop_hook.py; build the page in Hero.tsx"))
        XCTAssertTrue(syms.contains("detect_stale_build"))   // snake_case
        XCTAssertTrue(syms.contains("LoopController"))        // CamelCase
        XCTAssertTrue(syms.contains("dispatch_loop_hook.py")) // file.ext
        XCTAssertTrue(syms.contains("Hero.tsx"))              // web file.ext
    }

    func testExtractIgnoresPlainProse() {
        XCTAssertEqual(
            RepoProposalGrounder.extractCodeSymbols("Write the landing page and improve the launch copy"),
            [], "plain English must yield no symbols")
    }

    func testTestSymbolFallbackClassification() {
        XCTAssertTrue(RepoProposalGrounder.isTestSymbol("TriageEngineTests"))
        XCTAssertTrue(RepoProposalGrounder.isTestSymbol("test_foo"))
        XCTAssertFalse(RepoProposalGrounder.isTestSymbol("LoopController"))
    }

    func testGroundsOwnRepoSymbolDropsCrossProject() async throws {
        // Build a throwaway repo with one known symbol.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "struct WidgetFooBar { let n = 1 }\n"
            .write(to: dir.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        func git(_ args: [String]) async throws {
            _ = try await runProcess(executable: "/usr/bin/env", args: ["git"] + args, cwd: dir.path, timeout: 10)
        }
        try await git(["init", "-q"])
        try await git(["add", "."])  // git grep searches tracked files

        let grounder = RepoProposalGrounder()
        // A proposal about THIS repo's own symbol grounds.
        let ownRepo = await grounder.missingSymbols(
            inProposal: "Refactor WidgetFooBar for clarity", cwd: dir.path)
        XCTAssertEqual(ownRepo, [], "a symbol that exists in the session's repo must ground")

        // A landing-page proposal names code that doesn't exist here -> leak.
        let crossProject = await grounder.missingSymbols(
            inProposal: "Build the LandingHeroSection in page.tsx with a feature_grid_section",
            cwd: dir.path)
        XCTAssertFalse(crossProject.isEmpty, "cross-project symbols must be reported missing")
        XCTAssertTrue(crossProject.contains("LandingHeroSection") || crossProject.contains("page.tsx"),
                      "the cross-project symbol must be in the missing list; got \(crossProject)")

        // Pure-prose proposal grounds trivially (nothing to verify).
        let prose = await grounder.missingSymbols(
            inProposal: "Improve the documentation", cwd: dir.path)
        XCTAssertEqual(prose, [])
    }
}
