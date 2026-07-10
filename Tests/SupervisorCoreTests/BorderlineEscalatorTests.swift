// BorderlineEscalatorTests.swift — payoff 2 (gated). Classifier is pure;
// escalator runs against an injected fake panel. No network, no live triage.

import XCTest
@testable import SupervisorCore

final class BorderlineEscalatorTests: XCTestCase {

    private func cand(_ category: String, _ severity: FlagSeverity) -> TriageCandidate {
        TriageCandidate(category: category, severity: severity, matchedCommand: "cmd",
                        action: .notify, reasoningPlain: "p", reasoningTechnical: "t")
    }

    // MARK: - Classifier

    func testDeterministicCatchIsNeverBorderline() {
        // Even a medium destructive candidate is not second-guessed once the
        // syntactic catch has fired — the catch is authoritative.
        XCTAssertFalse(BorderlineClassifier.isBorderline(
            command: "git reset --hard",
            candidates: [cand("destructive_action_pending", .medium)],
            deterministicCaught: true))
    }

    func testMediumDestructiveIsBorderline() {
        XCTAssertTrue(BorderlineClassifier.isBorderline(
            command: "git clean -fdx",
            candidates: [cand("destructive_action_pending", .medium)],
            deterministicCaught: false))
    }

    func testMediumEditsIsBorderline() {
        XCTAssertTrue(BorderlineClassifier.isBorderline(
            command: "echo x >> ~/.zshrc",
            candidates: [cand("edits_outside_worktree", .medium)],
            deterministicCaught: false))
    }

    func testHighDestructiveIsNotBorderline() {
        // Already high — no upside to a second opinion; don't pay for a panel.
        XCTAssertFalse(BorderlineClassifier.isBorderline(
            command: "rm -rf /Users/x/Documents",
            candidates: [cand("destructive_action_pending", .high)],
            deterministicCaught: false))
    }

    func testNoFireButSuspiciousShapeIsBorderline() {
        // False-negative gap: nothing fired, but the command is destructive-shaped.
        XCTAssertTrue(BorderlineClassifier.isBorderline(
            command: "rm -rf ../other-project",
            candidates: [],
            deterministicCaught: false))
    }

    func testNoFireBenignCommandIsNotBorderline() {
        XCTAssertFalse(BorderlineClassifier.isBorderline(
            command: "ls -la && cat README.md",
            candidates: [],
            deterministicCaught: false))
    }

    func testFiredNonMediumWithSuspiciousShapeIsNotBorderline() {
        // A destructive candidate fired (at low) — the false-negative branch is
        // gated on NOT having fired a target category, so this is not borderline
        // via branch (b); and it's not medium, so not via (a).
        XCTAssertFalse(BorderlineClassifier.isBorderline(
            command: "rm -rf ./build",
            candidates: [cand("destructive_action_pending", .low)],
            deterministicCaught: false))
    }

    func testSuspiciousHeadStripsPathAndIgnoresArgs() {
        XCTAssertTrue(BorderlineClassifier.hasSuspiciousHead("/bin/rm -rf x"))
        XCTAssertTrue(BorderlineClassifier.hasSuspiciousHead("git checkout ."))
        XCTAssertTrue(BorderlineClassifier.hasSuspiciousHead("make && rm -rf dist"))
        XCTAssertFalse(BorderlineClassifier.hasSuspiciousHead("echo rm is a word"))
        XCTAssertFalse(BorderlineClassifier.hasSuspiciousHead("ls -la"))
    }

    // MARK: - Verdict parsing

    func testConsensusParsing() {
        XCTAssertTrue(BorderlineEscalator.consensusRecommendsPause("PAUSE: deletes uncommitted work"))
        XCTAssertTrue(BorderlineEscalator.consensusRecommendsPause("I would PAUSE this"))
        XCTAssertFalse(BorderlineEscalator.consensusRecommendsPause("ALLOW: it only touches build artifacts"))
        XCTAssertFalse(BorderlineEscalator.consensusRecommendsPause("this is unclear and unparseable"))
    }

    func testDecisionPromptIncludesCommandAndVerdictInstruction() {
        let p = BorderlineEscalator.buildDecisionPrompt(
            command: "git checkout .", userPrompt: "clean up", primaryReasoning: "maybe risky")
        XCTAssertTrue(p.contains("git checkout ."))
        XCTAssertTrue(p.contains("clean up"))
        XCTAssertTrue(p.contains("PAUSE"))
        XCTAssertTrue(p.contains("ALLOW"))
    }

    // MARK: - Escalator (against a fake panel)

    private func coordinator(consensus: String?, throwsError: Bool = false) -> PanelCoordinator {
        let cfg = PanelConfig(members: [PanelMember(provider: .anthropic, model: "a"),
                                        PanelMember(provider: .deepseek, model: "b")],
                              judge: PanelMember(provider: .anthropic, model: "j"))
        let panel = DeliberationPanel(config: cfg) { _, req in
            if throwsError { throw NSError(domain: "panel", code: 1) }
            if req.tools != nil {
                return AnthropicMessageResponse(
                    id: "m", type: "message", role: "assistant", model: "j",
                    content: [AnthropicContentBlock(type: "tool_use", id: "t",
                        name: DeliberationPanel.judgeToolName,
                        input: .object([
                            "consensus": .string(consensus ?? ""),
                            "contradictions": .array([]), "blind_spots": .array([]),
                            "unique_insights": .array([]),
                        ]))],
                    stop_reason: "tool_use", stop_sequence: nil,
                    usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                          cache_creation_input_tokens: nil, cache_read_input_tokens: nil))
            }
            return AnthropicMessageResponse(
                id: "m", type: "message", role: "assistant", model: req.model,
                content: [AnthropicContentBlock(type: "text", text: "member answer")],
                stop_reason: "end_turn", stop_sequence: nil,
                usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                      cache_creation_input_tokens: nil, cache_read_input_tokens: nil))
        }
        return PanelCoordinator(panel: panel, mode: .diy)
    }

    func testPanelPauseVerdictUpgradesToHighPause() async {
        let escalator = BorderlineEscalator(coordinator: coordinator(consensus: "PAUSE: this discards uncommitted changes"))
        let d = await escalator.secondOpinion(command: "git checkout .", userPrompt: "clean up",
                                              primaryReasoning: "medium")
        XCTAssertTrue(d.upgraded)
        XCTAssertEqual(d.newSeverity, .high)
        XCTAssertEqual(d.newAction, .pause)
    }

    func testPanelAllowVerdictLeavesPrimaryUntouched() async {
        let escalator = BorderlineEscalator(coordinator: coordinator(consensus: "ALLOW: only build artifacts"))
        let d = await escalator.secondOpinion(command: "rm -rf ./build", userPrompt: "clean build",
                                              primaryReasoning: "medium")
        XCTAssertEqual(d, .noChange)
    }

    func testPanelErrorFailsSafeToNoChange() async {
        let escalator = BorderlineEscalator(coordinator: coordinator(consensus: nil, throwsError: true))
        let d = await escalator.secondOpinion(command: "git reset --hard", userPrompt: "",
                                              primaryReasoning: "")
        XCTAssertEqual(d, .noChange, "a panel failure must never upgrade — primary verdict stands")
    }
}
