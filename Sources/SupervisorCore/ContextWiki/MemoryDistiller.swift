// MemoryDistiller.swift — the CAPTURE + REDACT stages of the Second Brain loop.
//
// Extracts candidate memory entries from the recent transcripts of a project
// root. The transcripts are the same JSONL files SessionDiscovery tails
// (~/.claude/projects/<munged-root>/<session>.jsonl) — the JSONL IS the record
// (SessionObjective's stance), so distillation works after restarts and for
// sessions Supervisor never watched live.
//
// DETERMINISTIC FIRST. The heuristics below run with no API key and no network:
//   - corrections: a USER message that immediately follows an assistant action
//     and opens with a negation/correction shape ("no,", "don't", "actually",
//     "instead", "stop", "wrong");
//   - decisions:   explicit decision phrases ("let's use", "we should",
//     "always", "never");
//   - preferences: an explicit "prefer".
// Deterministic extraction reads USER-authored text ONLY — that is the
// proprietary-knowledge signal the feature exists to capture (the Reverse
// Information Paradox: what the user reveals in prompts/corrections). Assistant
// or tool "discoveries" phrased as stable facts are too fuzzy to classify
// deterministically; environmentFact/gotcha candidates come only from the
// optional LLM pass.
//
// OPTIONAL LLM PASS. A `MemorySurveyor` (SourceSurveyor's pattern: injectable,
// nil by default, provider-agnostic via LLMClient, failures degrade to the
// deterministic result) can reclassify/condense the deterministic candidates.
//
// REDACTION IS NON-NEGOTIABLE. Every candidate's text passes through the
// Redactor before it becomes a candidate, and again after the LLM pass
// (idempotent), so no secret from a transcript can reach the ledger, the DB,
// or SECOND-BRAIN.md.

import Foundation

public struct MemoryDistiller: Sendable {

    /// Max bytes of each transcript's tail to read (mirrors AsyncWorkScanner:
    /// recent turns are what matter, and the cap keeps a multi-MB transcript
    /// from blowing memory).
    public static let defaultTailBytes = 256 * 1024
    /// How many of the root's most recently modified transcripts to distill.
    public static let defaultMaxSessions = 20

    private let projectsDir: URL
    private let redactor: any Redactor
    private let surveyor: MemorySurveyor?
    private let tailBytes: Int
    private let maxSessions: Int
    private let trace: TraceLog

    /// - Parameters:
    ///   - projectsDir: where session transcripts live; defaults to
    ///     `ConfigPaths().claudeProjectsDir` (`~/.claude/projects`, the same
    ///     place the rest of the app reads).
    ///   - redactor: applied to every candidate's text before it exists.
    ///   - surveyor: optional cheap-model refinement pass; nil (the default)
    ///     keeps the distiller fully deterministic and offline.
    public init(
        projectsDir: URL? = nil,
        redactor: any Redactor = DefaultRedactor(),
        surveyor: MemorySurveyor? = nil,
        tailBytes: Int = MemoryDistiller.defaultTailBytes,
        maxSessions: Int = MemoryDistiller.defaultMaxSessions,
        trace: TraceLog = .shared
    ) {
        self.projectsDir = projectsDir ?? ConfigPaths().claudeProjectsDir
        self.redactor = redactor
        self.surveyor = surveyor
        self.tailBytes = tailBytes
        self.maxSessions = max(1, maxSessions)
        self.trace = trace
    }

    /// Distill candidates from the recent transcripts of `root`. Deterministic
    /// when no surveyor is configured; with one, the surveyor may condense or
    /// reclassify (its failure returns the deterministic set unchanged).
    /// Output is redacted, deduped by id, and deterministically ordered.
    public func distill(root: URL) async -> [MemoryCandidate] {
        await distill(from: recent(from: allTranscripts(root: root) ?? []), root: root)
    }

    /// One directory walk serving both loop inputs: the distilled candidates
    /// and the live-session evidence for the optimizer's retire rule. The
    /// DevTools flow used to call `distill` + `liveSessionIds` back to back,
    /// enumerating the projects dir and re-reading every transcript head
    /// twice (issue #54). Semantics are identical to calling both — including
    /// the nil-vs-empty distinction documented on `liveSessionIds`.
    public func snapshot(root: URL) async -> (candidates: [MemoryCandidate], liveSessionIds: Set<String>?) {
        let all = allTranscripts(root: root)
        return (
            candidates: await distill(from: recent(from: all ?? []), root: root),
            liveSessionIds: all.map { Set($0.map(\.sessionId)) }
        )
    }

