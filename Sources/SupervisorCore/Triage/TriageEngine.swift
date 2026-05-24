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
    public let cwd: String?      // v0.1.4: the router needs cwd to ask the locator for a PID
    public let candidate: TriageCandidate
    public let triggeringEvent: BashToolCallInfo
    public let usage: AnthropicUsage
    public let model: String
    public let prePost: PrePost  // for the pre-NEXT-action / just-ran copy split
    /// v0.1.6: the recent event window from TriageEngine's per-session buffer,
    /// passed through so RecoveryDocWriter can render the "last ~10 tool calls"
    /// section without re-parsing the JSONL or pulling from the tailer. The
    /// triggering event itself is the last element; everything before it is
    /// context. Empty if the window wasn't available at decision time.
    public let recentEvents: [SupervisorEvent]
    /// v0.1.6: the most recent user prompt in the window, surfaced separately
    /// so the recovery doc can quote it verbatim without re-walking events.
    public let lastUserPrompt: String?

    public enum PrePost: Sendable {
        case preExecution     // tool_result not yet in window
        case alreadyExecuted  // tool_result present
    }

    public init(
        sessionId: String,
        cwd: String? = nil,
        candidate: TriageCandidate,
        triggeringEvent: BashToolCallInfo,
        usage: AnthropicUsage,
        model: String,
        prePost: PrePost,
        recentEvents: [SupervisorEvent] = [],
        lastUserPrompt: String? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.candidate = candidate
        self.triggeringEvent = triggeringEvent
        self.usage = usage
        self.model = model
        self.prePost = prePost
        self.recentEvents = recentEvents
        self.lastUserPrompt = lastUserPrompt
    }
}

@MainActor
public final class TriageEngine {

    private let client: LLMClient
    private let bus: EventBus
    private let trace: TraceLog
    private let model: String
    private let costStore: CostStore?
    private let redactor: any Redactor

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

    /// v0.3.0: optional secondary-call dependency. When non-nil,
    /// user_question_pending candidates with question_type=engineering
    /// trigger an `answerEngineering` call against PRINCIPLES.md, and
    /// taste candidates trigger a `translateTaste` rewrite. Nil
    /// disables the secondary calls (tests / no-PRINCIPLES installs);
    /// the engine still fires the primary flag but the inject text
    /// stays empty and the router degrades to notify.
    private let questionAnswerer: QuestionAnswerer?

    public init(
        client: LLMClient,
        bus: EventBus,
        model: String = Config.defaults.triageModel,
        windowSize: Int = 30,
        costStore: CostStore? = nil,
        redactor: any Redactor = DefaultRedactor(),
        questionAnswerer: QuestionAnswerer? = nil,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.bus = bus
        self.model = model
        self.windowSize = windowSize
        self.costStore = costStore
        self.redactor = redactor
        self.questionAnswerer = questionAnswerer
        self.trace = trace
    }

