// TriageEngine.swift
//
// Subscribes to EventBus. Maintains a per-session sliding window of recent
// events. On each Bash tool_call, builds a triage prompt and calls Haiku
// via forced `record_triage` tool. If Haiku fires a candidate, the engine
// emits a TriageDecision over its `decisions` publisher — Lifecycle wires
// that to FlagStore + Notifier + HoverViewModel.
//
// v0.1.0 keeps the engine narrow: single category, single tool family
// (Bash). Multi-category, windowed batching, and stop-reason-triggered
// triage all land in v0.1.1+.

import Combine
import Foundation

public struct TriageDecision: Sendable {
    public let sessionId: String
    public let candidate: TriageCandidate
    public let triggeringEvent: BashToolCallInfo
    public let usage: AnthropicUsage
    public let model: String
    public let prePost: PrePost  // for the pre-NEXT-action / just-ran copy split

    public enum PrePost: Sendable {
        case preExecution     // tool_result not yet in window
        case alreadyExecuted  // tool_result present
    }
}

@MainActor
public final class TriageEngine {

    private let client: AnthropicClient
    private let bus: EventBus
    private let trace: TraceLog
    private let model: String
    private let costStore: CostStore?

    /// Per-session sliding window of events.
    private var perSessionWindow: [String: [SupervisorEvent]] = [:]
    private let windowSize: Int

    /// Per-session map of toolUseId → bashToolCall, so a later tool_result
    /// can be matched to its parent call without re-scanning the window.
    private var bashCalls: [String: BashToolCallInfo] = [:]

    /// Hook for HoverViewModel — called whenever a triage call starts /
    /// finishes / produces a flag, so the dot color reflects state.
    public var onActivityChange: ((HoverViewModel.Activity) -> Void)?

    /// Hook for FlagRouter — called when Haiku fires.
    public var onDecision: ((TriageDecision) -> Void)?

    private var busSubscription: AnyCancellable?

    public init(
        client: AnthropicClient,
        bus: EventBus,
        model: String = Config.defaults.triageModel,
        windowSize: Int = 30,
        costStore: CostStore? = nil,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.bus = bus
        self.model = model
        self.windowSize = windowSize
        self.costStore = costStore
        self.trace = trace
    }

    public func start() {
        busSubscription = bus.subscribe { [weak self] event in
            Task { @MainActor in self?.consume(event: event) }
        }
        trace.emit("triage", "engine started model=\(model) windowSize=\(windowSize)")
    }

    public func stop() {
        busSubscription?.cancel()
        busSubscription = nil
        trace.emit("triage", "engine stopped")
    }

    // MARK: - Event consumption

    private func consume(event: SupervisorEvent) {
        let sessionId = event.sessionId
        var window = perSessionWindow[sessionId] ?? []
        window.append(event)
        if window.count > windowSize {
            window.removeFirst(window.count - windowSize)
        }
        perSessionWindow[sessionId] = window

        switch event {
        case .bashToolCall(let info):
            bashCalls[info.toolUseId] = info
            Task { await self.evaluate(call: info, prePost: .preExecution) }
        case .bashToolResult(let info):
            if let original = bashCalls[info.toolUseId] {
                // A bash command we already evaluated as preExecution may
                // now have finished. v0.1.0 re-evaluates on result arrival
                // only if the result was an error AND the original call
                // didn't already match — keeps Haiku calls bounded.
                if info.isError {
                    Task { await self.evaluate(call: original, prePost: .alreadyExecuted) }
                }
            }
        default:
            break
        }
    }

    // MARK: - Triage call

    private func evaluate(call: BashToolCallInfo, prePost: TriageDecision.PrePost) async {
        onActivityChange?(.triaging)

        let window = perSessionWindow[call.sessionId] ?? []
        let cwd = lastSessionCWD(in: window)
        let userPrompt = lastUserPrompt(in: window)
        let recentResult = lastBashResult(matching: call.toolUseId, in: window)

        let request = TriagePrompt.buildRequest(
            model: model,
            input: .init(
                cwd: cwd,
                userPrompt: userPrompt,
                bashCall: call,
                recentResult: recentResult,
                recentEvents: window
            )
        )

        trace.emit("triage", "evaluating session=\(call.sessionId) cmd=\(call.command.prefix(60))")

        let response: AnthropicMessageResponse
        do {
            response = try await client.createMessage(request)
        } catch {
            trace.emit("triage", "Haiku call failed: \(error)")
            onActivityChange?(.idle)
            return
        }

        // Cost accounting (best-effort).
        if let costStore {
            let cost = TokenAccounting.costUSD(model: model, usage: response.usage)
            try? costStore.recordHaiku(
                inputTokens: response.usage.input_tokens,
                outputTokens: response.usage.output_tokens,
                costUSD: cost
            )
        }

        guard let candidates = extractCandidates(from: response) else {
            trace.emit("triage", "Haiku didn't return record_triage call (stop_reason=\(response.stop_reason ?? "?"))")
            onActivityChange?(.idle)
            return
        }

        if candidates.isEmpty {
            trace.emit("triage", "all-clear for session=\(call.sessionId) cmd=\(call.command.prefix(40))")
            onActivityChange?(.idle)
            return
        }

        for candidate in candidates {
            let decision = TriageDecision(
                sessionId: call.sessionId,
                candidate: candidate,
                triggeringEvent: call,
                usage: response.usage,
                model: response.model,
                prePost: prePost
            )
            trace.emit("triage", "FLAG session=\(call.sessionId) severity=\(candidate.severity.rawValue) reasoning=\(candidate.reasoning.prefix(120))")
            onActivityChange?(.flagged(severity: candidate.severity))
            onDecision?(decision)
        }
    }

    // MARK: - Window helpers

    private func lastSessionCWD(in window: [SupervisorEvent]) -> String? {
        for event in window.reversed() {
            if case .sessionStart(let i) = event { return i.cwd }
        }
        return nil
    }

    private func lastUserPrompt(in window: [SupervisorEvent]) -> String? {
        for event in window.reversed() {
            if case .userPrompt(let i) = event { return i.text }
        }
        return nil
    }

    private func lastBashResult(matching toolUseId: String, in window: [SupervisorEvent]) -> BashToolResultInfo? {
        for event in window.reversed() {
            if case .bashToolResult(let i) = event, i.toolUseId == toolUseId { return i }
        }
        return nil
    }

    // MARK: - Response decoding

    private func extractCandidates(from response: AnthropicMessageResponse) -> [TriageCandidate]? {
        for block in response.content {
            guard block.type == "tool_use",
                  block.name == TriagePrompt.recordTriageToolName,
                  case let .object(input)? = block.input,
                  case let .array(candidatesArr)? = input["candidates"]
            else { continue }
            var out: [TriageCandidate] = []
            for raw in candidatesArr {
                guard case let .object(c) = raw,
                      case let .string(cat)? = c["category"],
                      case let .string(sev)? = c["severity"],
                      case let .string(reason)? = c["reasoning"],
                      case let .string(cmd)? = c["matched_command"],
                      let severity = FlagSeverity(rawValue: sev)
                else { continue }
                out.append(TriageCandidate(
                    category: cat,
                    severity: severity,
                    reasoning: reason,
                    matchedCommand: cmd
                ))
            }
            return out
        }
        return nil
    }
}
