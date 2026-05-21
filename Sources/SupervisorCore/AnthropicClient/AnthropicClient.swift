// AnthropicClient.swift
//
// URLSession-backed thin wrapper around the Anthropic Messages API.
//
// Two public surfaces matter:
//   - validateKey()  : 1-token throwaway used by the onboarding window
//                      to confirm a user-entered key is valid.
//   - createMessage(): the full triage / escalation call.
//
// The Redactor is non-optional by the initializer's signature; you can't
// construct an AnthropicClient without one, and every payload that goes
// over the wire is passed through `redactor.redact(_:)` first. This is
// the architectural enforcement of DESIGN.md §8 item 3.

import Foundation

public final class AnthropicClient: Sendable {

    public let baseURL: URL
    public let session: URLSession
    private let apiKey: String
    private let redactor: any Redactor
    private let traceLog: TraceLog
    private let apiVersion: String

    /// `apiKey` is held in memory only — never written to disk by the
    /// client. The Keychain wrapper is the only persistent store.
    /// `redactor` is required; passing nil isn't expressible.
    public init(
        apiKey: String,
        redactor: any Redactor,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared,
        traceLog: TraceLog = .shared,
        apiVersion: String = "2023-06-01"
    ) {
        self.apiKey = apiKey
        self.redactor = redactor
        self.baseURL = baseURL
        self.session = session
        self.traceLog = traceLog
        self.apiVersion = apiVersion
    }

    // MARK: - Public surface

    /// Resolve key validity. Returns .valid on success; throws typed error
    /// on failure. Uses a 1-token Haiku call so we don't burn budget.
    public func validateKey() async throws -> KeyValidation {
        let req = AnthropicMessageRequest(
            model: "claude-haiku-4-5-20251001",
            max_tokens: 1,
            system: nil,
            messages: [
                .init(role: "user", content: .string("ping"))
            ],
            tools: nil,
            tool_choice: nil
        )
        do {
            let resp = try await createMessage(req)
            traceLog.emit("api", "validateKey ok model=\(resp.model) input=\(resp.usage.input_tokens) output=\(resp.usage.output_tokens)")
            return .valid(model: resp.model)
        } catch let e as AnthropicClientError {
            traceLog.emit("api", "validateKey failed: \(e.localizedDescription)")
            throw e
        }
    }

    /// Full Messages call. Redaction is applied to the request body before
    /// transmission. Caller is responsible for assembling the prompt.
    @discardableResult
    public func createMessage(_ request: AnthropicMessageRequest) async throws -> AnthropicMessageResponse {

        // 1. Encode the request to JSON.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bodyData: Data
        do {
            bodyData = try encoder.encode(request)
        } catch {
            throw AnthropicClientError.decodingFailed(reason: "request encode: \(error)")
        }

        // 2. Apply redaction at the JSON-string level. If any sk-/ghp_/etc.
        //    pattern made it into the prompt, it gets masked before it
        //    leaves the process.
        let rawJSON = String(decoding: bodyData, as: UTF8.self)
        let redacted = redactor.redact(rawJSON)
        let outgoing = Data(redacted.utf8)

        traceLog.emit(
            "api",
            "POST /v1/messages model=\(request.model) max_tokens=\(request.max_tokens) bytes=\(outgoing.count)"
        )

        // 3. Build the URL request.
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("/v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = outgoing

        // 4. Send.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            traceLog.emit("api", "URLSession failed: \(error)")
            throw AnthropicClientError.network(underlying: "\(error)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicClientError.decodingFailed(reason: "non-HTTP response")
        }

        // 5. Map status codes to typed errors.
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw AnthropicClientError.invalidKey(message: Self.extractErrorMessage(from: data))
        case 403:
            throw AnthropicClientError.permissionDenied(message: Self.extractErrorMessage(from: data))
        case 429:
            let retry = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw AnthropicClientError.rateLimit(
                message: Self.extractErrorMessage(from: data),
                retryAfter: retry
            )
        case 400..<500:
            throw AnthropicClientError.requestError(
                status: http.statusCode,
                message: Self.extractErrorMessage(from: data)
            )
        case 500..<600:
            throw AnthropicClientError.serverError(
                status: http.statusCode,
                message: Self.extractErrorMessage(from: data)
            )
        default:
            throw AnthropicClientError.requestError(
                status: http.statusCode,
                message: "unexpected status"
            )
        }

        // 6. Decode the response.
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(AnthropicMessageResponse.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(512), as: UTF8.self)
            throw AnthropicClientError.decodingFailed(reason: "body: \(preview) — error: \(error)")
        }
    }

    // MARK: - Helpers

    private static func extractErrorMessage(from data: Data) -> String {
        if let body = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
            return "\(body.error.type): \(body.error.message)"
        }
        return String(decoding: data.prefix(512), as: UTF8.self)
    }
}

public enum KeyValidation: Sendable, Equatable {
    case valid(model: String)
}
