// ContextAuditor.swift — the general capability, wired end to end.
//
// One entry point: point it at ANY project root and it produces a complete,
// non-destructive `AuditReport` — the raw inventory, deterministic metrics, an
// optional semantic survey, the consolidated wiki, the generated schema, and
// the ranked recommendations. Nothing is written to the source tree; the report
// is a value the caller renders/persists as it likes.
//
// PIPELINE (raw sources -> wiki -> schema):
//   1. scan     — enumerate context surfaces (read-only, deterministic)
//   2. metrics  — model-free duplication + weight analysis (always runs)
//   3. survey   — OPTIONAL cheap-model fan-out (only if a surveyor is supplied)
//   4. consolidate — wiki topics + ranked recommendations + schema conventions
//
// The clock is injected (`now`) so `generatedAt` is deterministic in tests. The
// surveyor is injected and optional so the whole audit runs — and is testable —
// with no network at all.

import Foundation

public struct ContextAuditor: Sendable {

    private let scanner: ContextSourceScanner
    private let metricsEngine: ContextMetrics
    private let consolidator: WikiConsolidator
    private let trace: TraceLog

    public init(
        scanner: ContextSourceScanner = ContextSourceScanner(),
        metrics: ContextMetrics = ContextMetrics(),
        consolidator: WikiConsolidator = WikiConsolidator(),
        trace: TraceLog = .shared
    ) {
        self.scanner = scanner
        self.metricsEngine = metrics
        self.consolidator = consolidator
        self.trace = trace
    }

    /// Run a full audit of `root`. Pass a `surveyor` to enable the cheap-model
    /// semantic pass; omit it (the default) for a deterministic, offline audit.
    public func audit(
        root: URL,
        surveyor: SourceSurveyor? = nil,
        now: Date = Date()
    ) async -> AuditReport {
        let sources = scanner.scan(root: root)
        trace.emit("context-wiki", "scanned \(root.path): \(sources.count) sources (\(sources.filter { $0.isProse }.count) context/prose)")

        // Read every text source ONCE into an immutable cache, so metrics and the
        // survey share reads and the closures are Sendable-clean.
        var built: [String: String] = [:]
        for src in sources where src.isText {
            if let text = try? String(contentsOfFile: src.path, encoding: .utf8) {
                built[src.path] = text
            }
        }
        let cache = built
        let contents: @Sendable (RawSource) -> String? = { cache[$0.path] }

        let metrics = metricsEngine.compute(sources: sources, contents: contents)

        var surveys: [SourceSurvey] = []
        if let surveyor {
            surveys = await surveyor.survey(sources: sources, contents: contents)
        }

        let wiki = consolidator.buildWiki(sources: sources, metrics: metrics, surveys: surveys)
        let recommendations = consolidator.recommendations(sources: sources, metrics: metrics, surveys: surveys)
        let schema = consolidator.generateSchema(root: root.path, sources: sources, metrics: metrics)

        return AuditReport(
            root: root.path,
            generatedAt: now,
            sources: sources,
            metrics: metrics,
            surveys: surveys,
            wiki: wiki,
            schema: schema,
            recommendations: recommendations,
            usedLLM: surveyor != nil
        )
    }
}
