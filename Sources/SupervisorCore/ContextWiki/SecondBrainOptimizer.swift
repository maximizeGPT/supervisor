// SecondBrainOptimizer.swift — the MERGE + RETIRE + MEASURE stages of the loop.
//
// A pure value-level function: (ledger, candidates) -> (ledger', delta). No
// I/O, no clock reads, no model calls — every rule below is pinned by a unit
// test with literals, and the same inputs always produce the same outputs
// (WikiConsolidator's "deterministic on purpose" stance).
//
// ONE ITERATION:
//   merge   — a candidate whose id (or absorbed alias id) matches an active
//             entry CONFIRMS it: lastConfirmedIteration bumps, confidence steps
//             up. A near-duplicate (normalized-text containment, same kind)
//             MERGES: the richer text wins, the other is absorbed and its id
//             recorded, so a re-run of the same inputs confirms instead of
//             re-merging — the idempotence property.
//   retire  — an active entry contradicted by a new correction retires; so does
//             an entry unconfirmed for `retireAfterUnconfirmedIterations`
//             iterations WHOSE source session is gone (both halves required —
//             a fact from a still-present transcript is merely dormant).
//   measure — the IterationDelta (added/confirmed/merged/retired/activeTotal),
//             with an optional context-drift note from the most recent Context
//             Wiki AuditReport when the caller has one.
//
// IDEMPOTENT: running the same candidates against the resulting ledger again
// adds and merges NOTHING (everything id-matches and confirms). That makes the
// loop safe to re-run on any cadence without inflating the brain.

import Foundation

public struct SecondBrainOptimizer: Sendable {

    /// How many iterations an entry may go unconfirmed before it is retirable
    /// (the other half of the rule: its source session must also be gone).
    public let retireAfterUnconfirmedIterations: Int

    /// Containment shorter than this many normalized characters is treated as
    /// coincidence, not a near-duplicate — "use spaces" is contained in far too
    /// many unrelated facts to merge on.
    public static let minContainmentLength = 12

    public static let defaultRetireAfterUnconfirmedIterations = 5

    public init(
        retireAfterUnconfirmedIterations: Int = SecondBrainOptimizer.defaultRetireAfterUnconfirmedIterations
    ) {
        self.retireAfterUnconfirmedIterations = max(1, retireAfterUnconfirmedIterations)
    }

    /// Run one iteration of the loop.
    ///
    /// - Parameters:
    ///   - ledger: the current brain (start from `MemoryLedger.empty(root:)`).
    ///   - candidates: freshly distilled (already redacted) candidates.
    ///   - liveSessionIds: the session ids whose transcripts still exist for
    ///     the root (MemoryDistiller.liveSessionIds). `nil` = unknown, which
    ///     disables the staleness retire rule — we never retire a fact on
    ///     staleness alone without positive evidence its source is gone.
    ///   - priorReport: the most recent Context Wiki audit for the same root,
    ///     if one exists; feeds the delta's optional drift note.
    ///   - now: injected clock for the ledger's `updatedAt` (deterministic in
    ///     tests).
    public func optimize(
        ledger: MemoryLedger,
        candidates: [MemoryCandidate],
        liveSessionIds: Set<String>? = nil,
        priorReport: AuditReport? = nil,
        now: Date = Date()
    ) -> (ledger: MemoryLedger, delta: IterationDelta) {
        var next = ledger
        next.iteration += 1
        next.updatedAt = now
        let iteration = next.iteration

        var added = 0
        var merged = 0
        var retired = 0
        // Entries confirmed this iteration (each counted once, however many
        // candidates re-observed the same fact).
        var confirmedIds = Set<String>()
        // Entries whose confidence already stepped up this iteration — at most
        // ONE step per entry per run, however many candidates (id match plus
        // contained variants) re-observed the same fact in one batch.
        var bumpedIds = Set<String>()

        // Deterministic candidate order: timestamp, then id. The distiller
        // already emits this order; re-sorting makes the function total.
        let ordered = candidates.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }

