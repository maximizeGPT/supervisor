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
}

// MARK: - URL protocol mock

final class LLMProviderMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, Data, [String: String])] = [:]
    nonisolated(unsafe) static var lastRequestHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Record the request headers for assertions.
        if let headers = request.allHTTPHeaderFields {
            Self.lastRequestHeaders = headers
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
