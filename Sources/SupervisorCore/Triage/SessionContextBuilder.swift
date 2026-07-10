// SessionContextBuilder.swift - v0.2.0 M2b.
//
// Factored OUT of Dispatcher.dispatchForIdleSession so the Dispatcher
// (single-step fallback) and the Planner (multi-step decomposition) build
// the SAME SessionContext from the SAME sources, rather than each keeping
// its own copy of the fetch/read wiring. There is one place that knows how
// to assemble the bundle: here.
//
// The bundle it produces:
//   - open issues  (gh, via the injected IssueFetching; [] on failure)
//   - recent pull requests (gh, via PRFetching; [] on failure or nil fetcher)
//   - branch commits (git, via BranchCommitFetching; [] on failure)
//   - recent dispatch proposals (DispatchHistoryReading; [] if no reader)
//   - Known Gaps  (trial-notes.md in the cwd; "" if absent)
//   - the session objective (the opening user prompt, via SessionObjective)
//   - PRODUCT-DIRECTION.md (cwd repo root; "" if absent)
//
// Every source degrades to empty rather than throwing, exactly as the
// Dispatcher did inline, so neither consumer can crash on a wedged gh /
// git / missing file. `traceTag` lets each caller keep its own trace
// channel ("dispatch" vs "plan") while sharing the assembly.

import Foundation

/// Builds a `SessionContext` from the live session + repo state. Pure
/// namespace; the concrete fetchers/readers are injected so tests can stub
/// them (and a nil fetcher yields the empty-source behavior).
public enum SessionContextBuilder {

    /// Assemble the context bundle. Concurrently fetches issues + commits
    /// (both swallow errors into empty arrays), then reads the synchronous
    /// best-effort sources (recent proposals, Known Gaps, objective,
    /// product direction). Never throws.
    public static func build(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent],
        priorDispatchesConsidered: Int = 0,
        issueFetcher: (any IssueFetching)?,
        commitFetcher: (any BranchCommitFetching)?,
        prFetcher: (any PRFetching)? = nil,
        dispatchHistory: (any DispatchHistoryReading)?,
        trace: TraceLog,
        traceTag: String
    ) async -> SessionContext {
        // Concurrent fetches. Both swallow errors into empty arrays so the
        // build proceeds even when gh / git misbehave; trace tags from the
        // fetchers already discriminate the reason.
        async let issuesFut: [DispatchIssue] = {
            guard let fetcher = issueFetcher, let cwd = cwd else { return [] }
            do {
                return try await fetcher.fetchOpenIssues(cwd: cwd)
            } catch {
                trace.emit(traceTag, "gh fetch threw, proceeding with empty issues: \(error)")
                return []
            }
        }()
        async let commitsFut: [DispatchCommit] = {
            guard let fetcher = commitFetcher,
                  let cwd = cwd,
                  let branch = gitBranch else { return [] }
            do {
                return try await fetcher.fetchBranchCommits(
                    cwd: cwd, branch: branch, baseBranch: "main"
                )
            } catch {
                trace.emit(traceTag, "git log threw, proceeding with empty commits: \(error)")
                return []
            }
        }()
        // Recent pull requests (open + merged). `gh` resolves the repo from the
        // git remote at cwd, so this works for any user/repo. A nil fetcher
        // yields [] (no PR section), exactly like a nil issue fetcher.
        async let prsFut: [DispatchPullRequest] = {
            guard let fetcher = prFetcher, let cwd = cwd else { return [] }
            do {
                return try await fetcher.fetchRecentPullRequests(cwd: cwd)
            } catch {
                trace.emit(traceTag, "gh pr list threw, proceeding with empty PRs: \(error)")
                return []
            }
        }()
        let issues = await issuesFut
        let commits = await commitsFut
        let prs = await prsFut

        // Recent proposals this loop already produced for THIS session, so the
        // consumer (and the deterministic backstop) can avoid re-proposing them.
        // Synchronous + best-effort: a nil reader or a read error yields [].
        let recentProposals = dispatchHistory?.recentProposalHeads(
            sessionId: sessionUUID, limit: 6
        ) ?? []

        // The session's standing work record, so the consumer reasons against
        // the REAL backlog instead of fabricating work when issues/commits give
        // no clear move.
        let knownGaps = cwd.flatMap { $0.isEmpty ? nil : readKnownGaps(cwd: $0) } ?? ""

        // The session's objective (its opening prompt) - the through-line the
        // consumer drives toward.
        let objective = SessionObjective.read(sessionId: sessionUUID)
        if let objective {
            trace.emit(traceTag, "objective session=\(sessionUUID) bytes=\(objective.utf8.count)")
        }

        // PRODUCT-DIRECTION.md from the cwd repo root - the project's north star.
        let productDirection = cwd.flatMap { c -> String? in
            guard !c.isEmpty else { return nil }
            return try? String(contentsOf: URL(fileURLWithPath: c)
                .appendingPathComponent("PRODUCT-DIRECTION.md"), encoding: .utf8)
        } ?? ""

        return SessionContext(
            sessionUUID: sessionUUID,
            cwd: cwd,
            gitBranch: gitBranch,
            lastNTurns: lastNTurns,
            openIssues: issues,
            currentBranchCommits: commits,
            recentPullRequests: prs,
            priorDispatchesConsidered: priorDispatchesConsidered,
            productDirection: productDirection,
            objective: objective,
            knownGaps: knownGaps,
            recentDispatchProposals: recentProposals
        )
    }
}