        for candidate in ordered {
            let candidateNorm = candidate.normalizedText

            // 1. Identity (exact id or previously absorbed alias). ONE scan
            //    with ONE predicate for every status — a future identity tweak
            //    applied to a retired-only scan but not the active one (or
            //    vice versa) would let retired facts resurrect. The matched
            //    entry's status decides:
            //      retired -> the fact STAYS retired. The transcript that
            //                 taught it can be re-distilled forever; letting
            //                 the old text resurrect would silently undo the
            //                 correction (or staleness call) that retired it.
            //      active  -> CONFIRM.
            //      merged  -> absorbed entries don't decide: their ids were
            //                 propagated into the absorbing survivor's
            //                 mergedIDs at merge time, so the survivor is in
            //                 the same match set and resolves the candidate.
            var retiredMatch = false
            var activeIdx: Int?
            for idx in next.entries.indices
            where next.entries[idx].id == candidate.id || next.entries[idx].mergedIDs.contains(candidate.id) {
                switch next.entries[idx].status {
                case .retired: retiredMatch = true
                case .active: if activeIdx == nil { activeIdx = idx }
                case .merged: break
                }
            }
            if retiredMatch { continue }
            if let idx = activeIdx {
                confirm(&next.entries[idx], iteration: iteration, newlyConfirmed: &confirmedIds, bumped: &bumpedIds)
                continue
            }

            // 2. A correction that names an active non-correction fact
            //    CONTRADICTS it: the old belief retires, the correction lands.
            if candidate.kind == .correction,
               let idx = next.entries.firstIndex(where: {
                   $0.status == .active && $0.kind != .correction
                       && Self.isNearDuplicate(candidateNorm, MemoryEntry.normalize($0.text))
               }) {
                next.entries[idx].status = .retired
                retired += 1
                next.entries.append(Self.entry(from: candidate, iteration: iteration))
                added += 1
                continue
            }

            // 3. Near-duplicate within the same kind -> MERGE. The richer
            //    (longer-normalized) text becomes the entry's text; the other
            //    id is recorded in mergedIDs so re-runs confirm, not re-merge.
            if let idx = next.entries.firstIndex(where: {
                $0.status == .active && $0.kind == candidate.kind
                    && Self.isNearDuplicate(candidateNorm, MemoryEntry.normalize($0.text))
            }) {
                let existing = next.entries[idx]
                if candidateNorm.count > MemoryEntry.normalize(existing.text).count {
                    // Candidate is richer: it becomes the entry, the old entry
                    // is absorbed (status .merged) and its identity carried.
                    var absorbed = existing
                    absorbed.status = .merged
                    next.entries[idx] = absorbed
                    // One confidence step per entry per iteration: skip the
                    // bump when the host was already confirmed this run.
                    let firstBumpThisIteration = bumpedIds.insert(existing.id).inserted
                    bumpedIds.insert(candidate.id)   // the survivor's new id counts as stepped too
                    next.entries.append(MemoryEntry(
                        id: candidate.id,
                        kind: candidate.kind,
                        text: candidate.text,
                        provenance: existing.provenance,   // origin stays with the first sighting
                        status: .active,
                        confidence: firstBumpThisIteration ? existing.confidence.bumped : existing.confidence,
                        firstSeenIteration: existing.firstSeenIteration,
                        lastConfirmedIteration: iteration,
                        mergedIDs: existing.mergedIDs + [existing.id]
                    ))
                } else {
                    // Existing entry is at least as rich: absorb the candidate.
                    // Counted as a merge, not a confirm — the re-observation
                    // still bumps recency, and confidence steps up at most
                    // once per entry per iteration (an id match earlier in the
                    // same batch already counted as this entry's step).
                    if !next.entries[idx].mergedIDs.contains(candidate.id) {
                        next.entries[idx].mergedIDs.append(candidate.id)
                    }
                    next.entries[idx].lastConfirmedIteration = iteration
                    if bumpedIds.insert(next.entries[idx].id).inserted {
                        next.entries[idx].confidence = next.entries[idx].confidence.bumped
                    }
                }
                merged += 1
                continue
            }

            // 4. Genuinely new knowledge.
            next.entries.append(Self.entry(from: candidate, iteration: iteration))
            added += 1
        }

        // RETIRE (staleness): unconfirmed for N iterations AND source session
        // gone. Requires positive knowledge of the live set — `nil` skips.
        if let live = liveSessionIds {
            for idx in next.entries.indices where next.entries[idx].status == .active {
                let entry = next.entries[idx]
                guard iteration - entry.lastConfirmedIteration >= retireAfterUnconfirmedIterations,
                      !live.contains(entry.provenance.sessionId) else { continue }
                next.entries[idx].status = .retired
                retired += 1
            }
        }

        let delta = IterationDelta(
            iteration: iteration,
            added: added,
            confirmed: confirmedIds.count,
            merged: merged,
            retired: retired,
            activeTotal: next.activeEntries.count,
            contextDriftNote: priorReport.map(Self.driftNote(from:))
        )
        next.recentDeltas = Array((next.recentDeltas + [delta]).suffix(MemoryLedger.deltaHistoryCap))
        return (next, delta)
    }

    // MARK: - Helpers

    /// Re-observation: bump lastConfirmed + one confidence step, count the
    /// entry once per iteration (both the confirmed delta and the confidence
    /// step saturate at one per entry per run).
    private func confirm(
        _ entry: inout MemoryEntry,
        iteration: Int,
        newlyConfirmed: inout Set<String>,
        bumped: inout Set<String>
    ) {
        entry.lastConfirmedIteration = iteration
        if bumped.insert(entry.id).inserted {
            entry.confidence = entry.confidence.bumped
        }
        newlyConfirmed.insert(entry.id)
    }

    private static func entry(from candidate: MemoryCandidate, iteration: Int) -> MemoryEntry {
        MemoryEntry(
            id: candidate.id,
            kind: candidate.kind,
            text: candidate.text,
            provenance: MemoryProvenance(
                sessionId: candidate.sessionId,
                timestamp: candidate.timestamp,
                excerptHash: candidate.excerptHash
            ),
            status: .active,
            confidence: .low,
            firstSeenIteration: iteration,
            lastConfirmedIteration: iteration
        )
    }

    /// Near-duplicate: one normalized text contains the other, and the shorter
    /// side is long enough that the containment isn't coincidence.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        guard min(a.count, b.count) >= minContainmentLength else { return false }
        return a.contains(b) || b.contains(a)
    }

    /// The one-line context-drift trend derived from the latest AuditReport —
    /// ties the brain's iteration log to the Context Wiki's bloat measure.
    static func driftNote(from report: AuditReport) -> String {
        "context surfaces at last audit: \(report.metrics.duplicateBlocks.count) duplicated block(s), ~\(report.totalReclaimableLines) reclaimable line(s), top severity \(report.topSeverity.rawValue)"
    }
}
