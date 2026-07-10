// RecoveryDocWriter.swift — v0.1.6 intervention recovery context.
//
// When the router fires SIGSTOP or SIGTERM on a Claude Code session,
// it writes a markdown recovery document to
//   ~/Library/Application Support/Supervisor/recovery/
//   <ISO8601>-<uuid-short>-<action>.md
// IMMEDIATELY BEFORE the signal lands. The doc is the handoff: the user
// reads it to decide what to do next; the resumed-or-restarted assistant
// reads it to know what was happening when it was stopped.
//
// Generation timing is non-negotiable: the doc MUST be written before
// the signal goes out. For pause that's a soft requirement; for kill
// it's essential because the assistant process is gone after SIGTERM
// and any state derivation from the live process becomes impossible.
//
// Retention: the last `retentionLimit` files (default 50) are kept;
// older ones are deleted on every successful write.
//
// v0.1.8: write() is async with a configurable timeout (default 2s).
// The synchronous String.write(to:atomically:encoding:) call races
// against a Task.sleep sentinel in a TaskGroup. On a healthy local
// SSD the write completes in <1ms; the timeout exists for pathological
// cases (frozen NFS mount, stalled encrypted-disk lock, FUSE driver
// hang) that would otherwise block the router thread indefinitely,
// preventing SIGSTOP/SIGTERM from ever going out.

import Darwin
import Foundation

/// What the router did (or is about to do) — passed to the writer so the
/// "What to do next" section can branch on action without re-reading
/// the InterventionOutcome enum (which carries other fields not
/// relevant to the doc).
public enum RecoveryAction: String, Sendable {
    case pause
    case kill
}

public struct RecoveryDocWriter: Sendable {

    public let directory: URL
    public let retentionLimit: Int
    public let timeoutSeconds: Double
    private let trace: TraceLog
    private let writeOp: @Sendable (String, URL) throws -> Void

    public init(
        directory: URL,
        retentionLimit: Int = 50,
        timeoutSeconds: Double = 2.0,
        trace: TraceLog = .shared,
        writeOperation: (@Sendable (String, URL) throws -> Void)? = nil
    ) {
        self.directory = directory
        self.retentionLimit = retentionLimit
        self.timeoutSeconds = timeoutSeconds
        self.trace = trace
        self.writeOp = writeOperation ?? { content, url in
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Write the recovery doc for an upcoming pause or kill. Returns the
    /// URL the doc was written to, or `nil` on filesystem failure or
    /// timeout.
    ///
    /// Caller (the router) is expected to invoke this BEFORE sending
    /// SIGSTOP/SIGTERM so that for kill, the process state can still be
    /// referenced if needed (the PID is known before the signal — we
    /// pass it in here, not derived from a now-dead process).
    ///
    /// The write races against a `timeoutSeconds` sentinel. On timeout
    /// the method returns nil; the router's existing fallback (inline
    /// banner copy from v0.1.4) handles it.
    @discardableResult
    public func write(
        decision: TriageDecision,
        action: RecoveryAction,
        pid: pid_t
    ) async -> URL? {
        ensureDirExists()
        let now = Date()
        let url = directory.appendingPathComponent(filename(now: now,
                                                            sessionId: decision.sessionId,
                                                            action: action))
        let markdown = buildMarkdown(decision: decision, action: action, pid: pid, ts: now)
        let op = writeOp
        let writeResult: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try op(markdown, url)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
                return false // timeout sentinel
            }
            for await result in group {
                group.cancelAll()
                return result
            }
            return false
        }
        if writeResult {
            trace.emit("recovery", "wrote \(url.lastPathComponent) action=\(action.rawValue) pid=\(pid)")
            rotateIfNeeded()
            return url
        } else {
            trace.emit("recovery", "TIMEOUT_OR_ERROR writing \(url.lastPathComponent) timeout=\(timeoutSeconds)s")
            return nil
        }
    }

    // MARK: - Naming

    private func filename(now: Date, sessionId: String, action: RecoveryAction) -> String {
        // ISO8601 but filename-safe (no colons).
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let stamp = iso.string(from: now).replacingOccurrences(of: ":", with: "-")
        // Shorten the session UUID to its first 8 chars to keep the filename
        // tractable when listed in Finder.
        let shortId = String(sessionId.prefix(8))
        return "\(stamp)-\(shortId)-\(action.rawValue).md"
    }

