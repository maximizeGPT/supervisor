// PromptCacheOrderingTests.swift
//
// DeepSeek bills input tokens served from a cached prompt prefix at roughly a
// tenth of a miss, and the cached prefix ends at the first token that differs
// from the last request. So the cheap request is the one whose static text
// comes first and whose per-call text comes last.
//
// These tests pin the ordering property directly (the shared prefix between
// two requests that differ only in session context) rather than the exact
// bytes, and pin that no section was lost in the move.

import XCTest
@testable import SupervisorCore

final class PromptCacheOrderingTests: XCTestCase {

    private func userText(_ req: AnthropicMessageRequest) -> String {
        guard case .string(let s) = req.messages[0].content else { return "" }
        return s
    }

    private func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            if x != y { break }
            count += 1
        }
        return count
    }

    private func idleRequest(
        cwd: String = "/Users/test/proj",
        branch: String = "feat/x",
        seconds: TimeInterval = 30,
        events: [SupervisorEvent] = []
    ) -> AnthropicMessageRequest {
        TriagePrompt.buildIdleEvaluationRequest(
            model: "deepseek-chat",
            sessionId: "s1",
            cwd: cwd,
            gitBranch: branch,
            userPrompt: "do the thing",
            stopShapedPhrase: "no_tool_use",
            secondsSinceLastEvent: seconds,
            recentEvents: events
        )
    }

    // MARK: - The system prompt is the big shared prefix, and it is identical

    func testIdleSystemPromptIsIdenticalAcrossSessions() {
        let a = idleRequest(cwd: "/a", branch: "main")
        let b = idleRequest(cwd: "/b", branch: "feat/y", seconds: 900)
        XCTAssertEqual(a.system, b.system,
                       "the rubric is the bulk of the prompt; if it varied, nothing would cache")
        XCTAssertGreaterThan(a.system?.count ?? 0, 2000)
    }

    // MARK: - The user message leads with static text

    func testIdleUserMessageLeadsWithTheStaticScopeParagraph() {
        let text = userText(idleRequest())
        XCTAssertTrue(text.hasPrefix(TriagePrompt.idleScopeInstruction),
                      "the one paragraph that never changes has to come first to be cacheable")
    }

    func testBashUserMessageLeadsWithTheStaticScopeParagraph() {
        let req = TriagePrompt.buildRequest(model: "deepseek-chat", input: .init(
            cwd: "/Users/test/proj",
            userPrompt: "ship it",
            bashCall: .init(sessionId: "s1", command: "rm -rf /tmp/x", description: nil,
                            toolUseId: "toolu_1", turnUUID: "t1", ts: Date()),
            recentResult: nil,
            recentEvents: []
        ))
        let text = userText(req)
        XCTAssertTrue(text.hasPrefix(TriagePrompt.bashScopeInstruction),
                      "same rule on the bash path")
        XCTAssertTrue(text.contains("Call record_triage exactly once."))
    }

    /// Two idle calls for DIFFERENT sessions still share the whole static head.
    func testTwoDifferentSessionsShareAStaticHead() {
        let a = userText(idleRequest(cwd: "/a", branch: "main"))
        let b = userText(idleRequest(cwd: "/b", branch: "feat/y"))
        XCTAssertGreaterThanOrEqual(sharedPrefixLength(a, b), TriagePrompt.idleScopeInstruction.count,
                                    "the shared prefix must reach at least to the end of the static paragraph")
    }

    /// The section that changes on EVERY call for the SAME session is last, so
    /// a repeat idle call on an unchanged session shares nearly the whole body.
    func testOnlyTheTrailingSignalsDifferBetweenTwoTicksOfOneSession() {
        let first = userText(idleRequest(seconds: 30))
        let second = userText(idleRequest(seconds: 90))
        let shared = sharedPrefixLength(first, second)
        // Everything up to "seconds_since_last_event: " is identical.
        XCTAssertGreaterThan(shared, first.count - 40,
                             "only the elapsed-seconds value should fall outside the shared prefix")
        XCTAssertTrue(first.hasSuffix("seconds_since_last_event: 30"))
        XCTAssertTrue(second.hasSuffix("seconds_since_last_event: 90"))
    }

    // MARK: - Reordering moved sections, it did not drop them

    func testIdlePromptStillCarriesEverySection() {
        let event = SupervisorEvent.assistantText(.init(
            sessionId: "s1", text: "ready for next", turnUUID: "t1", ts: Date()))
        let text = userText(idleRequest(events: [event]))
        for section in [
            "# Session working directory", "/Users/test/proj",
            "# Session git branch", "feat/x",
            "# Most recent user prompt", "do the thing",
            "# Recent event window (chronological)", "assistantText: ready for next",
            "# Idle-check signals", "stop_shaped_phrase_matched: no_tool_use",
            "worker_idle_post_completion",
        ] {
            XCTAssertTrue(text.contains(section), "reordering must not drop: \(section)")
        }
    }

    func testBashPromptStillCarriesEverySection() {
        let req = TriagePrompt.buildRequest(model: "deepseek-chat", input: .init(
            cwd: "/Users/test/proj",
            userPrompt: "ship it",
            bashCall: .init(sessionId: "s1", command: "rm -rf /tmp/x", description: "clean",
                            toolUseId: "toolu_1", turnUUID: "t1", ts: Date()),
            recentResult: nil,
            recentEvents: []
        ))
        let text = userText(req)
        for section in [
            "# Session working directory", "# Most recent user prompt",
            "# Bash command under review", "command: rm -rf /tmp/x",
            "description: clean", "toolUseId: toolu_1",
            "# Has the command already executed?", "No — pre-execution decision window.",
            "# Recent event window (chronological)",
            "destructive_action_pending",
        ] {
            XCTAssertTrue(text.contains(section), "reordering must not drop: \(section)")
        }
    }

    // MARK: - Cache telemetry decoding (provider-specific, tolerant)

    func testDeepSeekCacheTokensDecodeIntoUsage() throws {
        let json = """
        {"id":"c1","model":"deepseek-chat","choices":[{"index":0,
          "message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":5500,"completion_tokens":12,"total_tokens":5512,
                  "prompt_cache_hit_tokens":5120,"prompt_cache_miss_tokens":380}}
        """
        let resp = try JSONDecoder().decode(OpenAIChatResponse.self, from: Data(json.utf8))
        let translated = try LLMClient.translateResponse(resp, requestedModel: "deepseek-chat")
        XCTAssertEqual(translated.usage.input_tokens, 380,
                       "DeepSeek's prompt_tokens INCLUDES the hits; AnthropicUsage.input_tokens excludes them, so the misses are what belongs in the field")
        XCTAssertEqual(translated.usage.cache_read_input_tokens, 5120,
                       "a cache hit has to reach the usage record or the win is unmeasurable")
        XCTAssertEqual(
            translated.usage.input_tokens + (translated.usage.cache_read_input_tokens ?? 0), 5500,
            "the two fields still have to add back up to the prompt the provider billed"
        )
    }

    /// The double-billing regression itself, at the seam that caused it: a
    /// cached DeepSeek call cost MORE in the ledger than the same call with the
    /// cache cold, and the new $2/day cap tripped on spend that never happened.
    func testDeepSeekCacheHitIsNotBilledTwiceEndToEnd() throws {
        let json = """
        {"id":"c1","model":"deepseek-chat","choices":[{"index":0,
          "message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":10000,"completion_tokens":0,"total_tokens":10000,
                  "prompt_cache_hit_tokens":8000,"prompt_cache_miss_tokens":2000}}
        """
        let resp = try JSONDecoder().decode(OpenAIChatResponse.self, from: Data(json.utf8))
        let translated = try LLMClient.translateResponse(resp, requestedModel: "deepseek-chat")
        let cost = TokenAccounting.costUSD(model: "deepseek-chat", usage: translated.usage)

        // 2,000 misses @ $0.28/1M = $0.00056; 8,000 hits @ $0.028/1M = $0.000224.
        XCTAssertEqual(cost, 0.000784, accuracy: 1e-9)

        // What the bug charged: all 10,000 at the input rate ($0.0028) PLUS the
        // 8,000 again at the cache rate ($0.000224). Kept as an explicit number
        // so a regression reads as a 3.9x overcharge rather than an opaque
        // float mismatch.
        let doubleBilled = 10_000 * (0.28 / 1_000_000) + 8_000 * (0.028 / 1_000_000)
        XCTAssertEqual(doubleBilled, 0.003024, accuracy: 1e-9)
        XCTAssertLessThan(cost, doubleBilled,
                          "a cache HIT must cost less than a miss, never more")
    }

    /// The other half of the same claim: a provider that reports no cache split
    /// is unaffected, so this fix cannot quietly under-bill anyone else.
    func testProviderWithoutCacheKeysBillsEveryPromptToken() throws {
        let json = """
        {"id":"c1","model":"deepseek-chat","choices":[{"index":0,
          "message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":10000,"completion_tokens":0}}
        """
        let resp = try JSONDecoder().decode(OpenAIChatResponse.self, from: Data(json.utf8))
        let translated = try LLMClient.translateResponse(resp, requestedModel: "deepseek-chat")
        XCTAssertEqual(translated.usage.input_tokens, 10_000)
        XCTAssertEqual(TokenAccounting.costUSD(model: "deepseek-chat", usage: translated.usage),
                       0.0028, accuracy: 1e-9)
    }

    /// A provider that reported more hits than prompt tokens would be lying,
    /// but a negative token count would poison the ledger far worse than a
    /// zero. Pin the clamp.
    func testHitsExceedingPromptTokensClampAtZero() throws {
        let json = """
        {"id":"c1","model":"deepseek-chat","choices":[{"index":0,
          "message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":100,"completion_tokens":0,"prompt_cache_hit_tokens":500}}
        """
        let resp = try JSONDecoder().decode(OpenAIChatResponse.self, from: Data(json.utf8))
        let translated = try LLMClient.translateResponse(resp, requestedModel: "deepseek-chat")
        XCTAssertEqual(translated.usage.input_tokens, 0,
                       "an impossible split clamps to zero rather than recording negative tokens")
    }

    func testUsageWithoutCacheKeysStillDecodes() throws {
        // Every other OpenAI-compatible provider omits both keys.
        let json = """
        {"id":"c1","model":"kimi","choices":[{"index":0,
          "message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":100,"completion_tokens":5}}
        """
        let resp = try JSONDecoder().decode(OpenAIChatResponse.self, from: Data(json.utf8))
        let translated = try LLMClient.translateResponse(resp, requestedModel: "kimi")
        XCTAssertEqual(translated.usage.input_tokens, 100)
        XCTAssertNil(translated.usage.cache_read_input_tokens,
                     "absent cache keys mean 'not reported', never 'zero hits'")
    }

    func testMissingUsageBlockStillDecodes() throws {
        let json = """
        {"id":"c1","model":"kimi","choices":[{"index":0,
          "message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
        """
        let resp = try JSONDecoder().decode(OpenAIChatResponse.self, from: Data(json.utf8))
        let translated = try LLMClient.translateResponse(resp, requestedModel: "kimi")
        XCTAssertEqual(translated.usage.input_tokens, 0)
        XCTAssertNil(translated.usage.cache_read_input_tokens)
    }
}
