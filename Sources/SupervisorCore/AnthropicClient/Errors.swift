// Errors.swift
//
// Typed surface for Anthropic API failures. Onboarding and Triage both
// branch on these cases — never on raw error messages — so the error
// surface needs to be exhaustive and stable.

import Foundation

public enum AnthropicClientError: Error, Sendable, Equatable {

    /// 401. Bad or revoked API key. Onboarding surfaces this as "key
    /// invalid; please re-enter."
    case invalidKey(message: String)

    /// 403. Permission error — key is valid but lacks access (rare for
    /// non-org keys, but possible if the org admin restricts models).
    case permissionDenied(message: String)

    /// 429. Rate limit. Includes the suggested retry-after if Anthropic
    /// returned one.
    case rateLimit(message: String, retryAfter: TimeInterval?)

    /// 4xx other than 401/403/429. Caller can choose to surface verbatim.
    case requestError(status: Int, message: String)

    /// 5xx. Retryable but ambiguous.
    case serverError(status: Int, message: String)

    /// Local URLSession failure: no network, DNS, TLS, timeout.
    case network(underlying: String)

    /// Response shape didn't match what we expected. Includes the partial
    /// body string so the trace log captures the unexpected payload.
    case decodingFailed(reason: String)

    /// The client was constructed without a Redactor. Should never happen
    /// in production (initializer signature requires one), but the
    /// downstream caller still gets a clean error.
    case redactorMissing
}

extension AnthropicClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidKey(let m): return "Anthropic key invalid: \(m)"
        case .permissionDenied(let m): return "Anthropic permission denied: \(m)"
        case .rateLimit(let m, let r):
            if let r { return "Anthropic rate limit: \(m) (retry after ~\(Int(r))s)" }
            return "Anthropic rate limit: \(m)"
        case .requestError(let s, let m): return "Anthropic request error \(s): \(m)"
        case .serverError(let s, let m): return "Anthropic server error \(s): \(m)"
        case .network(let u): return "Network error contacting Anthropic: \(u)"
        case .decodingFailed(let r): return "Anthropic response decode failed: \(r)"
        case .redactorMissing: return "AnthropicClient initialized without a Redactor"
        }
    }
}
