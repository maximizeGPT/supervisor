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

    /// v0.3.0 cost hook (P0-4). Called once per successful `createMessage`
    /// with the requested model id and the usage block the provider
    /// returned — createMessage is the single choke point every network
    /// call flows through, so wiring this records ALL spend (triage,
    /// QuestionAnswerer, Dispatcher, LLMConversationMatcher) with no
    /// per-call-site plumbing. nil (the default) = no recording, i.e.
    /// exactly the pre-v0.3.0 behavior.
    ///
    /// Wired in exactly ONE place in production: SupervisorApp's
    /// enterRunningState hands the shared running-state client a recorder
    /// backed by the same CostStore the panel reads. TriageEngine's old
    /// per-call-site recordHaiku calls were removed at the same time —
    /// recording lives here and ONLY here, or spend double-counts.
    private let costRecorder: (@Sendable (_ model: String, _ usage: AnthropicUsage) -> Void)?

    /// v0.3.0 daily-cap gate (P0-4). Consulted at the top of every
    /// `createMessage`; when it returns a (cap, spent) pair with
    /// spent >= cap, the call throws `DailyCapExceededError` WITHOUT
    /// making a network request. Return nil for "no cap configured /
    /// don't gate". nil closure (the default) = no gating at all.
    ///
    /// Wired next to `costRecorder` in SupervisorApp's enterRunningState:
    /// reads UserConfig.dailyCostCapUSD (re-loaded per call, so cap edits
    /// apply live) against CostStore.todayTotalUSD().
    private let capCheck: (@Sendable () -> (cap: Double, spent: Double)?)?

    /// Finding 3 (2026-07-03): in-flight spend reservation, so the daily-cap
    /// gate holds under concurrent bursts. Guards a single `reserved` Double
    /// (the sum of estimates for calls that have passed the gate but not yet
    /// recorded). An actor because `createMessage` is `async` and the client
    /// is `Sendable` — many Tasks can be inside `createMessage` at once.
    private let spendReserve = SpendReserve()

    public init(
        provider: LLMProvider,
        apiKey: String,
        redactor: any Redactor,
        baseURL: URL? = nil,
        session: URLSession = .shared,
        traceLog: TraceLog = .shared,
        anthropicVersion: String = "2023-06-01",
        costRecorder: (@Sendable (_ model: String, _ usage: AnthropicUsage) -> Void)? = nil,
        capCheck: (@Sendable () -> (cap: Double, spent: Double)?)? = nil
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.redactor = redactor
        self.baseURL = baseURL ?? provider.baseURL
        self.session = session
        self.traceLog = traceLog
        self.anthropicVersion = anthropicVersion
        self.costRecorder = costRecorder
        self.capCheck = capCheck
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
        // v0.3.0 daily-cap gate: refuse BEFORE any network work. The
        // check sits ahead of encoding/redaction on purpose — a capped
        // call should cost nothing, not even CPU.
        //
        // Finding 3 (2026-07-03): the gate compares against RECORDED spend,
        // which only updates AFTER a call's network round-trip completes. Under
        // a concurrent burst, N Tasks all read the same pre-spend `spent`, all
        // pass `spent >= cap`, and actual spend overshoots the cap by ~N calls.
        // Fix: reserve an estimate of this call's cost in an in-flight
        // accumulator (the `spendReserve` actor) and gate on
        // `spent + reserved >= cap` ATOMICALLY. Because the reserve-and-check
        // runs inside the actor, a second concurrent call sees the first's
        // reservation and is refused once the in-flight total would blow the
        // cap — bounding overshoot to about one reservation's granularity. A
        // single (non-concurrent) call still gates on `spent` alone: the
        // in-flight total is 0 at that point, so `admit` reduces to the exact
        // pre-Finding-3 boundary (`spent >= cap`).
        var reservation: Double? = nil
        if let capCheck, let limit = capCheck() {
            let estimate = reservationEstimateUSD(for: request)
            if let blocking = await spendReserve.admit(estimate: estimate, spent: limit.spent, cap: limit.cap) {
                traceLog.emit(
                    "api",
                    "daily cap reached: spent=\(limit.spent) reserved=\(blocking) cap=\(limit.cap) provider=\(provider.rawValue) — call refused"
                )
                throw DailyCapExceededError(capUSD: limit.cap, spentUSD: limit.spent)
            }
            reservation = estimate
        }

        do {
            // First redaction pass, over the PLAINTEXT. JSONEncoder writes a
            // newline as the two characters `\n`, so on the encoded body the
            // `(?m)^` line anchors and the `\b` boundaries at line starts never
            // fire — an `export FOO=...` line or a line-leading `ghp_`/`AKIA`
            // token would sail through an encoded-body pass alone. Redacting
            // here, before any encoding, gives every pattern the real newlines
            // it was written against. The encoded-body pass inside each POST
            // path stays as a second layer.
            let redactedRequest = plaintextRedacted(request)
            let response: AnthropicMessageResponse
            switch provider.apiShape {
            case .anthropic:
                response = try await postAnthropic(redactedRequest)
            case .openAICompat:
                response = try await postOpenAICompat(redactedRequest)
            }

            // v0.3.0 cost hook: record the spend of every successful call at
            // the choke point. Passes the REQUESTED model id (the pricing
            // table is keyed on the ids we configure, e.g. "deepseek-chat"),
            // not the wire-echoed one. See the `costRecorder` doc comment for
            // the double-counting handoff with TriageEngine.
            costRecorder?(request.model, response.usage)
            // Finding 3: the real cost is now recorded (visible to the next
            // capCheck), so release the estimate from the in-flight total.
            if let reservation { await spendReserve.release(reservation) }
            return response
        } catch {
            // Finding 3: nothing was recorded — release the reservation so a
            // failed call doesn't permanently occupy in-flight headroom.
            if let reservation { await spendReserve.release(reservation) }
            throw error
        }
    }

    // MARK: - Plaintext redaction (first pass, pre-encoding)

    /// Returns a copy of `request` with every human-content string — the
    /// system prompt and each message's content — run through the redactor
    /// while it is still plaintext. Fail-closed the same way the
    /// encoded-body pass is: the redacted copy is built before any request
    /// body exists and is the only value handed to the POST paths, so no
    /// code path can encode or send the original strings.
    private func plaintextRedacted(_ request: AnthropicMessageRequest) -> AnthropicMessageRequest {
        AnthropicMessageRequest(
            model: request.model,
            max_tokens: request.max_tokens,
            system: request.system.map { redactor.redact($0) },
            messages: request.messages.map { message in
                AnthropicMessage(role: message.role, content: plaintextRedacted(message.content))
            },
            tools: request.tools,
            tool_choice: request.tool_choice
        )
    }

    private func plaintextRedacted(_ content: AnthropicContent) -> AnthropicContent {
        switch content {
        case .string(let s):
            return .string(redactor.redact(s))
        case .blocks(let blocks):
            return .blocks(blocks.map { block in
                AnthropicContentBlock(
                    type: block.type,
                    text: block.text.map { redactor.redact($0) },
                    id: block.id,
                    name: block.name,
                    input: block.input,
                    tool_use_id: block.tool_use_id,
                    content: block.content
                )
            })
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
        // Second-layer pass over the encoded body. The plaintext pass in
        // createMessage() already ran; this catches anything assembled by
        // the encoder itself.
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
        // Second-layer pass over the encoded body. The plaintext pass in
        // createMessage() already ran; this catches anything assembled by
        // the encoder itself.
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

        let isLengthTruncated = choice.finish_reason == "length"

        if let calls = choice.message.tool_calls, !calls.isEmpty {
            for call in calls {
                // Tool arguments arrive as a JSON-encoded string. Parse them
                // back into an AnthropicJSON tree so the rest of the
                // pipeline sees the same shape it would from Anthropic.
                let parsedInput: AnthropicJSON?
                if let argData = call.function.arguments.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(AnthropicJSON.self, from: argData) {
                    parsedInput = parsed
                } else if isLengthTruncated,
                          let repairedData = Self.tryRepairTruncatedJSON(call.function.arguments),
                          let repaired = try? JSONDecoder().decode(AnthropicJSON.self, from: repairedData) {
                    // finish_reason=length: DeepSeek hit max_tokens and truncated
                    // the JSON mid-string. Attempt repair — close unterminated
                    // strings, add missing braces, or truncate to the last complete
                    // key-value pair. Mirrors the Python hook's
                    // _try_repair_truncated_json (v0.5.1-hook).
                    parsedInput = repaired
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

    // MARK: - JSON truncation repair (v0.5.1)

    /// Attempt to recover a JSON object from a truncated string.
    /// DeepSeek sometimes hits max_tokens mid-JSON, leaving unterminated
    /// strings and missing closing braces. Mirrors the Python hook's
    /// `_try_repair_truncated_json` (v0.5.1-hook, commit ed8fccd).
    ///
    /// Returns repaired JSON as Data suitable for JSONDecoder, or nil.
    static func tryRepairTruncatedJSON(_ raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Strategy 1: close unterminated string + add missing braces.
        var repaired = trimmed
        let quoteCount = repaired.filter { $0 == "\"" }.count
        if quoteCount % 2 != 0 {
            repaired += "\""
        }
        let openBraces = repaired.filter { $0 == "{" }.count - repaired.filter { $0 == "}" }.count
        let openBrackets = repaired.filter { $0 == "[" }.count - repaired.filter { $0 == "]" }.count
        repaired += String(repeating: "]", count: max(0, openBrackets))
        repaired += String(repeating: "}", count: max(0, openBraces))
        if let data = repaired.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           obj is [String: Any] {
            return data
        }

        // Strategy 2: truncate to last complete key-value pair.
        let chars = Array(raw)
        for i in stride(from: chars.count - 1, through: 1, by: -1) {
            guard chars[i] == "," || chars[i] == "{" else { continue }
            let prefix = chars[i] == "," ? String(chars[..<i]) : String(chars[...i])
            var candidate = prefix
            let ob = candidate.filter { $0 == "{" }.count - candidate.filter { $0 == "}" }.count
            let ok = candidate.filter { $0 == "[" }.count - candidate.filter { $0 == "]" }.count
            candidate += String(repeating: "]", count: max(0, ok))
            candidate += String(repeating: "}", count: max(0, ob))
            if let data = candidate.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               obj is [String: Any] {
                return data
            }
        }
        return nil
    }

    // MARK: - Daily-cap reservation (Finding 3)

    /// A conservative worst-case cost for ONE call, in USD. Used only to
    /// reserve in-flight spend so a concurrent burst can't blow the daily cap
    /// between the pre-call `spent` read and the post-call record.
    ///
    /// Estimate basis: the ENTIRE `max_tokens` budget billed at the model's
    /// OUTPUT rate (output is the pricier side, and the reply length is the one
    /// unknown at gate time), plus a rough input allowance from the request
    /// text at ~4 chars/token. Overestimating is safe — it only makes the gate
    /// slightly more conservative under concurrency; a single call still gates
    /// on recorded `spent` alone (in-flight total is 0). An unknown model
    /// records as $0 (loud silence per TokenAccounting), so it reserves $0 too
    /// — the reservation never gates a model whose spend the store treats as
    /// free.
    func reservationEstimateUSD(for request: AnthropicMessageRequest) -> Double {
        guard let price = TokenAccounting.prices[request.model] else { return 0 }
        let inputChars = (request.system?.count ?? 0) + request.messages.reduce(0) { acc, message in
            switch message.content {
            case .string(let s):
                return acc + s.count
            case .blocks(let blocks):
                return acc + blocks.reduce(0) { $0 + ($1.text?.count ?? 0) }
            }
        }
        let inputTokens = Double(inputChars) / 4.0
        let outputTokens = Double(request.max_tokens)
        return inputTokens * (price.inputPer1M / 1_000_000)
             + outputTokens * (price.outputPer1M / 1_000_000)
    }

    /// Serializes the in-flight reservation accounting for the daily-cap gate.
    /// `admit` is the atomic "gate + reserve" step: two concurrent calls can't
    /// both read the same pre-reservation total and both pass, because the
    /// second runs after the first has committed its reservation.
    private actor SpendReserve {
        /// Sum of estimates for calls admitted but not yet recorded/released.
        private(set) var reserved: Double = 0

        /// Atomic gate. If `spent` plus what is ALREADY in flight (reserved by
        /// other concurrent calls, NOT this one) would meet or exceed `cap`,
        /// refuse: return the blocking in-flight total and reserve nothing.
        /// Otherwise reserve `estimate` for this call and return nil (admitted).
        /// A single, non-concurrent call sees `reserved == 0`, so the test
        /// reduces to `spent >= cap` — the exact pre-Finding-3 boundary.
        func admit(estimate: Double, spent: Double, cap: Double) -> Double? {
            if spent + reserved >= cap {
                return reserved
            }
            reserved += estimate
            return nil
        }

        /// Drop a prior reservation once its call has recorded (or failed).
        /// `max(0, …)` guards against any double-release drifting negative.
        func release(_ estimate: Double) {
            reserved = max(0, reserved - estimate)
        }
    }
}
