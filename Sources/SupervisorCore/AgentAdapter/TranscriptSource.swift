// TranscriptSource.swift
//
// The producer-side seam of the agent-agnostic abstraction. A `TranscriptSource`
// knows, for one agent, WHERE its session transcripts live on disk and HOW to
// turn a raw transcript line into the shared `SupervisorEvent` stream. The tail
// itself — kqueue watching, byte offsets, backfill/fast-forward, inactivity
// close (SessionTail) — is format-independent and reused unchanged; only the
// discovery roots and the per-line parse differ between agents.
//
// This is intentionally the SAME shape Claude Code's existing EventParser
// already satisfies (`parse(line:) -> [SupervisorEvent]`), so the two agents
// converge on one contract with no rewrite of the hot Observation files. See
// docs/codex-support/DESIGN.md §4.

import Foundation

/// Raw transcript line → zero or more domain events. One instance per
/// transcript file (matches SessionTail's "a fresh parser per session"
/// lifecycle), so a parser may carry per-file state (a session id that the
/// file's lines don't repeat, a tool-call id registry, a once-only
/// sessionStart latch).
public protocol TranscriptLineParser: AnyObject {
    func parse(line: String) -> [SupervisorEvent]
}

/// Everything discovery needs to find + adopt one agent's transcripts. A
/// `SessionDiscovery` parameterized by this can watch either agent's tree; the
/// events it publishes land on the same EventBus regardless of source.
public protocol TranscriptSource: Sendable {
    /// Which agent this source produces events for.
    var agent: AgentKind { get }

    /// Directory root(s) to watch for transcript files. Claude Code:
    /// ~/.claude/projects (a project-hash tree). Codex: ~/.codex/sessions (a
    /// date tree). Discovery recurses these looking for transcript files.
    var watchRoots: [URL] { get }

    /// True if `file` is a transcript this source owns (Claude Code: a
    /// top-level `<id>.jsonl`; Codex: a `rollout-*.jsonl`).
    func isTranscript(_ file: URL) -> Bool

    /// The session id for a transcript file. Claude Code embeds it as the
    /// filename stem; Codex embeds the uuid in `rollout-<ts>-<uuid>.jsonl`
    /// (and repeats it once in session_meta, but never per-line).
    func sessionId(for file: URL) -> String

    /// A "namespace" for the session record's projectHash column. Claude Code
    /// uses the cwd-derived project-hash directory name; Codex has no such
    /// thing, so its source supplies a stable namespace (the agent name).
    func projectNamespace(for file: URL) -> String

    /// A fresh per-file parser bound to this session id + path.
    func makeParser(sessionId: String, path: URL) -> any TranscriptLineParser
}
