// QuestionAnswerer.swift — v0.3.0 B3.
//
// Second-stage call: takes a `user_question_pending` candidate and either
// (a) answers an engineering question by reading PRINCIPLES.md as context,
// or (b) rewrites a taste question into plain language for a non-technical
// user. Safety questions don't reach this layer — they go straight to
// notify so the user sees them unmodified.
//
// Cost is bounded: PRINCIPLES.md is ~8K tokens; the question itself is
// ~200 chars; output is ≤200 chars for inject (we want to type a short
// answer into the terminal) or ≤2 sentences for the taste rewrite. One
// secondary call per user_question_pending flag, ~$0.01-0.02 against
// Haiku 4.5 rates.
//
// Output schema is constrained via a forced tool call — same shape as
// the primary record_triage call so we don't drift away from structured
// outputs. Confidence is a string enum {high, medium, low}; low
// confidence on an engineering question triggers degradation to the
// taste path (translate + surface to user) so we don't fabricate
// answers.

import Foundation

public struct EngineeringAnswer: Sendable, Equatable {
    /// The answer Supervisor will inject into the terminal. Should be a
    /// single short line — what a senior engineer would type back.
    public let answer: String
    /// Self-reported confidence. "low" means PRINCIPLES.md didn't have
    /// a clear answer; the engine degrades to the taste path.
    public let confidence: Confidence
    /// Brief reference to which principle / section grounded the answer
    /// — surfaced in the trace, not the inject text.
    public let citation: String

    public enum Confidence: String, Sendable, Equatable {
        case high
        case medium
        case low
    }
}

public struct TasteRewrite: Sendable, Equatable {
    /// Plain-language rewrite of the assistant's question, written so a
    /// non-engineer can understand and answer it. Replaces the
    /// `reasoning_plain` on the candidate when surfaced as a banner.
    public let plainQuestion: String
}

public final class QuestionAnswerer: Sendable {

    private let client: LLMClient
    private let principlesText: String
    private let trace: TraceLog

    /// `principlesText` is the full PRINCIPLES.md body, loaded once at
    /// construction. We don't re-read on every call — the doc is
    /// session-stable and the read is O(KB).
    public init(
        client: LLMClient,
        principlesText: String,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.principlesText = principlesText
        self.trace = trace
    }

    // MARK: - Engineering path

    public func answerEngineering(question: String) async throws -> EngineeringAnswer {
        let req = AnthropicMessageRequest(
            model: client.provider.defaultTriageModel,
            max_tokens: 600,
            system: Self.engineeringSystemPrompt,
            messages: [
                .init(role: "user", content: .string(Self.engineeringUserMessage(
                    question: question,
                    principles: principlesText
                )))
            ],
            tools: [Self.recordAnswerTool],
            tool_choice: .forced(Self.recordAnswerToolName)
        )
        let resp = try await client.createMessage(req)
        trace.emit("triage.answer", "running secondary haiku model=\(resp.model) input=\(resp.usage.input_tokens) output=\(resp.usage.output_tokens)")
        guard let parsed = Self.parseEngineeringAnswer(from: resp) else {
            trace.emit("triage.answer", "ERROR could not parse engineering answer; degrading to low-confidence empty")
            return EngineeringAnswer(answer: "", confidence: .low, citation: "")
        }
        trace.emit("triage.answer", "returned: \(parsed.answer.prefix(160)) (confidence=\(parsed.confidence.rawValue) citation=\(parsed.citation.prefix(80)))")
        return parsed
    }

    // MARK: - Taste path

    public func translateTaste(question: String) async throws -> TasteRewrite {
        let req = AnthropicMessageRequest(
            model: client.provider.defaultTriageModel,
            max_tokens: 200,
            system: Self.tasteSystemPrompt,
            messages: [
                .init(role: "user", content: .string(Self.tasteUserMessage(question: question)))
            ],
            tools: [Self.rewriteQuestionTool],
            tool_choice: .forced(Self.rewriteQuestionToolName)
        )
        let resp = try await client.createMessage(req)
        trace.emit("triage.translate", "running secondary haiku model=\(resp.model) input=\(resp.usage.input_tokens) output=\(resp.usage.output_tokens)")
        guard let parsed = Self.parseTasteRewrite(from: resp) else {
            trace.emit("triage.translate", "ERROR parse failed; passing through original question")
            return TasteRewrite(plainQuestion: question)
        }
        trace.emit("triage.translate", "returned: \(parsed.plainQuestion.prefix(160))")
        return parsed
    }

    // MARK: - Prompts

