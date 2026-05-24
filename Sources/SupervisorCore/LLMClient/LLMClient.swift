// LLMClient.swift — v0.2.0 multi-provider triage client.
//
// Replaces the v0.1.x `AnthropicClient` as the URLSession-backed wrapper
// used by triage + onboarding-validation. Same public shape (validateKey,
// createMessage) so call sites move with a one-line type change; the new
// thing is that requests can target any provider listed in `LLMProvider`.
//
// Architecture:
//   - The canonical internal request/response is still
//     `AnthropicMessageRequest` / `AnthropicMessageResponse`. That keeps
//     `TriagePrompt` and the rest of the triage pipeline unchanged.
//   - For `apiShape == .anthropic`, we serialize as Anthropic JSON and
//     decode the Anthropic response — i.e. the v0.1.x path is preserved
//     verbatim. The Anthropic CI test suite still validates this path.
//   - For `apiShape == .openAICompat` (DeepSeek, Moonshot, MiniMax,
//     Qwen-HF), we translate the canonical request into OpenAI's
//     chat.completions shape, POST it, then translate the response back
//     into the canonical Anthropic shape. The TriageEngine's
//     extractCandidates() code path is identical in both cases.
//
// Why translation, not abstraction at the call site? Two reasons:
//   1. The triage prompt is mature (calibrated, tested). Rebuilding
//      it in an OpenAI-native shape would mean re-doing the calibration.
//   2. The forced-tool-call semantics are the same in both protocols;
//      the only difference is field names and where the JSON lives.
//      A translator is ~50 lines; a parallel pipeline would be ~500.
//
// The `redactor` requirement, the trace-log lines, the URLSession
// behavior, and the typed error mapping (`AnthropicClientError`) all
// carry over from the v0.1.x `AnthropicClient` unchanged.

import Foundation

/// Returned from `LLMClient.validateKey()`. The model echoed back lets
/// the caller log which model the provider used for the 1-token check
/// (useful when a provider has multiple defaults and the wire model
/// differs from `defaultTriageModel`).
public enum KeyValidation: Sendable, Equatable {
    case valid(model: String)
}

public final class LLMClient: Sendable {

    public let provider: LLMProvider
    public let baseURL: URL
    public let session: URLSession
    private let apiKey: String
    private let redactor: any Redactor
    private let traceLog: TraceLog

    /// Anthropic-version header. Only sent when talking to Anthropic.
    private let anthropicVersion: String

    public init(
        provider: LLMProvider,
        apiKey: String,
        redactor: any Redactor,
        baseURL: URL? = nil,
        session: URLSession = .shared,
        traceLog: TraceLog = .shared,
        anthropicVersion: String = "2023-06-01"
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.redactor = redactor
        self.baseURL = baseURL ?? provider.baseURL
        self.session = session
        self.traceLog = traceLog
        self.anthropicVersion = anthropicVersion
    }

    // MARK: - Public surface

    /// 1-token throwaway to confirm the key works. Same semantics as
    /// the v0.1.x `AnthropicClient.validateKey()`, but now provider-aware:
    /// for OpenAI-compat providers we POST to `/v1/chat/completions`
    /// with a minimal "ping" message; for Anthropic we hit `/v1/messages`
    /// with the same single-token request shape v0.1.x used.
    public func validateKey() async throws -> KeyValidation {
        let req = AnthropicMessageRequest(
            model: provider.defaultTriageModel,
            max_tokens: 1,
            system: nil,
            messages: [.init(role: "user", content: .string("ping"))],
            tools: nil,
            tool_choice: nil
        )
        do {
            let resp = try await createMessage(req)
            traceLog.emit(
                "api",
                "validateKey ok provider=\(provider.rawValue) model=\(resp.model) input=\(resp.usage.input_tokens) output=\(resp.usage.output_tokens)"
            )
            return .valid(model: resp.model)
        } catch let e as AnthropicClientError {
            traceLog.emit("api", "validateKey failed provider=\(provider.rawValue): \(e.localizedDescription)")
            throw e
        }
    }

