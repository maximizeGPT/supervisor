// SessionObjective.swift — the session's objective, read from its transcript.
//
// The objective is the user's opening ask — the through-line the dispatch loop
// drives toward (PRODUCT-DIRECTION.md, "drive a session to its objective"). The
// loop used to reason only locally ("obvious mechanical follow-on?") and idle
// when the immediate thread looked done, because it had no model of what the
// user was actually trying to build. Anchoring on the objective gives it a next
// step even when repo state is quiet.
//
// Source of truth is the JSONL transcript, not a live capture: the JSONL IS the
// record, so the objective survives Supervisor restarts and is available even
// for sessions that started before Supervisor was watching (the first user turn
// has long since rolled off the rolling event window by dispatch time).

import Foundation

public enum SessionObjective {

    /// The session's objective: its first plain user prompt, or nil if none is
    /// found. A "plain user prompt" is a `type == "user"` line whose
    /// `message.content` is a non-empty String — the opening instruction. Lines
    /// whose content is an array (tool_result user messages) are skipped; they
    /// aren't the objective. Reads only the head of the file because the opening
    /// prompt sits at the top, so it stays cheap on multi-MB transcripts.
    public static func read(
        sessionId: String,
        projectsDir: URL? = nil,
        headBytes: Int = 131_072
    ) -> String? {
        guard let url = DesktopConversationTargeter.transcriptURL(sessionId: sessionId, projectsDir: projectsDir),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes), !data.isEmpty else { return nil }
        // Lossy decode never fails (a multibyte char clipped at the byte budget
        // becomes a replacement char, not a nil result).
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // If we hit the byte budget the final line may be truncated — drop it so
        // we never parse a half-line. (When the file is smaller than headBytes
        // the last line is complete, so keep it.)
        if data.count >= headBytes, lines.count > 1 { lines.removeLast() }

        for line in lines {
            guard line.contains("\"user\""),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "user",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? String else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
