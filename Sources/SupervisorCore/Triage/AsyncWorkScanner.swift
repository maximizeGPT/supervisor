// AsyncWorkScanner.swift - v0.2.0 M7. Detection of OUTSTANDING async work for the
// stall watchdog.
//
// THE PROBLEM. The stall watchdog only fires when a background task or sub-agents
// are actually outstanding. But Supervisor's PARSED event stream
// (SupervisorEvent) deliberately surfaces only Bash tool calls, and it does NOT
// carry (a) the `run_in_background` flag on a Bash call, nor (b) any Task/Agent
// (sub-agent) tool_use at all - the EventParser drops every non-Bash tool_use and
// keeps only `command` + `description` off a Bash call. So the parsed window
// cannot tell us whether a detached background task or a sub-agent is in flight.
//
// THE CHOICE. Rather than widen the core event model + the redaction/triage path
// (which the M7 scope forbids), this scanner reads the session's transcript JSONL
// DIRECTLY - the SAME file the InterventionRouter already reads to confirm an
// inject landed - and looks at the raw `tool_use` / `tool_result` blocks that the
// parser discards. This keeps M7 fully ADDITIVE: no change to SupervisorEvent,
// EventParser, the triage prompt, or redaction. The transcript is local JSONL; no
// network, no model call.
//
// WHAT COUNTS AS AN OUTSTANDING ASYNC LAUNCH.
//   - A background Bash:   a `tool_use` with name == "Bash" and input
//     `run_in_background == true`.
//   - A sub-agent:         a `tool_use` whose name is "Task" or "Agent" (the
//     sub-agent / fan-out tools).
// Each launch has an `id`; its completion is a later `tool_result` with a
// matching `tool_use_id`. We pair them: a launch with NO matching result is
// OUTSTANDING.
//
// THE HEURISTIC FALLBACK (documented, per spec). Precise launch/result pairing is
// preferred, but a background task's result can be late, batched, or (for a truly
// detached process) never written as a tool_result at all. So the scanner ALSO
// applies a recency + silence heuristic: if a qualifying launch was observed
// RECENTLY (within `lookbackSeconds` of the latest transcript activity) and the
// session has since gone quiet, it is treated as outstanding even if a result was
// not positively paired. Concretely, `outstanding` is true when there is at least
// one qualifying launch AND (it is unpaired OR it is the most recent meaningful
// activity i.e. nothing of substance happened after it). Token size is a SOFT
// hint only and is NOT required here - we never gate on an (unobservable) detached
// token count; the presence + silence is the signal.
//
// COST. The scanner reads the tail of the JSONL (capped) and parses line JSON; it
// runs only on the watchdog path (a session that is already idle past the
// interval), so it is off the hot per-event path entirely.

import Foundation

/// Detects whether a session has an OUTSTANDING background task or sub-agent by
/// reading its transcript JSONL. A small value type; the transcript locator is
/// injected so tests can point at a fixture file (and production uses the real
/// `~/.claude/projects` lookup via DesktopConversationTargeter).
public struct AsyncWorkScanner: Sendable {

    /// The async-launch tool names that count as a sub-agent fan-out.
    static let subAgentToolNames: Set<String> = ["Task", "Agent"]

    /// How far back from the latest transcript activity a launch may sit and
    /// still be considered "recent" for the heuristic-fallback arm. Default 4h
    /// (the loop's outer horizon) so a long-but-legitimate background task is not
    /// prematurely declared finished; the watchdog's own silence interval is what
    /// makes it actionable, this only bounds the lookback.
    public static let defaultLookbackSeconds: TimeInterval = 4 * 60 * 60

    /// Max bytes of the transcript tail to read. A background-task launch + the
    /// surrounding turns are tiny; we only need recent history. Caps the read so a
    /// huge transcript never blows memory on the watchdog path.
    public static let defaultTailBytes = 512 * 1024

