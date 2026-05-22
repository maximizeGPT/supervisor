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

        // sessionStart on first line we successfully parse (regardless of
        // type — queue-operation is usually first in real session files).
        if !emittedSessionStart,
           let sessionId = obj["sessionId"] as? String,
           let ts = parseTS(obj["timestamp"]) ?? parseTS(obj["timestamp"] as? String) {
            let cwd = (obj["cwd"] as? String) ?? "<unknown>"
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
              let ts = parseTS(obj["timestamp"]) else { return [] }
        guard let message = obj["message"] as? [String: Any] else { return [] }

        var out: [SupervisorEvent] = []

        // content may be a String (a plain user prompt) or an array of
        // blocks (containing tool_result entries).
        if let str = message["content"] as? String, !str.isEmpty {
            out.append(.userPrompt(.init(sessionId: sessionId, text: str, ts: ts)))
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
                if let str = block["text"] as? String, !str.isEmpty {
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
              let ts = parseTS(obj["timestamp"]),
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
                      name == "Bash",
                      let toolUseId = block["id"] as? String,
                      let input = block["input"] as? [String: Any] else {
                    // Non-Bash tool calls: ignored in v0.1.0. Edit/Write/Read
                    // land in v0.1.1.
                    continue
                }
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
            default:
                break  // thinking, etc.
            }
        }
        return out
    }

    // MARK: - System

    private func parseSystem(_ obj: [String: Any]) -> [SupervisorEvent] {
        guard let sessionId = obj["sessionId"] as? String,
              let ts = parseTS(obj["timestamp"]) else { return [] }
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

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func parseTS(_ raw: Any?) -> Date? {
        guard let str = raw as? String else { return nil }
        return Self.isoFormatter.date(from: str) ?? Self.isoFormatterNoFrac.date(from: str)
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
