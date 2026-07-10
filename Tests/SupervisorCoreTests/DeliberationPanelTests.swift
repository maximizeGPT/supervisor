// DeliberationPanelTests.swift — panel + judge fan-out/fuse behavior.
//
// The panel calls through an injected @Sendable send closure (the LLMClient
// costRecorder/capCheck idiom), so these tests exercise the real fan-out,
// judge parsing, degrade paths, and usage accounting with NO network.

import XCTest
@testable import SupervisorCore

final class DeliberationPanelTests: XCTestCase {

    // MARK: - Fixtures

    private func member(_ label: String, _ model: String, provider: LLMProvider = .anthropic) -> PanelMember {
        PanelMember(provider: provider, model: model, label: label)
    }

    private func usage(_ i: Int, _ o: Int) -> AnthropicUsage {
        AnthropicUsage(input_tokens: i, output_tokens: o,
                       cache_creation_input_tokens: nil, cache_read_input_tokens: nil)
    }

    private func textResponse(model: String, text: String, i: Int = 10, o: Int = 5) -> AnthropicMessageResponse {
        AnthropicMessageResponse(
            id: "msg", type: "message", role: "assistant", model: model,
            content: [AnthropicContentBlock(type: "text", text: text)],
            stop_reason: "end_turn", stop_sequence: nil, usage: usage(i, o)
        )
    }

    private func judgeResponse(
        consensus: String,
        contradictions: [String] = [],
        blindSpots: [String] = [],
        uniqueInsights: [String] = [],
        i: Int = 20, o: Int = 8
    ) -> AnthropicMessageResponse {
        func arr(_ xs: [String]) -> AnthropicJSON { .array(xs.map { .string($0) }) }
        let input: AnthropicJSON = .object([
            "consensus": .string(consensus),
            "contradictions": arr(contradictions),
            "blind_spots": arr(blindSpots),
            "unique_insights": arr(uniqueInsights),
        ])
        return AnthropicMessageResponse(
            id: "msg", type: "message", role: "assistant", model: "judge",
            content: [AnthropicContentBlock(type: "tool_use", id: "t1",
                                            name: DeliberationPanel.judgeToolName, input: input)],
            stop_reason: "tool_use", stop_sequence: nil, usage: usage(i, o)
        )
    }

    private func config() -> PanelConfig {
        PanelConfig(
            members: [member("A", "model-a"), member("B", "model-b"), member("C", "model-c")],
            judge: member("Judge", "judge")
        )
    }

    // MARK: - Happy path

    func testFusesMemberAnswersIntoStructuredVerdict() async throws {
        let panel = DeliberationPanel(config: config()) { _, request in
            if request.tools != nil {
                return self.judgeResponse(consensus: "use approach X",
                                          contradictions: ["A vs B on caching"],
                                          blindSpots: ["nobody mentioned auth"],
                                          uniqueInsights: ["C flagged a race"])
            }
            return self.textResponse(model: request.model, text: "answer from \(request.model)")
        }

        let result = try await panel.deliberate(decision: "How should we build the cache?")

        XCTAssertFalse(result.degraded)
        XCTAssertEqual(result.consensus, "use approach X")
        XCTAssertEqual(result.contradictions, ["A vs B on caching"])
        XCTAssertEqual(result.blindSpots, ["nobody mentioned auth"])
        XCTAssertEqual(result.uniqueInsights, ["C flagged a race"])
        XCTAssertEqual(result.perMember.count, 3)
        XCTAssertTrue(result.perMember.allSatisfy { $0.succeeded })
        // Order preserved regardless of task-group completion order.
        XCTAssertEqual(result.perMember.map { $0.member.label }, ["A", "B", "C"])
    }

    func testUsageSumsMembersPlusJudge() async throws {
        let panel = DeliberationPanel(config: config()) { _, request in
            request.tools != nil
                ? self.judgeResponse(consensus: "c", i: 20, o: 8)
                : self.textResponse(model: request.model, text: "x", i: 10, o: 5)
        }
        let result = try await panel.deliberate(decision: "q")
        // 3 members (10/5 each) + judge (20/8).
        XCTAssertEqual(result.usage.memberCalls, 3)
        XCTAssertEqual(result.usage.judgeCalls, 1)
        XCTAssertEqual(result.usage.inputTokens, 3 * 10 + 20)
        XCTAssertEqual(result.usage.outputTokens, 3 * 5 + 8)
    }