    public let lookbackSeconds: TimeInterval
    public let tailBytes: Int
    /// Resolve a session id to its transcript JSONL URL. Injected for tests;
    /// production passes the DesktopConversationTargeter lookup.
    private let transcriptURL: @Sendable (String) -> URL?
    /// Observability hook, fired exactly once per actual tail-read + parse in
    /// `scan()`. Defaults to a no-op; tests inject a counter to assert that the
    /// engine's file-identity cache prevents a redundant re-parse of an unchanged
    /// transcript (Finding 1a). Production never sets it.
    private let onScanParse: @Sendable () -> Void

    public init(
        lookbackSeconds: TimeInterval = AsyncWorkScanner.defaultLookbackSeconds,
        tailBytes: Int = AsyncWorkScanner.defaultTailBytes,
        transcriptURL: @escaping @Sendable (String) -> URL? = { sessionId in
            DesktopConversationTargeter.transcriptURL(sessionId: sessionId)
        },
        onScanParse: @escaping @Sendable () -> Void = {}
    ) {
        self.lookbackSeconds = lookbackSeconds
        self.tailBytes = tailBytes
        self.transcriptURL = transcriptURL
        self.onScanParse = onScanParse
    }

    /// The cheap stat of a session's transcript file: its byte size and last
    /// modification time. Reads NO content (an `attributesOfItem` stat only), so
    /// the watchdog can decide on each tick whether the transcript changed since
    /// the last scan and skip a redundant tail-read + full JSON parse when it did
    /// not (Finding 1a). Returns nil when the transcript is missing/unreadable;
    /// the caller then treats it as "no cache key" and falls through to a scan
    /// (which itself returns `.none` for a missing file - no fabricated stall).
    ///
    /// Correctness: if neither size nor mtime advanced, no line was appended or
    /// rewritten, so the outstanding determination over the same bytes cannot
    /// have changed - reusing the prior Scan is exact, not approximate.
    public struct FileIdentity: Sendable, Equatable {
        public let size: UInt64
        public let mtime: Date
        public init(size: UInt64, mtime: Date) {
            self.size = size
            self.mtime = mtime
        }
    }

    public func fileIdentity(sessionId: String) -> FileIdentity? {
        guard let url = transcriptURL(sessionId),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date.distantPast
        return FileIdentity(size: size, mtime: mtime)
    }

    /// The result of scanning a session for outstanding async work.
    public struct Scan: Sendable, Equatable {
        /// True when a background task or sub-agent is outstanding (see the
        /// file-level "WHAT COUNTS" + heuristic-fallback docs). This is the bool
        /// the watchdog gates on.
        public var outstanding: Bool
        /// How many qualifying launches (background Bash + sub-agent) were seen at
        /// all, for the trace. 0 means the watchdog never fires (no async work).
        public var launchCount: Int
        /// How many of those had NO positively-paired completion. >0 is the
        /// strong (non-heuristic) signal; the trace distinguishes it from the
        /// recency-only arm.
        public var unpairedCount: Int
        /// The model id observed on the transcript's assistant turns, if any.
        /// This is the OPPORTUNISTIC model read that feeds WatchdogPolicy's
        /// model-awareness; nil when the transcript carried none (the watchdog
        /// then uses the default interval). The "use it if visible" extension
        /// point named in the spec.
        public var observedModel: String?

        /// PART B (stall failure-mode classification) signals. Collected in the
        /// SAME single pass over the transcript lines that the outstanding
        /// determination uses - no extra read, no extra parse. They feed
        /// StallClassifier.classify to label WHY a session stalled. All are
        /// derived from what the scanner already reads (the raw tool_use /
        /// tool_result / text blocks); none widens the core event model.

        /// True when the MOST RECENT outstanding (or recency-live) launch is a
        /// sub-agent (Task/Agent), i.e. the silence is a sub-agent fan-out
        /// rather than a single background Bash going quiet.
        public var lastOutstandingIsSubAgent: Bool
        /// True when the tail of the transcript looks like Claude Code is
        /// waiting on the human (an assistant question with no following user
        /// turn). A stall here is "awaiting input", not a dead background task.
        public var awaitingInputSignal: Bool
        /// True when a recent assistant/result block carries a rate-limit /
        /// overloaded marker (e.g. "rate limit", "429", "overloaded").
        public var rateLimitSignal: Bool
        /// True when a recent result block carries a hard-failure marker that
        /// reads as a crash (e.g. "panic", "segmentation fault", "killed",
        /// "fatal error", a process-exit/abort line).
        public var crashSignal: Bool

