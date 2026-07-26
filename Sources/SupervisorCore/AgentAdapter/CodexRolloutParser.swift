// CodexRolloutParser.swift
//
// Raw OpenAI Codex rollout JSONL line → SupervisorEvent. The Codex analog of
// EventParser: it produces the SAME domain events the TriageEngine already
// consumes, so a Codex session flows through the identical safety rubric,
// injection ledger, and intervention routing with no downstream change.
//
// Field reference (verified on disk, Codex 26.616.32156 / cli 0.142.0-alpha.1):
//   docs/codex-support/CODEX-FORMAT.md
//
// Codex differs from Claude Code in three ways this parser absorbs:
//
//  1. NO per-line sessionId. Codex writes the id once (session_meta + filename);
//     the parser is constructed with the id (from the filename) and stamps it on
//     every event. One parser per file — matches SessionTail's lifecycle.
//
//  2. Two parallel streams in one file. `response_item` is the model-facing
//     conversation (always present); `event_msg` is a UI stream. To avoid
//     emitting the same prose twice, OWNER PROMPTS and ASSISTANT TEXT come
//     ONLY from `event_msg` (user_message / agent_message), while SHELL COMMANDS
//     and their results — which have no event_msg equivalent in exec mode — come
//     from `response_item` (function_call / function_call_output).
//
//  3. The self-authorization surface looks different but is the same problem.
//     Codex's non-owner "user"-ish turns are `response_item message role=user`
//     carrying AGENTS.md/system context and `role=developer` permission blocks.
//     Those are IGNORED; only `event_msg.user_message` yields userPrompt(.owner).
//     This feeds the existing UserPromptOrigin / InjectionLedger machinery.
//
// The `.jsonl` channel tag is reused (these events are literally parsed from a
// JSONL file); a dedicated `.codexRollout` EventChannel case is deferred to the
// discovery-wiring stage so this slice touches no existing Observation file.

import Foundation

public final class CodexRolloutParser: TranscriptLineParser {

    private let sessionId: String
    private let projectHash: String
    private let jsonlPath: String

    /// sessionStart is emitted once, from the FIRST session_meta (the primary
    /// session). A forked/imported rollout carries a SECOND session_meta for the
    /// parent thread — this latch keeps that from re-emitting a start with the
    /// parent's cwd.
    private var emittedSessionStart = false

    /// call_id of every function_call we treated as a shell command, so the
    /// matching function_call_output is emitted as a bashToolResult (and other
    /// tools' outputs are ignored) — mirrors EventParser's Bash id registry.
    private var shellCallIds = Set<String>()

    /// Monotonic id for assistantText turnUUID (Codex agent_message carries no
    /// per-item uuid; downstream only needs a stable-unique value).
    private var assistantSeq = 0

    public init(sessionId: String, projectHash: String, jsonlPath: String) {
        self.sessionId = sessionId
        self.projectHash = projectHash
        self.jsonlPath = jsonlPath
    }

    /// Function-call `name`s that denote a shell command across Codex modes /
    /// model tool configs. Defensive superset: exec_command is what this build
    /// emits; the others guard against interactive/desktop/model variance so the
    /// destructive-action surface is never silently dropped.
    private static let shellToolNames: Set<String> = [
        "exec_command", "shell", "bash", "local_shell", "container.exec",
    ]

    public func parse(line: String) -> [SupervisorEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return [] }
        let ts = TranscriptTail.parseTS(obj["timestamp"]) ?? Date()

