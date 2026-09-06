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

/// v0.3.0 (P0-4): the user's daily spend cap has been reached. Thrown by
/// `LLMClient.createMessage` BEFORE any network call is made, when the
/// injected cap-check hook reports today's spend at or above the
/// configured cap (`cost.daily_cap_usd` in config.yaml). Deliberately
/// local — no request left the machine, no tokens were billed.
///
/// A standalone type rather than a new `AnthropicClientError` case on
/// purpose: `OnboardingViewModel.mapClientError` switches exhaustively
/// over the enum (no default), so a new case would force every
/// error-mapping site to grow an arm — and the cap is a local policy
/// refusal, not a wire-level provider failure, so callers that map
/// provider errors should not have to handle it. Catch it explicitly:
///   catch let cap as DailyCapExceededError { ... }
public struct DailyCapExceededError: Error, Sendable, Equatable {
    /// The configured daily cap, in USD.
    public let capUSD: Double
    /// Today's recorded spend at the time of the refused call, in USD. When
    /// `storeReadFailed` is true this is NOT a measurement: `DailyCapGate`
    /// synthesizes it equal to `capUSD` so an unreadable ledger fails closed.
    public let spentUSD: Double
    /// True when the refusal came from a cost store that could not be read,
    /// not from real spend reaching the cap.
    ///
    /// This flag exists because dropping it produced a paging bug worth
    /// spelling out. Without it, a broken ledger reached the owner as
    /// "Today's model spend reached $5.00 of the $5.00 cap. Raise
    /// cost.daily_cap_usd to resume" — a figure that was invented, and a
    /// remedy that can never work, because the synthesized spend rises with
    /// whatever new cap the owner sets. The honest event for this state is
    /// `.triageDegraded(.costStoreUnreadable)`, and `SystemEscalationEvent`
    /// can only pick it if the error still carries the distinction.
    public let storeReadFailed: Bool

    /// Defaulted so the many call sites that construct a genuine cap hit read
    /// exactly as they did before.
    public init(capUSD: Double, spentUSD: Double, storeReadFailed: Bool = false) {
        self.capUSD = capUSD
        self.spentUSD = spentUSD
        self.storeReadFailed = storeReadFailed
    }
}

extension DailyCapExceededError: LocalizedError {
    public var errorDescription: String? {
        if storeReadFailed {
            return "Cost store unreadable, so spend cannot be checked against the daily cap; call skipped"
        }
        return String(
            format: "Daily cost cap reached: spent $%.2f of $%.2f cap; call skipped",
            spentUSD, capUSD
        )
    }
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