    public func start() {
        busSubscription = bus.subscribe { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.consume(event: event) }
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
        case .assistantText(let info):
            // v0.3.0: cheap local prefilter to keep API spend bounded.
            // Only assistant texts that look like they might contain a
            // user-directed question get sent to the secondary triage call.
            if TriagePrompt.looksLikeQuestionToUser(info.text) {
                Task { await self.evaluateAssistantText(info: info) }
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
                cwd: cwd,
                candidate: candidate,
                triggeringEvent: call,
                usage: response.usage,
                model: response.model,
                prePost: prePost,
                recentEvents: window,
                lastUserPrompt: userPrompt
            )
            trace.emit("triage", "FLAG session=\(call.sessionId) severity=\(candidate.severity.rawValue) action=\(candidate.action.rawValue) plain=\"\(candidate.reasoningPlain)\" tech=\"\(candidate.reasoningTechnical.prefix(200))\"")
            if let note = candidate.asymmetryNote, !note.isEmpty {
                trace.emit("triage", "FLAG.asymmetry session=\(call.sessionId) \(note)")
            }
            onActivityChange?(.flagged(severity: candidate.severity, action: candidate.action))
            onDecision?(decision)
        }
    }

    // MARK: - Assistant-text triage (v0.3.0)

    /// Evaluate an assistant message for the `user_question_pending`
    /// category. Triggered by the local prefilter in `consume()`. Runs
    /// the same record_triage tool against a focused prompt; for each
    /// candidate that fires, enriches with the secondary
    /// QuestionAnswerer call (engineering → inject text; taste →
    /// rewritten reasoning_plain; safety → pass through unchanged).
    private func evaluateAssistantText(info: AssistantTextInfo) async {
        onActivityChange?(.triaging)

        let window = perSessionWindow[info.sessionId] ?? []
        let cwd = lastSessionCWD(in: window)
        let userPrompt = lastUserPrompt(in: window)

        let request = TriagePrompt.buildAssistantQuestionRequest(
            model: model,
            sessionId: info.sessionId,
            cwd: cwd,
            userPrompt: userPrompt,
            assistantText: info.text,
            recentEvents: window
        )

        trace.emit("triage", "evaluating session=\(info.sessionId) assistant_text_len=\(info.text.count)")

        let response: AnthropicMessageResponse
        do {
            response = try await client.createMessage(request)
        } catch {
            trace.emit("triage", "Assistant-text triage call failed: \(error)")
            onActivityChange?(.idle)
            return
        }

        if let costStore {
            let cost = TokenAccounting.costUSD(model: model, usage: response.usage)
            try? costStore.recordHaiku(
                inputTokens: response.usage.input_tokens,
                outputTokens: response.usage.output_tokens,
                costUSD: cost
            )
        }

        guard let candidates = extractCandidates(from: response) else {
            trace.emit("triage", "Assistant-text: no record_triage call from Haiku")
            onActivityChange?(.idle)
            return
        }
        if candidates.isEmpty {
            trace.emit("triage", "Assistant-text all-clear (prefilter hit but Haiku didn't fire)")
            onActivityChange?(.idle)
            return
        }

        // For each fired candidate, run the secondary call to populate
        // suggestedInjectText (engineering) or rewrite reasoning_plain
        // (taste). Safety passes through untouched.
        for candidate in candidates {
            let enriched = await enrichWithSecondaryAnswer(
                candidate: candidate,
                question: info.text,
                sessionId: info.sessionId
            )
            // Triage flags on assistant text use the BashToolCallInfo
            // synthetic-bridge so the existing TriageDecision struct
            // works unchanged. The triggering "command" is the
            // assistant's question text, truncated.
            let pseudoTrigger = BashToolCallInfo(
                sessionId: info.sessionId,
                command: String(info.text.prefix(200)),
                description: nil,
                toolUseId: info.turnUUID,  // closest-available unique id
                turnUUID: info.turnUUID,
                ts: info.ts
            )
            let decision = TriageDecision(
                sessionId: info.sessionId,
                cwd: cwd,
                candidate: enriched,
                triggeringEvent: pseudoTrigger,
                usage: response.usage,
                model: response.model,
                prePost: .preExecution,  // assistant is waiting; nothing executed yet
                recentEvents: window,
                lastUserPrompt: userPrompt
            )
            trace.emit("triage", "FLAG session=\(info.sessionId) category=\(enriched.category) severity=\(enriched.severity.rawValue) action=\(enriched.action.rawValue) question_type=\(enriched.questionType ?? "?")")
            onActivityChange?(.flagged(severity: enriched.severity, action: enriched.action))
            onDecision?(decision)
        }
    }

    /// Run the secondary QuestionAnswerer call when appropriate. The
    /// returned candidate may have suggestedInjectText populated
    /// (engineering high/medium confidence) OR reasoning_plain rewritten
    /// (taste, or engineering low confidence degraded to taste). Safety
    /// candidates and non-user_question_pending categories pass through.
    private func enrichWithSecondaryAnswer(
        candidate: TriageCandidate,
        question: String,
        sessionId: String
    ) async -> TriageCandidate {
        guard candidate.category == "user_question_pending",
              let answerer = questionAnswerer else {
            return candidate
        }
        let qt = candidate.questionType ?? "safety"

        switch qt {
        case "engineering":
            do {
                let answer = try await answerer.answerEngineering(question: question)
                if answer.confidence == .low || answer.answer.isEmpty {
                    // Degrade: PRINCIPLES didn't have a clear answer.
                    // Rewrite as taste and surface to user.
                    trace.emit("triage", "engineering low-confidence; degrading to taste session=\(sessionId)")
                    let rewrite = (try? await answerer.translateTaste(question: question))?.plainQuestion
                        ?? candidate.reasoningPlain
                    return reconfigure(
                        candidate,
                        action: .notify,
                        reasoningPlain: rewrite
                    )
                }
                return reconfigure(
                    candidate,
                    action: .inject,
                    suggestedInjectText: answer.answer
                )
            } catch {
                trace.emit("triage", "engineering answer call failed: \(error); degrading to notify")
                return reconfigure(candidate, action: .notify)
            }

        case "taste":
            do {
                let rewrite = try await answerer.translateTaste(question: question)
                return reconfigure(
                    candidate,
                    action: .notify,
                    reasoningPlain: rewrite.plainQuestion
                )
            } catch {
                trace.emit("triage", "taste translate call failed: \(error); using original")
                return reconfigure(candidate, action: .notify)
            }

        case "safety":
            // No secondary call. Safety questions reach the user
            // exactly as Haiku surfaced them.
            return reconfigure(candidate, action: .notify)

        default:
            return candidate
        }
    }

    /// Rebuild a candidate with new field values. TriageCandidate is
    /// immutable; this is the canonical "with" pattern.
    private func reconfigure(
        _ c: TriageCandidate,
        action: FlagAction? = nil,
        reasoningPlain: String? = nil,
        suggestedInjectText: String? = nil
    ) -> TriageCandidate {
        TriageCandidate(
            category: c.category,
            severity: c.severity,
            matchedCommand: c.matchedCommand,
            action: action ?? c.action,
            reasoningPlain: reasoningPlain ?? c.reasoningPlain,
            reasoningTechnical: c.reasoningTechnical,
            asymmetryNote: c.asymmetryNote,
            suggestedInjectText: suggestedInjectText ?? c.suggestedInjectText,
            questionType: c.questionType
        )
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
                guard case let .object(c) = raw else { continue }
                if let candidate = parseCandidate(c) {
                    out.append(candidate)
                }
            }
            return out
        }
        return nil
    }

    /// Parse one candidate dict. The bare minimum to fire a flag at all is
    /// `category` + `severity` — everything else has a defined fallback so
    /// a slightly-broken Haiku response still produces a usable flag rather
    /// than vanishing silently. Logs `triage.schema.malformed` whenever
    /// any field falls back. Reasoning fields go through the Redactor
    /// before they land on the in-memory candidate — defense in depth.
    private func parseCandidate(_ c: [String: AnthropicJSON]) -> TriageCandidate? {
        guard case let .string(cat)? = c["category"],
              case let .string(sev)? = c["severity"],
              let severity = FlagSeverity(rawValue: sev) else {
            trace.emit("triage", "schema.malformed candidate missing category/severity raw=\(serializeForTrace(c))")
            return nil
        }

        var malformed = false
        var fallbackReason: [String] = []

        let matchedCommand: String
        if case let .string(cmd)? = c["matched_command"], !cmd.isEmpty {
            matchedCommand = cmd
        } else {
            matchedCommand = "(missing)"
            malformed = true
            fallbackReason.append("matched_command")
        }

        let action: FlagAction
        if case let .string(actStr)? = c["recommended_action"],
           let a = FlagAction(rawValue: actStr) {
            action = a
        } else {
            action = .notify
            malformed = true
            fallbackReason.append("recommended_action")
        }

        let reasoningPlain: String
        let reasoningTechnical: String
        let plainRaw: String?
        let techRaw: String?
        if case let .string(p)? = c["reasoning_plain"], !p.isEmpty {
            plainRaw = p
        } else {
            plainRaw = nil
            malformed = true
            fallbackReason.append("reasoning_plain")
        }
        if case let .string(t)? = c["reasoning_technical"], !t.isEmpty {
            techRaw = t
        } else {
            techRaw = nil
            malformed = true
            fallbackReason.append("reasoning_technical")
        }

        // Fallback rule (Mohammed-approved): when reasoning_plain is
        // missing, do NOT substitute reasoning_technical into the banner —
        // the whole point of the split is that technical text is unfit
        // for a banner. Use a fixed string instead.
        if let p = plainRaw {
            reasoningPlain = redactor.redact(p)
        } else {
            reasoningPlain = TriagePrompt.malformedVerdictBannerText
        }
        if let t = techRaw {
            reasoningTechnical = redactor.redact(t)
        } else {
            reasoningTechnical = ""
        }

        var asymmetryNote: String? = nil
        if case let .string(note)? = c["asymmetry_note"], !note.isEmpty {
            asymmetryNote = redactor.redact(note)
        }

        // v0.3.0: question_type is required when category is
        // user_question_pending and ignored otherwise. If the category
        // requires it and Haiku omits it, default to "safety" — that's
        // the rubric's safer-fallback rule.
        var questionType: String? = nil
        if cat == "user_question_pending" {
            if case let .string(qt)? = c["question_type"],
               ["engineering", "safety", "taste"].contains(qt) {
                questionType = qt
            } else {
                questionType = "safety"
                malformed = true
                fallbackReason.append("question_type")
            }
        }

        if malformed {
            // Log the raw verdict (un-redacted) for debugging per Mohammed:
            // trace log is local-only, README is honest about that.
            trace.emit("triage", "schema.malformed fields=\(fallbackReason.joined(separator: ",")) action=\(action.rawValue) raw=\(serializeForTrace(c))")
        }

        return TriageCandidate(
            category: cat,
            severity: severity,
            matchedCommand: matchedCommand,
            action: action,
            reasoningPlain: reasoningPlain,
            reasoningTechnical: reasoningTechnical,
            asymmetryNote: asymmetryNote,
            suggestedInjectText: nil,  // populated by secondary call in TriageEngine.evaluate
            questionType: questionType
        )
    }

    /// Compact-serialize the raw candidate dict for the trace log. Truncated
    /// at 400 chars to keep the rolling log readable; full reconstruction
    /// after the fact is rarely needed since reasoning_technical is also
    /// stored on the StoredFlag.
    private func serializeForTrace(_ dict: [String: AnthropicJSON]) -> String {
        var pairs: [String] = []
        for (k, v) in dict {
            switch v {
            case .string(let s):  pairs.append("\(k)=\(s.prefix(80))")
            case .integer(let n): pairs.append("\(k)=\(n)")
            case .double(let n):  pairs.append("\(k)=\(n)")
            case .bool(let b):    pairs.append("\(k)=\(b)")
            case .null:           pairs.append("\(k)=null")
            case .array:          pairs.append("\(k)=[…]")
            case .object:         pairs.append("\(k)={…}")
            }
        }
        let joined = pairs.joined(separator: " ")
        return String(joined.prefix(400))
    }
}
