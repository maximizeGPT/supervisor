// DeliberationPanel.swift — multi-model deliberation ("panel + judge").
//
// A panel runs the SAME decision past N member models concurrently, then a
// judge model fuses their answers into consensus / contradictions / blind
// spots / unique insights. This is the OpenRouter Fusion shape, done DIY over
// the existing multi-provider `LLMClient` so it runs on whatever provider keys
// are already configured and keeps the judge schema under our control.
//
// COST: a panel bills every member plus the judge (~4-5x a single completion),
// so it is NEVER on the triage tick. It is invoked on demand (user "second
// opinion") or selectively on borderline calls. See
// docs/multi-model-panel/DESIGN.md.
//
// Testability follows the LLMClient idiom (costRecorder / capCheck): the panel
// calls through an injected `@Sendable` send closure. `live(clients:)` builds
// the real closure that dispatches to the right per-provider LLMClient; tests
// inject a fake that returns canned answers with no network.

import Foundation

// MARK: - Configuration

/// One model in the panel (or the judge). `provider` selects which configured
/// `LLMClient` handles the call; `model` is the slug sent on the wire.
public struct PanelMember: Sendable, Equatable {
    public let provider: LLMProvider
    public let model: String
    /// Short display label for the per-member breakdown (e.g. "Haiku",
    /// "DeepSeek"). Defaults to the model slug.
    public let label: String

    public init(provider: LLMProvider, model: String, label: String? = nil) {
        self.provider = provider
        self.model = model
        self.label = label ?? model
    }
}

public struct PanelConfig: Sendable {
    /// The models that deliberate in parallel. At least one must succeed or the
    /// panel throws `PanelError.allMembersFailed`.
    public let members: [PanelMember]
    /// The model that fuses the member answers. If the judge call fails, the
    /// panel returns a `degraded` result carrying the raw member answers rather
    /// than throwing — a partial answer beats none.
    public let judge: PanelMember
    /// Upper bound on tokens each member / judge may generate.
    public let maxTokens: Int

    public init(members: [PanelMember], judge: PanelMember, maxTokens: Int = 1024) {
        self.members = members
        self.judge = judge
        self.maxTokens = maxTokens
    }
}

// MARK: - Result

/// One member's contribution, including failures (captured, not fatal, so the
/// UI can show "3 of 4 answered").
public struct MemberAnswer: Sendable {
    public let member: PanelMember
    public let text: String
    public let usage: AnthropicUsage?
    /// Non-nil if this member's call failed; `text` is empty in that case.
    public let error: String?

    public var succeeded: Bool { error == nil }
}

/// Rolled-up token accounting across every member + judge call. Money safety
/// is enforced upstream by each `LLMClient`'s daily-cap gate; this is for the
/// cost line the UI shows.
public struct PanelUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var memberCalls: Int
    public var judgeCalls: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, memberCalls: Int = 0, judgeCalls: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.memberCalls = memberCalls
        self.judgeCalls = judgeCalls
    }
}

/// The fused verdict. `degraded == true` means the judge call failed and the
/// consensus is a fallback (the first member's answer), with the structured
/// lists empty — the caller should say so rather than present it as a real
/// synthesis.
public struct PanelResult: Sendable {
    public let consensus: String
    public let contradictions: [String]
    public let blindSpots: [String]
    public let uniqueInsights: [String]
    public let perMember: [MemberAnswer]
    public let usage: PanelUsage
    public let degraded: Bool
}

public enum PanelError: Error, Equatable {
    /// Every member call failed; there is nothing for the judge to fuse.
    case allMembersFailed([String])
    /// OpenRouter Fusion returned an empty completion.
    case fusionReturnedNoContent
}

// MARK: - The panel

public struct DeliberationPanel: Sendable {
    /// The send seam. `provider` selects the client; `request.model` is the
    /// wire model. Mirrors `LLMClient.createMessage` so `live(clients:)` is a
    /// thin adapter and tests can substitute a fake.
    public typealias Send = @Sendable (_ provider: LLMProvider, _ request: AnthropicMessageRequest) async throws -> AnthropicMessageResponse

    public static let judgeToolName = "record_panel_verdict"

    private let config: PanelConfig
    private let send: Send

    public init(config: PanelConfig, send: @escaping Send) {
        self.config = config
        self.send = send
    }

