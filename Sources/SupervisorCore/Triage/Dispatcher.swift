// Dispatcher.swift — v0.4.0 Part B.
//
// Second-stage call for the worker_idle_post_completion flag.
//
// The primary triage call (record_triage in TriagePrompt.swift) decides
// WHETHER the worker is idle on an autonomous branch — a yes/no question
// the rubric body answers from a small context window. The Dispatcher
// answers the next question: now that we know the worker is idle, what
// task should it pick up next, and what prompt do we type into Claude
// Code's input to start it?
//
// That second question needs a much larger context than the triage
// rubric: PRINCIPLES.md (~28k chars), the session's last 10 turns,
// the current branch's commits, the open GitHub issue queue. So the
// design is two separate Haiku calls — keeps the triage rubric small
// and stateless, lets the Dispatcher carry the dispatch-shaped
// context. Same factoring as QuestionAnswerer's split from the
// primary triage call in v0.3.0.
//
// The Dispatcher's voice and constraints:
//
//   - It picks from documented work (open issues, mechanical
//     follow-on from recent commits). It does NOT invent feature
//     scope per §1d "file an issue, don't build the feature now."
//   - It returns confidence based on how clear the next task is,
//     not how plausible. PRINCIPLES §3a: write the asymmetry note
//     in the justification.
//   - It writes the next_task_proposal in the autonomous opener's
//     voice (§5 engineering-decisions-are-yours; §11 voice/tone).
//     The proposal IS the prompt that gets injected — it reads
//     like a session-opener written by Mohammed, not like LLM
//     output addressed to a user.
//
// Cost envelope (PRINCIPLES §9e): one dispatch is ~4-6k input + ~500
// output tokens against Haiku 4.5 → ~$0.005-0.008 per fire. With the
// idleReTriageIntervalSeconds=60s gate from Part A, even a continuously
// idle session caps at one dispatch/minute = $0.30/hr. Well under the
// $0.50 autonomous envelope.

import Foundation

// MARK: - Result types

/// Outcome of one Dispatcher call. The router branches on this:
/// `.ready` with confidence=.high triggers an inject; confidence=.medium
/// triggers a propose-and-wait banner; `.lowConfidence` triggers a
/// surface-the-idle-state banner; `.error` degrades to notify with the
/// underlying error as the trace reason.
public enum DispatchResult: Sendable, Equatable {
    /// The Dispatcher picked a task. `prompt` is the body to inject;
    /// `justification` lands in the trace + the asymmetry note;
    /// `confidence` decides whether to inject (.high) or surface
    /// (.medium). The router never injects on .medium — the spec's
    /// "propose and wait" path from Part A.
    ///
    /// `priorDispatchesEchoed` carries Haiku's read of the
    /// `prior_dispatches_considered` input — useful for the trace
    /// post-mortem to confirm Haiku saw the loop-state signal. nil
    /// when Haiku didn't echo it back (likely when Part C hasn't
    /// instrumented the engine yet).
    case ready(
        prompt: String,
        justification: String,
        confidence: DispatchConfidence,
        selectedPath: SelectedPath,
        selectedIssueNumber: Int?,
        priorDispatchesEchoed: Int?,
        requiresHumanPresence: Bool
    )
    /// The Dispatcher saw the idle state but couldn't pick a task
    /// with enough confidence to dispatch OR propose. `reasoning`
    /// surfaces in the banner so the user knows WHY supervisor went
    /// quiet rather than just hanging.
    case lowConfidence(reasoning: String)
    /// The Dispatcher itself errored — network, parse failure, etc.
    /// The router degrades to a plain notify; the error string lands
    /// in the trace.
    case error(reasoning: String)
    /// The session objective is complete. The loop stops cleanly (success) —
    /// the engine ends the loop on this rather than waiting for the
    /// 3-consecutive-low backstop. `summary` is the model's one-line account of
    /// what was built, for the trace + the "done" banner.
    case objectiveComplete(summary: String)

    public static func == (lhs: DispatchResult, rhs: DispatchResult) -> Bool {
        switch (lhs, rhs) {
        case let (.ready(p1, j1, c1, sp1, n1, e1, h1), .ready(p2, j2, c2, sp2, n2, e2, h2)):
            return p1 == p2 && j1 == j2 && c1 == c2 && sp1 == sp2 && n1 == n2 && e1 == e2 && h1 == h2
        case let (.lowConfidence(r1), .lowConfidence(r2)):
            return r1 == r2
        case let (.error(r1), .error(r2)):
            return r1 == r2
        case let (.objectiveComplete(s1), .objectiveComplete(s2)):
            return s1 == s2
        default:
            return false
        }
    }
}

public enum DispatchConfidence: String, Sendable, Equatable {
    case high
    case medium
    case low
}

/// Which of the two dispatch paths the Dispatcher picked (per spec B3).
/// `continue_branch` = mechanical follow-on from the current branch
/// (missing tests for new code, missing CHANGELOG, etc.).
/// `transition_to_issue` = jump to a sized issue from the queue.
/// `low_confidence_no_action` = no clear next task; surface to user.
public enum SelectedPath: String, Sendable, Equatable {
    case continueBranch = "continue_branch"
    case transitionToIssue = "transition_to_issue"
    case lowConfidenceNoAction = "low_confidence_no_action"
    /// The session objective is already met by the work so far — the loop should
    /// stop (success), not pick another task. Distinct from
    /// low_confidence_no_action ("couldn't pick") — this is "nothing left to
    /// pick, the thing is built." (Swift dispatcher only; the Python hook's
    /// schema doesn't include it, so it never emits it.)
    case objectiveComplete = "objective_complete"
}

// MARK: - Session context

/// The bundle the Dispatcher needs to make its call. The TriageEngine
/// assembles this at idle-flag time and hands it to the Dispatcher; the
/// Dispatcher is pure with respect to the bundle.
/// Read-only access to the recent `next_task_proposal` heads the dispatcher
/// already produced for a session. Injected into the Dispatcher so it can see
/// — and not re-propose — work it dispatched earlier this run. Without this the
/// dispatcher is amnesiac: it re-reads the same Known Gaps / Issues every cycle
/// and re-proposes already-completed work (the stale-loop failure the owner
/// hit — "calibrate Issue #12" dispatched three times). `LoopDispatchStore`
/// conforms in production; tests pass a canned array or nil.
public protocol DispatchHistoryReading: Sendable {
    /// Recent ready-dispatch proposal heads for `sessionId`, newest first.
    /// Implementations skip low-confidence / error rows (they carry no
    /// proposal). At most `limit` entries.
    func recentProposalHeads(sessionId: String, limit: Int) -> [String]
}

