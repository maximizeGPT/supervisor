// SecondBrainRenderer.swift — turn a MemoryLedger into the human-facing artifact.
//
// One markdown file plus a compact console summary:
//   SECOND-BRAIN.md   the brain's current knowledge, sectioned by kind, each
//                     entry with its confidence and a provenance footer; the
//                     retired/merged history collapsed at the bottom; the last
//                     few IterationDeltas as an iteration log table.
//
// Mirrors WikiRenderer: pure string-building over the value types;
// `writeArtifacts` is the only side-effecting method and it writes ONLY into a
// caller-chosen output directory — never the source tree, never the transcripts.
// The ledger is also written as plain JSON alongside the markdown: the brain is
// the USER'S artifact (the whole point of the feature), portable across models
// and providers.

import Foundation

public struct SecondBrainRenderer: Sendable {

    public init() {}

    // MARK: - Console summary

    /// A short, skimmable summary for a terminal / log line.
    public func consoleSummary(_ ledger: MemoryLedger, delta: IterationDelta) -> String {
        var out: [String] = []
        out.append("Second Brain — \(ledger.root)")
        out.append(String(repeating: "─", count: 56))
        out.append("Iteration:      \(delta.iteration)")
        out.append("This iteration: +\(delta.added) added, \(delta.confirmed) confirmed, \(delta.merged) merged, \(delta.retired) retired")
        out.append("Active entries: \(delta.activeTotal)")
        for kind in MemoryEntryKind.allCases {
            let count = ledger.activeEntries.filter { $0.kind == kind }.count
            if count > 0 { out.append("  \(kind.sectionTitle): \(count)") }
        }
        if let note = delta.contextDriftNote {
            out.append("Context drift:  \(note)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - SECOND-BRAIN.md

    public func renderBrain(_ ledger: MemoryLedger) -> String {
        var s = "# Second Brain\n\n"
        s += "> What this project's sessions have taught Supervisor about how YOU work —\n"
        s += "> your corrections, decisions, and preferences, distilled from the session\n"
        s += "> transcripts and improved each iteration. This knowledge is YOURS: it lives\n"
        s += "> only on this machine (this file, its JSON twin, and the local Supervisor\n"
        s += "> database), so switching models or providers never loses it. All text was\n"
        s += "> redacted before it was stored.\n\n"
        s += "Root: `\(ledger.root)`  \n"
        s += "Updated: \(SessionReportExporter.iso(ledger.updatedAt))  \n"
        s += "Iteration: \(ledger.iteration)  \n"
        s += "Active entries: \(ledger.activeEntries.count)\n\n"

        if ledger.activeEntries.isEmpty {
            s += "_No entries yet — run more sessions and iterate again._\n\n"
        }

        // One section per kind, in the vocabulary's declared order.
        for kind in MemoryEntryKind.allCases {
            let entries = ledger.activeEntries
                .filter { $0.kind == kind }
                .sorted {
                    if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                    if $0.firstSeenIteration != $1.firstSeenIteration { return $0.firstSeenIteration < $1.firstSeenIteration }
                    return $0.text < $1.text
                }
            guard !entries.isEmpty else { continue }
            s += "## \(kind.sectionTitle)\n\n"
            for entry in entries {
                s += "- **\(Self.escape(entry.text))** _(confidence: \(entry.confidence.rawValue))_\n"
                s += "  - _first seen iter \(entry.firstSeenIteration), last confirmed iter \(entry.lastConfirmedIteration) · session `\(Self.shortSession(entry.provenance.sessionId))` · \(SessionReportExporter.iso(entry.provenance.timestamp)) · excerpt \(entry.provenance.excerptHash)_\n"
            }
            s += "\n"
        }

        // Retired/merged history, collapsed — never deleted, always inspectable.
        let inactive = ledger.entries.filter { $0.status != .active }
        if !inactive.isEmpty {
            s += "## Retired\n\n"
            s += "<details>\n<summary>\(inactive.count) retired/merged entr\(inactive.count == 1 ? "y" : "ies")</summary>\n\n"
            for entry in inactive.sorted(by: { $0.text < $1.text }) {
                s += "- ~~\(Self.escape(entry.text))~~ _(\(entry.status.rawValue), \(entry.kind.rawValue), last confirmed iter \(entry.lastConfirmedIteration))_\n"
            }
            s += "\n</details>\n\n"
        }

        // Iteration log: the last few deltas, oldest first (the optimizer
        // already caps recentDeltas at deltaHistoryCap when it writes them).
        if !ledger.recentDeltas.isEmpty {
            s += "## Iteration log\n\n"
            s += "| Iteration | Added | Confirmed | Merged | Retired | Active |\n|--:|--:|--:|--:|--:|--:|\n"
            for delta in ledger.recentDeltas {
                s += "| \(delta.iteration) | \(delta.added) | \(delta.confirmed) | \(delta.merged) | \(delta.retired) | \(delta.activeTotal) |\n"
            }
            s += "\n"
            if let note = ledger.recentDeltas.last?.contextDriftNote {
                s += "_\(Self.escape(note))_\n"
            }
        }
        return s
    }

    // MARK: - Write

    public struct WrittenArtifacts: Sendable, Equatable {
        public var brainPath: URL
        public var ledgerJSONPath: URL
    }

    /// Write the artifacts into `outDir` (created if needed). Writes ONLY here —
    /// never the source tree. Returns the paths written.
    @discardableResult
    public func writeArtifacts(_ ledger: MemoryLedger, to outDir: URL) throws -> WrittenArtifacts {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let brain = outDir.appendingPathComponent("SECOND-BRAIN.md")
        let json = outDir.appendingPathComponent("second-brain-ledger.json")

        try renderBrain(ledger).write(to: brain, atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ledger).write(to: json)

        return WrittenArtifacts(brainPath: brain, ledgerJSONPath: json)
    }

    // MARK: - Helpers

    /// A recognizable-but-compact session label for the provenance footer.
    private static func shortSession(_ id: String) -> String {
        id.count > 8 ? String(id.prefix(8)) + "…" : id
    }

    /// Neutralize characters that would break a markdown table cell / list line.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
