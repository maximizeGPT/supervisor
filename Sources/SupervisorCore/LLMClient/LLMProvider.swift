// LLMProvider.swift — v0.2.0 multi-provider support.
//
// Supervisor's triage + escalation calls were Anthropic-only through
// v0.1.x. v0.2.0 adds DeepSeek, Moonshot (Kimi), MiniMax, and Qwen
// (via the Hugging Face router) so a user without Anthropic credit can
// still run the system.
//
// Two wire-protocol shapes cover all five providers:
//   - .anthropic     — Anthropic Messages API, `x-api-key` header
//   - .openAICompat  — OpenAI chat.completions, `Authorization: Bearer`
// DeepSeek / Moonshot / MiniMax / Qwen-HF all speak the OpenAI shape
// well enough (including tool / function calling) that one translator
// handles all four.
//
// Each provider is responsible for declaring its base URL, default
// model for triage, the placeholder text shown in the onboarding
// SecureField, and the Keychain service name for storing its key.

import Foundation

/// The set of providers Supervisor can talk to as of v0.2.0.
///
/// Adding a new provider: extend the enum, then fill out the same
/// switch arms below. The `LLMClient` doesn't need updating unless
/// the new provider speaks a third wire shape.
public enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case deepseek
    case moonshot
    case minimax
    case qwenHF       // Qwen via Hugging Face router
    case openrouter   // OpenRouter aggregator — the deliberation-panel / Fusion backend

    /// User-facing label for the onboarding picker and the
    /// status-bar "active provider" tooltip.
    public var displayName: String {
        switch self {
        case .anthropic:  return "Anthropic"
        case .deepseek:   return "DeepSeek"
        case .moonshot:   return "Moonshot (Kimi)"
        case .minimax:    return "MiniMax"
        case .qwenHF:     return "Qwen (via Hugging Face)"
        case .openrouter: return "OpenRouter"
        }
    }

    /// Base URL for the provider's HTTP API. The path component
    /// (e.g. `/v1/messages`, `/v1/chat/completions`) is appended by
    /// the client based on `apiShape`.
    public var baseURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://api.anthropic.com")!
        case .deepseek:  return URL(string: "https://api.deepseek.com")!
        case .moonshot:  return URL(string: "https://api.moonshot.ai")!
        case .minimax:   return URL(string: "https://api.minimax.chat")!
        case .qwenHF:    return URL(string: "https://router.huggingface.co")!
        // Full endpoint is https://openrouter.ai/api/v1/chat/completions; the
        // client appends `/v1/chat/completions` (openAICompat), so the base
        // stops at `/api`.
        case .openrouter: return URL(string: "https://openrouter.ai/api")!
        }
    }

    /// Wire-protocol shape. The translator in `LLMClient` switches
    /// on this to build the right request body and decode the right
    /// response.
    public var apiShape: APIShape {
        switch self {
        case .anthropic: return .anthropic
        default:         return .openAICompat
        }
    }

    /// HTTP header used to send the API key.
    public var authHeader: AuthHeader {
        switch self {
        case .anthropic: return .xApiKey
        default:         return .bearer
        }
    }

    /// Default model used for triage. The triage prompt is tuned for
    /// fast / cheap / tool-calling-capable models, so the defaults
    /// pick the equivalent of "the cheap fast one" per provider.
    public var defaultTriageModel: String {
        switch self {
        case .anthropic: return "claude-haiku-4-5-20251001"
        case .deepseek:  return "deepseek-chat"             // V3, OpenAI-compatible
        case .moonshot:  return "kimi-k2-0905-preview"      // Kimi K2, function-call capable
        case .minimax:   return "MiniMax-M1"                // MiniMax M1 reasoner
        case .qwenHF:    return "Qwen/Qwen2.5-72B-Instruct" // HF router shape
        // OpenRouter is primarily the panel/Fusion backend, not a triage
        // provider; if selected as the main provider, route triage through a
        // cheap tool-calling model. NOT `openrouter/fusion` — triage must stay
        // a single fast call, never a 4-5x panel.
        case .openrouter: return "openai/gpt-4o-mini"
        }
    }

    /// Vision-capable model for this provider, used to read a Claude.app
    /// screenshot for desktop conversation targeting. `nil` means this provider
    /// offers no vision model — in which case desktop screenshot-targeting
    /// surfaces a "configure a vision-capable provider" message and falls back
    /// to notify (never a silent degrade, never an auto-switch to a different
    /// provider). Per-provider, not one pinned model. Providers whose vision
    /// model name isn't verified yet are `nil` rather than a guess that would
    /// fail at call time; fill them in once verified against the live API.
    public var visionModel: String? {
        switch self {
        case .anthropic: return "claude-haiku-4-5-20251001"  // Claude 4.5 Haiku accepts image input
        case .deepseek:  return nil                          // deepseek-chat is text-only
        case .moonshot:  return nil                          // verify Kimi vision model before enabling
        case .minimax:   return nil                          // verify MiniMax vision model before enabling
        case .qwenHF:    return nil                          // verify Qwen-VL HF router id before enabling
        case .openrouter: return nil                         // verify an OpenRouter vision slug before enabling
        }
    }

    /// Placeholder text shown in the onboarding SecureField. Helps
    /// the user paste the right thing — every provider's key looks
    /// a little different.
    public var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-..."
        case .deepseek:  return "sk-..."
        case .moonshot:  return "sk-..."
        case .minimax:   return "eyJh... (JWT) or sk-..."
        case .qwenHF:    return "hf_..."
        case .openrouter: return "sk-or-..."
        }
    }

    /// Service name under which this provider's API key is stored
    /// in the macOS Keychain. Each provider gets its own service
    /// so users can switch back and forth without re-entering.
    public var keychainService: String {
        keychainService(base: Self.keychainServiceBase)
    }

    /// Injectable-base variant (unit-testable without touching the process
    /// environment): `<base>.<provider-suffix>`.
    public func keychainService(base: String) -> String {
        let suffix: String
        switch self {
        case .anthropic:  suffix = "anthropic"
        case .deepseek:   suffix = "deepseek"
        case .moonshot:   suffix = "moonshot"
        case .minimax:    suffix = "minimax"
        case .qwenHF:     suffix = "qwenhf"
        case .openrouter: suffix = "openrouter"
        }
        return base + "." + suffix
    }

    /// Base of every Supervisor Keychain service name. Production:
    /// `live.supervisor.api`. When `$SUPERVISOR_KEYCHAIN_PREFIX` is set
    /// (e.g. `test.supervisor.e2e`), it replaces the base, so an isolated
    /// E2E instance's key writes — including onboarding's first save and
    /// `migrateLegacyKeyIfPresent()`'s DELETE of the legacy item — land on
    /// items fully disjoint from a live Supervisor's real keys.
    public static var keychainServiceBase: String {
        keychainServiceBase(environment: ProcessInfo.processInfo.environment)
    }

    /// Injectable-environment variant so tests can assert the override logic
    /// without `setenv` (ProcessInfo caches its environment snapshot on first
    /// access, so an in-test `setenv` is not reliably visible).
    public static func keychainServiceBase(environment: [String: String]) -> String {
        if let prefix = environment["SUPERVISOR_KEYCHAIN_PREFIX"], !prefix.isEmpty {
            return prefix
        }
        return "live.supervisor.api"
    }

    /// Where the v0.1.x Anthropic-only Keychain item lived. Used by
    /// `migrateLegacyKeyIfPresent()` once on v0.2.0 first launch. Computed
    /// off `keychainServiceBase` (it IS the bare base) so an E2E instance's
    /// migration path deletes only a prefixed test item, never the live one.
    public static var legacyAnthropicKeychainService: String { keychainServiceBase }
}

/// Wire-protocol shape — what kind of JSON the provider speaks.
public enum APIShape: Sendable, Equatable {
    /// `POST /v1/messages` with Anthropic's custom messages/system/tools
    /// schema and the `tool_use` block in the response.
    case anthropic

    /// `POST /v1/chat/completions` with OpenAI's chat schema and
    /// `tool_calls` in `choices[0].message`. DeepSeek / Moonshot /
    /// MiniMax / Qwen (HF) all implement this faithfully enough that
    /// one path serves them all.
    case openAICompat
}

/// How the API key is sent on every request.
public enum AuthHeader: Sendable, Equatable {
    /// `x-api-key: <key>` — Anthropic's convention.
    case xApiKey

    /// `Authorization: Bearer <key>` — OpenAI convention, used by
    /// DeepSeek / Moonshot / MiniMax / Qwen-HF.
    case bearer
}
