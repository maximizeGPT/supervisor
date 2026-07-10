// ContextMetrics.swift — the deterministic, model-free analysis pass.
//
// Cross-file duplication is the single strongest signal of context re-bloat and
// it needs NO model to find: if the same rule is written verbatim in four skill
// files, that is a fact about the bytes, not an opinion. This type computes that
// (plus size/weight totals) purely, so the auditor produces a useful report even
// with no API key and zero budget. The optional semantic survey enriches this;
// it never replaces it.
//
// TESTABILITY. `compute` takes a `contents` closure — the auditor passes one
// that reads from disk; tests pass literals. No I/O, no clock: same inputs ->
// same `SourceMetrics`, so the duplicate-detection thresholds are pinned by unit
// tests with hand-written fixtures.

import Foundation

public struct ContextMetrics: Sendable {

    /// A normalized line shorter than this is ignored for duplication: short
    /// lines ("## Usage", "- yes", "```") collide by chance and would drown the
    /// signal in noise. 24 chars keeps real restated *sentences* and rules.
    public let minSignificantLength: Int

    /// The heaviest N text sources to surface for the summary / split recs.
    public let largestCount: Int

    /// Cap on reported duplicate blocks, so a pathological tree can't produce an
    /// unbounded report. Highest-value blocks are kept (see the sort in `compute`).
    public let maxDuplicateBlocks: Int

    public init(minSignificantLength: Int = 24, largestCount: Int = 8, maxDuplicateBlocks: Int = 200) {
        self.minSignificantLength = minSignificantLength
        self.largestCount = largestCount
        self.maxDuplicateBlocks = maxDuplicateBlocks
    }

    /// Compute metrics over `sources`. `contents(source)` returns the file's text
    /// (or nil if unreadable). Duplication + size analysis run over PROSE only —
    /// the context surface a session loads; scripts/assets are counted as weight.
    public func compute(sources: [RawSource], contents: (RawSource) -> String?) -> SourceMetrics {
        let proseSources = sources.filter { $0.isProse }
        let totalBytes = sources.reduce(0) { $0 + $1.byteCount }
        // Everything NOT loaded as context (binary assets + executed scripts).
        let nonContextBytes = sources.filter { !$0.isProse }.reduce(0) { $0 + $1.byteCount }
        let totalProseLines = proseSources.reduce(0) { $0 + $1.lineCount }
        let largest = proseSources.sorted { $0.lineCount > $1.lineCount }.prefix(largestCount)

        // Read + normalize every PROSE source once. Scripts are skipped: a bundled
        // .js re-including its modules is legitimate build output, not context
        // re-bloat, and would otherwise dominate the findings.
        var normalizedByPath: [String: [String]] = [:]
        for src in proseSources {
            guard let text = contents(src) else { continue }
            normalizedByPath[src.path] = text.components(separatedBy: "\n").map(Self.normalize)
        }

        let blocks = duplicateBlocks(normalizedByPath: normalizedByPath)

        return SourceMetrics(
            totalSources: sources.count,
            proseSources: proseSources.count,
            totalBytes: totalBytes,
            totalProseLines: totalProseLines,
            nonContextBytes: nonContextBytes,
            largestProseSources: Array(largest),
            duplicateBlocks: blocks
        )
    }

    // MARK: - Duplicate detection

    /// Find blocks of consecutive significant lines that appear — identically
    /// after normalization — in two or more distinct sources.
    func duplicateBlocks(normalizedByPath: [String: [String]]) -> [DuplicateBlock] {
        // 1. Map each significant normalized line to the SET of paths it appears
        //    in. Distinct paths only: a line repeated inside one file is not
        //    cross-file duplication.
        var pathsByLine: [String: Set<String>] = [:]
        for (path, lines) in normalizedByPath {
            for line in lines where isSignificant(line) {
                pathsByLine[line, default: []].insert(path)
            }
        }

        // 2. Walk each file's lines in order. A maximal run of consecutive
        //    significant lines that are each cross-file-duplicated AND share the
        //    EXACT same owning path-set is one block. Requiring an identical
        //    path-set keeps a block coherent (it's the same passage moving as a
        //    unit) instead of stitching unrelated coincidental lines.
        var seen: Set<String> = []           // dedup key -> block already emitted
        var blocks: [DuplicateBlock] = []

        for (_, lines) in normalizedByPath.sorted(by: { $0.key < $1.key }) {
            var i = 0
            while i < lines.count {
                let line = lines[i]
                guard isSignificant(line), let owners = pathsByLine[line], owners.count >= 2 else {
                    i += 1
                    continue
                }
                // Extend the run while significance + identical owner-set holds.
                var j = i + 1
                while j < lines.count,
                      isSignificant(lines[j]),
                      let owners2 = pathsByLine[lines[j]],
                      owners2 == owners {
                    j += 1
                }
                let span = j - i
                let occurrences = owners.sorted()
                // Dedup: the same block is discovered once per owning file. Key on
                // the owner-set + first line + span so it is emitted exactly once.
                let key = occurrences.joined(separator: "\u{1}") + "\u{2}\(span)\u{2}" + line
                if !seen.contains(key) {
                    seen.insert(key)
                    blocks.append(DuplicateBlock(
                        excerpt: excerptText(lines[i]),
                        lineSpan: span,
                        occurrences: occurrences
                    ))
                }
                i = j
            }
        }

        // 3. Rank: most reclaimable first, then longest, then wider spread, then
        //    text for a stable total order.
        blocks.sort {
            if $0.reclaimableLines != $1.reclaimableLines { return $0.reclaimableLines > $1.reclaimableLines }
            if $0.lineSpan != $1.lineSpan { return $0.lineSpan > $1.lineSpan }
            if $0.occurrences.count != $1.occurrences.count { return $0.occurrences.count > $1.occurrences.count }
            return $0.excerpt < $1.excerpt
        }
        return Array(blocks.prefix(maxDuplicateBlocks))
    }

    // MARK: - Normalization

    /// Normalize a line for comparison: strip surrounding whitespace, collapse
    /// internal runs of whitespace to one space, and lowercase. Content that is
    /// "the same rule" survives cosmetic edits (indentation, casing, extra
    /// spaces) and still collides.
    static func normalize(_ raw: String) -> String {
        let collapsed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        return collapsed.lowercased()
    }

    /// Whether a normalized line carries enough content to be worth matching.
    /// Filters blanks, too-short lines, and pure markdown/structure rulers that
    /// would collide by coincidence.
    func isSignificant(_ normalized: String) -> Bool {
        guard normalized.count >= minSignificantLength else { return false }
        // Reject lines that are only structural punctuation (---, ===, ```, | | |).
        let stripped = normalized.filter { !"#-=*_`|> .".contains($0) }
        return stripped.count >= 8
    }

    /// A short, human-readable excerpt for a block (the original-ish first line,
    /// bounded). Uses the already-normalized text; good enough to recognize.
    private func excerptText(_ normalized: String) -> String {
        String(normalized.prefix(140))
    }
}
