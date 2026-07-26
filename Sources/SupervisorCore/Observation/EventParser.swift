// EventParser.swift
//
// Raw JSONL line → SupervisorEvent. Only emits the event types v0.1.0
// consumes:
//   - sessionStart  (first parsed line per session)
//   - userPrompt    (user.message.content as string)
//   - assistantText (assistant.message.content[*].type == "text")
//   - bashToolCall  (assistant.message.content[*].type == "tool_use" + name == "Bash")
//   - bashToolResult (user.message.content[*].type == "tool_result" matching a known Bash tool_use_id)
//   - systemSignal  (type == "system" with preventedContinuation set)
//
// Everything else (queue-operation, ai-title, last-prompt, attachment,
// thinking blocks, non-Bash tool calls) parses successfully but emits
// nothing. The verbose-line discipline keeps the EventBus traffic
// proportional to what the rest of the system actually needs.
//
// Provenance guard (2026-07-02): not every line is main-session,
// owner-authored content. Sidechain lines (`isSidechain: true` — a
// subagent's transcript interleaved into the same JSONL, whose opening
// user-role turn is really the ASSISTANT's Task prompt) emit nothing past
// sessionStart. Machine-generated user-role turns (`isMeta: true` caveats,
// <command-*>/<local-command-stdout> slash-command echoes, and
// compact-continuation summaries) never become userPrompt. Any of these
// would otherwise read downstream as the owner's words — the
// destructive-action authorization anchor (TriageEngine.lastOwnerPrompt)
// and the session objective.

import Foundation

public final class EventParser: Sendable {

    /// Live registry of tool_use_id → tool name, so a later tool_result
    /// row can be matched to the right tool. We only emit
    /// `bashToolResult` for Bash calls. Stored as nonisolated unsafe map
    /// (parser is single-threaded per tail — guaranteed by SessionTail's
    /// serial queue).
    private final class IDRegistry: @unchecked Sendable {
        var bashToolUseIDs = Set<String>()
        func registerBash(_ id: String) { bashToolUseIDs.insert(id) }
        func isBash(_ id: String) -> Bool { bashToolUseIDs.contains(id) }
    }

    /// One registry per session. Tail vends a fresh parser per session,
    /// so this lives the length of one session's tail.
    private let registry = IDRegistry()

    /// Has the sessionStart event been emitted yet? First parsed line of
    /// each session emits one.
    private var emittedSessionStart = false

    private let projectHash: String
    private let jsonlPath: String

    public init(projectHash: String, jsonlPath: String) {
        self.projectHash = projectHash
        self.jsonlPath = jsonlPath
    }

    /// Parse one JSONL line. Returns zero or more events. Returns []
    /// (silently) on lines we don't consume; throws only on invalid JSON.
    public func parse(line: String) -> [SupervisorEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        guard let type = obj["type"] as? String else { return [] }

        var emitted: [SupervisorEvent] = []

        // sessionStart on the first event that actually CARRIES a cwd. The
        // lead-in lines in a real session file (ai-title, mode, queue-operation,
        // last-prompt) have no cwd — emitting sessionStart on those produced
        // cwd="<unknown>" and never updated, so the session stayed unresolved
        // and the dispatcher proposed cross-project work (2026-06-05). cwd (and
        // gitBranch) live on user/assistant/system events; require cwd before
        // emitting so sessionStart surfaces the REAL project.
        if !emittedSessionStart,
           let sessionId = obj["sessionId"] as? String,
           let cwd = obj["cwd"] as? String, !cwd.isEmpty,
           let ts = TranscriptTail.parseTS(obj["timestamp"]) {
            let gitBranch = obj["gitBranch"] as? String
            emitted.append(.sessionStart(.init(
                sessionId: sessionId,
                cwd: cwd,
                gitBranch: gitBranch,
                projectHash: projectHash,
                jsonlPath: jsonlPath,
                ts: ts
            )))
            emittedSessionStart = true
        }

        // Sidechain lines are a subagent's transcript, not the main session:
        // nothing on them may interleave into the main-session window. The
        // sidechain's opening user-role turn is assistant-authored (the Task
        // tool prompt) and would otherwise become lastOwnerPrompt; its
        // assistant/tool events aren't the observed session's work either.
        // sessionStart above still fires — the line carries the real cwd even
        // when its content is skippable.
        if (obj["isSidechain"] as? Bool) == true { return emitted }

        switch type {
        case "user":
            emitted.append(contentsOf: parseUserMessage(obj))
        case "assistant":
            emitted.append(contentsOf: parseAssistantMessage(obj))
        case "system":
            emitted.append(contentsOf: parseSystem(obj))
        default:
            break  // queue-operation, ai-title, last-prompt, attachment — ignored
        }

        return emitted
    }