    /// Build a panel whose send closure dispatches to the matching per-provider
    /// `LLMClient`. A member naming a provider absent from `clients` fails that
    /// one member (captured), never the whole panel.
    public static func live(config: PanelConfig, clients: [LLMProvider: LLMClient]) -> DeliberationPanel {
        DeliberationPanel(config: config) { provider, request in
            guard let client = clients[provider] else {
                throw NSError(domain: "DeliberationPanel", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "no configured client for provider \(provider.rawValue)"
                ])
            }
            return try await client.createMessage(request)
        }
    }

    /// Run the decision past the panel and fuse the answers.
    ///
    /// - Parameters:
    ///   - decision: the question / decision to deliberate on.
    ///   - systemPreamble: optional shared framing prepended to every member's
    ///     system prompt (e.g. project context).
    public func deliberate(decision: String, systemPreamble: String? = nil) async throws -> PanelResult {
        // 1. Fan out to members concurrently. Index-tagged so we can restore the
        //    configured order after the task group returns out of order.
        let members = config.members
        let maxTokens = config.maxTokens
        let send = self.send

        let answers: [MemberAnswer] = await withTaskGroup(of: (Int, MemberAnswer).self) { group in
            for (i, member) in members.enumerated() {
                group.addTask {
                    let request = Self.memberRequest(member: member, decision: decision,
                                                     systemPreamble: systemPreamble, maxTokens: maxTokens)
                    do {
                        let resp = try await send(member.provider, request)
                        return (i, MemberAnswer(member: member,
                                                text: Self.firstText(in: resp),
                                                usage: resp.usage, error: nil))
                    } catch {
                        return (i, MemberAnswer(member: member, text: "", usage: nil,
                                                error: "\(error)"))
                    }
                }
            }
            var collected = [(Int, MemberAnswer)]()
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        let succeeded = answers.filter { $0.succeeded }
        guard !succeeded.isEmpty else {
            throw PanelError.allMembersFailed(answers.compactMap { $0.error })
        }

        var usage = PanelUsage()
        for a in answers where a.succeeded {
            usage.inputTokens += a.usage?.input_tokens ?? 0
            usage.outputTokens += a.usage?.output_tokens ?? 0
            usage.memberCalls += 1
        }

        // 2. Judge fuses the successful answers. A judge failure degrades to a
        //    fallback rather than losing the whole panel.
        let judgeRequest = Self.judgeRequest(judge: config.judge, decision: decision,
                                             answers: succeeded, maxTokens: maxTokens)
        do {
            let resp = try await send(config.judge.provider, judgeRequest)
            usage.inputTokens += resp.usage.input_tokens
            usage.outputTokens += resp.usage.output_tokens
            usage.judgeCalls += 1
            if let verdict = Self.parseVerdict(from: resp) {
                return PanelResult(consensus: verdict.consensus,
                                   contradictions: verdict.contradictions,
                                   blindSpots: verdict.blindSpots,
                                   uniqueInsights: verdict.uniqueInsights,
                                   perMember: answers, usage: usage, degraded: false)
            }
            // Judge answered but not in the expected tool shape → degrade.
            return Self.degraded(from: succeeded, all: answers, usage: usage)
        } catch {
            return Self.degraded(from: succeeded, all: answers, usage: usage)
        }
    }

    // MARK: - Request construction

    static func memberRequest(member: PanelMember, decision: String,
                              systemPreamble: String?, maxTokens: Int) -> AnthropicMessageRequest {
        let system = [systemPreamble, Self.memberSystem].compactMap { $0 }.joined(separator: "\n\n")
        return AnthropicMessageRequest(
            model: member.model,
            max_tokens: maxTokens,
            system: system.isEmpty ? nil : system,
            messages: [AnthropicMessage(role: "user", content: .string(decision))],
            tools: nil,
            tool_choice: nil
        )
    }

    static let memberSystem =
        "You are one member of an expert panel answering a decision independently. "
        + "Give your own best answer with your reasoning. Do not hedge to match others; "
        + "your distinct view is the point. Be concise and concrete."

    static func judgeRequest(judge: PanelMember, decision: String,
                             answers: [MemberAnswer], maxTokens: Int) -> AnthropicMessageRequest {
        var body = "DECISION:\n\(decision)\n\n"
        for (i, a) in answers.enumerated() {
            body += "PANEL MEMBER \(i + 1) (\(a.member.label)):\n\(a.text)\n\n"
        }
        body += "Fuse these answers. Record the verdict via the \(judgeToolName) tool."

        let tool = AnthropicTool(
            name: judgeToolName,
            description: "Record the fused panel verdict.",
            input_schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "consensus": .object([
                        "type": .string("string"),
                        "description": .string("What all or most members agreed on (highest confidence)."),
                    ]),
                    "contradictions": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Points where members disagreed."),
                    ]),
                    "blind_spots": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Relevant considerations no member raised."),
                    ]),
                    "unique_insights": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Valuable observations only one member made."),
                    ]),
                ]),
                "required": .array([
                    .string("consensus"), .string("contradictions"),
                    .string("blind_spots"), .string("unique_insights"),
                ]),
            ])
        )
        return AnthropicMessageRequest(
            model: judge.model,
            max_tokens: maxTokens,
            system: Self.judgeSystem,
            messages: [AnthropicMessage(role: "user", content: .string(body))],
            tools: [tool],
            tool_choice: .forced(judgeToolName)
        )
    }

    static let judgeSystem =
        "You are the judge of an expert panel. You receive a decision and several "
        + "members' independent answers. Synthesize them honestly: state the consensus, "
        + "surface genuine contradictions, name blind spots none of them covered, and "
        + "credit unique insights. Do not invent agreement that is not there."

    // MARK: - Response parsing

    static func firstText(in resp: AnthropicMessageResponse) -> String {
        for block in resp.content where block.type == "text" {
            if let t = block.text, !t.isEmpty { return t }
        }
        return ""
    }

    struct Verdict {
        let consensus: String
        let contradictions: [String]
        let blindSpots: [String]
        let uniqueInsights: [String]
    }

    static func parseVerdict(from resp: AnthropicMessageResponse) -> Verdict? {
        for block in resp.content {
            guard block.type == "tool_use", block.name == judgeToolName,
                  case let .object(input)? = block.input else { continue }
            guard case let .string(consensus)? = input["consensus"], !consensus.isEmpty else { return nil }
            return Verdict(
                consensus: consensus,
                contradictions: stringArray(input["contradictions"]),
                blindSpots: stringArray(input["blind_spots"]),
                uniqueInsights: stringArray(input["unique_insights"])
            )
        }
        return nil
    }

    static func stringArray(_ value: AnthropicJSON?) -> [String] {
        guard case let .array(items)? = value else { return [] }
        return items.compactMap { if case let .string(s) = $0 { return s } else { return nil } }
    }

    static func degraded(from succeeded: [MemberAnswer], all: [MemberAnswer], usage: PanelUsage) -> PanelResult {
        PanelResult(
            consensus: succeeded.first?.text ?? "",
            contradictions: [], blindSpots: [], uniqueInsights: [],
            perMember: all, usage: usage, degraded: true
        )
    }

    // MARK: - OpenRouter Fusion (one-call backend)

    public static let defaultFusionModel = "openrouter/fusion"

    /// One-call panel via OpenRouter's server-side Fusion. OpenRouter runs its
    /// own panel + judge and returns a single fused completion, which we surface
    /// as `consensus`. Per-member answers are opaque here (Fusion does not
    /// expose them in the completion), and the structured contradictions /
    /// blind-spots breakdown is the DIY path's advantage — we do NOT depend on
    /// Fusion returning structured fields the live API shape hasn't been
    /// verified to guarantee. Billing is the sum of Fusion's underlying calls
    /// (~4-5x), enforced upstream by the `.openrouter` client's daily cap.
    ///
    /// Requires a `.openrouter` client in the send seam. Throws
    /// `PanelError.fusionReturnedNoContent` if Fusion returns no text.
    public func deliberateViaFusion(decision: String, systemPreamble: String? = nil,
                                    model: String = defaultFusionModel,
                                    maxTokens: Int = 1024) async throws -> PanelResult {
        let request = Self.fusionRequest(model: model, decision: decision,
                                         systemPreamble: systemPreamble, maxTokens: maxTokens)
        let resp = try await send(.openrouter, request)
        let text = Self.firstText(in: resp)
        let usage = PanelUsage(inputTokens: resp.usage.input_tokens,
                               outputTokens: resp.usage.output_tokens,
                               memberCalls: 0, judgeCalls: 1)
        guard !text.isEmpty else { throw PanelError.fusionReturnedNoContent }
        return PanelResult(consensus: text, contradictions: [], blindSpots: [],
                           uniqueInsights: [], perMember: [], usage: usage, degraded: false)
    }

    static func fusionRequest(model: String, decision: String,
                              systemPreamble: String?, maxTokens: Int) -> AnthropicMessageRequest {
        let system = [systemPreamble, Self.fusionSystem].compactMap { $0 }.joined(separator: "\n\n")
        return AnthropicMessageRequest(
            model: model,
            max_tokens: maxTokens,
            system: system.isEmpty ? nil : system,
            messages: [AnthropicMessage(role: "user", content: .string(decision))],
            tools: nil,
            tool_choice: nil
        )
    }

    static let fusionSystem =
        "Deliberate on this decision with your panel and return the fused synthesis: "
        + "the consensus view, plus any genuine disagreements or blind spots worth flagging."
}
