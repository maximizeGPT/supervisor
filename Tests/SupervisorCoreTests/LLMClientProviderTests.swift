// LLMClientProviderTests.swift — v0.2.0.
//
// Covers the multi-provider surface added in v0.2.0:
//   - LLMProvider's per-provider URL / auth / model defaults stay stable
//   - LLMClient sets the right auth header for each provider's
//     `authHeader` (x-api-key for Anthropic, Bearer for everyone else)
//   - Request translation Anthropic → OpenAI is lossless for the
//     triage-relevant fields (system prompt, user message, forced
//     tool_choice, tool definition)
//   - Response translation OpenAI → Anthropic produces a tool_use block
//     that TriageEngine.extractCandidates() can consume unchanged
//   - End-to-end: a mocked DeepSeek 200 response with a `tool_calls`
//     payload comes back as an AnthropicMessageResponse with a tool_use
//     block whose `input` field parses correctly

import XCTest
@testable import SupervisorCore

final class LLMClientProviderTests: XCTestCase {

    // MARK: - Provider metadata stability

    func testEveryProviderHasABaseURL() {
        for p in LLMProvider.allCases {
            XCTAssertEqual(p.baseURL.scheme, "https", "\(p) baseURL must be https")
            XCTAssertFalse(p.baseURL.host?.isEmpty ?? true, "\(p) baseURL must have a host")
        }
    }

    func testEveryProviderHasADefaultTriageModel() {
        for p in LLMProvider.allCases {
            XCTAssertFalse(p.defaultTriageModel.isEmpty, "\(p) must declare a defaultTriageModel")
        }
    }

    func testEveryProviderHasAUniqueKeychainService() {
        let services = LLMProvider.allCases.map { $0.keychainService }
        XCTAssertEqual(services.count, Set(services).count, "keychain service names must be unique")
        // Also must not collide with the legacy v0.1.x service name.
        XCTAssertFalse(services.contains(LLMProvider.legacyAnthropicKeychainService),
                       "per-provider names must not collide with legacy slot")
    }

    func testAnthropicUsesXApiKeyEveryoneElseUsesBearer() {
        XCTAssertEqual(LLMProvider.anthropic.authHeader, .xApiKey)
        for p in LLMProvider.allCases where p != .anthropic {
            XCTAssertEqual(p.authHeader, .bearer, "\(p) must use Bearer (OpenAI convention)")
        }
    }

    func testAnthropicIsTheOnlyAnthropicShape() {
        XCTAssertEqual(LLMProvider.anthropic.apiShape, .anthropic)
        for p in LLMProvider.allCases where p != .anthropic {
            XCTAssertEqual(p.apiShape, .openAICompat, "\(p) must be openAICompat")
        }
    }

    // MARK: - Request translation

    func testTranslateRequestMovesSystemToFirstMessage() {
        let req = AnthropicMessageRequest(
            model: "deepseek-chat",
            max_tokens: 256,
            system: "you are a triage agent",
            messages: [.init(role: "user", content: .string("ping"))],
            tools: nil,
            tool_choice: nil
        )
        let out = LLMClient.translateRequest(req)
        XCTAssertEqual(out.model, "deepseek-chat")
        XCTAssertEqual(out.max_tokens, 256)
        XCTAssertEqual(out.messages.count, 2)
        XCTAssertEqual(out.messages[0].role, "system")
        XCTAssertEqual(out.messages[0].content, "you are a triage agent")
        XCTAssertEqual(out.messages[1].role, "user")
        XCTAssertEqual(out.messages[1].content, "ping")
    }

    func testTranslateRequestOmitsSystemWhenAbsent() {
        let req = AnthropicMessageRequest(
            model: "m", max_tokens: 1,
            system: nil,
            messages: [.init(role: "user", content: .string("hi"))],
            tools: nil, tool_choice: nil
        )
        let out = LLMClient.translateRequest(req)
        XCTAssertEqual(out.messages.count, 1)
        XCTAssertEqual(out.messages[0].role, "user")
    }