public struct SessionContext: Sendable {
    public let sessionUUID: String
    public let cwd: String?
    public let gitBranch: String?
    /// Last ~10 turns from the session's rolling window. Used to
    /// surface "what did the worker just finish" to the Dispatcher.
    public let lastNTurns: [SupervisorEvent]
    /// Open issues from `gh issue list`. Empty array on fetch
    /// failure or gh not installed.
    public let openIssues: [DispatchIssue]
    /// Commits on this branch since it diverged from main. Empty on
    /// fetch failure or non-repo.
    public let currentBranchCommits: [DispatchCommit]
    /// How many dispatches the loop has already issued in this run.
    public let priorDispatchesConsidered: Int
    /// PRODUCT-DIRECTION.md content — the project's north star.
    /// Empty string if the file doesn't exist.
    public let productDirection: String
    /// The session's objective — the user's opening ask, read from the
    /// transcript. The through-line the loop drives toward: the dispatcher picks
    /// the next concrete step toward THIS, not merely a local follow-on. nil when
    /// no opening prompt is found (the loop falls back to local reasoning).
    public let objective: String?
    /// Known Gaps section from trial-notes.md — standing record of
    /// unfinished, unticketed, or blocked work.
    public let knownGaps: String
    /// TODO/FIXME markers from source files.
    public let sourceMarkers: [String]
    /// `git diff --stat main..HEAD` output lines.
    public let recentFilesChanged: [String]
    /// Proposal heads the dispatcher already produced this run (newest
    /// first). Surfaced to the model so it doesn't re-propose them, and used
    /// by the deterministic `stalenessRejection` backstop. Empty for a fresh
    /// loop or when no history reader is wired.
    public let recentDispatchProposals: [String]

    public init(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent],
        openIssues: [DispatchIssue],
        currentBranchCommits: [DispatchCommit],
        priorDispatchesConsidered: Int = 0,
        productDirection: String = "",
        objective: String? = nil,
        knownGaps: String = "",
        sourceMarkers: [String] = [],
        recentFilesChanged: [String] = [],
        recentDispatchProposals: [String] = []
    ) {
        self.sessionUUID = sessionUUID
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.lastNTurns = lastNTurns
        self.openIssues = openIssues
        self.currentBranchCommits = currentBranchCommits
        self.priorDispatchesConsidered = priorDispatchesConsidered
        self.productDirection = productDirection
        self.objective = objective
        self.knownGaps = knownGaps
        self.sourceMarkers = sourceMarkers
        self.recentFilesChanged = recentFilesChanged
        self.recentDispatchProposals = recentDispatchProposals
    }
}

/// A GitHub issue as seen by the Dispatcher. Mirrors the JSON shape
/// returned by `gh issue list --json number,title,body,labels` so the
/// IssueFetcher can decode directly. Labels carried as strings.
public struct DispatchIssue: Sendable, Equatable, Codable {
    public let number: Int
    public let title: String
    public let body: String
    public let labels: [String]

    public init(number: Int, title: String, body: String, labels: [String]) {
        self.number = number
        self.title = title
        self.body = body
        self.labels = labels
    }

    /// Match the gh JSON: labels arrive as `[{"name": "..."}, ...]`.
    /// We flatten to a string array at decode time so the Dispatcher
    /// prompt sees `bug, v0.4.0` rather than nested objects.
    enum CodingKeys: String, CodingKey {
        case number, title, body, labels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.number = try c.decode(Int.self, forKey: .number)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = (try? c.decode(String.self, forKey: .body)) ?? ""
        if let raw = try? c.decode([[String: String]].self, forKey: .labels) {
            self.labels = raw.compactMap { $0["name"] }
        } else {
            self.labels = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        try c.encode(labels.map { ["name": $0] }, forKey: .labels)
    }
}

/// One commit on the current branch since divergence from main. The
/// Dispatcher uses these to spot mechanical follow-on (e.g. "you just
/// added a feature but no CHANGELOG entry").
public struct DispatchCommit: Sendable, Equatable {
    public let sha: String
    public let subject: String
    public let body: String

    public init(sha: String, subject: String, body: String) {
        self.sha = sha
        self.subject = subject
        self.body = body
    }
}

// MARK: - The Dispatcher

/// Protocol for the engine-facing Dispatcher surface. Concrete impl
/// is `Dispatcher`; tests inject a mock that returns canned results.
public protocol Dispatching: Sendable {
    /// Assemble a SessionContext (fetches issues + commits internally)
    /// and run the Dispatcher call. Engine calls this on every idle
    /// fire; returns the structured result that the engine maps onto
    /// the TriageCandidate before handing to the router.
    ///
    /// `priorDispatchesConsidered` is the loop control's count of
    /// prior dispatches in this run (Part C populates this from the
    /// `loop_dispatches` table; 0 until then). The Dispatcher prompt
    /// uses it to weight thrashing detection.
    func dispatchForIdleSession(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent],
        priorDispatchesConsidered: Int
    ) async -> DispatchResult
}

extension Dispatching {
    /// Default arg = 0 keeps every existing call site source-compatible.
    /// New Part C callers pass an actual count; everyone else gets the
    /// fresh-context behavior.
    public func dispatchForIdleSession(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent]
    ) async -> DispatchResult {
        await dispatchForIdleSession(
            sessionUUID: sessionUUID,
            cwd: cwd,
            gitBranch: gitBranch,
            lastNTurns: lastNTurns,
            priorDispatchesConsidered: 0
        )
    }
}

public final class Dispatcher: Dispatching, Sendable {