    private func distill(from transcripts: [(sessionId: String, url: URL)], root: URL) async -> [MemoryCandidate] {
        var candidates: [MemoryCandidate] = []
        for (sessionId, url) in transcripts {
            // Shared tail reader (TranscriptTail): nil on read error means
            // this transcript is skipped.
            guard let lines = TranscriptTail.readTailLines(url, tailBytes: tailBytes) else { continue }
            candidates.append(contentsOf: Self.extractCandidates(
                lines: lines, sessionId: sessionId, redactor: redactor
            ))
        }
        trace.emit("second-brain", "distilled \(candidates.count) deterministic candidate(s) from \(root.path)")

        if let surveyor, !candidates.isEmpty {
            candidates = await surveyor.refine(candidates)
            // Defensive re-redaction of anything the model rephrased. The
            // Redactor is idempotent, so already-clean text is untouched.
            candidates = candidates.map {
                MemoryCandidate(
                    kind: $0.kind, text: redactor.redact($0.text),
                    sessionId: $0.sessionId, timestamp: $0.timestamp, excerptHash: $0.excerptHash
                )
            }
        }

        // Dedupe by id (same fact restated within/across the tails), keeping the
        // EARLIEST sighting as provenance, then order deterministically.
        var seen = Set<String>()
        let ordered = candidates
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id < $1.id
            }
            .filter { seen.insert($0.id).inserted }
        return ordered
    }

    /// The session ids whose transcript file still exists for `root` — feeds
    /// the optimizer's "source session gone" half of the retire rule. Returns
    /// nil when the root's projects directory is missing or unreadable: that
    /// is ABSENCE of evidence, not evidence the sessions are gone, and the
    /// optimizer treats nil as "unknown — never staleness-retire". An existing
    /// but empty directory returns an empty set (positive evidence: every
    /// source session IS gone).
    public func liveSessionIds(root: URL) -> Set<String>? {
        allTranscripts(root: root).map { Set($0.map(\.sessionId)) }
    }

    // MARK: - Transcript discovery

    /// Claude Code's projects-dir name for a cwd: every character outside
    /// ASCII [A-Za-z0-9] becomes "-" (e.g. `/Users/main/my_proj` ->
    /// `-Users-main-my-proj`). ASCII-only on purpose: Claude Code's own
    /// munging is ASCII, so a Unicode-aware `isLetter` would preserve 'é'/CJK
    /// where the real directory has '-' and miss the transcripts entirely.
    static func mungedDirectoryName(forRoot path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// All of the root's transcripts, or nil when the munged directory does
    /// not exist / cannot be enumerated (unknown, NOT "no sessions" — see
    /// `liveSessionIds`). The munge is lossy (`/a/b-c`, `/a/b.c`, `/a/b_c`
    /// share a directory), so a name match is not identity: a transcript whose
    /// recorded cwd differs from `root` is a foreign project's and is skipped.
    /// Transcripts with NO cwd record are kept — benefit of the doubt,
    /// matching the Python twin's fallback.
    private func allTranscripts(root: URL) -> [(sessionId: String, url: URL, mtime: Date)]? {
        let dir = projectsDir.appendingPathComponent(
            Self.mungedDirectoryName(forRoot: root.path), isDirectory: true
        )
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let rootPath = Self.normalizedPath(root.path)
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .filter { url in
                guard let cwd = Self.headCwd(url) else { return true }
                return Self.normalizedPath(cwd) == rootPath
            }
            .map { url in
                let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
                return (url.deletingPathExtension().lastPathComponent, url, mtime)
            }
    }

    /// The first recorded `cwd` in the transcript's head lines, or nil when
    /// none of them carries one. Reads only the head of the file (the same
    /// cheap approach as SessionObjective) because the session's cwd is
    /// stamped on the earliest records.
    static func headCwd(_ url: URL, headBytes: Int = 16_384) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // If we hit the byte budget the final line may be truncated — drop it.
        if data.count >= headBytes, lines.count > 1 { lines.removeLast() }
        for line in lines {
            guard line.contains("\"cwd\""),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// Normalize a path for the cwd == root comparison (resolve `..`/symlinks,
    /// strip trailing slashes) — mirrors the Python twin's `os.path.normpath`.
    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The most recently modified transcripts, capped at `maxSessions`, in a
    /// deterministic order (mtime desc, then filename).
    private func recent(from transcripts: [(sessionId: String, url: URL, mtime: Date)]) -> [(sessionId: String, url: URL)] {
        transcripts
            .sorted {
                if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
                return $0.sessionId < $1.sessionId
            }
            .prefix(maxSessions)
            .map { ($0.sessionId, $0.url) }
    }

    // MARK: - Deterministic extraction (pure; testable without a file)

    /// Walk already-read transcript lines and extract candidates from USER-
    /// authored text only. PURE (no I/O): tests feed lines directly.
    ///
    /// Skipped, matching SessionObjective/EventParser: sidechain (subagent)
    /// turns, isMeta caveats, and machine-generated user text (command echoes,
    /// compact-continuation summaries). tool_result blocks are machinery, not
    /// owner text, and never reset the "assistant acted last" flag.
    static func extractCandidates(
        lines: [String],
        sessionId: String,
        redactor: any Redactor
    ) -> [MemoryCandidate] {
        var out: [MemoryCandidate] = []
        // Corrections must FOLLOW an assistant action: true after an assistant
        // turn, cleared once the user says something (a second user message is
        // a new thought, not a correction of the assistant).
        var lastTurnWasAssistant = false

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Cheap prefilter before JSON-decoding every line.
            guard !trimmedLine.isEmpty,
                  trimmedLine.contains("\"user\"") || trimmedLine.contains("\"assistant\""),
                  let data = trimmedLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            // Sidechain (subagent) records are skipped for EVERY record type,
            // matching tail_session.py's ClaudeParser — a sidechain assistant
            // turn especially must not count as "assistant acted" for the
            // correction gate below.
            if (obj["isSidechain"] as? Bool) == true { continue }

            if type == "assistant" {
                lastTurnWasAssistant = true
                continue
            }
            guard type == "user" else { continue }
            // Not owner-authored: CLI-generated caveats.
            if (obj["isMeta"] as? Bool) == true { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            let ts = TranscriptTail.parseTS(obj["timestamp"]) ?? .distantPast

            // Owner text: a plain-string content, or the text blocks of an
            // array content (tool_result blocks are skipped — machinery).
            var texts: [String] = []
            if let str = message["content"] as? String {
                texts.append(str)
            } else if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where (block["type"] as? String) == "text" {
                    if let str = block["text"] as? String { texts.append(str) }
                }
            }

            var spokeThisTurn = false
            for text in texts {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if EventParser.isMachineGeneratedUserText(trimmed) { continue }
                spokeThisTurn = true
                guard let kind = classify(trimmed, followsAssistantAction: lastTurnWasAssistant) else { continue }
                // Redact BEFORE the text exists as a candidate; the excerpt
                // hash is over the redacted text too, so nothing secret-derived
                // is ever persisted.
                let redacted = redactor.redact(trimmed)
                let collapsed = redacted
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                out.append(MemoryCandidate(
                    kind: kind,
                    text: collapsed,
                    sessionId: sessionId,
                    timestamp: ts,
                    excerptHash: StableHash.fnv1a64Hex(MemoryEntry.normalize(redacted))
                ))
            }
            if spokeThisTurn { lastTurnWasAssistant = false }
        }
        return out
    }

    /// Classify one user-authored text. Returns nil when it carries no durable
    /// signal. PRECEDENCE: correction (needs a preceding assistant action),
    /// then preference, then decision — an "actually, let's use X" is a
    /// correction, not a fresh decision.
    static func classify(_ text: String, followsAssistantAction: Bool) -> MemoryEntryKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }   // too short to be a durable fact
        let lower = trimmed.lowercased()
        // Space-padded so word checks can't half-match ("never" vs "nevertheless"
        // still slips, but the padding stops prefix/suffix fusions cheaply).
        let padded = " " + lower + " "

        let correctionCues = ["no,", "no.", "don't", "do not", "stop", "wrong", "actually", "instead"]
        if followsAssistantAction,
           correctionCues.contains(where: { hasLeadingCue(lower, $0) }) || lower.contains(" instead of ") {
            return .correction
        }
        if padded.contains(" prefer ") {
            return .preference
        }
        let decisionPhrases = ["let's use", "lets use", "we should"]
        if decisionPhrases.contains(where: { lower.contains($0) })
            || padded.contains(" always ") || padded.contains(" never ") {
            return .decision
        }
        return nil
    }

    /// True when `text` opens with `cue` at a word boundary: the character
    /// after the cue is non-letter or absent. `hasPrefix` alone made
    /// "stopping here for today…" read as the cue "stop" (and "wrongly…" as
    /// "wrong") — a session sign-off became a durable correction that could
    /// even retire a real belief via the optimizer's contradiction rule.
    static func hasLeadingCue(_ text: String, _ cue: String) -> Bool {
        guard text.hasPrefix(cue) else { return false }
        let next = text.index(text.startIndex, offsetBy: cue.count)
        return next == text.endIndex || !text[next].isLetter
    }
}