    /// Full triage / escalation call. Same input as v0.1.x; under the
    /// hood we dispatch by provider's `apiShape` and translate if
    /// needed. The return type is `AnthropicMessageResponse` regardless
    /// of the wire shape so call sites don't branch.
    @discardableResult
    public func createMessage(_ request: AnthropicMessageRequest) async throws -> AnthropicMessageResponse {
        switch provider.apiShape {
        case .anthropic:
            return try await postAnthropic(request)
        case .openAICompat:
            return try await postOpenAICompat(request)
        }
    }

    // MARK: - Anthropic path (preserved from v0.1.x)

    private func postAnthropic(_ request: AnthropicMessageRequest) async throws -> AnthropicMessageResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bodyData: Data
        do {
            bodyData = try encoder.encode(request)
        } catch {
            throw AnthropicClientError.decodingFailed(reason: "request encode: \(error)")
        }
        let redacted = redactor.redact(String(decoding: bodyData, as: UTF8.self))
        let outgoing = Data(redacted.utf8)

        traceLog.emit(
            "api",
            "POST /v1/messages provider=anthropic model=\(request.model) max_tokens=\(request.max_tokens) bytes=\(outgoing.count)"
        )

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("/v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setAuthHeader(on: &urlRequest)
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = outgoing

        let (data, http) = try await send(urlRequest)
        try mapStatus(http, data: data)

        do {
            return try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(512), as: UTF8.self)
            throw AnthropicClientError.decodingFailed(reason: "body: \(preview) — error: \(error)")
        }
    }

    // MARK: - OpenAI-compatible path (new in v0.2.0)

    private func postOpenAICompat(_ request: AnthropicMessageRequest) async throws -> AnthropicMessageResponse {
        let openAIRequest = Self.translateRequest(request)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bodyData: Data
        do {
            bodyData = try encoder.encode(openAIRequest)
        } catch {
            throw AnthropicClientError.decodingFailed(reason: "request encode: \(error)")
        }
        let redacted = redactor.redact(String(decoding: bodyData, as: UTF8.self))
        let outgoing = Data(redacted.utf8)

        traceLog.emit(
            "api",
            "POST /v1/chat/completions provider=\(provider.rawValue) model=\(request.model) max_tokens=\(request.max_tokens) bytes=\(outgoing.count)"
        )

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("/v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setAuthHeader(on: &urlRequest)
        urlRequest.httpBody = outgoing

        let (data, http) = try await send(urlRequest)
        try mapStatus(http, data: data)

        do {
            let openAIResp = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            return try Self.translateResponse(openAIResp, requestedModel: request.model)
        } catch let e as AnthropicClientError {
            throw e
        } catch {
            let preview = String(decoding: data.prefix(512), as: UTF8.self)
            throw AnthropicClientError.decodingFailed(reason: "openai-compat body: \(preview) — error: \(error)")
        }
    }

    // MARK: - Shared HTTP helpers

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw AnthropicClientError.decodingFailed(reason: "non-HTTP response")
            }
            return (data, http)
        } catch let e as AnthropicClientError {
            throw e
        } catch {
            traceLog.emit("api", "URLSession failed: \(error)")
            throw AnthropicClientError.network(underlying: "\(error)")
        }
    }

    private func mapStatus(_ http: HTTPURLResponse, data: Data) throws {
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw AnthropicClientError.invalidKey(message: extractErrorMessage(from: data))
        case 403:
            throw AnthropicClientError.permissionDenied(message: extractErrorMessage(from: data))
        case 429:
            let retry = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw AnthropicClientError.rateLimit(
                message: extractErrorMessage(from: data),
                retryAfter: retry
            )
        case 400..<500:
            throw AnthropicClientError.requestError(
                status: http.statusCode,
                message: extractErrorMessage(from: data)
            )
        case 500..<600:
            throw AnthropicClientError.serverError(
                status: http.statusCode,
                message: extractErrorMessage(from: data)
            )
        default:
            throw AnthropicClientError.requestError(
                status: http.statusCode,
                message: "unexpected status"
            )
        }
    }

    private func setAuthHeader(on request: inout URLRequest) {
        switch provider.authHeader {
        case .xApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Extract a human-readable message from either an Anthropic-shaped
    /// error envelope or an OpenAI-shaped one. Both providers respond
    /// with structured JSON on 4xx/5xx; fall back to raw bytes if the
    /// shape doesn't match either.
    private func extractErrorMessage(from data: Data) -> String {
        if let body = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
            return "\(body.error.type): \(body.error.message)"
        }
        if let env = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data),
           let err = env.error {
            let parts = [err.type, err.message].compactMap { $0 }
            if !parts.isEmpty {
                return parts.joined(separator: ": ")
            }
        }
        return String(decoding: data.prefix(512), as: UTF8.self)
    }

    // MARK: - Anthropic ↔ OpenAI translation

    /// Translate the canonical Anthropic-shaped request into the OpenAI
    /// chat.completions shape. Lossless for the slice of fields Supervisor
    /// uses (single system prompt, single user message, forced-function
    /// tool call). Multi-turn / image / streaming aren't supported by the
    /// triage pipeline and aren't translated here either.
    static func translateRequest(_ req: AnthropicMessageRequest) -> OpenAIChatRequest {
        var messages: [OpenAIMessage] = []
        if let system = req.system, !system.isEmpty {
            messages.append(.init(role: "system", content: system))
        }
        for msg in req.messages {
            let text: String
            switch msg.content {
            case .string(let s):
                text = s
            case .blocks(let blocks):
                // Concatenate text blocks; ignore tool_use/tool_result for
                // the request side (the triage pipeline only sends text).
                text = blocks.compactMap { $0.text }.joined(separator: "\n")
            }
            messages.append(.init(role: msg.role, content: text))
        }

        let tools = req.tools?.map { tool in
            OpenAITool(
                type: "function",
                function: .init(
                    name: tool.name,
                    description: tool.description,
                    parameters: tool.input_schema
                )
            )
        }

        let toolChoice: OpenAIToolChoice? = {
            guard let tc = req.tool_choice else { return nil }
            // Anthropic's "tool" + name → OpenAI's forced function shape.
            // "any" and "auto" are also expressible but the triage pipeline
            // always uses the forced form, so we don't bother with the
            // string-shape variants here.
            if tc.type == "tool", let n = tc.name {
                return OpenAIToolChoice.forced(n)
            }
            if let n = tc.name {
                return OpenAIToolChoice.forced(n)
            }
            return nil
        }()

        return OpenAIChatRequest(
            model: req.model,
            max_tokens: req.max_tokens,
            messages: messages,
            tools: tools,
            tool_choice: toolChoice
        )
    }

    /// Translate an OpenAI chat.completions response back into the
    /// canonical Anthropic-shaped response so the triage engine's
    /// `extractCandidates(from:)` works unchanged. Tool calls become
    /// `tool_use` content blocks; plain assistant text becomes a `text`
    /// block; usage maps prompt/completion → input/output tokens.
    static func translateResponse(
        _ resp: OpenAIChatResponse,
        requestedModel: String
    ) throws -> AnthropicMessageResponse {
        guard let choice = resp.choices.first else {
            throw AnthropicClientError.decodingFailed(reason: "openai response had no choices")
        }
        var blocks: [AnthropicContentBlock] = []

        if let calls = choice.message.tool_calls, !calls.isEmpty {
            for call in calls {
                // Tool arguments arrive as a JSON-encoded string. Parse them
                // back into an AnthropicJSON tree so the rest of the
                // pipeline sees the same shape it would from Anthropic.
                let parsedInput: AnthropicJSON?
                if let argData = call.function.arguments.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(AnthropicJSON.self, from: argData) {
                    parsedInput = parsed
                } else {
                    // Malformed JSON in arguments — surface as null so the
                    // extractor can log the schema.malformed line instead
                    // of crashing.
                    parsedInput = .null
                }
                blocks.append(.init(
                    type: "tool_use",
                    text: nil,
                    id: call.id,
                    name: call.function.name,
                    input: parsedInput
                ))
            }
        }
        if let text = choice.message.content, !text.isEmpty {
            blocks.append(.init(type: "text", text: text))
        }

        let usage = AnthropicUsage(
            input_tokens: resp.usage?.prompt_tokens ?? 0,
            output_tokens: resp.usage?.completion_tokens ?? 0,
            cache_creation_input_tokens: nil,
            cache_read_input_tokens: nil
        )

        return AnthropicMessageResponse(
            id: resp.id ?? "openai-compat-unset",
            type: "message",
            role: choice.message.role,
            model: resp.model ?? requestedModel,
            content: blocks,
            stop_reason: choice.finish_reason,
            stop_sequence: nil,
            usage: usage
        )
    }
}
