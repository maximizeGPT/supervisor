// Models.swift
//
// Codable request/response shapes for the small slice of the Anthropic
// Messages API that Supervisor v0.1.0 needs:
//   - createMessage with tools + forced tool_choice (for the triage call)
//   - validateKey (a 1-token throwaway request)
//
// Schemas matched to api.anthropic.com Messages v1 as of 2026-05.

import Foundation

// MARK: - Request

public struct AnthropicMessageRequest: Codable, Sendable {
    public let model: String
    public let max_tokens: Int
    public let system: String?
    public let messages: [AnthropicMessage]
    public let tools: [AnthropicTool]?
    public let tool_choice: AnthropicToolChoice?

    public init(
        model: String,
        max_tokens: Int,
        system: String? = nil,
        messages: [AnthropicMessage],
        tools: [AnthropicTool]? = nil,
        tool_choice: AnthropicToolChoice? = nil
    ) {
        self.model = model
        self.max_tokens = max_tokens
        self.system = system
        self.messages = messages
        self.tools = tools
        self.tool_choice = tool_choice
    }
}

public struct AnthropicMessage: Codable, Sendable {
    public let role: String           // "user" | "assistant"
    public let content: AnthropicContent

    public init(role: String, content: AnthropicContent) {
        self.role = role
        self.content = content
    }
}

/// Anthropic's content field is heterogeneous — a string OR an array of
/// content blocks. v0.1.0 only sends user prompts as strings; we encode
/// both shapes to keep responses parseable.
public enum AnthropicContent: Codable, Sendable {
    case string(String)
    case blocks([AnthropicContentBlock])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .blocks(let b): try c.encode(b)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            self = .blocks(try c.decode([AnthropicContentBlock].self))
        }
    }
}

public struct AnthropicContentBlock: Codable, Sendable {
    public let type: String                        // "text" | "tool_use" | "tool_result" | "thinking"
    public let text: String?
    public let id: String?                         // present on tool_use
    public let name: String?                       // present on tool_use
    public let input: AnthropicJSON?               // present on tool_use
    public let tool_use_id: String?                // present on tool_result
    public let content: AnthropicJSON?             // present on tool_result

    public init(
        type: String,
        text: String? = nil,
        id: String? = nil,
        name: String? = nil,
        input: AnthropicJSON? = nil,
        tool_use_id: String? = nil,
        content: AnthropicJSON? = nil
    ) {
        self.type = type
        self.text = text
        self.id = id
        self.name = name
        self.input = input
        self.tool_use_id = tool_use_id
        self.content = content
    }
}

public struct AnthropicTool: Codable, Sendable {
    public let name: String
    public let description: String
    public let input_schema: AnthropicJSON

    public init(name: String, description: String, input_schema: AnthropicJSON) {
        self.name = name
        self.description = description
        self.input_schema = input_schema
    }
}

public struct AnthropicToolChoice: Codable, Sendable {
    public let type: String              // "auto" | "any" | "tool"
    public let name: String?             // required when type == "tool"

    public init(type: String, name: String? = nil) {
        self.type = type
        self.name = name
    }

    public static func forced(_ name: String) -> AnthropicToolChoice {
        .init(type: "tool", name: name)
    }
}

// MARK: - Response

public struct AnthropicMessageResponse: Codable, Sendable {
    public let id: String
    public let type: String             // "message"
    public let role: String             // "assistant"
    public let model: String
    public let content: [AnthropicContentBlock]
    public let stop_reason: String?
    public let stop_sequence: String?
    public let usage: AnthropicUsage
}

public struct AnthropicUsage: Codable, Sendable {
    public let input_tokens: Int
    public let output_tokens: Int
    public let cache_creation_input_tokens: Int?
    public let cache_read_input_tokens: Int?
}

// MARK: - Error response

public struct AnthropicErrorResponse: Codable, Sendable {
    public let type: String
    public let error: AnthropicErrorBody

    public struct AnthropicErrorBody: Codable, Sendable {
        public let type: String          // "authentication_error" | "rate_limit_error" | ...
        public let message: String
    }
}

// MARK: - Loose JSON wrapper

/// Anthropic's tool_use.input and tool.input_schema are arbitrary JSON.
/// We round-trip them losslessly with a value-type wrapper rather than a
/// generic [String: Any] (which doesn't conform to Codable).
public enum AnthropicJSON: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case array([AnthropicJSON])
    case object([String: AnthropicJSON])
    case null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .integer(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([AnthropicJSON].self) { self = .array(v); return }
        if let v = try? c.decode([String: AnthropicJSON].self) { self = .object(v); return }
        throw DecodingError.typeMismatch(
            AnthropicJSON.self,
            .init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value")
        )
    }
}
