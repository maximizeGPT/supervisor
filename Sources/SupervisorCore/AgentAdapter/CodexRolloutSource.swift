// CodexRolloutSource.swift
//
// The TranscriptSource for OpenAI Codex. Points discovery at ~/.codex/sessions
// (a YYYY/MM/DD date tree) and vends a CodexRolloutParser per rollout file.
//
// This value type is the whole producer-side integration surface for Codex: a
// future SessionDiscovery parameterized by TranscriptSource watches
// `watchRoots`, adopts files matching `isTranscript`, keys them by
// `sessionId(for:)`, and tails them through `makeParser(...)`. Nothing about the
// downstream pipeline changes.

import Foundation

public struct CodexRolloutSource: TranscriptSource {

    public let agent: AgentKind = .codex
    private let codexHome: URL

    /// `codexHome` defaults to ~/.codex; overridable for tests.
    public init(codexHome: URL? = nil) {
        self.codexHome = codexHome
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public var watchRoots: [URL] {
        [codexHome.appendingPathComponent("sessions", isDirectory: true)]
    }

    public func isTranscript(_ file: URL) -> Bool {
        file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-")
    }

    /// Extract the session uuid from `rollout-<ISO-ts>-<uuid>.jsonl`. The uuid is
    /// the trailing 5 hyphen groups (8-4-4-4-12); the timestamp prefix also
    /// contains hyphens, so we take the LAST five, not a fixed offset. Falls back
    /// to the filename stem if the shape is unexpected.
    public func sessionId(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        if parts.count >= 5 {
            return parts.suffix(5).joined(separator: "-")
        }
        return stem
    }

    /// Codex has no cwd-derived project-hash directory; namespace session records
    /// under the agent's sentinel so they don't collide with Claude Code's
    /// hashes AND the UI can derive the agent from a session's projectHash.
    public func projectNamespace(for file: URL) -> String { AgentKind.codex.projectNamespace ?? "codex" }

    public func makeParser(sessionId: String, path: URL) -> any TranscriptLineParser {
        CodexRolloutParser(sessionId: sessionId, projectHash: projectNamespace(for: path), jsonlPath: path.path)
    }
}