// MARK: - Optional LLM refinement (SourceSurveyor's pattern)

/// The optional cheap-model pass over deterministic candidates: reclassify
/// (a "correction" that is really an environment fact / gotcha) and condense
/// (a rambling message down to its one durable fact). OPTIONAL BY DESIGN —
/// absent a client/key/budget, the deterministic candidates already form a
/// complete iteration; any failure here returns them unchanged. Every call
/// goes through `LLMClient`, which redacts and enforces the daily cap before
/// any network work (and the candidates were redacted at extraction anyway).
public struct MemorySurveyor: Sendable {

    private let client: LLMClient
    private let model: String
    private let maxCandidates: Int
    private let trace: TraceLog

    /// - Parameters:
    ///   - client: a configured LLMClient (provider + key already resolved).
    ///   - model: defaults to the provider's cheapest triage model.
    ///   - maxCandidates: hard cap on how many candidates one call refines.
    public init(
        client: LLMClient,
        model: String? = nil,
        maxCandidates: Int = 40,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.model = model ?? client.provider.defaultTriageModel
        self.maxCandidates = maxCandidates
        self.trace = trace
    }

    /// Refine candidates in ONE batched call. Returns the input unchanged on
    /// any failure — the deterministic fallback is the contract. Candidates
    /// past `maxCandidates` skip the LLM and pass through untouched.
    public func refine(_ candidates: [MemoryCandidate]) async -> [MemoryCandidate] {
        let capped = Array(candidates.prefix(maxCandidates))
        let overflow = Array(candidates.dropFirst(maxCandidates))
        guard !capped.isEmpty else { return candidates }

        let kinds = MemoryEntryKind.allCases.map(\.rawValue).joined(separator: " | ")
        let system = """
        You curate a developer's "second brain": durable project knowledge distilled \
        from their coding-session messages. You will be given numbered candidate \
        facts. Reply with ONLY a JSON array, no prose, no code fence, of the \
        candidates worth keeping, matching exactly:
        [{"index": integer, "kind": string, "text": string}]
        - index: the candidate's number from the input.
        - kind: one of \(kinds).
        - text: the fact, condensed to ONE clear sentence (<= \(MemoryEntry.textCap) chars). Keep the \
        user's meaning; never invent facts.
        Drop candidates that are transient chatter rather than durable knowledge.
        """
        let user = capped.enumerated().map { i, c in
            "\(i). [\(c.kind.rawValue)] \(c.text)"
        }.joined(separator: "\n")

        let request = AnthropicMessageRequest(
            model: model,
            max_tokens: 1500,
            system: system,
            messages: [AnthropicMessage(role: "user", content: .string(user))],
            tools: nil,
            tool_choice: nil
        )

        do {
            let response = try await client.createMessage(request)
            let text = response.content.compactMap(\.text).joined()
            guard let refined = Self.parse(text, original: capped) else {
                trace.emit("second-brain", "refine parse failed — keeping deterministic candidates")
                return candidates
            }
            trace.emit("second-brain", "refined \(capped.count) candidate(s) -> \(refined.count) with \(model)")
            return refined + overflow
        } catch {
            trace.emit("second-brain", "refine call failed (\(error)) — keeping deterministic candidates")
            return candidates
        }
    }

    /// Intermediate decode shape — lenient about missing fields.
    private struct RefinedJSON: Decodable {
        var index: Int?
        var kind: String?
        var text: String?
    }

    /// Extract and decode the JSON array from a model reply. Tolerant of a
    /// leading/trailing sentence or a ```json fence by slicing to the outermost
    /// brackets. Provenance always comes from the ORIGINAL candidate at the
    /// returned index; an out-of-range index is dropped, an unknown kind keeps
    /// the original's. Returns nil if nothing decodes.
    static func parse(_ raw: String, original: [MemoryCandidate]) -> [MemoryCandidate]? {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end else {
            return nil
        }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RefinedJSON].self, from: data) else {
            return nil
        }
        var out: [MemoryCandidate] = []
        for item in decoded {
            guard let index = item.index, original.indices.contains(index) else { continue }
            let source = original[index]
            let kind = item.kind.flatMap(MemoryEntryKind.init(rawValue:)) ?? source.kind
            let text = (item.text?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? source.text
            out.append(MemoryCandidate(
                kind: kind,
                text: text,
                sessionId: source.sessionId,
                timestamp: source.timestamp,
                excerptHash: source.excerptHash
            ))
        }
        return out
    }
}
