// TokenAccounting.swift
//
// Per-1M-token pricing for the models Supervisor calls. Rates as of
// 2026-05. Loaded from a `pricing.yaml` override path in v0.1.4 (when
// Yams lands); v0.1.0 ships these hardcoded.
//
// The model id strings here are the published API names. If Anthropic
// retires one, the cost computation falls back to `unknownModelCost`
// (which equals zero, so spend appears as $0.00 — a visible signal
// that pricing data is stale rather than silently miscalculating).

import Foundation

public struct ModelPricing: Sendable {
    public let inputPer1M: Double
    public let outputPer1M: Double
    public let cacheReadPer1M: Double?
    public let cacheWritePer1M: Double?
}

public enum TokenAccounting {

    /// Process-wide rate table. Mutable for tests; immutable in production.
    public static var prices: [String: ModelPricing] = [
        // Claude Haiku 4.5 — 2026-05 rates.
        "claude-haiku-4-5-20251001": .init(
            inputPer1M: 1.00,
            outputPer1M: 5.00,
            cacheReadPer1M: 0.10,
            cacheWritePer1M: 1.25
        ),
        // Sonnet 4.6 — published rates.
        "claude-sonnet-4-6": .init(
            inputPer1M: 3.00,
            outputPer1M: 15.00,
            cacheReadPer1M: 0.30,
            cacheWritePer1M: 3.75
        ),
        // Sonnet 4.5 alias seen in some tool calls.
        "claude-sonnet-4-5": .init(
            inputPer1M: 3.00,
            outputPer1M: 15.00,
            cacheReadPer1M: 0.30,
            cacheWritePer1M: 3.75
        ),

        // v0.3.0: default triage models of the non-Anthropic providers
        // (see LLMProvider.defaultTriageModel). Without these, every
        // DeepSeek/Moonshot/MiniMax/Qwen call recorded $0.00 forever.

        // DeepSeek V3 — approximate list price, 2026-07.
        "deepseek-chat": .init(
            inputPer1M: 0.28,
            outputPer1M: 0.42,
            cacheReadPer1M: 0.028,
            cacheWritePer1M: nil
        ),
        // Moonshot Kimi K2 — approximate list price, 2026-07.
        "kimi-k2-0905-preview": .init(
            inputPer1M: 0.60,
            outputPer1M: 2.50,
            cacheReadPer1M: 0.15,
            cacheWritePer1M: nil
        ),
        // MiniMax M1 — approximate list price, 2026-07.
        "MiniMax-M1": .init(
            inputPer1M: 0.40,
            outputPer1M: 2.20,
            cacheReadPer1M: nil,
            cacheWritePer1M: nil
        ),
        // Qwen2.5-72B via the Hugging Face router — provider-dependent;
        // conservative approximate list price, 2026-07.
        "Qwen/Qwen2.5-72B-Instruct": .init(
            inputPer1M: 1.20,
            outputPer1M: 1.20,
            cacheReadPer1M: nil,
            cacheWritePer1M: nil
        ),
    ]

    /// True when a rate exists for `model`. Lets callers distinguish
    /// "genuinely free / unknown model" from "priced at zero" — the
    /// costUSD-returns-0 fallback is otherwise ambiguous.
    public static func isKnownModel(_ model: String) -> Bool {
        prices[model] != nil
    }

    /// Compute cost in USD for a usage block. Returns 0 for unknown models
    /// (loud silence — UI shows $0.00 cost, which signals stale pricing).
    public static func costUSD(model: String, usage: AnthropicUsage) -> Double {
        guard let p = prices[model] else { return 0 }
        var cost = 0.0
        cost += Double(usage.input_tokens) * (p.inputPer1M / 1_000_000)
        cost += Double(usage.output_tokens) * (p.outputPer1M / 1_000_000)
        if let cr = p.cacheReadPer1M, let n = usage.cache_read_input_tokens {
            cost += Double(n) * (cr / 1_000_000)
        }
        if let cw = p.cacheWritePer1M, let n = usage.cache_creation_input_tokens {
            cost += Double(n) * (cw / 1_000_000)
        }
        return cost
    }
}