    // MARK: - Partial failure tolerated

    func testOneMemberFailingStillFuses() async throws {
        let panel = DeliberationPanel(config: config()) { _, request in
            if request.tools != nil { return self.judgeResponse(consensus: "ok") }
            if request.model == "model-b" {
                throw NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
            }
            return self.textResponse(model: request.model, text: "answer")
        }
        let result = try await panel.deliberate(decision: "q")
        XCTAssertFalse(result.degraded)
        XCTAssertEqual(result.consensus, "ok")
        XCTAssertEqual(result.usage.memberCalls, 2, "only the 2 successful members count")
        let failed = result.perMember.first { $0.member.label == "B" }
        XCTAssertNotNil(failed?.error)
        XCTAssertFalse(failed?.succeeded ?? true)
        XCTAssertEqual(result.perMember.count, 3, "failed members are still reported")
    }

    // MARK: - All members fail

    func testAllMembersFailingThrows() async {
        let panel = DeliberationPanel(config: config()) { _, request in
            if request.tools != nil { return self.judgeResponse(consensus: "should not reach") }
            throw NSError(domain: "test", code: 1)
        }
        do {
            _ = try await panel.deliberate(decision: "q")
            XCTFail("expected allMembersFailed")
        } catch let e as PanelError {
            guard case let .allMembersFailed(errors) = e else { return XCTFail("wrong case") }
            XCTAssertEqual(errors.count, 3, "one error per failed member")
        } catch {
            XCTFail("expected PanelError, got \(error)")
        }
    }

    // MARK: - Judge degrade paths

    func testJudgeThrowingDegradesToFallback() async throws {
        let panel = DeliberationPanel(config: config()) { _, request in
            if request.tools != nil { throw NSError(domain: "judge", code: 9) }
            return self.textResponse(model: request.model, text: "member \(request.model) says hi")
        }
        let result = try await panel.deliberate(decision: "q")
        XCTAssertTrue(result.degraded)
        XCTAssertEqual(result.consensus, "member model-a says hi", "degrades to the first member's answer")
        XCTAssertTrue(result.contradictions.isEmpty)
        XCTAssertTrue(result.blindSpots.isEmpty)
        XCTAssertEqual(result.usage.memberCalls, 3)
        XCTAssertEqual(result.usage.judgeCalls, 0, "a thrown judge call recorded no judge usage")
    }

    func testJudgeReturningWrongShapeDegrades() async throws {
        let panel = DeliberationPanel(config: config()) { _, request in
            // Judge answers as plain text, not the record_panel_verdict tool.
            request.tools != nil
                ? self.textResponse(model: "judge", text: "I couldn't decide")
                : self.textResponse(model: request.model, text: "an answer")
        }
        let result = try await panel.deliberate(decision: "q")
        XCTAssertTrue(result.degraded)
        XCTAssertEqual(result.consensus, "an answer")
        XCTAssertEqual(result.usage.judgeCalls, 1, "the judge call happened and its usage counts even though it degraded")
    }

    func testJudgeEmptyConsensusDegrades() async throws {
        let panel = DeliberationPanel(config: config()) { _, request in
            request.tools != nil
                ? self.judgeResponse(consensus: "")   // empty consensus is not a real verdict
                : self.textResponse(model: request.model, text: "fallback text")
        }
        let result = try await panel.deliberate(decision: "q")
        XCTAssertTrue(result.degraded)
        XCTAssertEqual(result.consensus, "fallback text")
    }

    // MARK: - Request construction

    func testMemberRequestHasNoToolsAndCarriesDecision() {
        let req = DeliberationPanel.memberRequest(
            member: member("A", "model-a"), decision: "the decision text",
            systemPreamble: "PROJECT CONTEXT", maxTokens: 512)
        XCTAssertNil(req.tools, "members answer free-form, no forced tool")
        XCTAssertNil(req.tool_choice)
        XCTAssertEqual(req.model, "model-a")
        XCTAssertEqual(req.max_tokens, 512)
        XCTAssertTrue(req.system?.contains("PROJECT CONTEXT") ?? false, "preamble is prepended")
        if case let .string(s) = req.messages[0].content {
            XCTAssertEqual(s, "the decision text")
        } else { XCTFail("member decision must be a string message") }
    }

