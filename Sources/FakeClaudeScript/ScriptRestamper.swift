// ScriptRestamper.swift — pure line-rewriting for FakeClaudeCLI's --script mode.
//
// The E2E harness authors scenario JSONL fixtures ahead of time, but two of
// Supervisor's ingest gates make stale fixtures invisible: TriageEngine
// discards events older than ~120s (staleEventThresholdSeconds), and
// SessionDiscovery only tails transcripts modified within its 48h recency
// window. So a fixture replayed verbatim would be silently dropped. This
// restamps each line's `timestamp` to "now" at replay time, making a
// months-old fixture look like a live session.
//
// Lives in its own tiny Foundation-only library (not inside the FakeClaudeCLI
// executable) for one reason: XCTest can't import an executable target, and
// FakeClaudeCLI deliberately doesn't depend on SupervisorCore (it must stay
// independent of the code under test). A leaf library is the only home that
// keeps both properties AND lets Tests/SupervisorCoreTests exercise the logic.

import Foundation

public enum ScriptRestamper {

    /// Fixture placeholder for the replaying process's cwd. Fixtures can't
    /// know the harness's per-RUN_ID fake home ahead of time, and the
    /// ProcessLocator matches sessions to processes BY cwd — so fixtures
    /// write `__CWD__` and the replayer substitutes its real, current value.
    public static let cwdPlaceholder = "__CWD__"

    /// Fixture placeholder for the session id (mirrors `--session-id`, which
    /// tests use to get a predictable JSONL filename; the events inside must
    /// carry the same id or EventParser attributes them to a ghost session).
    public static let sessionIdPlaceholder = "__SESSION_ID__"

    /// Rewrite one fixture line for replay:
    ///   1. Substitute `__CWD__` / `__SESSION_ID__` placeholders (plain text,
    ///      before JSON parsing, so they work anywhere in the line).
    ///   2. Restamp the top-level `timestamp` field to `now` (ISO-8601 with
    ///      fractional seconds — the shape Claude Code writes and
    ///      EventParser expects). Claude-shaped events carry exactly one
    ///      timestamp and it is top-level; nested objects are left alone.
    ///
    /// Non-JSON lines (blank lines, comments a fixture author snuck in) pass
    /// through with only placeholder substitution — the tailer skips
    /// unparseable lines anyway, and silently EATING a malformed fixture line
    /// would make fixture bugs harder to see than letting it flow through.
    ///
    /// Note: re-serialization does not preserve key order. Consumers parse
    /// the JSON (EventParser), so order is immaterial.
    public static func restampLine(
        _ line: String,
        now: Date,
        cwd: String? = nil,
        sessionId: String? = nil
    ) -> String {
        var substituted = line
        if let cwd {
            substituted = substituted.replacingOccurrences(of: cwdPlaceholder, with: cwd)
        }
        if let sessionId {
            substituted = substituted.replacingOccurrences(of: sessionIdPlaceholder, with: sessionId)
        }

        guard let data = substituted.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return substituted }

        if obj["timestamp"] != nil {
            obj["timestamp"] = isoFormatter.string(from: now)
        }

        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let outString = String(data: out, encoding: .utf8)
        else { return substituted }
        return outString
    }

    /// Same ISO-8601 shape FakeClaudeCLI's synthetic mode has always written
    /// (internet date-time + fractional seconds), matching real Claude Code
    /// transcripts.
    public static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
