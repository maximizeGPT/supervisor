// SecondBrainCoordinator.swift — one Second Brain iteration, owned by Core.
//
// The DevTools `second-brain` case used to hold the loop's business rules
// inline (~100 lines): resume-from-latest-persisted-ledger, the honest-
// iteration dry-run rule (a preview still READS the prior ledger so its
// iteration number is real), the drift-note fetch from the latest Context
// Wiki audit, the snapshot -> optimize -> render ordering, and persist-
// after-render. Any second caller (the Mac app, a steward-triggered timer)
// would have had to re-implement that sequence; divergence there corrupts
// the iteration counters and delta history that make the "is the brain
// improving" measurement trustworthy (issue #54 item 2). This type is now
// the single home for those rules; the CLI reduces to argument parsing and
// printing.
//
// Ordering contract (stable across callers):
//   1. read prior ledger + latest audit (best-effort; missing DB = fresh
//      brain — surfaced as a warning only when persistence was requested,
//      never an error)
//   2. snapshot the transcripts (one walk: candidates + live-session
//      evidence)
//   3. optimize into the next ledger
//   4. write artifacts IF the caller asked for files (failure throws —
//      artifacts are the user-visible product of the run)
//   5. persist the iteration row IF asked (failure is a warning — the
//      artifacts already reflect the new state; a retry re-derives it)

import Foundation

public struct SecondBrainCoordinator {
    private let distiller: MemoryDistiller
    private let optimizer: SecondBrainOptimizer
    private let renderer: SecondBrainRenderer

    public init(
        distiller: MemoryDistiller = MemoryDistiller(),
        optimizer: SecondBrainOptimizer = SecondBrainOptimizer(),
        renderer: SecondBrainRenderer = SecondBrainRenderer()
    ) {
        self.distiller = distiller
        self.optimizer = optimizer
        self.renderer = renderer
    }

    /// Everything a caller needs to present the iteration without knowing
    /// the loop's internals.
    public struct IterationResult {
        /// The ledger AFTER this iteration.
        public let ledger: MemoryLedger
        public let delta: IterationDelta
        /// The persisted iteration this run resumed from, nil for a fresh
        /// brain — callers print "resuming from iteration N (M active entries)".
        public let resumedFromIteration: Int?
        /// Active entries in the resumed ledger (the M above), nil when fresh.
        public let resumedActiveEntryCount: Int?
        /// Where artifacts were written, nil when the caller didn't ask.
        public let artifactPaths: (brain: URL, ledgerJSON: URL)?
        /// The `second_brain_ledgers` row id when persisted, nil otherwise.
        public let persistedRowID: String?
        /// Non-fatal problems, in occurrence order, phrased for display.
        public let warnings: [String]
        /// The renderer's console summary for this ledger + delta.
        public let consoleSummary: String
    }

    /// A failed artifact write, carrying everything computed before the
    /// write so callers can still present the iteration (the old CLI
    /// printed the full summary before attempting the write; a caller
    /// catching this preserves that).
    public struct ArtifactWriteFailure: Error {
        public let underlying: Error
        public let consoleSummary: String
        public let resumedFromIteration: Int?
        public let resumedActiveEntryCount: Int?
    }

    /// Run ONE iteration for `root`. `database` nil means no resume and no
    /// persistence (fresh brain each run — the CLI warns before calling).
    /// `artifactsDir` nil means no files are written (dry preview);
    /// non-nil is an explicit request for files, independent of
    /// `persistToDatabase` (matching the CLI's --out / --persist split).
    /// Throws only `ArtifactWriteFailure`.
    public func runIteration(
        root: URL,
        database: SupervisorDatabase?,
        persistToDatabase: Bool,
        artifactsDir: URL?,
        now: Date = Date()
    ) async throws -> IterationResult {
        var warnings: [String] = []

        // 1. Prior state — best-effort: the loop is iterative, so resume
        // from the last persisted ledger and pick up the latest Context
        // Wiki audit for the drift note. A missing DB or row is a fresh
        // brain at iteration 0, never an error.
        var priorLedger = MemoryLedger.empty(root: root.path)
        var priorReport: AuditReport? = nil
        var resumedFrom: Int? = nil
        var resumedActiveCount: Int? = nil
        if let database {
            if let row = try? MemoryLedgerStore(database: database).latest(root: root.path),
               let prior = row.ledger() {
                priorLedger = prior
                resumedFrom = prior.iteration
                resumedActiveCount = prior.activeEntries.count
            }
            if let row = try? ContextAuditStore(database: database).latest(root: root.path) {
                priorReport = row.report()
            }
        }

        // 2 + 3. One transcript walk feeding both loop inputs, then the
        // pure optimize step.
        let snapshot = await distiller.snapshot(root: root)
        let (ledger, delta) = optimizer.optimize(
            ledger: priorLedger,
            candidates: snapshot.candidates,
            liveSessionIds: snapshot.liveSessionIds,
            priorReport: priorReport,
            now: now
        )

        // 4. Artifacts, only when asked. A failed write throws (with the
        // already-computed summary attached, so callers can still present
        // the iteration): the files are the run's user-visible product,
        // and silently succeeding without them would be a dishonest "done".
        let consoleSummary = renderer.consoleSummary(ledger, delta: delta)
        var artifactPaths: (brain: URL, ledgerJSON: URL)? = nil
        if let artifactsDir {
            do {
                let written = try renderer.writeArtifacts(ledger, to: artifactsDir)
                artifactPaths = (written.brainPath, written.ledgerJSONPath)
            } catch {
                throw ArtifactWriteFailure(
                    underlying: error,
                    consoleSummary: consoleSummary,
                    resumedFromIteration: resumedFrom,
                    resumedActiveEntryCount: resumedActiveCount
                )
            }
        }

        // 5. Persist AFTER render, so a persistence failure leaves correct
        // artifacts on disk and a warning, not a half-recorded iteration.
        var persistedRowID: String? = nil
        if persistToDatabase {
            if let database {
                do {
                    let row = try MemoryLedgerStore(database: database).record(ledger, delta: delta)
                    persistedRowID = row.id
                } catch {
                    warnings.append("could not persist iteration: \(error)")
                }
            } else {
                warnings.append("persistence requested but the DB is unavailable — iteration not saved")
            }
        }

        return IterationResult(
            ledger: ledger,
            delta: delta,
            resumedFromIteration: resumedFrom,
            resumedActiveEntryCount: resumedActiveCount,
            artifactPaths: artifactPaths,
            persistedRowID: persistedRowID,
            warnings: warnings,
            consoleSummary: consoleSummary
        )
    }
}
