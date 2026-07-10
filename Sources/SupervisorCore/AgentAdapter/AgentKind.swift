// AgentKind.swift
//
// Which coding agent a supervised session belongs to. Supervisor started as a
// Claude-Code-only supervisor; this enum is the discriminator that lets a
// second agent (OpenAI Codex) flow through the SAME SupervisorEvent pipeline —
// same EventBus, same TriageEngine, same safety rubric — while letting the
// intervention layer pick the right actuator (Claude Code = process signal +
// keystroke; Codex = process signal / app-server JSON-RPC).
//
// It is deliberately NOT carried on every SupervisorEvent: routing keys off the
// session, so the kind lives on the session record (and on SessionStartInfo when
// the wiring stage lands). Keeping events free of it means the whole downstream
// safety core stays agent-agnostic, which is the entire point of the abstraction
// (see docs/codex-support/DESIGN.md).

import Foundation

public enum AgentKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// Anthropic Claude Code. Transcripts: ~/.claude/projects/<hash>/<id>.jsonl.
    case claudeCode
    /// OpenAI Codex. Transcripts: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
    case codex

    /// Human-facing label for banners / hover UI ("Paused Codex before …").
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        }
    }

    /// Short chip label for the hover band, where space is tight.
    public var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex:      return "Codex"
        }
    }

    /// The namespace this agent's sessions are recorded under (the session
    /// record's `projectHash`). Claude Code uses a cwd-derived hash, so it has
    /// no single sentinel; Codex sessions are all namespaced `"codex"`. This is
    /// the seam that lets any surface holding a `projectHash` derive the agent
    /// (see `init(projectNamespace:)`) without an event or DB schema change.
    public var projectNamespace: String? {
        switch self {
        case .claudeCode: return nil          // cwd-derived; not a fixed sentinel
        case .codex:      return "codex"
        }
    }

    /// Derive the agent from a session record's `projectHash`. Only Codex has a
    /// fixed namespace; everything else is Claude Code (the default agent).
    public init(projectNamespace: String) {
        self = (projectNamespace == AgentKind.codex.projectNamespace) ? .codex : .claudeCode
    }
}
