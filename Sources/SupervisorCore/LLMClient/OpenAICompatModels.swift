// OpenAICompatModels.swift — v0.2.0.
//
// Wire-shape types for OpenAI-compatible chat.completions APIs.
// DeepSeek, Moonshot (Kimi), MiniMax, and Qwen-via-HF all implement
// this faithfully enough that one set of Codable shapes serves them all.
//
// These types are HTTP-layer only. `LLMClient` translates between
// these and Supervisor's internal canonical types
// (`AnthropicMessageRequest` / `AnthropicMessageResponse`) so the
// triage engine doesn't care which provider is on the other end.

import Foundation

// MARK: - Request

struct OpenAIChatRequest: Codable, Sendable {
    let model: String
    let max_tokens: Int
    let messages: [OpenAIMessage]
    let tools: [OpenAITool]?
    let tool_choice: OpenAIToolChoice?
}

struct OpenAIMessage: Codable, Sendable {
    let role: String              // "system" | "user" | "assistant" | "tool"
    let content: String
}

struct OpenAITool: Codable, Sendable {
    let type: String              // always "function"
    let function: OpenAIFunction
}

struct OpenAIFunction: Codable, Sendable {
    let name: String
    let description: String
    let parameters: AnthropicJSON  // OpenAI parameters schema is JSON; reuse our existing JSON enum
}

/// OpenAI's tool_choice is either a string ("auto" | "required" | "none")
/// or an object `{type: "function", function: {name: "..."}}` for the
/// forced-call case. The triage engine always uses the forced form.
struct OpenAIToolChoice: Codable, Sendable {
    let type: String              // "function"
    let function: ForcedFunction

    struct ForcedFunction: Codable, Sendable {
        let name: String
    }

    static func forced(_ name: String) -> OpenAIToolChoice {
        .init(type: "function", function: .init(name: name))
    }
}

// MARK: - Response

struct OpenAIChatResponse: Codable, Sendable {
    let id: String?
    let model: String?
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage?
}

struct OpenAIChoice: Codable, Sendable {
    let index: Int?
    let message: OpenAIResponseMessage
    let finish_reason: String?
}

struct OpenAIResponseMessage: Codable, Sendable {
    let role: String
    let content: String?
    let tool_calls: [OpenAIToolCall]?
}

struct OpenAIToolCall: Codable, Sendable {
    let id: String?
    let type: String?             // "function"
    let function: OpenAIFunctionCall
}

struct OpenAIFunctionCall: Codable, Sendable {
    let name: String
    /// JSON-encoded string (not a JSON object) — OpenAI returns the
    /// tool arguments as a stringified JSON blob.
    let arguments: String
}

struct OpenAIUsage: Codable, Sendable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int?
}

// MARK: - Error shape

struct OpenAIErrorEnvelope: Codable, Sendable {
    let error: OpenAIErrorBody?

    struct OpenAIErrorBody: Codable, Sendable {
        let message: String?
        let type: String?
        let code: String?
    }
}