    func testTranslateRequestForcesNamedFunctionToolChoice() {
        let req = AnthropicMessageRequest(
            model: "m", max_tokens: 1,
            system: nil,
            messages: [.init(role: "user", content: .string("hi"))],
            tools: [.init(name: "record_triage", description: "test",
                          input_schema: .object(["type": .string("object")]))],
            tool_choice: .forced("record_triage")
        )
        let out = LLMClient.translateRequest(req)
        XCTAssertEqual(out.tool_choice?.type, "function")
        XCTAssertEqual(out.tool_choice?.function.name, "record_triage")
        XCTAssertEqual(out.tools?.count, 1)
        XCTAssertEqual(out.tools?[0].function.name, "record_triage")
        XCTAssertEqual(out.tools?[0].type, "function")
    }

    func testTranslateRequestCollapsesContentBlocksToConcatenatedText() {
        let req = AnthropicMessageRequest(
            model: "m", max_tokens: 1,
            system: nil,
            messages: [
                .init(role: "user", content: .blocks([
                    .init(type: "text", text: "part 1"),
                    .init(type: "text", text: "part 2"),
                ])),
            ],
            tools: nil, tool_choice: nil
        )
        let out = LLMClient.translateRequest(req)
        XCTAssertEqual(out.messages[0].content, "part 1\npart 2")
    }

    // MARK: - Response translation

    func testTranslateResponseMapsToolCallsToToolUseBlocks() throws {
        let openAI = OpenAIChatResponse(
            id: "chatcmpl-abc",
            model: "deepseek-chat",
            choices: [
                .init(
                    index: 0,
                    message: .init(
                        role: "assistant",
                        content: nil,
                        tool_calls: [
                            .init(
                                id: "call_1",
                                type: "function",
                                function: .init(
                                    name: "record_triage",
                                    arguments: #"{"candidates":[{"category":"destructive_action_pending","severity":"high"}]}"#
                                )
                            ),
                        ]
                    ),
                    finish_reason: "tool_calls"
                ),
            ],
            usage: .init(prompt_tokens: 100, completion_tokens: 50, total_tokens: 150)
        )
        let mapped = try LLMClient.translateResponse(openAI, requestedModel: "deepseek-chat")
        XCTAssertEqual(mapped.content.count, 1)
        XCTAssertEqual(mapped.content[0].type, "tool_use")
        XCTAssertEqual(mapped.content[0].name, "record_triage")
        XCTAssertEqual(mapped.usage.input_tokens, 100)
        XCTAssertEqual(mapped.usage.output_tokens, 50)
        // Verify the parsed input is the same JSON object the extractor expects.
        guard case let .object(input)? = mapped.content[0].input,
              case let .array(candidates)? = input["candidates"],
              case let .object(c) = candidates.first
        else {
            XCTFail("translated tool_use input did not parse into the expected shape")
            return
        }
        XCTAssertEqual(c["category"], .string("destructive_action_pending"))
        XCTAssertEqual(c["severity"], .string("high"))
    }

    func testTranslateResponseFallsBackToNullInputOnMalformedArguments() throws {
        let openAI = OpenAIChatResponse(
            id: nil, model: nil,
            choices: [
                .init(index: 0, message: .init(role: "assistant", content: nil, tool_calls: [
                    .init(id: "x", type: "function",
                          function: .init(name: "record_triage", arguments: "this is not json"))
                ]), finish_reason: "tool_calls"),
            ],
            usage: nil
        )
        let mapped = try LLMClient.translateResponse(openAI, requestedModel: "any")
        XCTAssertEqual(mapped.content[0].input, .null,
                       "malformed JSON arguments must collapse to .null so extractCandidates can log + skip")
    }

    func testTranslateResponseHandlesPlainTextContent() throws {
        let openAI = OpenAIChatResponse(
            id: "x", model: "x",
            choices: [
                .init(index: 0, message: .init(role: "assistant", content: "hi there", tool_calls: nil),
                      finish_reason: "stop"),
            ],
            usage: .init(prompt_tokens: 1, completion_tokens: 1, total_tokens: 2)
        )
        let mapped = try LLMClient.translateResponse(openAI, requestedModel: "x")
        XCTAssertEqual(mapped.content.count, 1)
        XCTAssertEqual(mapped.content[0].type, "text")
        XCTAssertEqual(mapped.content[0].text, "hi there")
    }

    func testTranslateResponseThrowsWhenNoChoices() {
        let openAI = OpenAIChatResponse(id: nil, model: nil, choices: [], usage: nil)
        XCTAssertThrowsError(try LLMClient.translateResponse(openAI, requestedModel: "x"))
    }