    // MARK: - User message

    private func parseUserMessage(_ obj: [String: Any]) -> [SupervisorEvent] {
        guard let sessionId = obj["sessionId"] as? String,
              let ts = TranscriptTail.parseTS(obj["timestamp"]) else { return [] }
        guard let message = obj["message"] as? [String: Any] else { return [] }

        var out: [SupervisorEvent] = []

        // A user-role turn the human didn't type must never become userPrompt
        // (it would be `.owner` downstream). isMeta covers CLI-generated
        // caveat turns; the text-shape check covers slash-command echoes and
        // compact-continuation summaries.
        let isMeta = (obj["isMeta"] as? Bool) == true

        // content may be a String (a plain user prompt) or an array of
        // blocks (containing tool_result entries).
        if let str = message["content"] as? String, !str.isEmpty {
            if !isMeta, !Self.isMachineGeneratedUserText(str) {
                out.append(.userPrompt(.init(sessionId: sessionId, text: str, ts: ts)))
            }
            return out
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        for block in blocks {
            guard let btype = block["type"] as? String else { continue }
            switch btype {
            case "tool_result":
                if let toolUseId = block["tool_use_id"] as? String,
                   registry.isBash(toolUseId) {
                    let isError = (block["is_error"] as? Bool) ?? false
                    let output = Self.stringifyToolResultContent(block["content"])
                    out.append(.bashToolResult(.init(
                        sessionId: sessionId,
                        toolUseId: toolUseId,
                        output: output,
                        isError: isError,
                        ts: ts
                    )))
                }
            case "text":
                if let str = block["text"] as? String, !str.isEmpty,
                   !isMeta, !Self.isMachineGeneratedUserText(str) {
                    out.append(.userPrompt(.init(sessionId: sessionId, text: str, ts: ts)))
                }
            default:
                break
            }
        }
        return out
    }

    // MARK: - Assistant message

    private func parseAssistantMessage(_ obj: [String: Any]) -> [SupervisorEvent] {
        guard let sessionId = obj["sessionId"] as? String,
              let ts = TranscriptTail.parseTS(obj["timestamp"]),
              let turnUUID = obj["uuid"] as? String else { return [] }
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }

        var out: [SupervisorEvent] = []
        for block in content {
            guard let btype = block["type"] as? String else { continue }
            switch btype {
            case "text":
                if let str = block["text"] as? String, !str.isEmpty {
                    out.append(.assistantText(.init(
                        sessionId: sessionId,
                        text: str,
                        turnUUID: turnUUID,
                        ts: ts
                    )))
                }
            case "tool_use":
                guard let name = block["name"] as? String,
                      let toolUseId = block["id"] as? String,
                      let input = block["input"] as? [String: Any] else {
                    continue
                }
                switch name {
                case "Bash":
                    let command = (input["command"] as? String) ?? ""
                    let description = input["description"] as? String
                    registry.registerBash(toolUseId)
                    out.append(.bashToolCall(.init(
                        sessionId: sessionId,
                        command: command,
                        description: description,
                        toolUseId: toolUseId,
                        turnUUID: turnUUID,
                        ts: ts
                    )))
                case "Edit", "Write", "MultiEdit":
                    // The REVIEW dimension consumes fileEdit; the safety triage
                    // ignores it. Non-applying/empty edits parse to nil and emit
                    // nothing (a Write with no content, an Edit with no strings).
                    if let info = Self.parseFileEdit(
                        name: name, input: input, sessionId: sessionId,
                        toolUseId: toolUseId, turnUUID: turnUUID, ts: ts
                    ) {
                        out.append(.fileEdit(info))
                    }
                default:
                    break  // Read, Grep, Glob, MCP tools, etc. — not consumed
                }
            default:
                break  // thinking, etc.
            }
        }
        return out
    }

    // MARK: - System

