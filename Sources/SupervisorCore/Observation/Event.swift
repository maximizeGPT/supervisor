// Event.swift
//
// Domain type for everything the observation pipeline emits. Subscribers
// (Hover UI, TriageEngine, future Escalation) consume `SupervisorEvent`
// values from `EventBus`. The enum stays narrow in v0.1.0 — only the
// blocks we need for `destructive_action_pending` triage land here. The
// v0.1.1+ events (assistantThinking metadata, Edit/Write/Read tool calls)
// will add cases without breaking existing consumers.
//
// `channel:` is the v0.2 seam: today every event has channel=.jsonl. When
// the v0.2 Claude Code hook wire arrives, hook-sourced events will carry
// channel=.hookSocket. Downstream consumers branch on event type, not
// channel — the design keeps that path unbothered.

import Foundation

public enum EventChannel: String, Sendable, Equatable {
    case jsonl
    case hookSocket
}

public enum SupervisorEvent: Sendable, Equatable {

    /// Emitted once per session discovery. Confirms the JSONL exists and
    /// gives the subscribers cwd / git branch / first-seen timestamp.
    case sessionStart(SessionStartInfo)

    /// The user's prompt text (a user message with string content). Triage
    /// uses this to know what the user actually asked for — without it,
    /// `lost_the_thread` and `scope_creep` would have no anchor in v0.1.1+.
    case userPrompt(UserPromptInfo)

    /// Assistant's prose. `text` blocks only — `thinking` blocks are
    /// opaque (encrypted) and `tool_use` blocks have their own cases.
    case assistantText(AssistantTextInfo)

    /// Bash tool call. v0.1.0's only triage trigger surface. Edit, Write,
    /// Read, and MCP tools land in v0.1.1.
    case bashToolCall(BashToolCallInfo)

    /// Result of the most recent Bash tool call. v0.1.0 cares about
    /// `isError` and the first ~2KB of output (truncated for the prompt).
    case bashToolResult(BashToolResultInfo)

    /// A `system` line with `preventedContinuation: true` (a hook said no).
    /// Currently emitted but not consumed in v0.1.0; v0.1.4 wires the
    /// `prevented_continuation_ignored` rubric category to it.
    case systemSignal(SystemSignalInfo)

    public var sessionId: String {
        switch self {
        case .sessionStart(let v):     return v.sessionId
        case .userPrompt(let v):       return v.sessionId
        case .assistantText(let v):    return v.sessionId
        case .bashToolCall(let v):     return v.sessionId
        case .bashToolResult(let v):   return v.sessionId
        case .systemSignal(let v):     return v.sessionId
        }
    }

    public var timestamp: Date {
        switch self {
        case .sessionStart(let v):     return v.ts
        case .userPrompt(let v):       return v.ts
        case .assistantText(let v):    return v.ts
        case .bashToolCall(let v):     return v.ts
        case .bashToolResult(let v):   return v.ts
        case .systemSignal(let v):     return v.ts
        }
    }

    public var channel: EventChannel {
        switch self {
        case .sessionStart(let v):     return v.channel
        case .userPrompt(let v):       return v.channel
        case .assistantText(let v):    return v.channel
        case .bashToolCall(let v):     return v.channel
        case .bashToolResult(let v):   return v.channel
        case .systemSignal(let v):     return v.channel
        }
    }
}

// MARK: - Per-case payloads

public struct SessionStartInfo: Sendable, Equatable {
    public let sessionId: String
    public let cwd: String
    public let gitBranch: String?
    public let projectHash: String
    public let jsonlPath: String
    public let ts: Date
    public var channel: EventChannel = .jsonl

    public init(sessionId: String, cwd: String, gitBranch: String?, projectHash: String, jsonlPath: String, ts: Date, channel: EventChannel = .jsonl) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.projectHash = projectHash
        self.jsonlPath = jsonlPath
        self.ts = ts
        self.channel = channel
    }
}

public struct UserPromptInfo: Sendable, Equatable {
    public let sessionId: String
    public let text: String
    public let ts: Date
    public var channel: EventChannel = .jsonl

    public init(sessionId: String, text: String, ts: Date, channel: EventChannel = .jsonl) {
        self.sessionId = sessionId
        self.text = text
        self.ts = ts
        self.channel = channel
    }
}

public struct AssistantTextInfo: Sendable, Equatable {
    public let sessionId: String
    public let text: String
    public let turnUUID: String
    public let ts: Date
    public var channel: EventChannel = .jsonl

    public init(sessionId: String, text: String, turnUUID: String, ts: Date, channel: EventChannel = .jsonl) {
        self.sessionId = sessionId
        self.text = text
        self.turnUUID = turnUUID
        self.ts = ts
        self.channel = channel
    }
}

public struct BashToolCallInfo: Sendable, Equatable {
    public let sessionId: String
    public let command: String
    public let description: String?
    public let toolUseId: String
    public let turnUUID: String
    public let ts: Date
    public var channel: EventChannel = .jsonl

    public init(sessionId: String, command: String, description: String?, toolUseId: String, turnUUID: String, ts: Date, channel: EventChannel = .jsonl) {
        self.sessionId = sessionId
        self.command = command
        self.description = description
        self.toolUseId = toolUseId
        self.turnUUID = turnUUID
        self.ts = ts
        self.channel = channel
    }
}

public struct BashToolResultInfo: Sendable, Equatable {
    public let sessionId: String
    public let toolUseId: String
    public let output: String
    public let isError: Bool
    public let ts: Date
    public var channel: EventChannel = .jsonl

    public init(sessionId: String, toolUseId: String, output: String, isError: Bool, ts: Date, channel: EventChannel = .jsonl) {
        self.sessionId = sessionId
        self.toolUseId = toolUseId
        self.output = output
        self.isError = isError
        self.ts = ts
        self.channel = channel
    }
}

public struct SystemSignalInfo: Sendable, Equatable {
    public let sessionId: String
    public let subtype: String
    public let preventedContinuation: Bool
    public let ts: Date
    public var channel: EventChannel = .jsonl

    public init(sessionId: String, subtype: String, preventedContinuation: Bool, ts: Date, channel: EventChannel = .jsonl) {
        self.sessionId = sessionId
        self.subtype = subtype
        self.preventedContinuation = preventedContinuation
        self.ts = ts
        self.channel = channel
    }
}