    func testJudgeRequestForcesVerdictToolAndIncludesAnswers() {
        let answers = [
            MemberAnswer(member: member("A", "model-a"), text: "alpha view", usage: nil, error: nil),
            MemberAnswer(member: member("B", "model-b"), text: "beta view", usage: nil, error: nil),
        ]
        let req = DeliberationPanel.judgeRequest(
            judge: member("Judge", "judge"), decision: "decide this",
            answers: answers, maxTokens: 256)
        XCTAssertEqual(req.tool_choice?.type, "tool")
        XCTAssertEqual(req.tool_choice?.name, DeliberationPanel.judgeToolName)
        XCTAssertEqual(req.tools?.first?.name, DeliberationPanel.judgeToolName)
        guard case let .string(body) = req.messages[0].content else {
            return XCTFail("judge body must be a string message")
        }
        XCTAssertTrue(body.contains("alpha view"))
        XCTAssertTrue(body.contains("beta view"))
        XCTAssertTrue(body.contains("decide this"))
    }

    // MARK: - live(clients:) adapter

    func testLiveWithMissingProviderClientFailsThatMember() async {
        // No clients configured, so every member's provider lookup fails →
        // all members fail → allMembersFailed (never a crash).
        let panel = DeliberationPanel.live(config: config(), clients: [:])
        do {
            _ = try await panel.deliberate(decision: "q")
            XCTFail("expected allMembersFailed with no clients")
        } catch let e as PanelError {
            guard case let .allMembersFailed(errors) = e else { return XCTFail("wrong case") }
            XCTAssertEqual(errors.count, 3)
            XCTAssertTrue(errors.allSatisfy { $0.contains("no configured client") })
        } catch {
            XCTFail("expected PanelError, got \(error)")
        }
    }

    // MARK: - OpenRouter Fusion backend

    func testFusionReturnsCompletionAsConsensus() async throws {
        let panel = DeliberationPanel(config: config()) { provider, request in
            XCTAssertEqual(provider, .openrouter, "Fusion must route to the OpenRouter provider")
            XCTAssertEqual(request.model, DeliberationPanel.defaultFusionModel)
            return self.textResponse(model: request.model, text: "the fused synthesis", i: 30, o: 12)
        }
        let result = try await panel.deliberateViaFusion(decision: "How should we cache?")
        XCTAssertFalse(result.degraded)
        XCTAssertEqual(result.consensus, "the fused synthesis")
        XCTAssertTrue(result.perMember.isEmpty, "Fusion members are opaque")
        XCTAssertEqual(result.usage.judgeCalls, 1)
        XCTAssertEqual(result.usage.inputTokens, 30)
        XCTAssertEqual(result.usage.outputTokens, 12)
    }

    func testFusionRequestHasNoToolsAndUsesFusionModel() {
        let req = DeliberationPanel.fusionRequest(
            model: DeliberationPanel.defaultFusionModel, decision: "decide",
            systemPreamble: "CTX", maxTokens: 256)
        XCTAssertEqual(req.model, "openrouter/fusion")
        XCTAssertNil(req.tools)
        XCTAssertNil(req.tool_choice)
        XCTAssertTrue(req.system?.contains("CTX") ?? false)
        if case let .string(s) = req.messages[0].content {
            XCTAssertEqual(s, "decide")
        } else { XCTFail("decision must be a string message") }
    }

    func testFusionEmptyResponseThrows() async {
        let panel = DeliberationPanel(config: config()) { _, request in
            self.textResponse(model: request.model, text: "")  // no content
        }
        do {
            _ = try await panel.deliberateViaFusion(decision: "q")
            XCTFail("expected fusionReturnedNoContent")
        } catch let e as PanelError {
            XCTAssertEqual(e, .fusionReturnedNoContent)
        } catch {
            XCTFail("expected PanelError, got \(error)")
        }
    }
}
