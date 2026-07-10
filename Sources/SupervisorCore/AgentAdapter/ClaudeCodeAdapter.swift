// ClaudeCodeAdapter.swift
//
// Fits the EXISTING Claude Code observation path onto the agent-agnostic
// TranscriptSource / TranscriptLineParser protocols — proving the abstraction
// is a generalization of what already ships, not a parallel universe. Crucially
// this adds the conformance in a SEPARATE file: EventParser.swift (hot in the
// concurrent review-dimension / context-wiki-auditor branches) is not touched.
//
// EventParser already exposes `parse(line:) -> [SupervisorEvent]`, so the
// conformance is empty. ClaudeCodeSource mirrors SessionDiscovery's current
// ~/.claude/projects/<hash>/<id>.jsonl layout.

import Foundation

// EventParser is already structurally a TranscriptLineParser.
extension EventParser: TranscriptLineParser {}

public struct ClaudeCodeSource: TranscriptSource {

    public let agent: AgentKind = .claudeCode
    private let projectsDir: URL

    /// `projectsDir` defaults to ~/.claude/projects; overridable for tests and to
    /// match ConfigPaths.claudeProjectsDir in production wiring.
    public init(projectsDir: URL? = nil) {
        self.projectsDir = projectsDir
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public var watchRoots: [URL] { [projectsDir] }

    public func isTranscript(_ file: URL) -> Bool { file.pathExtension == "jsonl" }

    /// Claude Code embeds the session id as the filename stem.
    public func sessionId(for file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
    }

    /// The project-hash directory name (cwd-derived), e.g. `-Users-main`.
    public func projectNamespace(for file: URL) -> String {
        file.deletingLastPathComponent().lastPathComponent
    }

    public func makeParser(sessionId: String, path: URL) -> any TranscriptLineParser {
        EventParser(projectHash: projectNamespace(for: path), jsonlPath: path.path)
    }
}
