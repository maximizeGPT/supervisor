// LLMCallMeter.swift — what supervision actually cost, once an hour.
//
// The trace already carried a line per API call, which is the wrong grain for
// the question the owner asked ("why did this fill $10 overnight?"): 300 lines
// an hour is not a number, it is a haystack. This counts calls, input tokens,
// cache-hit tokens and estimated spend at the one choke point every model call
// goes through, and the app drains it once an hour into a single line.
//
// In-memory and per-process on purpose. The durable daily total is the
// CostStore's job; this is the shape of the hour, and a relaunch starting a
// fresh hour loses nothing that matters.

import Foundation

/// Rolling per-hour call counters. Written from `LLMClient.createMessage` on
/// any thread, drained from the app's hourly timer.
public final class LLMCallMeter: @unchecked Sendable {

    /// The instance every LLMClient records to unless a test injects its own,
    /// so panel calls and triage calls land in the same hourly line.
    public static let shared = LLMCallMeter()

    public struct Window: Sendable, Equatable {
        public var calls: Int = 0
        public var inputTokens: Int = 0
        public var outputTokens: Int = 0
        /// Input tokens the provider said it served from a cached prefix. Zero
        /// means either no hits or a provider that does not report them; the
        /// per-call `usage` trace line distinguishes those.
        public var cacheHitTokens: Int = 0
        public var estimatedUSD: Double = 0
    }

    private let lock = NSLock()
    private var window = Window()

    public init() {}

    public func record(usage: AnthropicUsage, costUSD: Double) {
        lock.lock()
        window.calls += 1
        window.inputTokens += usage.input_tokens
        window.outputTokens += usage.output_tokens
        window.cacheHitTokens += usage.cache_read_input_tokens ?? 0
        window.estimatedUSD += costUSD
        lock.unlock()
    }

    /// Read the current window and reset it. The caller owns the line.
    public func drain() -> Window {
        lock.lock()
        defer { window = Window(); lock.unlock() }
        return window
    }

    /// Read without resetting (diagnostics, tests).
    public func peek() -> Window {
        lock.lock(); defer { lock.unlock() }
        return window
    }

    /// The hourly trace line. Pure, so its shape is pinned by a test rather
    /// than by reading an hour of logs.
    public static func hourlyLine(_ w: Window, dayTotalUSD: Double?, capUSD: Double?) -> String {
        var parts = [
            "cost.hourly",
            "calls=\(w.calls)",
            "input_tokens=\(w.inputTokens)",
            "cache_hit=\(w.cacheHitTokens)",
            "est_usd=\(String(format: "%.4f", w.estimatedUSD))",
        ]
        if let dayTotalUSD { parts.append("day_total_usd=\(String(format: "%.2f", dayTotalUSD))") }
        parts.append("cap_usd=\(capUSD.map { String(format: "%.2f", $0) } ?? "off")")
        return parts.joined(separator: " ")
    }
}