        public init(
            outstanding: Bool,
            launchCount: Int,
            unpairedCount: Int,
            observedModel: String?,
            lastOutstandingIsSubAgent: Bool = false,
            awaitingInputSignal: Bool = false,
            rateLimitSignal: Bool = false,
            crashSignal: Bool = false
        ) {
            self.outstanding = outstanding
            self.launchCount = launchCount
            self.unpairedCount = unpairedCount
            self.observedModel = observedModel
            self.lastOutstandingIsSubAgent = lastOutstandingIsSubAgent
            self.awaitingInputSignal = awaitingInputSignal
            self.rateLimitSignal = rateLimitSignal
            self.crashSignal = crashSignal
        }

        /// The empty scan: nothing outstanding. Used when the transcript can't be
        /// found / read (we never fabricate a stall from a missing file).
        public static let none = Scan(outstanding: false, launchCount: 0, unpairedCount: 0, observedModel: nil)
    }

    /// Scan a session's transcript for outstanding async work. Reads the capped
    /// tail of the JSONL, walks the raw tool_use / tool_result blocks, pairs
    /// launches to completions, and applies the recency + silence heuristic.
    /// Returns `.none` when the transcript is missing or unreadable (no
    /// fabricated stalls). `now` is injected so the recency arm is deterministic
    /// in tests.
    public func scan(sessionId: String, now: Date) -> Scan {
        guard let url = transcriptURL(sessionId), let lines = readTailLines(url) else {
            return .none
        }
        // One real tail-read + parse just happened; let an injected probe count it
        // so the engine's file-identity cache can be verified to elide redundant
        // re-parses of an unchanged transcript (Finding 1a). No-op in production.
        onScanParse()
        return Self.classify(lines: lines, now: now, lookbackSeconds: lookbackSeconds)
    }

    // MARK: - Pure classification (testable without a file)

    /// One observed async launch.
    private struct Launch {
        let id: String
        let ts: Date
        let kind: String   // "bg_bash" | "subagent:<name>"
    }