    static let engineeringSystemPrompt: String = """
    You are Supervisor's engineering-question answerer. Your job is to
    answer technical questions that Claude Code has asked the user, by
    drawing on PRINCIPLES.md — Supervisor's operating manual — and
    nothing else.

    Output rules:
      - One short line, ≤200 characters. Supervisor will type this
        verbatim into the user's terminal as the response Claude Code
        is waiting for.
      - Plain prose. No markdown, no code fences, no preamble. Just the
        answer text Claude Code should read.
      - If PRINCIPLES.md gives a clear answer, return it with confidence
        "high" and cite the section ("§1c", "§6f", etc.).
      - If PRINCIPLES.md hints at an answer but doesn't enumerate it,
        return your best read with confidence "medium" and cite the
        nearest relevant section.
      - If PRINCIPLES.md doesn't address the question, return confidence
        "low" and answer "(no clear answer in PRINCIPLES.md)". DO NOT
        fabricate. Supervisor will degrade to surfacing the question to
        the user when confidence is low.

    Call `record_answer` with your answer.
    """

    static func engineeringUserMessage(question: String, principles: String) -> String {
        """
        # The question
        Claude Code asked the user:

        > \(question)

        # PRINCIPLES.md (operating manual)

        \(principles)

        # Task
        Answer the question above, drawing on PRINCIPLES.md. Output via
        record_answer exactly once.
        """
    }

    static let tasteSystemPrompt: String = """
    You are Supervisor's taste-question translator. Your job is to take
    a technical-looking question that Claude Code has asked the user and
    rewrite it in plain language a non-engineer can understand and
    answer.

    Output rules:
      - The rewrite goes into a notification banner the user reads.
        Keep it short: 1-2 sentences, ≤140 characters total.
      - Strip jargon. Replace specific code/package/framework names
        with plain descriptions. ("Should I add Yams?" → "Should I add
        a YAML parser, or write the parsing by hand?")
      - Preserve the choice structure — the user still needs to pick
        between the same options Claude Code presented, just expressed
        in user-facing language.
      - Don't editorialize. Don't add advice. Just rewrite the question.

    Call `rewrite_question` with your translation.
    """

    static func tasteUserMessage(question: String) -> String {
        """
        # Original question from Claude Code
        > \(question)

        # Task
        Rewrite the question in plain language for a non-engineer.
        Output via rewrite_question exactly once.
        """
    }

    // MARK: - Tool schemas

    static let recordAnswerToolName = "record_answer"

    static var recordAnswerTool: AnthropicTool {
        AnthropicTool(
            name: recordAnswerToolName,
            description: "Record the engineering answer drawn from PRINCIPLES.md.",
            input_schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "answer": .object([
                        "type": .string("string"),
                        "description": .string("≤200 chars. Plain prose. The exact text Supervisor will type into the user's terminal.")
                    ]),
                    "confidence": .object([
                        "type": .string("string"),
                        "enum": .array([.string("high"), .string("medium"), .string("low")]),
                        "description": .string("high = PRINCIPLES has a clear answer; medium = nearest-section read; low = no clear answer, degrade to user.")
                    ]),
                    "citation": .object([
                        "type": .string("string"),
                        "description": .string("Brief reference to which section grounded the answer (e.g., '§1c', '§6f'). Empty when confidence is low.")
                    ])
                ]),
                "required": .array([
                    .string("answer"), .string("confidence"), .string("citation")
                ])
            ])
        )
    }

    static let rewriteQuestionToolName = "rewrite_question"

    static var rewriteQuestionTool: AnthropicTool {
        AnthropicTool(
            name: rewriteQuestionToolName,
            description: "Record the plain-language translation of a taste-shaped question.",
            input_schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "plain_question": .object([
                        "type": .string("string"),
                        "description": .string("1-2 sentences, ≤140 chars. Plain language. The text that lands in the notification banner.")
                    ])
                ]),
                "required": .array([.string("plain_question")])
            ])
        )
    }

    // MARK: - Parsers

    private static func parseEngineeringAnswer(from response: AnthropicMessageResponse) -> EngineeringAnswer? {
        for block in response.content {
            guard block.type == "tool_use",
                  block.name == recordAnswerToolName,
                  case let .object(input)? = block.input
            else { continue }
            guard case let .string(answer)? = input["answer"],
                  case let .string(confStr)? = input["confidence"],
                  let confidence = EngineeringAnswer.Confidence(rawValue: confStr)
            else { return nil }
            let citation: String
            if case let .string(c)? = input["citation"] { citation = c } else { citation = "" }
            return EngineeringAnswer(answer: answer, confidence: confidence, citation: citation)
        }
        return nil
    }

    private static func parseTasteRewrite(from response: AnthropicMessageResponse) -> TasteRewrite? {
        for block in response.content {
            guard block.type == "tool_use",
                  block.name == rewriteQuestionToolName,
                  case let .object(input)? = block.input
            else { continue }
            guard case let .string(plain)? = input["plain_question"] else { return nil }
            return TasteRewrite(plainQuestion: plain)
        }
        return nil
    }
}
