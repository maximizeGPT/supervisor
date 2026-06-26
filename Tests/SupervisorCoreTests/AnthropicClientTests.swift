// AnthropicClientTests.swift
//
// Two layers:
//
//   1. Mocked URLSession tests — exhaustive over the typed error surface.
//      Run in `swift test`, no network needed.
//
//   2. Live API tests — gated on ANTHROPIC_API_KEY env var.  Confirms the
//      mock-based contract matches Anthropic's actual error shapes.
//      Runs once during the v0.1.0 build with the user's real key.

import XCTest
@testable import SupervisorCore

final class AnthropicClientTests: XCTestCase {

    // MARK: - URLProtocol-based mock

    /// Per-test registry: { URL path → (statusCode, body, headers) }
    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]
    /// URLSession that resolves through MockURLProtocol.
    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override func setUp() {
        super.setUp()
        Self.canned.removeAll()
    }

    private func makeClient(session: URLSession? = nil) -> LLMClient {
        LLMClient(provider: .anthropic, 
            apiKey: "sk-ant-test-key",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: session ?? mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("supervisor-trace-\(UUID().uuidString).log"))
        )
    }

    // MARK: - Happy path

    func testCreateMessageHappyPath() async throws {
        let body = """
        {"id":"msg_01","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":1}}
        """
        Self.canned["/v1/messages"] = (200, Data(body.utf8), [:])

        let client = makeClient()
        let req = AnthropicMessageRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 1,
            messages: [.init(role: "user", content: .string("hi"))]
        )
        let resp = try await client.createMessage(req)
        XCTAssertEqual(resp.id, "msg_01")
        XCTAssertEqual(resp.usage.input_tokens, 3)
        XCTAssertEqual(resp.usage.output_tokens, 1)
    }

    // MARK: - Typed errors

    func testInvalidKey401() async {
        Self.canned["/v1/messages"] = (
            401,
            Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8),
            [:]
        )
        do {
            _ = try await makeClient().validateKey()
            XCTFail("expected invalidKey")
        } catch let AnthropicClientError.invalidKey(msg) {
            XCTAssertTrue(msg.contains("authentication_error"), "msg=\(msg)")
        } catch {
            XCTFail("expected invalidKey, got \(error)")
        }
    }

    func testPermissionDenied403() async {
        Self.canned["/v1/messages"] = (
            403,
            Data(#"{"type":"error","error":{"type":"permission_error","message":"forbidden"}}"#.utf8),
            [:]
        )
        do {
            _ = try await makeClient().validateKey()
            XCTFail()
        } catch AnthropicClientError.permissionDenied { /* ok */ } catch {
            XCTFail("got \(error)")
        }
    }

    func testRateLimit429WithRetryAfter() async {
        Self.canned["/v1/messages"] = (
            429,
            Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8),
            ["retry-after": "12"]
        )
        do {
            _ = try await makeClient().validateKey()
            XCTFail()
        } catch let AnthropicClientError.rateLimit(_, retry) {
            XCTAssertEqual(retry, 12)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testRateLimit429WithoutRetryAfter() async {
        Self.canned["/v1/messages"] = (
            429,
            Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"x"}}"#.utf8),
            [:]
        )
        do {
            _ = try await makeClient().validateKey()
            XCTFail()
        } catch let AnthropicClientError.rateLimit(_, retry) {
            XCTAssertNil(retry)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testServerError500() async {
        Self.canned["/v1/messages"] = (500, Data("oops".utf8), [:])
        do {
            _ = try await makeClient().validateKey()
            XCTFail()
        } catch AnthropicClientError.serverError(let s, _) {
            XCTAssertEqual(s, 500)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testGeneric4xx() async {
        Self.canned["/v1/messages"] = (404, Data("nope".utf8), [:])
        do {
            _ = try await makeClient().validateKey()
            XCTFail()
        } catch AnthropicClientError.requestError(let s, _) {
            XCTAssertEqual(s, 404)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testDecodingFailedOnMalformedBody() async {
        Self.canned["/v1/messages"] = (200, Data(#"{"id":"msg","type":"message","role":"assistant"}"#.utf8), [:])
        do {
            _ = try await makeClient().validateKey()
            XCTFail()
        } catch AnthropicClientError.decodingFailed { /* ok */ } catch {
            XCTFail("got \(error)")
        }
    }

    func testNetworkErrorSurfaces() async {
        // No canned response → MockURLProtocol returns a typed network error.
        Self.canned.removeAll()
        do {
            _ = try await makeClient().validateKey()
            XCTFail()
        } catch AnthropicClientError.network { /* ok */ } catch {
            XCTFail("got \(error)")
        }
    }

    // MARK: - Redactor is applied to the outgoing payload

    func testRedactorAppliedToRequestBody() async throws {
        let body = """
        {"id":"m","type":"message","role":"assistant","model":"x","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}
        """
        Self.canned["/v1/messages"] = (200, Data(body.utf8), [:])

        let client = makeClient()
        // Prompt contains a fake Anthropic key + GitHub token. Redactor
        // should mask both before transmission.
        let req = AnthropicMessageRequest(
            model: "x",
            max_tokens: 1,
            messages: [.init(role: "user", content: .string(
                "key sk-ant-abcd1234efgh5678ijkl90mnopqr token ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            ))]
        )
        _ = try await client.createMessage(req)

        let sent = MockURLProtocol.lastRequestBody ?? Data()
        let s = String(decoding: sent, as: UTF8.self)
        XCTAssertFalse(s.contains("sk-ant-abcd1234"),
                       "raw Anthropic key escaped redaction: \(s)")
        XCTAssertFalse(s.contains("ghp_AAAAAAAAAA"),
                       "raw GitHub token escaped redaction: \(s)")
        XCTAssertTrue(s.contains("<redacted:anthropic-key>") || s.contains("<redacted:github-token>"))
    }

    // MARK: - TokenAccounting

    func testTokenAccountingForKnownModel() {
        let usage = AnthropicUsage(
            input_tokens: 10_000,
            output_tokens: 1_000,
            cache_creation_input_tokens: nil,
            cache_read_input_tokens: nil
        )
        let cost = TokenAccounting.costUSD(model: "claude-haiku-4-5-20251001", usage: usage)
        // 10K input @ $1.00/1M = $0.01; 1K output @ $5.00/1M = $0.005; total $0.015.
        XCTAssertEqual(cost, 0.015, accuracy: 0.0001)
    }

    func testTokenAccountingUnknownModelIsZero() {
        let usage = AnthropicUsage(input_tokens: 9_999, output_tokens: 9_999,
                                   cache_creation_input_tokens: nil,
                                   cache_read_input_tokens: nil)
        XCTAssertEqual(TokenAccounting.costUSD(model: "made-up-model", usage: usage), 0)
    }

    // MARK: - Live API (gated)

    /// Runs only if ANTHROPIC_API_KEY is set in the env. I run this
    /// once during the Phase A build with his real key.
    func testLiveValidateKeyValidAndInvalid() async throws {
        guard let realKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
              !realKey.isEmpty else {
            throw XCTSkip("ANTHROPIC_API_KEY not set; live-API test skipped")
        }

        // Real key → must succeed.
        let realClient = LLMClient(provider: .anthropic, 
            apiKey: realKey,
            redactor: DefaultRedactor(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("supervisor-live-\(UUID().uuidString).log"))
        )
        let result = try await realClient.validateKey()
        switch result {
        case .valid(let model):
            XCTAssertTrue(model.contains("haiku"), "expected haiku, got \(model)")
        }

        // Bogus key → must throw .invalidKey.
        let bogusClient = LLMClient(provider: .anthropic, 
            apiKey: "sk-ant-invalid_test_key_should_fail_hard",
            redactor: DefaultRedactor(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("supervisor-live-\(UUID().uuidString).log"))
        )
        do {
            _ = try await bogusClient.validateKey()
            XCTFail("expected invalidKey for bogus key")
        } catch AnthropicClientError.invalidKey {
            // ok
        } catch {
            XCTFail("expected invalidKey, got \(error)")
        }
    }
}

// MARK: - URLProtocol mock

private final class MockURLProtocol: URLProtocol {

    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Capture the body before serving. URLProtocol receives body via
        // httpBodyStream when the body is large; URLSession's
        // `data(for:)` path uses httpBody so we read both.
        if let data = request.httpBody {
            Self.lastRequestBody = data
        } else if let stream = request.httpBodyStream {
            var buf = Data()
            stream.open()
            defer { stream.close() }
            let cap = 65_536
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
            defer { p.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(p, maxLength: cap)
                if n <= 0 { break }
                buf.append(p, count: n)
            }
            Self.lastRequestBody = buf
        } else {
            Self.lastRequestBody = nil
        }

        let path = request.url?.path ?? ""
        guard let (status, body, headers) = AnthropicClientTests.canned[path] else {
            let err = NSError(domain: NSURLErrorDomain,
                              code: NSURLErrorResourceUnavailable,
                              userInfo: [NSLocalizedDescriptionKey: "no canned response for \(path)"])
            client?.urlProtocol(self, didFailWithError: err)
            return
        }

        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