    /// Classify already-read transcript lines. PURE (no I/O): tests feed lines
    /// directly. Walks every line once, collecting:
    ///   - async launches (background Bash + Task/Agent), by tool_use id + ts,
    ///   - the set of tool_result ids seen (completions),
    ///   - the timestamp of the latest MEANINGFUL activity after each launch
    ///     (any assistant text / non-launch tool_use / tool_result), to drive the
    ///     "nothing of substance happened after the launch" heuristic,
    ///   - the most recent assistant `model` string (opportunistic, for policy).
    static func classify(lines: [String], now: Date, lookbackSeconds: TimeInterval) -> Scan {
        var launches: [Launch] = []
        var completedIds = Set<String>()
        var observedModel: String?
        // Timestamp of the latest substantive activity overall (used to bound the
        // lookback window for the recency arm).
        var latestActivityTs: Date?
        // For each launch id, the latest substantive-activity timestamp strictly
        // after it (set as we walk forward).
        var latestActivityTsAfterLaunch: [String: Date] = [:]

        // PART B signal accumulators, filled in the same single pass.
        // The kind+text of the LAST meaningful block seen (drives awaiting-input:
        // a trailing assistant question with no following user turn).
        var lastBlockRole: String?      // "assistant" | "user"
        var lastAssistantText: String = ""
        var sawUserAfterLastAssistant = false
        var rateLimitSignal = false
        var crashSignal = false

        func note(activity ts: Date) {
            if latestActivityTs == nil || ts > latestActivityTs! { latestActivityTs = ts }
            // Any launch already seen gets this as "activity after it".
            for l in launches where ts > l.ts {
                if let prev = latestActivityTsAfterLaunch[l.id], prev >= ts { continue }
                latestActivityTsAfterLaunch[l.id] = ts
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            let ts = parseTS(obj["timestamp"]) ?? Date.distantPast

            switch type {
            case "assistant":
                guard let message = obj["message"] as? [String: Any] else { continue }
                if let m = message["model"] as? String, !m.isEmpty { observedModel = m }
                guard let content = message["content"] as? [[String: Any]] else { continue }
                for block in content {
                    guard let btype = block["type"] as? String else { continue }
                    if btype == "tool_use", let name = block["name"] as? String, let id = block["id"] as? String {
                        if name == "Bash",
                           let input = block["input"] as? [String: Any],
                           isBackground(input) {
                            launches.append(Launch(id: id, ts: ts, kind: "bg_bash"))
                        } else if subAgentToolNames.contains(name) {
                            launches.append(Launch(id: id, ts: ts, kind: "subagent:\(name)"))
                        } else {
                            // A non-launch tool_use is substantive activity (the
                            // worker is doing other things, not blocked waiting).
                            note(activity: ts)
                        }
                    } else if btype == "text" {
                        note(activity: ts)
                        // PART B: track the trailing assistant text so a later
                        // awaiting-input check can ask "did the assistant end on a
                        // question with no user reply after it." A new assistant
                        // text block resets the "user replied since" flag.
                        if let text = block["text"] as? String, !text.isEmpty {
                            lastBlockRole = "assistant"
                            lastAssistantText = text
                            sawUserAfterLastAssistant = false
                        }
                        if let text = block["text"] as? String {
                            if Self.containsRateLimitMarker(text) { rateLimitSignal = true }
                        }
                    }
                }
            case "user":
                // tool_result blocks complete a launch; plain user text is activity.
                if let message = obj["message"] as? [String: Any] {
                    if let blocks = message["content"] as? [[String: Any]] {
                        for block in blocks {
                            guard let btype = block["type"] as? String else { continue }
                            if btype == "tool_result", let id = block["tool_use_id"] as? String {
                                completedIds.insert(id)
                                note(activity: ts)
                                // PART B: scan the result output for rate-limit /
                                // crash markers (a result is the most reliable
                                // carrier of "the background work died / throttled").
                                let out = Self.toolResultText(block)
                                if Self.containsRateLimitMarker(out) { rateLimitSignal = true }
                                if Self.containsCrashMarker(out) { crashSignal = true }
                            } else if btype == "text" {
                                note(activity: ts)
                                lastBlockRole = "user"
                                sawUserAfterLastAssistant = true
                            }
                        }
                    } else if let str = message["content"] as? String, !str.isEmpty {
                        note(activity: ts)
                        lastBlockRole = "user"
                        sawUserAfterLastAssistant = true
                    }
                }
            default:
                break
            }
        }

        // PART B: awaiting-input == the transcript ends on an assistant turn (no
        // user reply after the last assistant text) AND that text reads like a
        // question. Computed once here from the accumulators above.
        let awaitingInputSignal = (lastBlockRole == "assistant")
            && !sawUserAfterLastAssistant
            && Self.looksLikeQuestion(lastAssistantText)

        guard !launches.isEmpty else {
            return Scan(
                outstanding: false, launchCount: 0, unpairedCount: 0,
                observedModel: observedModel,
                lastOutstandingIsSubAgent: false,
                awaitingInputSignal: awaitingInputSignal,
                rateLimitSignal: rateLimitSignal,
                crashSignal: crashSignal
            )
        }

        // Unpaired = a launch with no matching tool_result id. The strong signal.
        let unpaired = launches.filter { !completedIds.contains($0.id) }

        // Recency arm: a launch is "live" if it sits within the lookback window of
        // the latest activity AND nothing substantive happened strictly after it
        // (the worker went quiet right after launching). This catches a detached
        // background task whose result is never written as a tool_result.
        let activityCeiling = latestActivityTs ?? now
        let recencyLive = launches.contains { l in
            guard activityCeiling.timeIntervalSince(l.ts) <= lookbackSeconds else { return false }
            // "Nothing of substance after it": no recorded post-launch activity.
            return latestActivityTsAfterLaunch[l.id] == nil
        }

        let outstanding = !unpaired.isEmpty || recencyLive

        // PART B: of the launches that are actually outstanding (unpaired, or the
        // recency-live ones), is the MOST RECENT a sub-agent? That distinguishes a
        // sub-agent fan-out stall from a lone background-Bash going quiet.
        let outstandingLaunches = launches.filter { l in
            if !completedIds.contains(l.id) { return true }
            guard activityCeiling.timeIntervalSince(l.ts) <= lookbackSeconds else { return false }
            return latestActivityTsAfterLaunch[l.id] == nil
        }
        let lastOutstandingIsSubAgent = outstandingLaunches
            .max(by: { $0.ts < $1.ts })?
            .kind.hasPrefix("subagent:") ?? false

        return Scan(
            outstanding: outstanding,
            launchCount: launches.count,
            unpairedCount: unpaired.count,
            observedModel: observedModel,
            lastOutstandingIsSubAgent: lastOutstandingIsSubAgent,
            awaitingInputSignal: awaitingInputSignal,
            rateLimitSignal: rateLimitSignal,
            crashSignal: crashSignal
        )
    }

    // MARK: - PART B signal helpers (pure text heuristics)

    /// Pull the textual content out of a tool_result block. The `content` may be
    /// a plain string or an array of {type:"text", text:...} blocks (Claude Code
    /// uses both shapes); concatenate whatever text is present.
    static func toolResultText(_ block: [String: Any]) -> String {
        if let s = block["content"] as? String { return s }
        if let arr = block["content"] as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Heuristic: does this assistant text end on a question to the human? A
    /// trailing "?" or a leading ask phrase. Conservative - a miss just falls
    /// through to a less specific classification, never a wrong action.
    static func looksLikeQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasSuffix("?") { return true }
        let lower = t.lowercased()
        let askPhrases = [
            "would you like", "should i", "do you want", "which option",
            "please confirm", "let me know", "waiting for your", "confirm whether",
        ]
        return askPhrases.contains { lower.contains($0) }
    }

    /// Rate-limit / overloaded markers (case-insensitive substring match).
    static func containsRateLimitMarker(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        let markers = ["rate limit", "rate_limit", "429", "too many requests", "overloaded", "quota exceeded"]
        return markers.contains { lower.contains($0) }
    }

    /// Hard-crash markers (case-insensitive substring match). Distinct from the
    /// Evaluator's compile/test failure markers: these read as a PROCESS dying.
    static func containsCrashMarker(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        let markers = [
            "segmentation fault", "segfault", "panic:", "fatal error:",
            "core dumped", "killed", "sigkill", "sigsegv", "sigabrt", "aborted (",
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Whether a Bash tool input requests a background run. Claude Code encodes
    /// this as `run_in_background: true`; accept the bool or a "true" string
    /// defensively.
    static func isBackground(_ input: [String: Any]) -> Bool {
        if let b = input["run_in_background"] as? Bool { return b }
        if let s = input["run_in_background"] as? String { return s.lowercased() == "true" }
        if let n = input["run_in_background"] as? NSNumber { return n.boolValue }
        return false
    }

    // MARK: - Timestamp parsing (mirrors EventParser)

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

    static func parseTS(_ raw: Any?) -> Date? {
        guard let str = raw as? String else { return nil }
        return isoFormatter.date(from: str) ?? isoFormatterNoFrac.date(from: str)
    }

    // MARK: - Tail read

    /// Read the last `tailBytes` of the file and split into lines. Drops a
    /// leading partial line (the byte window may start mid-line). Returns nil on
    /// any read error (caller treats as "no transcript -> no stall").
    private func readTailLines(_ url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd() else { return nil }
        if data.isEmpty { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        // If we started mid-file, the first element is likely a partial line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}