    private let client: LLMClient
    private let fallbackPrinciplesText: String
    private let principlesPath: URL?
    private let issueFetcher: (any IssueFetching)?
    private let commitFetcher: (any BranchCommitFetching)?
    private let dispatchHistory: (any DispatchHistoryReading)?
    private let grounder: (any ProposalGrounding)?
    private let trace: TraceLog

    /// `principlesText` is the fallback PRINCIPLES.md body. If
    /// `principlesPath` is provided, the Dispatcher re-reads from disk
    /// on each dispatch call so a 4-hour loop picks up edits. The disk
    /// read (~28k, <1ms on SSD) is cheap relative to the Haiku call.
    /// Falls back to the constructor text if the file read fails.
    ///
    /// `issueFetcher` and `commitFetcher` are optional: if nil, the
    /// dispatcher proceeds with empty context for that source.
    public init(
        client: LLMClient,
        principlesText: String,
        principlesPath: URL? = nil,
        issueFetcher: (any IssueFetching)? = nil,
        commitFetcher: (any BranchCommitFetching)? = nil,
        dispatchHistory: (any DispatchHistoryReading)? = nil,
        grounder: (any ProposalGrounding)? = nil,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.fallbackPrinciplesText = principlesText
        self.principlesPath = principlesPath
        self.issueFetcher = issueFetcher
        self.commitFetcher = commitFetcher
        self.dispatchHistory = dispatchHistory
        self.grounder = grounder
        self.trace = trace
    }

    /// Read PRINCIPLES.md from disk if a path is set, falling back to
    /// the constructor-provided text. Re-reads on every dispatch so
    /// long-running loops pick up edits.
    private var principlesText: String {
        guard let path = principlesPath,
              let fresh = try? String(contentsOf: path, encoding: .utf8),
              !fresh.isEmpty else {
            return fallbackPrinciplesText
        }
        return fresh
    }