    private func parseSystem(_ obj: [String: Any]) -> [SupervisorEvent] {
        guard let sessionId = obj["sessionId"] as? String,
              let ts = TranscriptTail.parseTS(obj["timestamp"]) else { return [] }
        let subtype = (obj["subtype"] as? String) ?? "unknown"
        let prevented = (obj["preventedContinuation"] as? Bool) ?? false
        return [.systemSignal(.init(
            sessionId: sessionId,
            subtype: subtype,
            preventedContinuation: prevented,
            ts: ts
        ))]
    }

    // MARK: - Helpers

    /// True when a user-role message's text is machine-generated, not typed
    /// by the owner: slash-command echoes (the CLI records the expansion as a
    /// user turn wrapped in <command-name>/<command-message>/
    /// <local-command-stdout> tags) and compact-continuation summaries (a
    /// resumed session opens with a generated recap that can DESCRIBE
    /// destructive work and would otherwise read as authorizing it). Shared
    /// with SessionObjective so the objective reader skips the same shapes.
    static func isMachineGeneratedUserText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let machinePrefixes = [
            "<command-name>",
            "<command-message>",
            "<local-command-stdout>",
            "This session is being continued from a previous conversation",
        ]
        return machinePrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// Per-hunk cap on edit text carried in the event. A `Write` can hand us a
    /// whole large file; keeping the event lean bounds EventBus + review-window
    /// memory. The review prompt truncates further; this is the outer guard.
    /// Mirrors `stringifyToolResultContent`'s truncation posture.
    static let fileEditHunkCap = 16_384

    private static func capText(_ s: String) -> String {
        guard s.utf8.count > fileEditHunkCap else { return s }
        return String(s.prefix(fileEditHunkCap)) + " …[truncated]"
    }

    /// Parse an `Edit` / `Write` / `MultiEdit` tool_use `input` into a
    /// `FileEditInfo`. Returns nil when the call carries nothing reviewable (no
    /// `file_path`, or no usable hunk) — the caller then emits nothing.
    ///
    ///   - Edit:      { file_path, old_string, new_string }              → 1 hunk
    ///   - Write:     { file_path, content }                             → 1 hunk (oldString nil)
    ///   - MultiEdit: { file_path, edits: [{ old_string, new_string }] } → 1 hunk / edit
    static func parseFileEdit(
        name: String,
        input: [String: Any],
        sessionId: String,
        toolUseId: String,
        turnUUID: String,
        ts: Date
    ) -> FileEditInfo? {
        guard let filePath = input["file_path"] as? String, !filePath.isEmpty else { return nil }

        var hunks: [FileEditHunk] = []
        switch name {
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            hunks.append(.init(oldString: nil, newString: capText(content)))
        case "Edit":
            let newString = input["new_string"] as? String
            let oldString = input["old_string"] as? String
            // An Edit with neither side is not reviewable.
            guard newString != nil || oldString != nil else { return nil }
            hunks.append(.init(
                oldString: oldString.map(capText),
                newString: capText(newString ?? "")
            ))
        case "MultiEdit":
            guard let edits = input["edits"] as? [[String: Any]] else { return nil }
            for edit in edits {
                let newString = edit["new_string"] as? String
                let oldString = edit["old_string"] as? String
                guard newString != nil || oldString != nil else { continue }
                hunks.append(.init(
                    oldString: oldString.map(capText),
                    newString: capText(newString ?? "")
                ))
            }
        default:
            return nil
        }

        guard !hunks.isEmpty else { return nil }
        return FileEditInfo(
            sessionId: sessionId,
            toolName: name,
            filePath: filePath,
            hunks: hunks,
            toolUseId: toolUseId,
            turnUUID: turnUUID,
            ts: ts
        )
    }

    /// `tool_result.content` is variable shape — string for simple results,
    /// array of blocks for complex ones. Stringify into a single chunk
    /// suitable for prompt embedding. Capped at 4 KB so a `find /` doesn't
    /// blow the prompt budget.
    static func stringifyToolResultContent(_ raw: Any?) -> String {
        let cap = 4096
        var s: String
        if let str = raw as? String {
            s = str
        } else if let arr = raw as? [[String: Any]] {
            // Each block may be {type: "text", text: "..."} — pull text.
            s = arr.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }.joined(separator: "\n")
            if s.isEmpty {
                s = (try? String(data: JSONSerialization.data(withJSONObject: arr), encoding: .utf8)) ?? ""
            }
        } else if let any = raw {
            s = "\(any)"
        } else {
            s = ""
        }
        if s.utf8.count > cap {
            let prefix = String(s.prefix(cap))
            return prefix + " …[truncated]"
        }
        return s
    }
}