        switch type {
        case "session_meta":
            return parseSessionMeta(payload, ts: ts)
        case "event_msg":
            return parseEventMsg(payload, ts: ts)
        case "response_item":
            return parseResponseItem(payload, ts: ts)
        default:
            return []  // turn_context and anything future — ignored
        }
    }

    // MARK: - session_meta → sessionStart

    private func parseSessionMeta(_ payload: [String: Any], ts: Date) -> [SupervisorEvent] {
        guard !emittedSessionStart else { return [] }
        guard let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return [] }
        var branch: String? = nil
        if let git = payload["git"] as? [String: Any] {
            branch = (git["branch"] as? String) ?? (git["current_branch"] as? String)
        }
        emittedSessionStart = true
        return [.sessionStart(.init(
            sessionId: sessionId,
            cwd: cwd,
            gitBranch: branch,
            projectHash: projectHash,
            jsonlPath: jsonlPath,
            ts: ts
        ))]
    }

    // MARK: - event_msg → userPrompt (owner) / assistantText

    private func parseEventMsg(_ payload: [String: Any], ts: Date) -> [SupervisorEvent] {
        guard let sub = payload["type"] as? String else { return [] }
        switch sub {
        case "user_message":
            // The ONLY owner-prompt signal. Codex fires this once for the human's
            // turn; the AGENTS.md/system context that pollutes response_item user
            // messages does not appear here.
            guard let msg = payload["message"] as? String, !msg.isEmpty else { return [] }
            return [.userPrompt(.init(sessionId: sessionId, text: msg, ts: ts, origin: .owner))]
        case "agent_message":
            guard let msg = payload["message"] as? String, !msg.isEmpty else { return [] }
            assistantSeq += 1
            return [.assistantText(.init(
                sessionId: sessionId, text: msg,
                turnUUID: "codex-agent-\(assistantSeq)", ts: ts
            ))]
        default:
            return []  // task_started, task_complete, token_count — not consumed
        }
    }

    // MARK: - response_item → bashToolCall / bashToolResult

    private func parseResponseItem(_ payload: [String: Any], ts: Date) -> [SupervisorEvent] {
        guard let sub = payload["type"] as? String else { return [] }
        switch sub {
        case "function_call":
            guard let name = payload["name"] as? String,
                  Self.shellToolNames.contains(name),
                  let callId = payload["call_id"] as? String,
                  let command = Self.extractShellCommand(payload) else { return [] }
            shellCallIds.insert(callId)
            return [.bashToolCall(.init(
                sessionId: sessionId, command: command, description: nil,
                toolUseId: callId, turnUUID: callId, ts: ts
            ))]
        case "local_shell_call":
            // Alternate shell shape (some model/tool configs): the command lives
            // in a top-level `action`, not in stringified `arguments`.
            guard let callId = (payload["call_id"] as? String) ?? (payload["id"] as? String),
                  let command = Self.extractShellCommand(payload) else { return [] }
            shellCallIds.insert(callId)
            return [.bashToolCall(.init(
                sessionId: sessionId, command: command, description: nil,
                toolUseId: callId, turnUUID: callId, ts: ts
            ))]
        case "function_call_output", "custom_tool_call_output":
            guard let callId = payload["call_id"] as? String,
                  shellCallIds.contains(callId) else { return [] }
            let raw = Self.stringifyOutput(payload["output"])
            return [.bashToolResult(.init(
                sessionId: sessionId, toolUseId: callId,
                output: Self.cleanOutput(raw), isError: Self.outputIndicatesError(raw), ts: ts
            ))]
        default:
            // message (assistant text comes from event_msg to avoid dupes; user/
            // developer messages are non-owner context), reasoning — ignored.
            return []
        }
    }

    // MARK: - Shell command extraction

    /// Pull the shell command string from a function_call / local_shell_call
    /// payload. Tries, in order: stringified `arguments` → {cmd | command};
    /// then a top-level `action` → {command}. Command arrays are shell-joined.
    static func extractShellCommand(_ payload: [String: Any]) -> String? {
        if let argsStr = payload["arguments"] as? String,
           let argsData = argsStr.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
            if let cmd = args["cmd"] as? String, !cmd.isEmpty { return cmd }
            if let cmd = args["command"] as? String, !cmd.isEmpty { return cmd }
            if let arr = args["command"] as? [String], !arr.isEmpty { return joinArgv(arr) }
        }
        if let action = payload["action"] as? [String: Any] {
            if let cmd = action["command"] as? String, !cmd.isEmpty { return cmd }
            if let arr = action["command"] as? [String], !arr.isEmpty { return joinArgv(arr) }
        }
        return nil
    }

    /// Codex often invokes shells as `["bash","-lc","<script>"]` or
    /// `["/bin/zsh","-lc","<script>"]`. When the argv is a shell wrapper, the
    /// real command is the trailing script — surface THAT so the rubric vets the
    /// script, not the `-lc` boilerplate. Otherwise space-join.
    static func joinArgv(_ argv: [String]) -> String {
        if argv.count >= 3 {
            let head = (argv[0] as NSString).lastPathComponent
            if (head == "bash" || head == "zsh" || head == "sh"), argv[1] == "-lc" || argv[1] == "-c" {
                return argv[2...].joined(separator: " ")
            }
        }
        return argv.joined(separator: " ")
    }

    // MARK: - Output cleaning + error detection

    /// Strip Codex's wrapper header ("Chunk ID / Wall time / Process exited with
    /// code N / Original token count / Output:\n<body>") down to <body>. Keeps
    /// the tool output aligned with Claude Code's bashToolResult.output (the raw
    /// result), with the exit status captured separately by outputIndicatesError.
    static func cleanOutput(_ raw: String) -> String {
        let marker = "Output:\n"
        let body: String
        if let r = raw.range(of: marker) {
            body = String(raw[r.upperBound...])
        } else {
            body = raw
        }
        let cap = 4096
        if body.utf8.count > cap { return String(body.prefix(cap)) + " …[truncated]" }
        return body
    }

    /// Codex encodes the exit status in the output header ("Process exited with
    /// code N"). Nonzero → error, so bashToolResult.isError matches Claude Code
    /// semantics (which drives the result-arrival re-triage of failed commands).
    static func outputIndicatesError(_ raw: String) -> Bool {
        guard let r = raw.range(of: "Process exited with code ") else { return false }
        let rest = raw[r.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        if let code = Int(digits) { return code != 0 }
        return false
    }

    static func stringifyOutput(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let dict = raw as? [String: Any] {
            if let s = dict["output"] as? String { return s }
            if let s = dict["content"] as? String { return s }
            return (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? ""
        }
        if let any = raw { return "\(any)" }
        return ""
    }
}