    /// Engine-facing entry point. Concurrently fetches issues + commits
    /// (each with its own timeout/cache, both degrade silently to empty
    /// arrays on failure), assembles SessionContext, then runs the
    /// Haiku dispatch call.
    public func dispatchForIdleSession(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent],
        priorDispatchesConsidered: Int
    ) async -> DispatchResult {
        // Concurrent fetches. Both swallow errors into empty arrays so
        // the dispatch proceeds even when gh / git misbehave; trace
        // tags from the fetchers already discriminate the reason.
        async let issuesFut: [DispatchIssue] = {
            guard let fetcher = self.issueFetcher, let cwd = cwd else { return [] }
            do {
                return try await fetcher.fetchOpenIssues(cwd: cwd)
            } catch {
                self.trace.emit("dispatch", "gh fetch threw, proceeding with empty issues: \(error)")
                return []
            }
        }()
        async let commitsFut: [DispatchCommit] = {
            guard let fetcher = self.commitFetcher,
                  let cwd = cwd,
                  let branch = gitBranch else { return [] }
            do {
                return try await fetcher.fetchBranchCommits(
                    cwd: cwd, branch: branch, baseBranch: "main"
                )
            } catch {
                self.trace.emit("dispatch", "git log threw, proceeding with empty commits: \(error)")
                return []
            }
        }()
        let issues = await issuesFut
        let commits = await commitsFut
        // Recent proposals this loop already produced for THIS session, so the
        // model (and the deterministic backstop) can avoid re-proposing them.
        // Synchronous + best-effort: a nil reader or a read error yields [].
        let recentProposals = dispatchHistory?.recentProposalHeads(
            sessionId: sessionUUID, limit: 6
        ) ?? []
        // Read the session's standing work record so the loop proposes the REAL
        // backlog instead of fabricating a task when issues/commits give no
        // clear move. Without this the in-app dispatcher's knownGaps was always
        // empty (only the Python hook read it).
        let knownGaps = cwd.flatMap { $0.isEmpty ? nil : readKnownGaps(cwd: $0) } ?? ""

        // The session's objective (its opening prompt) — the through-line the
        // dispatcher drives toward, so it proposes the next step toward what the
        // user actually asked for, not merely a local follow-on.
        let objective = SessionObjective.read(sessionId: sessionUUID)
        if let objective {
            trace.emit("dispatch", "objective session=\(sessionUUID) bytes=\(objective.utf8.count)")
        }
        // Fold-in fix (§1c): the in-app dispatcher never populated
        // productDirection, so it never read PRODUCT-DIRECTION.md (only the
        // Python hook did). Read it from the cwd repo root, like knownGaps, so
        // the in-app dispatcher reasons against the project's north star too.
        let productDirection = cwd.flatMap { c -> String? in
            guard !c.isEmpty else { return nil }
            return try? String(contentsOf: URL(fileURLWithPath: c)
                .appendingPathComponent("PRODUCT-DIRECTION.md"), encoding: .utf8)
        } ?? ""
        let context = SessionContext(
            sessionUUID: sessionUUID,
            cwd: cwd,
            gitBranch: gitBranch,
            lastNTurns: lastNTurns,
            openIssues: issues,
            currentBranchCommits: commits,
            priorDispatchesConsidered: priorDispatchesConsidered,
            productDirection: productDirection,
            objective: objective,
            knownGaps: knownGaps,
            recentDispatchProposals: recentProposals
        )
        return await dispatch(context: context)
    }

    /// Pick the next task for an idle worker and produce the prompt to
    /// inject. Returns a structured `DispatchResult`; the caller (router)
    /// decides what to do with each case. Never throws — all errors land
    /// in `.error(reasoning:)` so the dispatch call cannot crash the
    /// engine.
    public func dispatch(context: SessionContext) async -> DispatchResult {
        let req = AnthropicMessageRequest(
            model: client.provider.defaultTriageModel,
            max_tokens: 8192,
            system: Self.systemPrompt,
            messages: [
                .init(role: "user", content: .string(Self.userMessage(
                    context: context,
                    principles: principlesText
                )))
            ],
            tools: [Self.recordDispatchTool],
            tool_choice: .forced(Self.recordDispatchToolName)
        )

        trace.emit("dispatch", "haiku call started session=\(context.sessionUUID) issues=\(context.openIssues.count) commits=\(context.currentBranchCommits.count) turns=\(context.lastNTurns.count)")

        let resp: AnthropicMessageResponse
        do {
            resp = try await client.createMessage(req)
        } catch {
            trace.emit("dispatch", "ERROR haiku call failed: \(error)")
            return .error(reasoning: "Haiku call failed: \(error)")
        }

        trace.emit("dispatch", "haiku returned model=\(resp.model) input=\(resp.usage.input_tokens) output=\(resp.usage.output_tokens) stop_reason=\(resp.stop_reason ?? "(nil)")")

        guard let parsed = Self.parseDispatchResult(from: resp) else {
            // Diagnostic: dump content block types + first 300 chars of any
            // tool_use input so we can see truncated JSON from max_tokens hits.
            let contentSummary = resp.content.map { "\($0.type):\($0.name ?? "-")" }.joined(separator: ", ")
            let rawHead = resp.content.first.flatMap { block -> String? in
                guard let input = block.input else { return nil }
                let s = String(describing: input)
                return String(s.prefix(300))
            } ?? "(no input)"
            trace.emit("dispatch", "ERROR parse failed stop_reason=\(resp.stop_reason ?? "(nil)") content=[\(contentSummary)] input_head=\"\(rawHead)\"")
            return .error(reasoning: "Dispatcher did not return a parseable record_dispatch call. stop_reason=\(resp.stop_reason ?? "(nil)")")
        }

        // Defensive: if the model returned confidence=.low OR
        // selectedPath=.lowConfidenceNoAction, normalize to .lowConfidence
        // regardless of what next_task_proposal says — the router
        // shouldn't inject a half-confidence proposal.
        switch parsed {
        case let .ready(prompt, justification, _, .objectiveComplete, _, _, _):
            // The model judged the session objective MET. Terminal success,
            // regardless of confidence — completion is a judgment, not a task to
            // dispatch, so it wins over the low-confidence normalization below.
            // summary prefers the proposal field (where the prompt asks for the
            // one-line account), falling back to the justification.
            let summary = prompt.isEmpty ? justification : prompt
            trace.emit("dispatch", "objective_complete summary=\"\(summary.prefix(160))\"")
            return .objectiveComplete(summary: summary)
        case let .ready(_, justification, .low, _, _, _, _):
            trace.emit("dispatch", "low-confidence dispatch path=\(parsed.selectedPathDescription) reasoning=\"\(justification.prefix(160))\"")
            return .lowConfidence(reasoning: justification)
        case let .ready(_, justification, _, .lowConfidenceNoAction, _, _, _):
            trace.emit("dispatch", "low-confidence dispatch (selected_path=low_confidence_no_action) reasoning=\"\(justification.prefix(160))\"")
            return .lowConfidence(reasoning: justification)
        case let .ready(prompt, justification, confidence, path, issueN, priorEchoed, requiresHuman):
            // ROOT-CAUSE PREMISE VERIFICATION. The in-app loop must not type a
            // proposal whose premise is false in the current tree. The runaway
            // was the dispatcher proposing to BUILD the loop / Dispatcher /
            // triage engine itself — machinery that already exists. The Python
            // Stop-hook grounds its proposals; the in-app loop never did, so it
            // dispatched "build the Dispatcher" raw. A rejected proposal
            // degrades to low-confidence (idle), which also feeds the
            // consecutive-low hard-stop, so a stuck dispatcher STOPS instead of
            // spinning — no manual kill needed.
            if let reject = Self.premiseRejection(proposal: prompt, justification: justification) {
                trace.emit("dispatch", "PREMISE_REJECT \(reject) — degrading to low-confidence idle (proposal builds/wires already-existing machinery)")
                return .lowConfidence(reasoning: "Premise rejected (\(reject)): the proposal builds or wires a component that already exists. Idling instead of dispatching already-done, self-referential work.")
            }
            // STALE-LOOP BACKSTOP. The model is shown its recent proposals (see
            // userMessage) and told not to repeat them, but if it re-proposes a
            // near-duplicate of work it already dispatched this run, degrade to
            // low-confidence. That idles the cycle AND feeds the consecutive-low
            // hard stop, so a stuck-repeating loop STOPS itself instead of
            // re-typing the same task at the worker — the failure the owner saw
            // ("calibrate Issue #12" dispatched three times). The prompt handles
            // re-worded repeats; this catches the case where the model ignores
            // the instruction outright.
            if let stale = Self.stalenessRejection(proposal: prompt, against: context.recentDispatchProposals) {
                trace.emit("dispatch", "STALE_REJECT \(stale) — degrading to low-confidence idle (proposal repeats a recent dispatch)")
                return .lowConfidence(reasoning: "Stale dispatch (\(stale)): this proposal repeats work already dispatched this run. Idling instead of re-typing the same task; if this recurs the consecutive-low stop will pause the loop.")
            }
            // ENV-CLAIM BACKSTOP. The dispatcher must not justify work with a
            // false UNBLOCKING PRECONDITION — "the ANTHROPIC_API_KEY is set;
            // sweeps are unblocked" when the key is absent (the live failure
            // 2026-06-04). Mirror of the Python hook's _ground_environment_claims.
            if let envReject = Self.environmentClaimRejection(proposal: prompt, justification: justification) {
                trace.emit("dispatch", "ENV_CLAIM_REJECT \(envReject) — degrading to low-confidence idle (fabricated unblocking precondition)")
                return .lowConfidence(reasoning: "Environment claim rejected (\(envReject)): the proposal asserts an unblocking precondition (API key / sweep available) that is not true. Idling instead of dispatching blocked work.")
            }
            // TASK 2: CROSS-PROJECT GROUNDING. The proposal must be about THIS
            // session's project. Verify every code symbol it names exists in the
            // repo at the session's cwd; a proposal that references another
            // project's code (a contaminated transcript proposing landing-page
            // work for the supervisor repo) fails to ground and is discarded.
            // Makes transcript contamination inert without scrubbing history.
            if let grounder {
                let cwd = context.cwd ?? ""
                if cwd.isEmpty {
                    trace.emit("dispatch", "CROSS_PROJECT_REJECT reason=no_cwd — cannot ground proposal; discarding")
                    return .lowConfidence(reasoning: "Cannot ground the proposal — this session's cwd is unresolved. Idling rather than dispatching ungrounded work.")
                }
                let missing = await grounder.missingSymbols(inProposal: prompt, cwd: cwd)
                if !missing.isEmpty {
                    let head = missing.prefix(5).joined(separator: ",")
                    trace.emit("dispatch", "CROSS_PROJECT_REJECT cwd=\(cwd) missing_symbols=\(head) — proposal names code absent from this session's repo; discarding")
                    return .lowConfidence(reasoning: "Cross-project proposal rejected: it references \(head), which does not exist in this session's repo (\(cwd)). Idling instead of dispatching another project's work into this session.")
                }
                // DEPLOY-STATE grounding: a proposal that justifies itself by
                // citing commits ("commit abc123 shipped X / was never
                // deployed") must reference REAL commits. A fabricated hash is a
                // fabricated premise (the 2026-06-07 "deploy the already-deployed
                // kill-catch" dispatch cited two hashes that don't exist). Check
                // proposal + justification — the deploy-state claim lives there.
                let badCommits = await grounder.missingCommits(inText: prompt + " " + justification, cwd: cwd)
                if !badCommits.isEmpty {
                    let head = badCommits.prefix(5).joined(separator: ",")
                    trace.emit("dispatch", "DEPLOY_STATE_REJECT cwd=\(cwd) missing_commits=\(head) — proposal cites commits absent from the repo; discarding")
                    return .lowConfidence(reasoning: "Deploy-state claim rejected: the proposal cites commit(s) \(head) that don't exist in this repo — a fabricated 'shipped/deployed/never-deployed' premise. Idling instead of acting on an unverifiable claim.")
                }
            }
            trace.emit("dispatch", "ready confidence=\(confidence.rawValue) path=\(path.rawValue) issue=\(issueN.map(String.init) ?? "-") prior_echoed=\(priorEchoed.map(String.init) ?? "-") requires_human=\(requiresHuman) prompt_bytes=\(prompt.utf8.count) just=\"\(justification.prefix(120))\"")
            return .ready(
                prompt: prompt,
                justification: justification,
                confidence: confidence,
                selectedPath: path,
                selectedIssueNumber: issueN,
                priorDispatchesEchoed: priorEchoed,
                requiresHumanPresence: requiresHuman
            )
        default:
            return parsed
        }
    }

    // MARK: - Prompts

    /// The Dispatcher system prompt. Synced with
    /// `Tools/dispatch-loop-hook/dispatcher-system-prompt.txt` which is
    /// the canonical source for the Python hook path. When editing,
    /// update both. The .txt file is what the Python hook reads at
    /// runtime; this static is what the Swift in-app path uses.
    static let systemPrompt: String = {
        // Resolve the prompt file on ANY checkout. The previous hardcoded
        // /Users/main/... path broke CI — the runner lives under
        // /Users/runner/work/..., so the load silently fell back to the stub
        // and every "prompt must contain X" test failed. `#filePath` is this
        // source file's location at COMPILE time, so we derive the repo root
        // from it portably (works on the runner, the owner's machine, and any
        // future clone). The file is git-tracked, so it's always in-tree.
        let rel = "Tools/dispatch-loop-hook/dispatcher-system-prompt.txt"
        let repoRoot = URL(fileURLWithPath: #filePath)  // <repo>/Sources/SupervisorCore/Triage/Dispatcher.swift
            .deletingLastPathComponent()   // Triage/
            .deletingLastPathComponent()   // SupervisorCore/
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // <repo>/
        let candidates = [
            repoRoot.appendingPathComponent(rel),                                            // any checkout (CI, dev, clone)
            URL(fileURLWithPath: "/Users/main/supervisor/").appendingPathComponent(rel),     // owner's machine, belt-and-suspenders
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(rel),                                                // run-from-repo-root
        ]
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        // Fallback: minimal inline version. Should never fire now that the
        // path is checkout-relative.
        return "You are the dispatcher for an autonomous Claude Code session. Pick the next task and write the prompt. Call record_dispatch exactly once."
    }()

    /// User message — pulls together the live context the system prompt
    /// references. Same pattern as `QuestionAnswerer.engineeringUserMessage`.
    static func userMessage(context: SessionContext, principles: String) -> String {
        var lines: [String] = []

        lines.append("# Session context")
        lines.append("session: \(context.sessionUUID)")
        lines.append("cwd: \(context.cwd ?? "(unknown)")")
        lines.append("branch: \(context.gitBranch ?? "(unknown)")")
        lines.append("")

        lines.append("# Loop state")
        lines.append("prior_dispatches_considered: \(context.priorDispatchesConsidered)")
        lines.append("")

        lines.append("# Proposals you ALREADY dispatched this run (do NOT repeat)")
        if context.recentDispatchProposals.isEmpty {
            lines.append("(none yet — first dispatch of the run)")
        } else {
            lines.append("You already typed these into the worker. Do NOT propose any of them again,")
            lines.append("and do NOT re-word the same task. If the worker pushed back on one as")
            lines.append("already-done, believe it. If the single most useful move you can find")
            lines.append("duplicates one of these, the work is already underway or complete — return")
            lines.append("confidence=low (selected_path=low_confidence_no_action) instead of repeating.")
            for (idx, p) in context.recentDispatchProposals.enumerated() {
                lines.append("\(idx + 1). \(p)")
            }
        }
        lines.append("")

        // Session objective — the through-line, the single most important
        // anchor. Drives the dispatcher toward what the user actually asked for
        // instead of idling when the immediate thread looks done.
        lines.append("# SESSION OBJECTIVE (the user's opening ask — the through-line you are driving toward)")
        lines.append("")
        if let objective = context.objective, !objective.isEmpty {
            lines.append(objective)
            lines.append("")
            lines.append("Your PRIMARY job is to pick the next concrete step that moves toward THIS objective. A step toward the stated objective is grounded work, not invented scope. Treat the objective as unmet until the work it describes is actually built and verified; keep driving the worker toward it rather than idling, unless a safety gate or the human says otherwise.")
            lines.append("")
            lines.append("FIRST judge completion: if the recent transcript and shipped work show the objective is ALREADY met (built and verified), return selected_path=objective_complete with a one-line summary of what was built in next_task_proposal. Do NOT invent a follow-on task past a met objective. Only when it is genuinely unmet do you pick the next step toward it.")
            lines.append("HONOR THE WORKER'S REJECTION: if the recent transcript shows the worker pushed back on a task as already-done, stale, or wrong (e.g. \"that was already deployed three deploys ago\", \"this is the loop re-proposing finished work\"), treat that task as DONE and never re-propose it. The worker rejecting a proposal is the strongest possible signal it must not be dispatched — re-typing it at them is the exact failure to avoid.")
        } else {
            lines.append("(no opening prompt captured — fall back to local reasoning from recent work, PRODUCT-DIRECTION.md, and the backlog)")
        }
        lines.append("")

        // Product direction — the north star
        lines.append("# PRODUCT-DIRECTION.md (where the project is going)")
        lines.append("")
        if !context.productDirection.isEmpty {
            lines.append(context.productDirection)
        } else {
            lines.append("(not found — no PRODUCT-DIRECTION.md in repo root; reason from PRINCIPLES.md and recent work instead)")
        }
        lines.append("")

        lines.append("# Recent commits on this branch (since divergence from main)")
        if context.currentBranchCommits.isEmpty {
            lines.append("(none — either fresh branch, or git fetch failed; treat as 'no commits to follow up on')")
        } else {
            for c in context.currentBranchCommits {
                lines.append("- \(c.sha.prefix(8)) \(c.subject)")
                if !c.body.isEmpty {
                    for line in c.body.split(separator: "\n") {
                        lines.append("  \(line)")
                    }
                }
            }
        }
        lines.append("")

        lines.append("# Recent files changed on this branch (git diff --stat main..HEAD)")
        if context.recentFilesChanged.isEmpty {
            lines.append("(none — either fresh branch, or git diff failed)")
        } else {
            for fl in context.recentFilesChanged {
                lines.append(fl)
            }
        }
        lines.append("")

        // Known Gaps — the standing work record
        lines.append("# Known Gaps (unfinished, unticketed, or blocked work)")
        lines.append("")
        if !context.knownGaps.isEmpty {
            lines.append(context.knownGaps)
        } else {
            lines.append("(no Known Gaps section found in trial-notes.md)")
        }
        lines.append("")

        lines.append("# Open GitHub issues")
        if context.openIssues.isEmpty {
            lines.append("(empty — this is normal; check Known Gaps and source markers for real remaining work)")
        } else {
            for i in context.openIssues {
                let labelTag = i.labels.isEmpty ? "" : " [\(i.labels.joined(separator: ", "))]"
                lines.append("## Issue #\(i.number) — \(i.title)\(labelTag)")
                if !i.body.isEmpty {
                    let trimmed = String(i.body.prefix(600))
                    lines.append(trimmed)
                }
                lines.append("")
            }
        }

        // Source-level markers
        lines.append("# Source markers (TODO/FIXME in recently-touched files)")
        if !context.sourceMarkers.isEmpty {
            for m in context.sourceMarkers {
                lines.append(m)
            }
        } else {
            lines.append("(none found)")
        }
        lines.append("")

        lines.append("# Session's last turns (what the worker just did — 'the screen')")
        if context.lastNTurns.isEmpty {
            lines.append("(no events in window)")
        } else {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for event in context.lastNTurns.suffix(10) {
                let ts = fmt.string(from: event.timestamp)
                lines.append(turnLine(event, ts: ts))
            }
        }
        lines.append("")

        lines.append("# PRINCIPLES.md (the project's operating manual)")
        lines.append("")
        lines.append(principles)
        lines.append("")

        lines.append("# Task")
        lines.append("Call `record_dispatch` exactly once. Choose the single most useful next move that advances the project direction, grounded in the real state of the work. The next_task_proposal you write IS the prompt that gets typed into Claude Code — write it like a senior collaborator giving specific, actionable direction.")

        return lines.joined(separator: "\n")
    }

    /// Compact one-liner for a single event in the recent-turns section.
    /// Mirrors TriagePrompt.eventSummaryLine so the Dispatcher and the
    /// triage paths surface session history in the same shape.
    private static func turnLine(_ event: SupervisorEvent, ts: String) -> String {
        switch event {
        case .sessionStart(let i):
            return "[\(ts)] sessionStart branch=\(i.gitBranch ?? "?")"
        case .userPrompt(let i):
            return "[\(ts)] userPrompt: \(i.text.prefix(240))"
        case .assistantText(let i):
            return "[\(ts)] assistantText: \(i.text.prefix(240))"
        case .bashToolCall(let i):
            return "[\(ts)] bashToolCall: \(i.command.prefix(200))"
        case .bashToolResult(let i):
            return "[\(ts)] bashToolResult error=\(i.isError) bytes=\(i.output.utf8.count)"
        case .systemSignal(let i):
            return "[\(ts)] systemSignal \(i.subtype)"
        }
    }

    // MARK: - Tool schema

    static let recordDispatchToolName = "record_dispatch"

    /// `record_dispatch` — forced tool call shape. Mirrors the spec's
    /// output schema in B3. `next_task_proposal` is empty when
    /// `selected_path == low_confidence_no_action`.
    static var recordDispatchTool: AnthropicTool {
        AnthropicTool(
            name: recordDispatchToolName,
            description: "Record the dispatch verdict: which task to pick up next + the prompt to inject into Claude Code.",
            input_schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "next_task_proposal": .object([
                        "type": .string("string"),
                        "description": .string("The actual prompt to type into Claude Code's input. 150-300 words, written in the autonomous opener's voice — first-person, direct, references PRINCIPLES sections by number, names acceptance criteria, includes a hard-stop reminder. Empty string when selected_path=low_confidence_no_action.")
                    ]),
                    "justification": .object([
                        "type": .string("string"),
                        "description": .string("2-3 sentences. Why this task, why now, what principles ground it. Lands in the trace log + the asymmetry note on the flag.")
                    ]),
                    "confidence": .object([
                        "type": .string("string"),
                        "enum": .array([.string("high"), .string("medium"), .string("low")]),
                        "description": .string("high → auto-dispatch (Supervisor types the prompt into Claude Code). medium → propose-and-wait (banner shows the proposal, user pastes if they want). low → surface the idle state (banner says 'I couldn't pick'). Per PRINCIPLES §9e budget envelope — only auto-dispatch on high.")
                    ]),
                    "selected_path": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("continue_branch"),
                            .string("transition_to_issue"),
                            .string("low_confidence_no_action"),
                            .string("objective_complete"),
                        ]),
                        "description": .string("continue_branch = mechanical follow-on on the current branch; transition_to_issue = pick a sized issue from the queue; low_confidence_no_action = couldn't pick a task, surface to user; objective_complete = the SESSION OBJECTIVE is already met by the work so far, so the loop should stop cleanly (put a one-line summary of what was built in next_task_proposal).")
                    ]),
                    "selected_issue_number": .object([
                        "type": .string("integer"),
                        "description": .string("REQUIRED when selected_path=transition_to_issue; omit otherwise. The issue number from the open queue.")
                    ]),
                    "prior_dispatches_considered": .object([
                        "type": .string("integer"),
                        "description": .string("Optional. Echo back the prior_dispatches_considered value you saw in the input, so the trace post-mortem can confirm you weighed thrashing detection correctly. Default 0 (fresh context). Populated by the engine; absent means the engine isn't yet instrumenting loop state (Part C ships the counter).")
                    ]),
                    "requires_human_presence": .object([
                        "type": .string("boolean"),
                        "description": .string("Set to true ONLY when the task is genuinely impossible for a terminal process — AX permission grants in System Settings, sustained visual observation trials. NOT for rebuilds, tests, commits, script execution, or any shell-executable operation. Default false.")
                    ]),
                ]),
                "required": .array([
                    .string("next_task_proposal"),
                    .string("justification"),
                    .string("confidence"),
                    .string("selected_path"),
                ])
            ])
        )
    }

    // MARK: - Parser

    /// Root-cause premise verification. Returns a rejection reason if the
    /// proposal's premise is false in the current tree, else nil.
    ///
    /// The recurring runaway: the dispatcher proposing to BUILD / WIRE the
    /// dispatch loop, the Dispatcher, the triage engine, the inject path — all
    /// of which already exist — i.e. the loop describing itself as work. This
    /// is the discipline the worker applies by hand ("verify the premise: is
    /// this already done?"), now enforced deterministically so the in-app loop
    /// can never type already-done, self-referential work.
    ///
    /// PRECISE by construction (phrase-anchored, not bag-of-words) so it
    /// rejects "build the Dispatcher" but NEVER "add a test for the
    /// dispatcher" or "fix the dispatcher's grounding" — only a build/wire verb
    /// applied directly to an existing component, or a false "X is not
    /// wired/built/missing" claim about one.
    static func premiseRejection(proposal: String, justification: String) -> String? {
        let text = (proposal + " ⋄ " + justification).lowercased()

        // Core machinery that ALREADY EXISTS in this repo. Proposing to build
        // or wire any of these is a false premise (and the loop's CLOSED rule:
        // it dispatches PRODUCT work, never builds itself).
        let existing = [
            "dispatch loop", "dispatcher", "loopcontroller", "loop controller", "loopconfig",
            "triage engine", "triageengine", "inject path", "injector", "interventionrouter",
            "intervention router", "dispatch engine", "dispatch queue", "self-extender",
            "selfextender", "dispatch hook", "deterministic catch", "deterministiccatch",
            "questionanswerer", "question answerer", "hardcodedrubric",
        ]
        // Build-from-scratch verbs (NOT fix/improve/add-test/review/close — those
        // are legitimate work ON existing code).
        let buildVerbs = ["build ", "implement ", "wire up ", "wire the ", "stand up ",
                          "introduce ", "create the ", "create a ", "write the ", "design the "]
        // Prepositions that, between a build verb and a component, make the
        // component a MODIFIER, not the thing being built ("a test FOR the
        // dispatcher"). Bias toward allowing when one is present.
        let prepositions = [" for ", " of ", " to ", " about ", " on ", " with ", " in ", " into "]
        // False "it's not there" claims directly after a component.
        let missingSuffixes = [" is not wired", " is not built", " is missing", " does not exist",
                              " doesn't exist", " isn't wired", " is not implemented",
                              " is not yet wired", " is not yet built", " needs to be built",
                              " needs to be wired"]

        for comp in existing {
            guard let r = text.range(of: comp) else { continue }
            // Window just BEFORE the component: a build verb here (and no
            // intervening preposition) means the component is the build object.
            // Catches "build the CGEventPost-based Dispatcher" (adjectives in
            // between) but not "build a test for the dispatcher".
            let winStart = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let before = String(text[winStart..<r.lowerBound])
            if buildVerbs.contains(where: { before.contains($0) }),
               !prepositions.contains(where: { before.contains($0) }) {
                return "build_existing(\(comp.replacingOccurrences(of: " ", with: "_")))"
            }
            // Window just AFTER the component: a false "not there" claim.
            let winEnd = text.index(r.upperBound, offsetBy: 18, limitedBy: text.endIndex) ?? text.endIndex
            let after = String(text[r.upperBound..<winEnd])
            if missingSuffixes.contains(where: { after.contains($0) }) {
                return "false_missing(\(comp.replacingOccurrences(of: " ", with: "_")))"
            }
        }
        return nil
    }

    /// Deterministic backstop against the stale-loop failure: the dispatcher
    /// re-proposing work it already dispatched this run. Returns a reason if
    /// `proposal` substantially repeats any entry in `recent` (recent
    /// ready-proposal heads), else nil. A hit degrades the dispatch to
    /// low-confidence — same shape as `premiseRejection` — which idles the
    /// cycle and feeds the consecutive-low hard stop.
    ///
    /// Similarity = Jaccard over prefix-stemmed significant tokens. Threshold
    /// 0.85 — deliberately HIGH, so this is a narrow backstop for near-verbatim
    /// repeats only. The PRIMARY fix is the prompt grounding (it sees the recent
    /// proposals and can tell "do bucket 2" from "re-do bucket 1"); this catches
    /// the case where the model ignores that and re-types essentially the same
    /// proposal. Numbers are kept as identity-bearing tokens, so sequential
    /// numbered work ("bucket 1" vs "bucket 2") stays well under threshold and
    /// is NOT blocked. Both sides need ≥4 significant tokens — too-short heads
    /// are not judged.
    static func stalenessRejection(proposal: String, against recent: [String]) -> String? {
        let target = significantTokens(proposal)
        guard target.count >= 4 else { return nil }
        for prior in recent {
            let priorTokens = significantTokens(prior)
            guard priorTokens.count >= 4 else { continue }
            let overlap = target.intersection(priorTokens).count
            let union = target.union(priorTokens).count
            guard union > 0 else { continue }
            let jaccard = Double(overlap) / Double(union)
            if jaccard >= 0.85 {
                let pct = Int((jaccard * 100).rounded())
                return "\(pct)% overlap with recent dispatch \"\(prior.prefix(56))\""
            }
        }
        return nil
    }

    /// Lowercased, prefix-6 stemmed significant tokens for similarity. Strips
    /// punctuation/markdown and generic stopwords, and collapses morphological
    /// variants crudely via a 6-char prefix so "calibrate"/"calibration" both
    /// stem to "calibr". Numbers are KEPT regardless of length — "12", "2", "7"
    /// carry task identity (Issue #12, bucket 2, step 7), and keeping them is
    /// what lets sequential numbered work stay distinct. Deterministic; no model.
    static func significantTokens(_ s: String) -> Set<String> {
        let cleaned = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : " " }
        let words = String(cleaned).split(separator: " ").map(String.init)
        // Generic loop/instruction filler that carries no task identity.
        let stop: Set<String> = [
            "the", "and", "for", "with", "this", "that", "into", "its", "you",
            "next", "task", "direction", "please", "lets", "let", "then", "run",
            "now", "your", "from", "have", "has", "will", "should", "make", "via",
            "per", "all", "any", "out", "use", "using", "still", "just", "not",
        ]
        return Set(
            words
                .filter { ($0.count >= 3 || $0.allSatisfy(\.isNumber)) && !stop.contains($0) }
                .map { String($0.prefix(6)) }
        )
    }

    /// Deterministic guard against the dispatcher fabricating an UNBLOCKING
    /// PRECONDITION to justify blocked work — the live failure on 2026-06-04:
    /// "The ANTHROPIC_API_KEY is set; calibration sweeps are unblocked" when the
    /// key was absent and the sweep had been blocked all session. Mirror of the
    /// Python hook's `_ground_environment_claims`. Returns a reason if the
    /// proposal asserts the key/sweep is AVAILABLE but `anthropicKey` is empty.
    ///
    /// `anthropicKey` defaults to this process's env, but CAVEAT: Supervisor.app
    /// may launch without the worker's shell env, so absence here isn't proof
    /// the sweep would lack a key. We still reject — the asymmetry favors it: a
    /// false-reject merely declines to AUTO-dispatch an expensive sweep (the
    /// owner can trigger it), while a miss dispatches fabricated-premise work.
    /// The Python hook (worker-env-accurate) is the authoritative check; this is
    /// Supervisor.app's conservative backstop. The param is injectable for tests.
    static func environmentClaimRejection(
        proposal: String,
        justification: String,
        anthropicKey: String? = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    ) -> String? {
        guard assertsEnvironmentAvailability(proposal + " " + justification) else { return nil }
        if (anthropicKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "key/sweep asserted available but ANTHROPIC_API_KEY absent"
        }
        return nil
    }

    /// True if `text` POSITIVELY asserts the API key / live sweep is available.
    /// The required adjacency (subject + is/are/'s + optional adverb + positive
    /// predicate) means the honest negated inverse — "the key is NOT set",
    /// "sweeps are still blocked" — does NOT match, so the guard never fires on
    /// a truthful "it's blocked" statement. Mirrors the Python `_ENV_AVAILABILITY_RE`.
    static func assertsEnvironmentAvailability(_ text: String) -> Bool {
        let pattern = #"(?i)\b(anthropic[_ ]?api[_ ]?key|api[_ ]?key|the key|keys|sweep|sweeps|calibration|live[ -]?api)\b\s+(?:is|are|'s|was|were)\s+(?:now\s+|finally\s+|already\s+)?(set|present|available|configured|enabled|unblocked)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, range: range) != nil
    }

    /// Decode the record_dispatch tool call into a DispatchResult.
    /// Returns nil if the response shape is unusable (no tool call /
    /// missing required fields). The caller maps nil to .error.
    static func parseDispatchResult(from response: AnthropicMessageResponse) -> DispatchResult? {
        for block in response.content {
            guard block.type == "tool_use",
                  block.name == recordDispatchToolName,
                  case let .object(input)? = block.input
            else { continue }

            guard case let .string(proposal)? = input["next_task_proposal"],
                  case let .string(justification)? = input["justification"],
                  case let .string(confStr)? = input["confidence"],
                  case let .string(pathStr)? = input["selected_path"]
            else { return nil }

            let confidence = DispatchConfidence(rawValue: confStr) ?? .low
            let path = SelectedPath(rawValue: pathStr) ?? .lowConfidenceNoAction

            var issueNumber: Int? = nil
            if case let .integer(n)? = input["selected_issue_number"] {
                issueNumber = Int(n)
            }

            var priorEchoed: Int? = nil
            if case let .integer(n)? = input["prior_dispatches_considered"] {
                priorEchoed = Int(n)
            }

            var requiresHuman = false
            if case let .bool(b)? = input["requires_human_presence"] {
                requiresHuman = b
            }

            return .ready(
                prompt: proposal,
                justification: justification,
                confidence: confidence,
                selectedPath: path,
                selectedIssueNumber: issueNumber,
                priorDispatchesEchoed: priorEchoed,
                requiresHumanPresence: requiresHuman
            )
        }
        return nil
    }
}

// MARK: - Selected-path description helper

extension DispatchResult {
    /// Trace-line-friendly description of the selected path.
    var selectedPathDescription: String {
        switch self {
        case let .ready(_, _, _, path, _, _, _): return path.rawValue
        case .lowConfidence: return "low_confidence_no_action"
        case .error: return "error"
        case .objectiveComplete: return "objective_complete"
        }
    }
}
