// SourceSurveyor.swift — the fan-out SURVEY pass over raw sources.
//
// This is the part the feature deliberately runs on the CHEAP model: a wide,
// boring, per-file read that extracts what each source is for, what it covers,
// what's load-bearing, and what looks like dead weight. It is the in-product
// analog of fanning file-reading out to a fleet of small-model subagents — one
// call per source, concurrency-bounded, each independent.
//
// OPTIONAL BY DESIGN. The deterministic metrics pass already yields a full
// report; this only ENRICHES it (semantic overlap the byte-level dup detector
// can't see — the same rule phrased two different ways). If there's no API key,
// no budget, or a call fails, that source's survey is simply absent and the
// audit proceeds. The auditor never blocks on it.
//
// COST + SAFETY. Uses the provider's default (cheapest) triage model. Content is
// truncated per source so a giant file can't blow token budget, and every call
// goes through `LLMClient`, which redacts secrets and enforces the daily cap
// before any network work.

import Foundation

public struct SourceSurveyor: Sendable {

    private let client: LLMClient
    private let model: String
    private let maxConcurrent: Int
    private let perSourceCharLimit: Int
    private let maxSources: Int
    private let trace: TraceLog

    /// - Parameters:
    ///   - client: a configured LLMClient (provider + key already resolved).
    ///   - model: which model to survey with. Defaults to the cheapest triage
    ///     model for the client's provider (Haiku for Anthropic).
    ///   - maxConcurrent: fan-out width. Small by default to stay gentle on rate
    ///     limits and budget.
    ///   - perSourceCharLimit: content is truncated to this before sending.
    ///   - maxSources: hard cap on how many sources get an LLM call in one run.
    public init(
        client: LLMClient,
        model: String? = nil,
        maxConcurrent: Int = 4,
        perSourceCharLimit: Int = 12_000,
        maxSources: Int = 60,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.model = model ?? client.provider.defaultTriageModel
        self.maxConcurrent = max(1, maxConcurrent)
        self.perSourceCharLimit = perSourceCharLimit
        self.maxSources = maxSources
        self.trace = trace
    }

    /// Survey the instruction-text sources. `contents` returns each file's text.
    /// Returns one `SourceSurvey` per source that surveyed successfully (order
    /// not guaranteed); failures are dropped, never thrown.
    public func survey(
        sources: [RawSource],
        contents: @escaping @Sendable (RawSource) -> String?
    ) async -> [SourceSurvey] {
        let targets = sources
            .filter { $0.isText && $0.kind.isInstructionText }
            .sorted { $0.lineCount > $1.lineCount }        // richest files first
            .prefix(maxSources)

        var results: [SourceSurvey] = []
        // Bounded fan-out: a sliding window of at most `maxConcurrent` in-flight
        // calls, so a large skill tree doesn't open 60 sockets at once.
        var iterator = targets.makeIterator()

        await withTaskGroup(of: SourceSurvey?.self) { group in
            var inFlight = 0
            func submitNext() {
                guard let src = iterator.next() else { return }
                let text = contents(src) ?? ""
                let clipped = String(text.prefix(perSourceCharLimit))
                let model = self.model
                group.addTask { await self.surveyOne(source: src, content: clipped, model: model) }
                inFlight += 1
            }
            for _ in 0..<maxConcurrent { submitNext() }
            while inFlight > 0 {
                if let survey = await group.next() {
                    inFlight -= 1
                    if let survey { results.append(survey) }
                    submitNext()
                }
            }
        }
        trace.emit("context-wiki", "survey pass complete: \(results.count)/\(targets.count) sources surveyed with \(model)")
        return results
    }

    // MARK: - One source

    private func surveyOne(source: RawSource, content: String, model: String) async -> SourceSurvey? {
        let system = """
        You audit a project's AI-context files (CLAUDE.md, SKILL.md, slash-command \
        docs) for bloat and redundancy. You will be given ONE file. Reply with ONLY a \
        JSON object, no prose, no code fence, matching exactly:
        {"purpose": string, "topics": [string], "loadBearing": [string], \
        "deadWeight": [string], "overlapsNotes": [string], "bloatScore": integer 1-5}
        - purpose: one line, what this file is for.
        - topics: the distinct rules/claims/concepts it covers (short phrases).
        - loadBearing: the content that MUST be preserved.
        - deadWeight: filler, stale, boilerplate, or content likely restated elsewhere.
        - overlapsNotes: what this likely overlaps with (other files/skills), if any.
        - bloatScore: 1 lean .. 5 severely bloated.
        Keep arrays short (<= 8 items). Be concrete.
        """
        let user = """
        PATH: \(source.path)
        KIND: \(source.kind.rawValue)\(source.skill.map { " (skill: \($0))" } ?? "")
        LINES: \(source.lineCount)

        --- FILE CONTENT START ---
        \(content)
        --- FILE CONTENT END ---
        """

        let request = AnthropicMessageRequest(
            model: model,
            max_tokens: 900,
            system: system,
            messages: [AnthropicMessage(role: "user", content: .string(user))],
            tools: nil,
            tool_choice: nil
        )

        do {
            let response = try await client.createMessage(request)
            let text = response.content.compactMap(\.text).joined()
            guard let survey = Self.parse(text, path: source.path) else {
                trace.emit("context-wiki", "survey parse failed for \(source.path)")
                return nil
            }
            return survey
        } catch {
            trace.emit("context-wiki", "survey call failed for \(source.path): \(error)")
            return nil
        }
    }

    // MARK: - Parsing

    /// Intermediate decode shape — lenient about missing fields.
    private struct SurveyJSON: Decodable {
        var purpose: String?
        var topics: [String]?
        var loadBearing: [String]?
        var deadWeight: [String]?
        var overlapsNotes: [String]?
        var bloatScore: Int?
    }

    /// Extract and decode the JSON object from a model reply. Tolerant of a
    /// leading/trailing sentence or a ```json fence by slicing to the outermost
    /// braces. Returns nil if nothing decodes.
    static func parse(_ raw: String, path: String) -> SourceSurvey? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            return nil
        }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SurveyJSON.self, from: data) else {
            return nil
        }
        return SourceSurvey(
            path: path,
            purpose: decoded.purpose ?? "",
            topics: decoded.topics ?? [],
            loadBearing: decoded.loadBearing ?? [],
            deadWeight: decoded.deadWeight ?? [],
            overlapsNotes: decoded.overlapsNotes ?? [],
            bloatScore: decoded.bloatScore ?? 1
        )
    }
}