    // MARK: - v0.5.1: JSON truncation repair

    func testTryRepairUnterminatedString() {
        let truncated = #"{"next_task_proposal": "Fix the bug in dispatch"#
        let repaired = LLMClient.tryRepairTruncatedJSON(truncated)
        XCTAssertNotNil(repaired, "should repair unterminated string")
        let obj = try! JSONSerialization.jsonObject(with: repaired!) as! [String: Any]
        XCTAssertNotNil(obj["next_task_proposal"])
    }

    func testTryRepairMissingClosingBrace() {
        let truncated = #"{"confidence": "high", "next_task_proposal": "Do the thing""#
        let repaired = LLMClient.tryRepairTruncatedJSON(truncated)
        XCTAssertNotNil(repaired, "should repair missing brace")
        let obj = try! JSONSerialization.jsonObject(with: repaired!) as! [String: Any]
        XCTAssertEqual(obj["confidence"] as? String, "high")
    }

    func testTryRepairTruncatedAtKeyBoundary() {
        let truncated = #"{"confidence": "high", "next_task_pro"#
        let repaired = LLMClient.tryRepairTruncatedJSON(truncated)
        XCTAssertNotNil(repaired, "should truncate to last complete pair")
        let obj = try! JSONSerialization.jsonObject(with: repaired!) as! [String: Any]
        XCTAssertEqual(obj["confidence"] as? String, "high")
    }

    func testTryRepairReturnsNilForEmpty() {
        XCTAssertNil(LLMClient.tryRepairTruncatedJSON(""))
        XCTAssertNil(LLMClient.tryRepairTruncatedJSON("   "))
    }