    // MARK: - Directory + retention

    private func ensureDirExists() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: [.creationDateKey],
                                                         options: [.skipsHiddenFiles])
        else { return }
        let mdFiles = entries.filter { $0.pathExtension == "md" }
        guard mdFiles.count > retentionLimit else { return }
        // Sort by creation date ascending → oldest first → delete excess.
        let sorted = mdFiles.sorted { a, b in
            let ad = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return ad < bd
        }
        let toDelete = sorted.prefix(sorted.count - retentionLimit)
        for url in toDelete {
            try? fm.removeItem(at: url)
        }
        trace.emit("recovery", "rotated, dropped \(toDelete.count) old docs (keep \(retentionLimit))")
    }

    // MARK: - Markdown rendering

    private func buildMarkdown(decision: TriageDecision,
                                action: RecoveryAction,
                                pid: pid_t,
                                ts: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tsString = iso.string(from: ts)
        let shortId = String(decision.sessionId.prefix(8))
        let c = decision.candidate

        var out: [String] = []

        out.append("# Intervention recovery: \(action.rawValue) on session \(shortId)")
        out.append("")
        out.append("## What happened")
        out.append("")
        out.append("Supervisor fired **\(action.rawValue)** on Claude Code at `\(tsString)`.")
        out.append("- **Reason category**: `\(c.category)`")
        out.append("- **Severity**: `\(c.severity.rawValue)`")
        out.append("")
        out.append("**Plain reasoning (what the banner said):**")
        out.append("")
        out.append(quoteBlock(c.reasoningPlain))
        out.append("")
        out.append("**Technical reasoning (full):**")
        out.append("")
        out.append(quoteBlock(c.reasoningTechnical))
        out.append("")
        if let asym = c.asymmetryNote, !asym.isEmpty {
            out.append("**Asymmetry note:**")
            out.append("")
            out.append(quoteBlock(asym))
            out.append("")
        }

        out.append("## What Claude Code was doing")
        out.append("")
        out.append("- **Working directory**: `\(decision.cwd ?? "(unknown)")`")
        out.append("- **Session ID**: `\(decision.sessionId)`")
        out.append("- **Process PID**: `\(pid)`")
        out.append("")
        out.append("**User's most recent prompt:**")
        out.append("")
        let userQuote = decision.lastUserPrompt.map { String($0.prefix(500)) } ?? "(no user prompt in the recent window)"
        out.append(quoteBlock(userQuote))
        out.append("")
        out.append("**The action that triggered the intervention:**")
        out.append("")
        out.append("```")
        out.append(c.matchedCommand)
        out.append("```")
        out.append("")

        out.append("**Last \(min(10, decision.recentEvents.filter { ifBashToolCall($0) }.count)) tool calls before the intervention** (chronological):")
        out.append("")
        let recentToolCalls = decision.recentEvents
            .compactMap { event -> BashToolCallInfo? in
                if case let .bashToolCall(info) = event { return info } else { return nil }
            }
            .suffix(10)
        if recentToolCalls.isEmpty {
            out.append("_No prior tool calls in the window._")
        } else {
            let tsFmt = ISO8601DateFormatter()
            tsFmt.formatOptions = [.withInternetDateTime]
            for call in recentToolCalls {
                let t = tsFmt.string(from: call.ts)
                let cmd = call.command.replacingOccurrences(of: "\n", with: " ⏎ ")
                let head = String(cmd.prefix(160))
                let suffix = cmd.count > 160 ? "…" : ""
                out.append("- `[\(t)]` `\(head)\(suffix)`")
            }
        }
        out.append("")

        out.append("## What to do next")
        out.append("")
        switch action {
        case .pause:
            appendPauseRecovery(into: &out, pid: pid, category: c.category, command: c.matchedCommand)
        case .kill:
            appendKillRecovery(into: &out, cwd: decision.cwd, ts: tsString,
                                reasoningPlain: c.reasoningPlain,
                                command: c.matchedCommand,
                                userPrompt: decision.lastUserPrompt,
                                recentToolCalls: recentToolCalls)
        }

        return out.joined(separator: "\n")
    }

    private func quoteBlock(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    private func ifBashToolCall(_ event: SupervisorEvent) -> Bool {
        if case .bashToolCall = event { return true }
        return false
    }

    private func appendPauseRecovery(into out: inout [String],
                                      pid: pid_t,
                                      category: String,
                                      command: String) {
        out.append("The Claude Code process is paused (SIGSTOP), PID **\(pid)**.")
        out.append("All state is intact. To resume:")
        out.append("")
        out.append("```sh")
        // The pause stops the whole process group (so an already-forked
        // shell child freezes too); the resume must be group-wide for the
        // same reason, or the parent wakes and hangs on a stopped child.
        out.append("kill -CONT -\"$(ps -o pgid= -p \(pid) | tr -d ' ')\"")
        out.append("```")
        out.append("")
        out.append("Before resuming, decide: **was the flagged action correct?**")
        out.append("")
        out.append("- **If YES** (the action was authorized and safe): resume,")
        out.append("  then paste this into the Claude Code prompt:")
        out.append("    ```")
        out.append("    Supervisor paused you on \(category) for `\(command)`.")
        out.append("    User has reviewed and authorized. Continue.")
        out.append("    ```")
        out.append("- **If NO** (the action was wrong): resume,")
        out.append("  then paste:")
        out.append("    ```")
        out.append("    Supervisor paused you on \(category) for `\(command)`.")
        out.append("    User has reviewed and the action was NOT correct.")
        out.append("    Do not retry. Instead: <user fills in or omits>")
        out.append("    ```")
        out.append("- **If UNSURE**: leave paused. Read the technical reasoning")
        out.append("  and recent tool calls above to decide.")
    }

    private func appendKillRecovery(into out: inout [String],
                                     cwd: String?,
                                     ts: String,
                                     reasoningPlain: String,
                                     command: String,
                                     userPrompt: String?,
                                     recentToolCalls: ArraySlice<BashToolCallInfo>) {
        let cwdDisplay = cwd ?? "(unknown, the session's cwd was not captured)"
        out.append("The Claude Code session is dead. To continue the work,")
        out.append("start a new `claude` invocation in `\(cwdDisplay)` and paste")
        out.append("this as your first message:")
        out.append("")
        out.append("---")
        out.append("")
        out.append("Previous Claude Code session was killed by Supervisor (a safety")
        out.append("harness) at `\(ts)`. The kill fired because:")
        out.append("")
        out.append(quoteBlock(reasoningPlain))
        out.append("")
        out.append("You were working on: \(taskSummary(userPrompt: userPrompt) )")
        out.append("")
        out.append("**Progress before the kill (recent tool calls):**")
        out.append("")
        if recentToolCalls.isEmpty {
            out.append("_No tool calls in the captured window._")
        } else {
            let tsFmt = ISO8601DateFormatter()
            tsFmt.formatOptions = [.withInternetDateTime]
            for call in recentToolCalls {
                let t = tsFmt.string(from: call.ts)
                let cmd = call.command
                    .replacingOccurrences(of: "\n", with: " ⏎ ")
                let head = String(cmd.prefix(160))
                out.append("- `[\(t)]` `\(head)\(cmd.count > 160 ? "…" : "")`")
            }
        }
        out.append("")
        out.append("**Do NOT retry the specific action that triggered the kill:**")
        out.append("")
        out.append("```")
        out.append(command)
        out.append("```")
        out.append("")
        out.append("Determine an alternative safe path forward. If the only safe path")
        out.append("is to stop and ask the user, write a status note to")
        out.append("`/trial-notes.md` (or wherever the session journaling lives) and")
        out.append("stop.")
        out.append("")
        out.append("---")
    }

    /// Best-effort one-line summary of what the killed session was up to.
    /// For v0.1.6, just quotes the user's most recent prompt (truncated).
    /// A future PR can LLM-summarize from the full JSONL.
    private func taskSummary(userPrompt: String?) -> String {
        guard let p = userPrompt, !p.isEmpty else {
            return "(unknown, no recent user prompt was captured in the window)"
        }
        let oneLine = p.replacingOccurrences(of: "\n", with: " ")
        return "the user's most recent prompt was: \"\(String(oneLine.prefix(240)))\(oneLine.count > 240 ? "…" : "")\""
    }
}