    func testTranslateResponseRepairsTruncatedArgsOnFinishReasonLength() throws {
        // Simulates DeepSeek returning finish_reason=length with truncated
        // tool-call arguments. The translator should repair the JSON.
        let truncatedArgs = #"{"next_task_proposal": "Read the file", "confidence": "high", "selected_path": "continue_bra"#
        let openAI = OpenAIChatResponse(
            id: "test",
            model: "deepseek-chat",
            choices: [OpenAIChoice(
                index: 0,
                message: OpenAIResponseMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [OpenAIToolCall(
                        id: "call_1",
                        type: "function",
                        function: OpenAIFunctionCall(
                            name: "record_dispatch",
                            arguments: truncatedArgs
                        )
                    )]
                ),
                finish_reason: "length"
            )],
            usage: OpenAIUsage(prompt_tokens: 100, completion_tokens: 8192, total_tokens: 8292)
        )
        let mapped = try LLMClient.translateResponse(openAI, requestedModel: "deepseek-chat")
        XCTAssertEqual(mapped.content.count, 1)
        XCTAssertEqual(mapped.content[0].type, "tool_use")
        // Input should be a parsed object, not .null
        if case let .object(input)? = mapped.content[0].input {
            XCTAssertNotNil(input["next_task_proposal"])
            XCTAssertNotNil(input["confidence"])
        } else {
            XCTFail("repaired input should be an object, got: \(String(describing: mapped.content[0].input))")
        }
    }

    func testTranslateResponseDoesNotRepairWhenFinishReasonIsStop() throws {
        // When finish_reason is NOT length, truncated args should remain .null
        let truncatedArgs = #"{"next_task_proposal": "unterminated"#
        let openAI = OpenAIChatResponse(
            id: "test",
            model: "deepseek-chat",
            choices: [OpenAIChoice(
                index: 0,
                message: OpenAIResponseMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [OpenAIToolCall(
                        id: "call_1",
                        type: "function",
                        function: OpenAIFunctionCall(
                            name: "record_dispatch",
                            arguments: truncatedArgs
                        )
                    )]
                ),
                finish_reason: "stop"
            )],
            usage: nil
        )
        let mapped = try LLMClient.translateResponse(openAI, requestedModel: "deepseek-chat")
        XCTAssertEqual(mapped.content[0].input, .null,
            "should NOT repair when finish_reason is not length")
    }

    // MARK: - End-to-end via MockURLProtocol

    func testOpenAICompatPathSendsBearerAndDecodesToolCall() async throws {
        let mockResponse: Data = Data(#"""
        {"id":"chatcmpl-1","model":"deepseek-chat","choices":[
          {"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
            {"id":"call_1","type":"function","function":{"name":"record_triage","arguments":"{\"candidates\":[]}"}}
          ]},"finish_reason":"tool_calls"}
        ],"usage":{"prompt_tokens":42,"completion_tokens":3,"total_tokens":45}}
        """#.utf8)

        LLMProviderMockURLProtocol.responses = [
            "/v1/chat/completions": (200, mockResponse, [:]),
        ]
        LLMProviderMockURLProtocol.lastRequestHeaders = [:]

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LLMProviderMockURLProtocol.self]
        let client = LLMClient(
            provider: .deepseek,
            apiKey: "sk-deepseek-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.deepseek.test")!,
            session: URLSession(configuration: cfg)
        )

        let req = AnthropicMessageRequest(
            model: "deepseek-chat",
            max_tokens: 256,
            system: "sys",
            messages: [.init(role: "user", content: .string("hi"))],
            tools: [.init(name: "record_triage", description: "x",
                          input_schema: .object(["type": .string("object")]))],
            tool_choice: .forced("record_triage")
        )

        let resp = try await client.createMessage(req)
        XCTAssertEqual(resp.usage.input_tokens, 42)
        XCTAssertEqual(resp.usage.output_tokens, 3)
        XCTAssertEqual(resp.model, "deepseek-chat")
        XCTAssertEqual(resp.content.first?.type, "tool_use")
        // Auth header on the wire must be Bearer for DeepSeek.
        let auth = LLMProviderMockURLProtocol.lastRequestHeaders["Authorization"]
        XCTAssertEqual(auth, "Bearer sk-deepseek-test")
        XCTAssertNil(LLMProviderMockURLProtocol.lastRequestHeaders["x-api-key"],
                     "x-api-key must NOT be sent to OpenAI-compatible providers")
    }

    func testAnthropicPathStillSendsXApiKey() async throws {
        let resp: Data = Data(#"""
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}
        """#.utf8)

        LLMProviderMockURLProtocol.responses = [
            "/v1/messages": (200, resp, [:]),
        ]
        LLMProviderMockURLProtocol.lastRequestHeaders = [:]

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LLMProviderMockURLProtocol.self]
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: URLSession(configuration: cfg)
        )

        _ = try await client.validateKey()
        XCTAssertEqual(LLMProviderMockURLProtocol.lastRequestHeaders["x-api-key"], "sk-ant-test")
        XCTAssertNil(LLMProviderMockURLProtocol.lastRequestHeaders["Authorization"],
                     "Anthropic must NOT receive a Bearer header")
    }

    // MARK: - v0.3.0: cost recorder hook + daily-cap gate

    /// Thread-safe capture box for the @Sendable hooks under test.
    private final class HookCapture: @unchecked Sendable {
        var recordedModel: String?
        var recordedUsage: AnthropicUsage?
        var recorderCalls = 0
    }

    func testCostRecorderFiresWithUsageAfterSuccessfulCall() async throws {
        let mockResponse: Data = Data(#"""
        {"id":"chatcmpl-1","model":"deepseek-chat","choices":[
          {"index":0,"message":{"role":"assistant","content":"ok","tool_calls":null},"finish_reason":"stop"}
        ],"usage":{"prompt_tokens":42,"completion_tokens":3,"total_tokens":45}}
        """#.utf8)
        LLMProviderMockURLProtocol.responses = [
            "/v1/chat/completions": (200, mockResponse, [:]),
        ]

        let capture = HookCapture()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LLMProviderMockURLProtocol.self]
        let client = LLMClient(
            provider: .deepseek,
            apiKey: "sk-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.deepseek.test")!,
            session: URLSession(configuration: cfg),
            costRecorder: { model, usage in
                capture.recordedModel = model
                capture.recordedUsage = usage
                capture.recorderCalls += 1
            }
        )

        let req = AnthropicMessageRequest(
            model: "deepseek-chat", max_tokens: 16,
            system: nil,
            messages: [.init(role: "user", content: .string("hi"))],
            tools: nil, tool_choice: nil
        )
        _ = try await client.createMessage(req)

        XCTAssertEqual(capture.recorderCalls, 1, "recorder must fire exactly once per call")
        XCTAssertEqual(capture.recordedModel, "deepseek-chat",
                       "recorder must receive the requested model id (pricing-table key)")
        XCTAssertEqual(capture.recordedUsage?.input_tokens, 42)
        XCTAssertEqual(capture.recordedUsage?.output_tokens, 3)
    }

    func testCapCheckAtCapThrowsWithoutNetworkRequest() async throws {
        LLMProviderMockURLProtocol.responses = [
            "/v1/chat/completions": (200, Data("{}".utf8), [:]),
        ]
        LLMProviderMockURLProtocol.requestCount = 0

        let capture = HookCapture()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LLMProviderMockURLProtocol.self]
        let client = LLMClient(
            provider: .deepseek,
            apiKey: "sk-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.deepseek.test")!,
            session: URLSession(configuration: cfg),
            costRecorder: { _, _ in capture.recorderCalls += 1 },
            capCheck: { .init(cap: 5.0, spent: 5.0) }  // exactly at cap
        )

        let req = AnthropicMessageRequest(
            model: "deepseek-chat", max_tokens: 16,
            system: nil,
            messages: [.init(role: "user", content: .string("hi"))],
            tools: nil, tool_choice: nil
        )
        do {
            _ = try await client.createMessage(req)
            XCTFail("call at cap must throw DailyCapExceededError")
        } catch let e as DailyCapExceededError {
            XCTAssertEqual(e, DailyCapExceededError(capUSD: 5.0, spentUSD: 5.0))
        }
        XCTAssertEqual(LLMProviderMockURLProtocol.requestCount, 0,
                       "a capped call must make NO network request")
        XCTAssertEqual(capture.recorderCalls, 0,
                       "a capped call records nothing (nothing was spent)")
    }

    func testCapCheckOverCapThrows() async throws {
        LLMProviderMockURLProtocol.requestCount = 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LLMProviderMockURLProtocol.self]
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: URLSession(configuration: cfg),
            capCheck: { .init(cap: 2.0, spent: 3.75) }  // over cap
        )
        let req = AnthropicMessageRequest(
            model: "claude-haiku-4-5-20251001", max_tokens: 1,
            system: nil,
            messages: [.init(role: "user", content: .string("ping"))],
            tools: nil, tool_choice: nil
        )
        do {
            _ = try await client.createMessage(req)
            XCTFail("call over cap must throw DailyCapExceededError")
        } catch let e as DailyCapExceededError {
            XCTAssertEqual(e, DailyCapExceededError(capUSD: 2.0, spentUSD: 3.75))
        }
        XCTAssertEqual(LLMProviderMockURLProtocol.requestCount, 0)
    }

    func testCapCheckUnderCapProceeds() async throws {
        let mockResponse: Data = Data(#"""
        {"id":"chatcmpl-1","model":"deepseek-chat","choices":[
          {"index":0,"message":{"role":"assistant","content":"ok","tool_calls":null},"finish_reason":"stop"}
        ],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
        """#.utf8)
        LLMProviderMockURLProtocol.responses = [
            "/v1/chat/completions": (200, mockResponse, [:]),
        ]
        LLMProviderMockURLProtocol.requestCount = 0

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LLMProviderMockURLProtocol.self]
        let client = LLMClient(
            provider: .deepseek,
            apiKey: "sk-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.deepseek.test")!,
            session: URLSession(configuration: cfg),
            capCheck: { .init(cap: 5.0, spent: 4.99) }  // under cap
        )
        let req = AnthropicMessageRequest(
            model: "deepseek-chat", max_tokens: 16,
            system: nil,
            messages: [.init(role: "user", content: .string("hi"))],
            tools: nil, tool_choice: nil
        )
        let resp = try await client.createMessage(req)
        XCTAssertEqual(resp.usage.input_tokens, 1)
        XCTAssertEqual(LLMProviderMockURLProtocol.requestCount, 1,
                       "under-cap call must proceed to the network")
    }

    func testNilCapCheckReturningNilMeansNoGating() async throws {
        // capCheck wired but reporting "no cap configured" — must not gate.
        let mockResponse: Data = Data(#"""
        {"id":"chatcmpl-1","model":"deepseek-chat","choices":[
          {"index":0,"message":{"role":"assistant","content":"ok","tool_calls":null},"finish_reason":"stop"}
        ],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
        """#.utf8)
        LLMProviderMockURLProtocol.responses = [
            "/v1/chat/completions": (200, mockResponse, [:]),
        ]

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LLMProviderMockURLProtocol.self]
        let client = LLMClient(
            provider: .deepseek,
            apiKey: "sk-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.deepseek.test")!,
            session: URLSession(configuration: cfg),
            capCheck: { nil }
        )
        let req = AnthropicMessageRequest(
            model: "deepseek-chat", max_tokens: 16,
            system: nil,
            messages: [.init(role: "user", content: .string("hi"))],
            tools: nil, tool_choice: nil
        )
        _ = try await client.createMessage(req)  // must not throw
    }

    // MARK: - Pre-encoding redaction (gold test)

    func testLineLeadingTokenIsRedactedBeforeReachingTheWire() async throws {
        // Regression: JSONEncoder writes `\n` as two characters, so a token
        // at the start of a line loses its leading `\b` on the encoded body
        // (it is preceded by the word-char `n` of the escape) and an
        // encoded-body-only redaction pass lets it through. createMessage's
        // plaintext pass must strip it before encoding — the raw token must
        // never appear in the captured outgoing body.
        let mockResponse: Data = Data(#"""
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}
        """#.utf8)
        LLMProviderMockURLProtocol.responses = [
            "/v1/messages": (200, mockResponse, [:]),
        ]
        LLMProviderMockURLProtocol.lastRequestBody = Data()

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [LLMProviderMockURLProtocol.self]
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: URLSession(configuration: cfg)
        )

        let token = "ghp_" + String(repeating: "A", count: 36)
        let req = AnthropicMessageRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 16,
            system: nil,
            messages: [.init(role: "user", content: .string("tool output:\n\(token)\nend"))],
            tools: nil,
            tool_choice: nil
        )
        _ = try await client.createMessage(req)

        let body = String(decoding: LLMProviderMockURLProtocol.lastRequestBody, as: UTF8.self)
        XCTAssertFalse(body.isEmpty, "mock must capture the outgoing body")
        XCTAssertFalse(body.contains(token), "line-leading token must never reach the wire")
        XCTAssertTrue(body.contains("<redacted:github-token>"))
    }

    // MARK: - Finding 3: daily-cap reservation under concurrency

    /// The reservation estimate is a conservative worst case: the whole
    /// max_tokens budget billed at the model's OUTPUT rate, plus a ~4-chars/
    /// token input allowance. Asserted directly because forcing true
    /// concurrency deterministically is fragile.
    func testReservationEstimateIsWorstCaseOutputPlusInputAllowance() {
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "k",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!
        )
        // Haiku 4.5: input 1.00/1M, output 5.00/1M.
        // Empty message text → 0 input tokens; 100k output tokens * 5/1e6 = 0.5.
        let req = AnthropicMessageRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 100_000,
            system: nil,
            messages: [.init(role: "user", content: .string(""))],
            tools: nil, tool_choice: nil
        )
        XCTAssertEqual(client.reservationEstimateUSD(for: req), 0.5, accuracy: 1e-9)

        // 8 input chars → 2 tokens * 1/1e6 = 2e-6 added on top of the 0.5 output.
        let reqWithInput = AnthropicMessageRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 100_000,
            system: nil,
            messages: [.init(role: "user", content: .string("abcdefgh"))],
            tools: nil, tool_choice: nil
        )
        XCTAssertEqual(client.reservationEstimateUSD(for: reqWithInput), 0.5 + 2e-6, accuracy: 1e-9)
    }

    /// An unknown model records as $0 (loud silence), so it must reserve $0 too
    /// — otherwise the reservation would gate a model the store treats as free.
    func testReservationEstimateIsZeroForUnknownModel() {
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "k",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!
        )
        let req = AnthropicMessageRequest(
            model: "no-such-model-xyz",
            max_tokens: 100_000,
            system: nil,
            messages: [.init(role: "user", content: .string("hi"))],
            tools: nil, tool_choice: nil
        )
        XCTAssertEqual(client.reservationEstimateUSD(for: req), 0)
    }

    /// The race the reservation closes: with a fixed near-cap `spent`, N
    /// concurrent createMessage calls would ALL pass the old `spent >= cap`
    /// gate and overshoot by ~N calls. The delayed mock keeps each admitted
    /// call in flight long enough that all N reach the atomic `admit` step
    /// before any releases, so the in-flight reservation actually bites:
    /// cap 1.0, estimate 0.5/call → 0+0<1 (admit), 0+0.5<1 (admit),
    /// 0+1.0>=1 (refuse ×3). Exactly two are admitted regardless of the order
    /// the tasks reach the actor.
    func testConcurrentCallsNearCapAreBoundedByReservation() async throws {
        let body = Data(#"""
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}
        """#.utf8)
        DelayedCapMockURLProtocol.response = (200, body)
        // Keep admitted calls in flight long enough that all 5 tasks reach the
        // atomic `admit` step before any releases — generous for slow CI.
        DelayedCapMockURLProtocol.delaySeconds = 1.0

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [DelayedCapMockURLProtocol.self]
        // Fixed cap 1.0 / spent 0.0 — recorded spend never moves during the
        // test, so any bounding must come from the in-flight reservation.
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: URLSession(configuration: cfg),
            capCheck: { .init(cap: 1.0, spent: 0.0) }
        )
        // Estimate per call ≈ 0.5 (100k output tokens at Haiku's 5/1M).
        let req = AnthropicMessageRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 100_000,
            system: nil,
            messages: [.init(role: "user", content: .string("hi"))],
            tools: nil, tool_choice: nil
        )

        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<5 {
                group.addTask {
                    do { _ = try await client.createMessage(req); return true }
                    catch { return false }
                }
            }
            var out: [Bool] = []
            for await ok in group { out.append(ok) }
            return out
        }

        let admitted = results.filter { $0 }.count
        XCTAssertEqual(admitted, 2,
            "reservation must bound concurrent admits to floor(cap/estimate) = 2; got \(admitted)")
        XCTAssertEqual(results.count - admitted, 3,
            "the other three concurrent calls must be refused by the reservation gate")
    }

    /// After an admitted call records + releases, the freed headroom is
    /// reusable: a later (sequential) call sees reserved back at 0 and gates
    /// on `spent` alone. Guards against the release path leaking reservations.
    func testReservationIsReleasedSoSequentialCallsStillProceed() async throws {
        let body = Data(#"""
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}
        """#.utf8)
        DelayedCapMockURLProtocol.response = (200, body)
        DelayedCapMockURLProtocol.delaySeconds = 0.0

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [DelayedCapMockURLProtocol.self]
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: URLSession(configuration: cfg),
            capCheck: { .init(cap: 1.0, spent: 0.0) }  // spent stays 0 (no real recorder wired)
        )
        let req = AnthropicMessageRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 100_000,          // reserves 0.5 while in flight
            system: nil,
            messages: [.init(role: "user", content: .string("hi"))],
            tools: nil, tool_choice: nil
        )
        // Three back-to-back calls. Each reserves 0.5, then releases on return.
        // If release leaked, the third would see reserved >= 1.0 and be refused.
        for _ in 0..<3 {
            _ = try await client.createMessage(req)  // must not throw
        }
    }
}

// MARK: - URL protocol mock

final class LLMProviderMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, Data, [String: String])] = [:]
    nonisolated(unsafe) static var lastRequestHeaders: [String: String] = [:]
    nonisolated(unsafe) static var lastRequestBody: Data = Data()
    /// v0.3.0: total requests that reached the mock. Lets the daily-cap
    /// tests assert a capped call made NO network request at all.
    nonisolated(unsafe) static var requestCount: Int = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        // Record the request headers + body for assertions. URLSession hands
        // URLProtocol the body as a stream, not via `httpBody`, so drain it.
        if let headers = request.allHTTPHeaderFields {
            Self.lastRequestHeaders = headers
        }
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                body.append(contentsOf: buffer[0..<read])
            }
            Self.lastRequestBody = body
        } else if let body = request.httpBody {
            Self.lastRequestBody = body
        }
        let path = request.url?.path ?? ""
        guard let (status, body, extraHeaders) = Self.responses[path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var headers = ["Content-Type": "application/json"]
        for (k, v) in extraHeaders { headers[k] = v }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Delaying URL protocol mock (Finding 3 concurrency)

/// Sleeps `delaySeconds` in startLoading so multiple admitted calls stay in
/// flight simultaneously — the condition under which the daily-cap
/// reservation must bound concurrent admits.
final class DelayedCapMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var delaySeconds: TimeInterval = 0.5
    nonisolated(unsafe) static var response: (Int, Data) = (200, Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.delaySeconds > 0 {
            Thread.sleep(forTimeInterval: Self.delaySeconds)
        }
        let (status, body) = Self.response
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
